# Nomad 与 E2B Orchestrator 的关系

本文档解释 Nomad 调度器与 E2B Orchestrator 组件之间的关系。

## 核心结论

**Nomad 是调度器，Orchestrator 是被调度的工作负载** —— 两者是「部署者」与「被部署者」的关系。

Orchestrator 本身 **不使用 Nomad API**，它完全不感知自己运行在 Nomad 之上。

---

## 架构图

```
┌─────────────────────────────────────────────────────────────┐
│                      NOMAD CLUSTER                          │
│                                                             │
│   ┌────────────────┐         ┌────────────────┐             │
│   │  Nomad Server  │◄────────│  Nomad Client  │             │
│   │  (控制平面)     │         │  (每个节点)     │             │
│   └────────────────┘         └───────┬────────┘             │
│                                      │                      │
│                          部署 (raw_exec)                     │
│                                      ▼                      │
│              ┌────────────────────────────────────┐         │
│              │         ORCHESTRATOR               │         │
│              │  • gRPC API 服务                   │         │
│              │  • 直接管理 Firecracker microVM    │         │
│              │  • 沙箱生命周期管理                 │         │
│              │  • 模板缓存                        │         │
│              │  • 网络/存储管理                   │         │
│              │  【不使用 Nomad API】              │         │
│              └────────────────────────────────────┘         │
│                              ▲                              │
│                              │ gRPC                         │
│              ┌───────────────┴───────────────┐              │
│              │          API SERVICE          │              │
│              │  • 使用 Nomad API 发现节点     │              │
│              │  • 路由请求到 Orchestrator     │              │
│              └───────────────────────────────┘              │
└─────────────────────────────────────────────────────────────┘
```

---

## 关系详解

| 方面 | 说明 |
|---|---|
| **Nomad 的角色** | 调度平台，负责在集群中部署和管理 Orchestrator 进程 |
| **Orchestrator 的角色** | Firecracker VM 管理器，直接操作底层虚拟化 |
| **部署方式** | Nomad 将 Orchestrator 作为 `system` 类型 Job 部署（每个节点一个实例） |
| **运行方式** | 使用 `raw_exec` 驱动直接运行二进制（非容器化，需要 root 权限操作 Firecracker） |
| **Orchestrator 是否调用 Nomad API** | **否** —— Orchestrator 完全不感知 Nomad |
| **谁调用 Nomad API** | **API 服务** —— 用于服务发现，找到哪些节点上有 Orchestrator |

---

## Nomad 如何部署 Orchestrator

Orchestrator 以 Nomad **system job** 形式部署，定义在 `iac/modules/job-orchestrator/jobs/orchestrator.hcl`：

```hcl
job "orchestrator-${latest_orchestrator_job_id}" {
  type = "system"    # 每个符合条件的节点运行一个实例
  node_pool = "${node_pool}"
  
  group "client-orchestrator" {
    task "start" {
      driver = "raw_exec"   # 直接运行二进制，非容器化
      config {
        command = "/bin/bash"
        args    = ["-c", "chmod +x local/orchestrator && local/orchestrator"]
      }
      
      # 二进制从云存储下载
      artifact {
        source = "gcs::https://www.googleapis.com/storage/v1/..."
      }
    }
    
    # Nomad 原生服务发现
    service {
      name     = "orchestrator"
      port     = "orchestrator"
      provider = "nomad"
      
      check {
        type     = "http"
        path     = "/health"
        interval = "5s"
        timeout  = "2s"
      }
    }
  }
}
```

**关键特性**：

- `type = "system"`：确保每个节点运行一个实例
- `driver = "raw_exec"`：直接运行二进制，获得完整系统权限（Firecracker 需要）
- `artifact`：Nomad 自动从 GCS/S3 下载二进制
- `service`：注册到 Nomad 服务发现，API 服务可以找到它

---

## API 服务如何发现 Orchestrator

API 服务使用 Nomad API 进行服务发现（代码位于 `packages/api/internal/orchestrator/client.go`）：

```go
func (o *Orchestrator) listNomadNodes(ctx context.Context) ([]nodemanager.NomadServiceDiscovery, error) {
    options := &nomadapi.QueryOptions{
        Filter: "Status == \"ready\" and NodePool == \"default\"",
    }
    nomadNodes, _, err := o.nomadClient.Nodes().List(options.WithContext(ctx))
    // 返回所有运行 Orchestrator 的健康节点
}
```

服务发现过滤器（`packages/shared/pkg/clusters/discovery/nomad.go`）：

```go
var FilterTemplateBuildersAndOrchestrators = NomadQueryFilter(
    "ClientStatus == \"running\" and ((TaskGroup == \"template-manager\"...) or (TaskGroup == \"client-orchestrator\"...))",
)
```

---

## Orchestrator 的核心功能

Orchestrator 直接管理 Firecracker microVM，主要功能包括：

| 功能 | 代码位置 |
|---|---|
| gRPC 服务器 | `packages/orchestrator/internal/server/` |
| Firecracker VM 管理 | `packages/orchestrator/internal/sandbox/fc/` |
| 沙箱生命周期 | `packages/orchestrator/internal/sandbox/` |
| 网络管理 | `packages/orchestrator/internal/sandbox/network/` |
| NBD 存储 | `packages/orchestrator/internal/sandbox/nbd/` |
| 模板缓存 | `packages/orchestrator/internal/sandbox/template/` |

入口点（`packages/orchestrator/main.go`）：

```go
func main() {
    factories.Run(factories.Options{
        Version:       version,
        EgressFactory: defaultEgressFactory,
    })
}
```

---

## 为什么这样设计？

### 1. Firecracker 需要特权操作

创建 VM 需要：
- `/dev/kvm` 访问权限
- 网络命名空间和 iptables 操作
- 块设备挂载
- cgroup 管理

必须使用 `raw_exec` 而非 Docker 容器。

### 2. 职责分离

| 组件 | 职责 |
|---|---|
| **Nomad** | 决定「在哪里运行」—— 节点选择、资源分配、故障恢复 |
| **Orchestrator** | 决定「怎么运行」—— VM 创建、网络配置、存储管理 |

### 3. 弹性和自愈

- Nomad 自动监控 Orchestrator 健康状态
- 崩溃后自动重启
- 节点故障时在其他节点重新调度（对于非 system job）

### 4. 服务发现

Nomad 原生服务发现让 API 能动态感知：
- 哪些节点有 Orchestrator
- 每个 Orchestrator 的地址和端口
- 健康状态

---

## 数据流

```
用户请求
    │
    ▼
┌─────────┐  1. 查询 Nomad API   ┌─────────────┐
│   API   │ ──────────────────► │ Nomad Server │
│ Service │ ◄────────────────── │             │
└────┬────┘  2. 返回节点列表     └─────────────┘
     │
     │ 3. 选择最佳节点（best-of-K 算法）
     │
     │ 4. gRPC 调用
     ▼
┌──────────────┐
│ Orchestrator │
│  (节点 A)    │
└──────┬───────┘
       │
       │ 5. 创建/管理 Firecracker VM
       ▼
┌──────────────┐
│  Firecracker │
│   microVM    │
└──────────────┘
```

---

## 如果不用 Nomad

如果要在自建机房不使用 Nomad，需要替换以下能力：

| Nomad 提供的能力 | 自建替代方案 |
|---|---|
| 进程调度和监控 | systemd / Kubernetes DaemonSet |
| 服务发现 | Consul / etcd / DNS / Kubernetes Service |
| 健康检查和自愈 | systemd watchdog / K8s liveness probe |
| 二进制分发 | 手动部署 / Ansible / 容器镜像 |
| 多节点编排 | Kubernetes / 手动管理 |

### systemd 替代示例

```ini
# /etc/systemd/system/e2b-orchestrator.service
[Unit]
Description=E2B Orchestrator
After=network.target

[Service]
Type=simple
ExecStart=/opt/e2b/orchestrator
Restart=always
RestartSec=5
Environment=STORAGE_PROVIDER=AWSBucket
Environment=TEMPLATE_BUCKET_NAME=e2b-templates
# ... 其他环境变量

[Install]
WantedBy=multi-user.target
```

### 服务发现替代

需要额外组件（如 Consul）或静态配置：

```yaml
# 静态配置示例
orchestrators:
  - host: node1.example.com
    port: 5000
  - host: node2.example.com
    port: 5000
  - host: node3.example.com
    port: 5000
```

---

## 相关文档

- [自建机房部署指南](./self-host-baremetal.md)
- [E2B 本地开发指南](../DEV-LOCAL.md)
- [Nomad System Job 文档](https://developer.hashicorp.com/nomad/docs/schedulers#system)
