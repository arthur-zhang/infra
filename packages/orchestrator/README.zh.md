# Orchestrator 项目概述

Orchestrator 是 E2B 基础设施的核心组件，负责管理和编排 **Firecracker microVM**（微虚拟机）的生命周期。它是一个用 Go 编写的高性能服务，提供沙箱环境的创建、快照、恢复和资源管理。

## 核心职责

1. **VM 生命周期管理** - 创建、启动、暂停、恢复、销毁 Firecracker 虚拟机
2. **快照系统** - 支持 VM 内存和磁盘的快照/恢复，实现快速冷启动
3. **网络管理** - 为每个 VM 配置隔离的网络环境（通过 iptables 和 netlink）
4. **存储管理** - 使用 NBD（Network Block Device）提供块设备支持
5. **模板缓存** - 管理预构建的 VM 模板，加速沙箱创建
6. **资源监控** - 通过 cgroup 进行资源限制和统计

## 架构组成

### 主要模块（pkg/ 目录）

- **sandbox/** - 核心沙箱管理逻辑
  - `fc/` - Firecracker 集成
  - `network/` - 网络配置（IP 分配、路由）
  - `nbd/` - 块设备管理
  - `template/` - 模板缓存和加载
  - `block/` - 块设备 I/O 和缓存
  - `cgroup/` - 资源限制

- **server/** - gRPC 服务端，暴露 orchestrator API
- **tcpfirewall/** - TCP 出口流量代理和防火墙
- **nfsproxy/** - NFS 代理（用于文件系统共享）
- **portmap/** - 端口映射服务
- **hyperloopserver/** - Hyperloop 协议服务器（快速数据传输）
- **template/** - 模板管理服务
- **volumes/** - 卷管理
- **metrics/** - 监控指标收集
- **factories/** - 服务初始化和依赖注入

## 工作流程

```
API 请求 → gRPC Server → Sandbox Manager
                              ↓
                    创建 Firecracker VM
                              ↓
                    配置网络 (network/)
                              ↓
                    挂载存储 (nbd/)
                              ↓
                    加载模板快照 (template/)
                              ↓
                    启动 VM + Envd (in-VM daemon)
                              ↓
                    返回沙箱连接信息
```

## 关键特性

### 快照系统
- 支持内存快照（memfile）和磁盘快照（rootfs）
- 增量快照（基于父快照构建）
- 块级去重和压缩
- 支持本地存储和 GCS 远程存储

### 命令行工具（cmd/ 目录）
- `create-build` - 创建新的 VM 构建/快照
- `resume-build` - 从快照恢复 VM
- `copy-build` - 在存储间复制构建
- `mount-build-rootfs` - 挂载构建的根文件系统
- `inspect-build` - 检查构建元数据
- `show-build-diff` - 显示两个构建的差异

## 技术栈

- **Firecracker** - AWS 开源的轻量级虚拟化技术
- **gRPC** - 服务间通信
- **NBD** - 网络块设备协议
- **Cgroup v2** - 资源隔离和限制
- **OpenTelemetry** - 可观测性（traces/metrics/logs）
- **HugePages** - 2MB 大页内存优化性能

## 运行要求

- **需要 root 权限**（Firecracker 需要）
- **NBD 内核模块**（`modprobe nbd`）
- **HugePages 配置**（用于内存快照）
- **Linux 内核** 支持 netlink、iptables

## 性能优化

这个项目是 E2B 实现"秒级启动隔离代码执行环境"的核心技术，通过快照技术将传统需要几秒的 VM 启动时间压缩到毫秒级。

详细的技术文档请参考：
- [fc 目录技术细节](pkg/sandbox/fc/README.zh.md)

## `make run-local` 执行流程

### 1. Makefile 阶段

```makefile
# 1) 加载 .env.local 中的环境变量
$(call setup_local_env)

# 2) 创建测试用的 volume 目录
mkdir -p ./.data/test-volume

# 3) 以本机 hostname 作为 NODE_ID，启动预编译的二进制
NODE_ID=$(HOSTNAME) ./bin/orchestrator
```

> **前提条件**：需先执行 `make build-local` 编译出 `./bin/orchestrator`。

### 2. Go 入口 — `main.go`

```
main()
  └─ factories.Run(Options{
       Version:       "0.1.0",
       CommitSHA:     commitSHA,       // 编译时通过 ldflags 注入
       EgressFactory: defaultEgressFactory,  // 创建 tcpfirewall
     })
```

`defaultEgressFactory` 利用共享依赖（Logger、Config、Sandboxes 等）创建 **TCP Firewall** 作为出口流量代理。

### 3. `factories/run.go` — `Run()` → `run()`

`Run()` 首先解析配置并创建必要目录，然后进入 `run()` 主函数，按顺序完成以下初始化：

| 阶段 | 说明 |
|------|------|
| **配置解析** | `cfg.Parse()` — 从环境变量读取所有配置项 |
| **目录创建** | `ensureDirs()` — 确保 cache / sandbox / template 等目录存在 |
| **信号处理** | 注册 `SIGINT` / `SIGTERM` / `SIGUSR1` 处理器 |
| **机器信息** | `machineinfo.Detect()` — 检测 CPU 平台，用于 orchestrator 池匹配 |
| **遥测初始化** | OpenTelemetry — traces / metrics / logs |
| **ClickHouse** | 初始化分析事件和主机统计上报 |
| **Feature Flags** | LaunchDarkly 特性开关客户端 |
| **Sandbox 基础设施** | `sandbox.Map`、网络 Slot Pool、cgroup、NBD 服务 |
| **EgressFactory** | 调用 `main.go` 提供的工厂函数，创建 TCP Firewall |
| **模板缓存** | TemplateCache + Peer Client（模板在节点间同步） |
| **NFS Proxy** | Portmapper + NFS 代理（文件系统共享） |
| **网络服务** | cmux 在同一 TCP 端口上复用 gRPC 和 HTTP |
| **HTTP Server** | 提供 `/health` 健康检查端点 和 `/upload` 本地上传端点 |
| **gRPC Server** | 注册 Orchestrator / TemplateManager / Info / Health 服务 |
| **pprof Server** | 独立端口提供性能分析 |

### 4. 主循环

```go
select {
case <-sig.Done():        // 收到 shutdown 信号
case serviceErr := <-serviceError:  // 某个 service 报错
}
```

阻塞等待，直到收到终止信号或某个服务发生致命错误。

### 5. 优雅关闭

1. 将服务状态标记为 **Draining**
2. 等待 Template Manager 排空（如果存在）
3. **逆序关闭** 所有注册的 closers：gRPC → HTTP → cmux → pprof → egress → 其他组件
4. 等待 `errgroup` 中所有 goroutine 完成
5. 清除 lock 文件（仅在非开发模式下）

### 整体流程图

```
make run-local
  │
  ├─ 加载 .env.local
  ├─ mkdir -p .data/test-volume
  └─ NODE_ID=$(hostname) ./bin/orchestrator
       │
       └─ factories.Run()
            ├─ cfg.Parse()           ← 解析配置
            ├─ ensureDirs()          ← 创建目录
            └─ run()
                 ├─ Signal Handler (SIGINT/SIGTERM/SIGUSR1)
                 ├─ machineinfo.Detect()
                 ├─ Telemetry (OpenTelemetry)
                 ├─ ClickHouse / FeatureFlags
                 ├─ sandbox.Map / NetworkSlotPool / cgroup / NBD
                 ├─ EgressFactory → TCP Firewall
                 ├─ TemplateCache / PeerClient
                 ├─ NFS Proxy + Portmapper
                 ├─ cmux Server (复用端口)
                 │    ├─ HTTP: /health, /upload
                 │    └─ gRPC: Orchestrator, TemplateManager, Info, Health
                 ├─ pprof Server
                 │
                 ├─ select { 等待信号或错误 }
                 │
                 └─ Graceful Shutdown (逆序关闭所有组件)
```
