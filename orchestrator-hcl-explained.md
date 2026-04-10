# Orchestrator Nomad HCL 详解

## 1. Job 级别

```hcl
job "orchestrator-${latest_orchestrator_job_id}" {
  type = "system"
  node_pool = "${node_pool}"
  priority = 91
```

- **`type = "system"`**：系统类型 Job，在 `node_pool` 中**每个节点**自动运行一个实例（类似 K8s DaemonSet）
- **Job 名带 `job_id`**：每次更新生成新 Job 名，实现蓝绿部署/滚动更新
- **`priority = 91`**：高优先级（0-100），资源抢占时优先保留 Orchestrator

## 2. Network

```hcl
network {
  port "orchestrator"       { static = "${port}" }
  port "orchestrator-proxy" { static = "${proxy_port}" }
}
```

- **静态端口**：固定绑定端口（如 5008/5009），不让 Nomad 随机分配
- `orchestrator`：gRPC 主服务端口
- `orchestrator-proxy`：反向代理端口，给 Client SDK 连接 sandbox 用

## 3. Constraint

```hcl
constraint {
  attribute = "$${meta.orchestrator_job_version}"
  value     = "${latest_orchestrator_job_id}"
}
```

- **仅非 dev 环境生效**：要求节点的 meta 标签 `orchestrator_job_version` 必须匹配当前 Job ID
- 用途：**滚动更新**——先更新节点 meta，再提交新 Job，旧 Job 因 constraint 不满足自动退出

## 4. Service 注册

```hcl
service {
  name     = "orchestrator"
  provider = "nomad"           # 用 Nomad 原生服务发现，不是 Consul
  check {
    type = "http"
    path = "/health"           # HTTP 健康检查
  }
}
```

- 注册了两个服务：`orchestrator`（HTTP health check）和 `orchestrator-proxy`（TCP check）
- **`provider = "nomad"`**：服务注册在 Nomad 自身，不依赖 Consul 服务发现（Consul 仅用于 KV）

## 5. Task

### Driver

```hcl
driver = "raw_exec"
```

直接在宿主机上运行，**不用容器**。因为 Orchestrator 需要操作 Firecracker、iptables、netlink 等底层系统资源，必须 root 权限直接执行。

### Restart

```hcl
restart { attempts = 0 }
```

失败不自动重启，避免反复崩溃循环。由外部监控告警处理。

### 环境变量（分三类）

| 类别 | 变量 | 说明 |
|---|---|---|
| **节点信息** | `NODE_ID`, `NODE_IP`, `NODE_LABELS` | Nomad 运行时变量 `${node.*}`，标识当前节点 |
| **核心依赖** | `CONSUL_TOKEN`, `REDIS_URL`, `CLICKHOUSE_*` | Consul KV 分配 IP 槽位；Redis 缓存；ClickHouse 分析 |
| **云厂商** | `STORAGE_PROVIDER`, `ARTIFACTS_REGISTRY_*` | 条件渲染：GCP 用 GCS+Artifact Registry，AWS 用 S3+ECR |

### 执行方式

```hcl
artifact {
  source = "${artifact_source}"    # 从 GCS/S3 下载二进制
}
config {
  command = "/bin/bash"
  args    = ["-c", "chmod +x local/orchestrator && local/orchestrator"]
}
```

Nomad 的 `artifact` 先把二进制下载到 `local/` 目录，然后 `chmod +x` 并直接执行。

## 6. `$${...}` vs `${...}` 的区别

- **`${...}`**：Terraform 模板变量，在 `terraform apply` 时渲染（如 `${port}` → `5008`）
- **`$${...}`**：转义后变成 `${...}`，留给 **Nomad 运行时**解析（如 `${node.unique.name}`）

## 7. 整体流程

```
terraform apply → 渲染 HCL 模板 → 提交给 Nomad
→ Nomad 在每个匹配节点上：下载二进制 → 注入环境变量 → 直接执行
→ Orchestrator 启动后连接 Consul KV / Redis / ClickHouse
→ 注册到 Nomad 服务发现，等待 API 层调度 sandbox
```

## 8. Orchestrator 如何注册到 Nomad

**不需要手动注册**，这是 Nomad 自动完成的。

### Job 调度（自动）

当执行 `nomad job run orchestrator.nomad.hcl` 时：

```
nomad job run orchestrator.nomad.hcl
    ↓
type = "system" → Nomad 自动在每个匹配节点上启动一个实例
    ↓
Orchestrator 进程运行在节点上，监听 5008 端口
```

### 服务注册 + 健康检查（自动）

HCL 里的 `service` 块就是注册声明：

```hcl
service {
  name     = "orchestrator"
  port     = "orchestrator"
  provider = "nomad"        # Nomad 自动注册，不需要手动调 API
  check {
    type = "http"
    path = "/health"        # Nomad 定期检查，不健康自动标记
  }
}
```

### API 如何发现 Orchestrator

API 甚至**不依赖 service 注册**，而是直接查 Nomad 节点列表：

```go
// packages/api/internal/orchestrator/client.go
// 调 Nomad API 列出所有 ready 节点
nomadNodes, _, err := o.nomadClient.Nodes().List(filter: "Status == ready")

// 用节点 IP + 固定端口直连
address := fmt.Sprintf("%s:%d", node.Address, 5008)
```

### 总结

只需要执行一条命令：

```bash
nomad job run orchestrator.nomad.hcl
```

剩下的全是自动的：Nomad 调度 → 启动进程 → 注册服务 → 健康检查 → API 通过 Nomad 节点列表发现它。

## 9. 基础设施服务是否需要注册到 Consul

Orchestrator 对 Consul 的**唯一硬依赖**是 KV Store（用于 IP Slot 分配）。其他服务（Redis、PG、ClickHouse）都通过环境变量传入地址，可以选择用 Consul DNS 或直连。

| 组件 | 是否必须注册 Consul | 原因 |
|---|---|---|
| **Consul 自身** | ✅ 必须部署 | Orchestrator 用 KV 做 IP 槽位分配 |
| Redis | ❌ 可选 | 通过 `REDIS_URL` 环境变量传入 |
| PostgreSQL | ❌ 可选 | 通过 `POSTGRES_CONNECTION_STRING` 传入 |
| ClickHouse | ❌ 可选 | 通过 `CLICKHOUSE_CONNECTION_STRING` 传入 |
| Loki/OTEL | ❌ 可选 | 通过环境变量传入 |

自建机房推荐注册到 Consul 统一做服务发现，方便运维；但也可以直接在环境变量里写 IP 地址。
