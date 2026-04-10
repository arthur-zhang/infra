# Consul、Nomad、Orchestrator 的关系

本文档解释 E2B 项目中 Consul、Nomad 和 Orchestrator 三个核心组件之间的关系。

## 核心结论

**Consul 是电话簿（谁在哪），Nomad 是调度员（谁该干什么），Orchestrator 是干活的人（管理虚拟机）。**

Orchestrator 完全不知道自己被 Nomad 调度、被 Consul 注册——它只管接收 gRPC 请求然后操作 Firecracker。

---

## 分层架构

```
┌─────────────────────────────────────────────────────┐
│                    Consul                            │
│              (服务注册与发现)                          │
│                                                     │
│  维护一个服务目录：                                    │
│  "orchestrator-abc123" → node1:5008                 │
│  "orchestrator-abc123" → node2:5008                 │
│  "orchestrator-abc123" → node3:5008                 │
└──────────────────────┬──────────────────────────────┘
                       │ 注册/查询
                       │
┌──────────────────────┴──────────────────────────────┐
│                     Nomad                            │
│               (任务调度器)                             │
│                                                     │
│  决定「在哪台机器上运行什么」                            │
│  - system job: 每个符合条件的节点跑一个 Orchestrator    │
│  - service job: API、Loki、ClickHouse 等             │
│  - 健康检查、崩溃重启、滚动更新                         │
└──────────────────────┬──────────────────────────────┘
                       │ raw_exec 启动
                       │
┌──────────────────────┴──────────────────────────────┐
│                  Orchestrator                        │
│            (Firecracker VM 管理器)                    │
│                                                     │
│  决定「怎么运行虚拟机」                                │
│  - 创建/销毁 Firecracker microVM                     │
│  - 网络配置 (iptables, netlink)                      │
│  - 存储管理 (NBD)                                    │
│  - 快照/恢复 (UFFD)                                  │
│  - 模板缓存                                          │
│  【完全不感知 Nomad 和 Consul 的存在】                 │
└─────────────────────────────────────────────────────┘
```

---

## 各自职责

| | Consul | Nomad | Orchestrator |
|---|---|---|---|
| **定位** | 服务目录 | 调度器 | VM 管理器 |
| **核心能力** | 服务注册、健康检查、KV 存储 | 任务调度、资源分配、故障恢复 | Firecracker 生命周期管理 |
| **感知谁** | 所有注册的服务 | Consul（用于服务注册）| 谁都不感知 |
| **被谁调用** | API 服务（查询节点）、Nomad（注册服务） | Terraform（提交 Job） | API 服务（gRPC 调用） |

---

## 关键交互

### 1. Nomad → Consul：自动服务注册

Nomad Job 定义中声明了 Consul 服务注册（`iac/modules/job-orchestrator/jobs/orchestrator.hcl`）：

```hcl
# orchestrator.hcl
service {
  name     = "orchestrator"
  port     = "orchestrator"
  provider = "consul"        # ← Nomad 自动注册到 Consul

  check {
    type     = "http"
    path     = "/health"
    interval = "5s"
  }
}
```

Nomad 启动 Orchestrator 后，自动把它注册到 Consul 的服务目录。Orchestrator 本身不需要写任何 Consul 相关代码。

### 2. API → Consul：服务发现

API 服务需要知道请求该发给哪个 Orchestrator 节点（`packages/shared/pkg/clusters/discovery/nomad.go`）：

```go
// API 通过查询所有健康的 Orchestrator 节点
FilterTemplateBuildersAndOrchestrators = NomadQueryFilter(
    "ClientStatus == \"running\" and TaskGroup == \"client-orchestrator\"...",
)
```

### 3. API → Orchestrator：gRPC 业务调用

```
用户请求 POST /sandboxes
    ↓
API 查询 Consul → 获取 Orchestrator 节点列表
    ↓
API 用 best-of-K 算法选择最佳节点
    ↓
API 通过 gRPC 调用 Orchestrator.CreateSandbox()
    ↓
Orchestrator 创建 Firecracker VM
```

---

## 完整请求流程

```
┌────────┐
│  用户   │
└───┬────┘
    │ POST /sandboxes
    ▼
┌────────────┐  1. 查询服务目录   ┌──────────┐
│  API 服务   │ ───────────────► │  Consul  │
│  (Gin)     │ ◄─────────────── │          │
└─────┬──────┘  2. 返回节点列表   └──────────┘
      │
      │ 3. 选择最佳节点（best-of-K 算法）
      │
      │ 4. gRPC 调用
      ▼
┌──────────────┐                 ┌──────────┐
│ Orchestrator │ ◄── 部署/监控 ── │  Nomad   │
│  (节点 A)    │                 │          │
└──────┬───────┘                 └──────────┘
       │                              │
       │ 5. 创建 VM                    │ Nomad 启动 Orchestrator 时
       ▼                              │ 自动注册到 Consul
┌──────────────┐                      ▼
│  Firecracker │                 ┌──────────┐
│   microVM    │                 │  Consul  │
└──────────────┘                 └──────────┘
```

---

## 部署拓扑

```
┌─────────────────────────────────────────────────────────────┐
│                     Nomad/Consul 集群                        │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐    │
│  │           Control Plane (3 节点)                     │    │
│  │  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐ │    │
│  │  │ Nomad Server │ │ Nomad Server │ │ Nomad Server │ │    │
│  │  │ Consul Server│ │ Consul Server│ │ Consul Server│ │    │
│  │  └──────────────┘ └──────────────┘ └──────────────┘ │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │  API 节点     │  │  Worker 节点  │  │  Worker 节点  │      │
│  │              │  │              │  │              │      │
│  │ Nomad Client │  │ Nomad Client │  │ Nomad Client │      │
│  │ Consul Agent │  │ Consul Agent │  │ Consul Agent │      │
│  │              │  │              │  │              │      │
│  │ ┌──────────┐ │  │ ┌────────────┐│  │ ┌────────────┐│      │
│  │ │ API 容器 │ │  │ │Orchestrator││  │ │Orchestrator││      │
│  │ └──────────┘ │  │ └──────┬─────┘│  │ └──────┬─────┘│      │
│  │              │  │        │      │  │        │      │      │
│  │              │  │   ┌────▼────┐ │  │   ┌────▼────┐ │      │
│  │              │  │   │FC VM 1  │ │  │   │FC VM 3  │ │      │
│  │              │  │   │FC VM 2  │ │  │   │FC VM 4  │ │      │
│  │              │  │   └─────────┘ │  │   └─────────┘ │      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
└─────────────────────────────────────────────────────────────┘
```

---

## 如果不用 Nomad/Consul

在自建机房中，可以用以下方案替代：

| 能力 | Nomad/Consul 提供 | 替代方案 |
|---|---|---|
| 进程调度和监控 | Nomad system job | systemd / Kubernetes DaemonSet |
| 服务发现 | Consul 服务目录 | etcd / DNS / Kubernetes Service / 静态配置 |
| 健康检查和自愈 | Nomad + Consul health check | systemd watchdog / K8s liveness probe |
| 二进制分发 | Nomad artifact | Ansible / 容器镜像 |
| 多节点编排 | Nomad 调度器 | Kubernetes / 手动管理 |

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

[Install]
WantedBy=multi-user.target
```

### 静态服务发现替代

```yaml
# 不用 Consul 时，API 需要静态配置 Orchestrator 地址
orchestrators:
  - host: node1.example.com
    port: 5008
  - host: node2.example.com
    port: 5008
  - host: node3.example.com
    port: 5008
```

---

## 常见问题

### Q: Orchestrator 为什么不用 Docker 而用 raw_exec？

Firecracker 需要直接访问 `/dev/kvm`、操作 iptables、挂载块设备、管理 cgroup，这些特权操作在 Docker 容器中很难正确配置。`raw_exec` 让 Orchestrator 以 root 权限直接运行在宿主机上。

### Q: Consul 和 Nomad 的服务发现有什么区别？

Nomad 自带简单的服务发现（`provider = "nomad"`），但 Orchestrator 使用 Consul（`provider = "consul"`）因为 Consul 提供更丰富的健康检查、KV 存储和跨数据中心能力。

### Q: 如果 Consul 挂了会怎样？

API 无法发现新的 Orchestrator 节点，但已建立的 gRPC 连接不受影响。已运行的沙箱继续正常工作，只是无法创建新沙箱。

### Q: 如果 Nomad 挂了会怎样？

已运行的 Orchestrator 进程不受影响（它不感知 Nomad）。但如果 Orchestrator 崩溃，Nomad 无法自动重启它。新的部署和更新也无法进行。

---

## 相关文档

- [Terraform 与 Nomad 的关系](./terraform-nomad-relationship.md)
- [Nomad 与 Orchestrator 的关系](./nomad-orchestrator-relationship.md)
- [自建机房部署指南](./self-host-baremetal.md)
- [请求流程](./request-flow.md)
