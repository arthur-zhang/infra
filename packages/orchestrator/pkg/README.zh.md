# Orchestrator pkg 包深度解析

## 1. 概述

`packages/orchestrator/pkg/` 是 E2B Orchestrator 的核心库，包含 Firecracker microVM 编排引擎的所有核心功能实现。它提供了从块设备虚拟化、沙箱生命周期管理到网络安全策略的完整技术栈。

### 整体架构图

```
┌─────────────────────────────────────────────────────────────────┐
│                        gRPC / HTTP Layer                         │
│  ┌──────────┐  ┌────────────────┐  ┌────────────┐  ┌─────────┐ │
│  │  server   │  │ hyperloopserver│  │ healthcheck│  │factories│ │
│  │ (gRPC API)│  │ (VM回调API)    │  │ (健康检查)  │  │(工厂函数)│ │
│  └─────┬─────┘  └───────┬────────┘  └────────────┘  └─────────┘ │
│        │                │                                         │
├────────┼────────────────┼─────────────────────────────────────────┤
│        ▼                ▼          核心引擎                       │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │                      sandbox                               │  │
│  │  ┌────────┐ ┌───────┐ ┌───────┐ ┌──────┐ ┌────────────┐  │  │
│  │  │ block  │ │ build │ │ cgroup│ │ envd │ │  cleanup   │  │  │
│  │  │(块设备) │ │(构建) │ │(资源) │ │(VM内)│ │  (清理)    │  │  │
│  │  └────────┘ └───────┘ └───────┘ └──────┘ └────────────┘  │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                   │
├───────────────────────────────────────────────────────────────────┤
│                      存储与文件系统层                              │
│  ┌──────────┐  ┌──────────┐  ┌─────────┐  ┌──────────────────┐  │
│  │ nfsproxy │  │ chrooted │  │ volumes │  │ template         │  │
│  │ (NFS服务) │  │ (chroot) │  │ (卷管理)│  │ (模板构建)       │  │
│  └──────────┘  └──────────┘  └─────────┘  └──────────────────┘  │
│                                                                   │
├───────────────────────────────────────────────────────────────────┤
│                         网络与安全层                              │
│  ┌──────────────┐  ┌─────────┐  ┌─────────┐  ┌──────────────┐  │
│  │ tcpfirewall  │  │  proxy  │  │ portmap │  │   metrics    │  │
│  │ (出口防火墙)  │  │(反向代理)│  │(端口映射)│  │  (系统指标)   │  │
│  └──────────────┘  └─────────┘  └─────────┘  └──────────────┘  │
│                                                                   │
├───────────────────────────────────────────────────────────────────┤
│                       基础设施层                                  │
│  ┌──────┐  ┌────────┐  ┌─────────┐  ┌──────────┐               │
│  │ cfg  │  │ events │  │ parsing │  │  units   │               │
│  │(配置) │  │ (事件)  │  │ (解析)   │  │(单位转换) │               │
│  └──────┘  └────────┘  └─────────┘  └──────────┘               │
└─────────────────────────────────────────────────────────────────┘
```

### 包依赖关系

```
server ──→ sandbox ──→ block ──→ build
  │           │            └──→ cgroup
  │           └──→ envd
  │           └──→ cleanup
  ├──→ template
  ├──→ nfsproxy ──→ chrooted
  ├──→ proxy
  ├──→ tcpfirewall
  └──→ volumes ──→ chrooted
```

---

## 2. 核心模块详解

### 2.1 sandbox — 沙箱核心引擎

沙箱的生命周期管理中心，协调块设备、网络、cgroup 等子系统。

#### sandbox/block — 块设备虚拟化层

这是整个系统中最性能关键的子包，实现了按需从远程存储加载数据的分层存储系统。

**核心接口：**

```go
// 只读设备接口
type ReadonlyDevice interface {
    Slicer           // 内存映射访问
    SeekableReader   // 可定位读取
}

// 可写设备接口
type Device interface {
    ReadonlyDevice
    WriteAt(p []byte, off int64) (n int, err error)
}
```

**分层架构：**

```
┌───────────────────────────┐
│     Overlay (COW 层)      │ ← 运行时写入
├───────────────────────────┤
│     Tracker (访问追踪)     │ ← 记录访问模式
├───────────────────────────┤
│  Chunker (按需加载层)      │ ← 从远程存储拉取
│  ├─ FullFetchChunker      │    整块获取
│  └─ StreamingChunker      │    流式获取（渐进式通知）
├───────────────────────────┤
│     Local / Empty         │ ← 本地文件或空设备
└───────────────────────────┘
```

**关键实现细节：**

1. **按需分页（Demand Paging）**：不下载整个 rootfs/内存快照，仅在访问时加载对应块
2. **singleflight 去重**：同一块的并发请求只触发一次远程拉取
3. **流式渐进通知**：`StreamingChunker` 在大块数据部分就绪时即通知等待者，而非等待整块完成
4. **Overlay COW**：读取先查本地缓存，缺失时回退到只读基础设备

**Tracker 与 PrefetchTracker：**

```go
// Tracker 使用 bitset 记录哪些块被访问过
type Tracker struct {
    accessed bitset.BitSet
}

// PrefetchTracker 记录访问顺序，用于优化预取
type PrefetchTracker struct {
    accessOrder map[uint64]int  // 块索引 → 访问顺序
}
```

预取优化流程：多次运行 VM → 收集访问模式 → 生成预取映射 → 后续恢复时按顺序预加载热数据块。

#### sandbox/build — 构建与缓存管理

管理构建产物（diff）的持久化存储和缓存淘汰。

**核心类型：**

```go
// DiffStore 管理构建差异的缓存
type DiffStore struct {
    cache *ttlcache.Cache  // 内存级 TTL 缓存
}

// File 跨多个构建虚拟化文件
// 通过 header 映射将读取请求路由到正确的构建层
type File struct {
    header    *Header
    layers    map[string]ReadonlyDevice
}
```

**存储后端：**
- `StorageDiff`：从远程存储（S3/GCS）通过 chunker 拉取
- `LocalDiffFile`：构建过程中使用的临时本地文件

#### sandbox/cgroup — 资源管理

实现 Linux cgroup v2 的 CPU 和内存计量。

```go
type CgroupHandle struct {
    dirFD int  // cgroup 目录文件描述符
}
```

**关键机制：**
- 使用 `CLONE_INTO_CGROUP` 通过目录 FD 将 Firecracker 进程原子性地放入对应 cgroup
- 周期性读取 `cpu.stat`、`memory.current`、`memory.peak` 用于计费和监控
- 提供 `noopManager` 适配无 cgroup 支持的环境（Strategy 模式）

#### sandbox/cleanup — 清理协调器

```go
type Cleanup struct {
    priority []CleanupFunc  // 优先清理项
    standard []CleanupFunc  // 标准清理项
}
```

所有清理函数按 LIFO 顺序执行（后注册的先执行），确保依赖顺序正确。

#### sandbox/envd — VM 内代理通信

通过 HTTP `/init` 端点初始化 VM 内的 envd 代理，发送环境变量、访问令牌和卷挂载配置。使用无限重试策略等待代理启动。

#### sandbox/checks — 健康检查

基于 Ticker 的周期性健康检查，使用原子 CAS 操作实现线程安全的状态转换（Healthy ↔ Unhealthy）。

---

### 2.2 server — gRPC 服务层

Orchestrator 的主 gRPC 服务实现，提供 `SandboxService` 和 `ChunkService`。

**核心操作：**

| RPC | 功能 | 说明 |
|-----|------|------|
| `Create` | 创建/恢复沙箱 | 通过 semaphore 控制并发，防止节点过载 |
| `Pause` | 暂停沙箱 | 创建内存/磁盘快照，异步上传到全局存储 |
| `Checkpoint` | 检查点 | 与 Pause 类似，但可继续运行 |
| `ReadAtBuildSeekable` | P2P 块读取 | 允许其他编排器直接拉取本地缓存的模板块 |

**P2P 模板分发：**

```
Orchestrator A ──(Redis)──→ peerRegistry
                              │
Orchestrator B ←──(gRPC)─────┘
   "我需要 build X 的块 42"
```

使用 Redis 注册本地缓存的模板，其他节点可直接拉取，避免从全局存储下载。

---

### 2.3 nfsproxy — NFS 代理层

为沙箱提供虚拟化的 NFS 文件系统服务。

**请求处理流程：**

```
客户端连接 ──→ onConnect (追踪 span)
    │
    ▼
MOUNT 请求 ──→ NFSHandler.Mount
    │            ├─ 通过源 IP 识别沙箱
    │            ├─ 验证请求的卷在沙箱配置中
    │            └─ 使用 chrooted.Builder 创建隔离文件系统
    │
    ▼
NFS 操作 ──→ 装饰器链
    │
    ├─ Tracing    (OpenTelemetry spans)
    ├─ Metrics    (OTel metrics)
    ├─ Logging    (详细日志)
    ├─ Recovery   (panic 保护)
    │
    ▼
wrappedFS ──→ chrooted 环境中执行系统调用
```

**装饰器模式：** NFS handler 和 billy.Filesystem 接口通过多层装饰器增强功能，每层关注单一横切关注点。

**适配器模式：** `wrappedFS`/`wrappedFile`/`wrappedChange` 将标准 `*os.File` 操作适配到 `go-nfs` 库要求的 `billy` 接口。

---

### 2.4 chrooted — Chroot 隔离环境

基于 Linux mount namespace 和 `pivot_root` 的文件系统隔离。

**实现机制：**

```go
// Builder 根据卷配置创建 chroot 环境
type Builder struct {
    volumePaths map[string]string
}

// Chrooted 表示一个活跃的 chroot 会话
type Chrooted struct {
    root string
    ns   *mountNS  // 私有挂载命名空间
}

// mountNS 通过专用 OS 线程和请求-响应通道管理命名空间
type mountNS struct {
    reqCh chan nsRequest
}
```

**关键流程：**
1. 锁定 OS 线程 → 调用 `unix.Unshare(CLONE_NEWNS)` 创建新挂载命名空间
2. Bind-mount 目标目录 → `pivot_root` 切换根目录
3. 所有文件系统操作通过 `act` 方法在专用线程中执行（Command 模式）

`fs.go` 和 `change.go` 中的方法是标准 `os` 操作（Create, Open, Stat, Chown 等）在私有命名空间内的安全包装。

---

### 2.5 tcpfirewall — TCP 出口防火墙

透明 TCP 代理，对沙箱实施出口安全规则。

**工作原理：**

```
沙箱出站流量
    │
    ▼  iptables REDIRECT
┌──────────────────────┐
│    TCP Firewall       │
│  ┌─────────────────┐ │
│  │ connectionHandler│ │
│  │  ├─ 80  → HTTP  │ │  peek 请求头获取 Host
│  │  ├─ 443 → TLS   │ │  peek ClientHello 获取 SNI
│  │  └─ other → TCP  │ │
│  └─────────────────┘ │
│           │           │
│  ┌────────▼────────┐ │
│  │ domainHandler   │ │  匹配 NetworkEgress 配置
│  │ cidrOnlyHandler │ │  匹配 IP 范围
│  └─────────────────┘ │
└──────────┬───────────┘
           │ 允许
           ▼
      上游目标（自行 DNS 解析，防止 DNS 欺骗）
```

**安全机制：**
- 通过源 IP 查找沙箱及其 `NetworkEgress` 配置
- HTTP 流量提取 Host 头进行域名匹配
- TLS 流量提取 SNI 进行域名匹配
- 自行 DNS 解析，防止沙箱内部 DNS 欺骗
- CIDR 范围匹配支持 IP 白名单

---

### 2.6 template — 模板构建引擎

编排从 Docker 镜像或其他模板构建沙箱模板的多阶段流程。

**多阶段构建流水线：**

```
Base Phase ──→ User/Step Phases ──→ Finalize Phase ──→ Optimize Phase
 (拉取镜像)     (运行用户命令)        (清理/配置)         (预取优化)
```

**阶段说明：**

| 阶段 | 功能 |
|------|------|
| Base | 拉取 Docker 镜像，设置初始 rootfs |
| User/Step | 在临时沙箱中运行用户定义的命令 |
| Finalize | 系统配置（swap、用户账户）、清理临时文件 |
| Optimize | 生成预取元数据，加速后续恢复 |

使用 `LayerExecutor` 管理构建生命周期，支持通过 hash 索引缓存跳过冗余步骤。

---

### 2.7 proxy — 入口反向代理

沙箱的高性能入口代理。

```go
type SandboxProxy struct {
    proxy          *httputil.ReverseProxy
    connLimiter    *connlimit.Limiter
    metrics        *Metrics
}
```

**请求处理：**
1. 从请求中提取 `sandboxId` 和 `port`
2. 验证沙箱存在性
3. 校验 `e2b-traffic-access-token` 请求头
4. 处理 host 伪装（host masking）
5. 连接数限制和 OTel 指标收集

订阅 `sandbox.Map` 事件，沙箱销毁时自动清理连接限制状态。

---

### 2.8 portmap — Portmapper 服务

RFC 1057 SUN-RPC Portmapper 实现，用于 NFS 动态端口映射。

**核心功能：**
- `PMAPPROC_SET`：注册端口映射
- `PMAPPROC_GETPORT`：查询端口映射
- 专门为 NFS3 和 mountd 注册端口

使用装饰器模式添加日志（`wrapWithLogging`）和 panic 恢复（`wrapWithRecovery`）。

---

### 2.9 volumes — 卷管理服务

通过 gRPC 接口管理持久卷，支持不需要运行沙箱的文件操作。

**主要 RPC：**

| RPC | 功能 |
|-----|------|
| `CreateVolume` | 在主机磁盘上创建卷目录 |
| `DeleteVolume` | 删除卷目录 |
| `FileCreate` | 在卷中创建文件 |
| `FileGet` | 获取文件内容 |
| `DirList` | 列出目录内容 |

所有操作通过 `chrooted.Builder` 确保安全隔离。

---

### 2.10 其他工具包

#### cfg — 服务配置

```go
type ServiceType string

const (
    Orchestrator    ServiceType = "orchestrator"
    TemplateManager ServiceType = "template-manager"
    UnknownService  ServiceType = "unknown"
)
```

通过环境变量解析服务类型，支持单进程运行多个服务角色。

#### events — 事件发布

异步将沙箱事件发布到多个投递目标，使用 Observer/Pub-Sub 模式。内置字段验证确保 `SandboxID`、`SandboxTeamID`、`Timestamp` 必填。

#### factories — 工厂函数

简化网络服务器创建：
- `NewCMUXServer`：连接多路复用器（cmux）
- `NewHTTPServer`：基础 HTTP 服务器

#### healthcheck — 健康检查

HTTP `/health` 端点，返回服务状态和版本信息。unhealthy 时返回 503。

#### hyperloopserver — Hyperloop API

沙箱到编排器的回调 REST API（使用 Gin 框架）：
- `POST /logs`：接收沙箱日志（通过源 IP 验证身份）
- `GET /me`：返回沙箱自身 ID

使用 OpenAPI 合约和验证中间件。

#### localupload — 本地上传

本地存储模式下的文件上传 HTTP handler：
- HMAC 签名令牌验证
- 路径遍历防护
- 原子文件写入（临时文件 + `os.Rename`）

#### metrics — 系统指标

使用 `gopsutil` 采集主机级指标（CPU、内存、磁盘），过滤虚拟分区。

#### units — 单位转换

```go
func MBToBytes(mb int64) int64 { return mb << 20 }
func BytesToMB(b int64) int64  { return b >> 20 }
```

#### parsing — UUID 解析

安全的 UUID 解析工具函数。

---

## 3. 设计模式总结

| 模式 | 使用位置 | 说明 |
|------|---------|------|
| **装饰器/中间件** | nfsproxy, portmap | 日志、指标、追踪、恢复的分层增强 |
| **策略模式** | cgroup (noop/real), storage backends | 可替换的实现 |
| **Command 模式** | chrooted (mountNS), cleanup | 通过通道发送函数到专用线程/LIFO 执行 |
| **Builder 模式** | chrooted, template | 复杂对象的步骤化构建 |
| **适配器模式** | nfsproxy (os → billy) | 接口转换 |
| **Observer/Pub-Sub** | events, proxy (sandbox.Map) | 事件驱动的资源清理 |
| **工厂方法** | factories, cfg | 简化对象创建 |
| **代理模式** | sandbox/build (File) | 跨构建层的读取路由 |
| **singleflight** | block/chunk | 并发请求去重 |

---

## 4. 性能关键路径

### 沙箱恢复路径

```
Create RPC
    │
    ├─ semaphore 获取（并发控制）
    │
    ├─ block 设备初始化
    │   ├─ StreamingChunker（按需加载）
    │   ├─ PrefetchTracker 预取热数据
    │   └─ Overlay COW 层
    │
    ├─ Firecracker 启动
    │   └─ CLONE_INTO_CGROUP（cgroup 原子放置）
    │
    ├─ envd 初始化（无限重试）
    │
    └─ Healthcheck 启动
```

### 关键优化点

1. **按需分页**：不预加载整个 rootfs/memfile
2. **singleflight**：同一块的并发请求仅触发一次远程 I/O
3. **流式渐进通知**：大块数据部分就绪即可使用
4. **P2P 模板分发**：节点间直接传输，减少全局存储压力
5. **预取映射**：基于历史访问模式优化冷启动

---

## 5. 安全机制

| 层级 | 机制 | 实现 |
|------|------|------|
| 文件系统 | mount namespace + pivot_root | chrooted 包 |
| 网络出口 | iptables + SNI/Host 检查 | tcpfirewall 包 |
| 资源 | cgroup v2 CPU/内存限制 | sandbox/cgroup 包 |
| 认证 | HMAC 令牌、access token | localupload, proxy 包 |
| 入口 | 连接数限制、access token 校验 | proxy 包 |

---

## 6. 开发指南

### 新增 NFS 文件系统操作装饰器

遵循现有的装饰器模式（logged/metrics/tracing/recovery），在对应目录下实现 `handler.go`、`fs.go`、`file.go`、`change.go`，然后在 `proxy.go` 中注册。

### 新增沙箱清理步骤

```go
sandbox.cleanup.Add(ctx, func(ctx context.Context) {
    // 清理逻辑
})

// 需要优先执行的清理
sandbox.cleanup.AddPriority(ctx, func(ctx context.Context) {
    // 优先清理逻辑
})
```

### 新增块设备类型

实现 `ReadonlyDevice` 接口：

```go
type ReadonlyDevice interface {
    Slicer           // Slice(off, length) ([]byte, error)
    SeekableReader   // ReadAt(p []byte, off int64) (n int, err error)
    io.Closer
}
```

### 测试

```bash
# 运行 pkg 下的单元测试
cd packages/orchestrator
go test -race -v ./pkg/...

# 特定包
go test -race -v ./pkg/sandbox/block/...
go test -race -v ./pkg/nfsproxy/...
go test -race -v ./pkg/portmap/...
```

---

## 7. 参考

- **Firecracker 文档**：[firecracker-microvm/firecracker](https://github.com/firecracker-microvm/firecracker)
- **NBD 协议**：[Network Block Device](https://nbd.sourceforge.io/)
- **go-nfs**：[willscott/go-nfs](https://github.com/willscott/go-nfs)
- **billy 接口**：[go-git/go-billy](https://github.com/go-git/go-billy)
- **cgroup v2**：[Linux Kernel Documentation](https://docs.kernel.org/admin-guide/cgroup-v2.html)
- **OpenTelemetry Go**：[open-telemetry/opentelemetry-go](https://github.com/open-telemetry/opentelemetry-go)
