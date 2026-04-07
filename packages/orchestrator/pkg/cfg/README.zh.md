# Orchestrator cfg 包深度解析

## 1. 概述

`packages/orchestrator/pkg/cfg` 是 E2B Orchestrator 的集中式配置管理包。它通过环境变量驱动整个 Orchestrator 服务的配置，涵盖 Firecracker VM、存储路径、网络、Redis、ClickHouse、NFS 代理等所有子系统的参数。

```
环境变量 (.env / Nomad / K8s)
        │
        ▼
  ┌───────────┐
  │ cfg.Parse()│  ← caarlos0/env 库
  └─────┬─────┘
        │
        ▼
  ┌───────────┐    嵌套组合
  │  Config   │────────────────────────────┐
  │           │                            │
  │ ├─ BuilderConfig (VM 构建相关)         │
  │ │   ├─ StorageConfig (存储路径)        │
  │ │   └─ NetworkConfig (网络配置)        │
  │ ├─ Redis / ClickHouse 连接             │
  │ ├─ NFS Proxy 开关                      │
  │ ├─ gRPC / Proxy 端口                   │
  │ └─ ServiceType 选择                    │
  └────────────────────────────────────────┘
        │
        ▼
  Orchestrator / TemplateManager / Builder
```

**核心职责：**

- 从环境变量解析所有配置，提供类型安全的 Go struct
- 支持变量展开（`${ORCHESTRATOR_BASE_PATH}/build`）
- 自动将相对路径转为绝对路径
- 解析服务类型（orchestrator / template-manager），实现多模式复用
- 验证持久化卷挂载路径

**文件结构：**

| 文件 | 作用 |
|------|------|
| `model.go` | 配置结构体定义 + 解析逻辑 |
| `service.go` | 服务类型枚举与解析 |
| `model_test.go` | 单元测试 |

## 2. 配置层次结构

cfg 包采用嵌套 struct 组合设计，将配置按职责分层：

```
Config（完整配置 — Orchestrator 运行时使用）
├── BuilderConfig（构建配置 — 可独立使用，用于 build-template 等命令）
│   ├── storage.Config（存储路径配置 — 来自 shared 包）
│   └── network.Config（网络配置 — 来自 sandbox/network 包）
├── Redis 配置
├── ClickHouse 配置
├── NFS Proxy 配置
├── 端口配置
└── 服务选择
```

这种设计允许不同场景使用不同粒度的配置：
- `cfg.Parse()` → 返回完整 `Config`，用于 Orchestrator 主进程
- `cfg.ParseBuilder()` → 仅返回 `BuilderConfig`，用于 `build-template`、`create-build` 等独立工具

## 3. 配置项完整参考

### 3.1 BuilderConfig（VM 构建配置）

| 环境变量 | 类型 | 默认值 | 说明 |
|----------|------|--------|------|
| `ALLOW_SANDBOX_INTERNET` | bool | `true` | 是否允许沙箱访问外网 |
| `DOMAIN_NAME` | string | `""` | 服务域名 |
| `ENVD_TIMEOUT` | Duration | `10s` | envd 守护进程超时时间 |
| `FIRECRACKER_VERSIONS_DIR` | string | `/fc-versions` | Firecracker 版本目录 |
| `HOST_ENVD_PATH` | string | `/fc-envd/envd` | 宿主机上 envd 二进制路径 |
| `HOST_KERNELS_DIR` | string | `/fc-kernels` | 宿主机内核目录 |
| `ORCHESTRATOR_BASE_PATH` | string | `/orchestrator` | Orchestrator 基础目录（其他路径的展开基准） |
| `SANDBOX_DIR` | string | `/fc-vm` | 沙箱 VM 文件目录 |
| `SHARED_CHUNK_CACHE_PATH` | string | `""` | 共享块缓存路径 |
| `TEMPLATES_DIR` | string | `${ORCHESTRATOR_BASE_PATH}/build-templates` | 模板构建目录（支持变量展开） |
| `DEFAULT_CACHE_DIR` | string | `${ORCHESTRATOR_BASE_PATH}/build` | 默认缓存目录（支持变量展开） |

### 3.2 StorageConfig（存储路径）

来自 `packages/shared/pkg/storage`，嵌入在 BuilderConfig 中：

| 环境变量 | 类型 | 默认值 | 说明 |
|----------|------|--------|------|
| `SANDBOX_CACHE_DIR` | string | `${ORCHESTRATOR_BASE_PATH}/sandbox` | 沙箱缓存目录 |
| `SNAPSHOT_CACHE_DIR` | string | `/mnt/snapshot-cache` | 快照缓存目录 |
| `TEMPLATE_CACHE_DIR` | string | `${ORCHESTRATOR_BASE_PATH}/template` | 模板缓存目录 |

### 3.3 NetworkConfig（网络配置）

来自 `packages/orchestrator/pkg/sandbox/network`：

| 环境变量 | 类型 | 默认值 | 说明 |
|----------|------|--------|------|
| `SANDBOX_ORCHESTRATOR_IP` | string | `192.0.2.1` | 沙箱内看到的 Orchestrator IP（保留地址段） |
| `SANDBOX_HYPERLOOP_PROXY_PORT` | uint16 | `5010` | Hyperloop 代理端口 |
| `SANDBOX_NFS_PROXY_PORT` | uint16 | `5011` | NFS 代理端口 |
| `SANDBOX_PORTMAPPER_PORT` | uint16 | `5012` | Portmapper 端口 |
| `USE_LOCAL_NAMESPACE_STORAGE` | bool | `false` | 是否使用本地命名空间存储 |
| `SANDBOX_TCP_FIREWALL_HTTP_PORT` | uint16 | `5016` | TCP 防火墙 HTTP 端口 |
| `SANDBOX_TCP_FIREWALL_TLS_PORT` | uint16 | `5017` | TCP 防火墙 TLS 端口 |
| `SANDBOX_TCP_FIREWALL_OTHER_PORT` | uint16 | `5018` | TCP 防火墙其他流量端口 |

### 3.4 Config 独有字段（Orchestrator 运行时）

| 环境变量 | 类型 | 默认值 | 说明 |
|----------|------|--------|------|
| `CLICKHOUSE_CONNECTION_STRING` | string | `""` | ClickHouse 连接字符串 |
| `FORCE_STOP` | bool | `false` | 强制停止模式 |
| `GRPC_PORT` | uint16 | `5008` | gRPC 服务端口 |
| `LAUNCH_DARKLY_API_KEY` | string | `""` | LaunchDarkly 功能开关 API Key |
| `LOCAL_UPLOAD_BASE_URL` | string | `""` | 本地上传基础 URL |
| `NODE_IP` | string | `localhost` | 当前节点 IP |
| `NODE_LABELS` | []string | `""` | 节点标签（逗号分隔） |
| `ORCHESTRATOR_LOCK_PATH` | string | `/orchestrator.lock` | Orchestrator 文件锁路径 |
| `ORCHESTRATOR_SERVICES` | []string | `orchestrator` | 启用的服务类型（逗号分隔） |
| `PERSISTENT_VOLUME_MOUNTS` | map[string]string | `nil` | 持久化卷挂载映射 |
| `PROXY_PORT` | uint16 | `5007` | HTTP 代理端口 |
| `REDIS_CLUSTER_URL` | string | `""` | Redis 集群 URL |
| `REDIS_TLS_CA_BASE64` | string | `""` | Redis TLS CA 证书（Base64） |
| `REDIS_URL` | string | `""` | Redis 单节点 URL |
| `REDIS_POOL_SIZE` | int | `10` | Redis 连接池大小 |

#### NFS Proxy 配置

| 环境变量 | 类型 | 默认值 | 说明 |
|----------|------|--------|------|
| `NFS_PROXY_LOGGING` | bool | `false` | 启用 NFS 代理日志 |
| `NFS_PROXY_TRACING` | bool | `false` | 启用 NFS 代理链路追踪 |
| `NFS_PROXY_METRICS` | bool | `true` | 启用 NFS 代理指标采集 |
| `NFS_PROXY_RECORD_HANDLE_CALLS` | bool | `false` | 记录 NFS handle 调用 |
| `NFS_PROXY_RECORD_STAT_CALLS` | bool | `false` | 记录 NFS stat 调用 |
| `NFS_PROXY_LOG_LEVEL` | nfs.LogLevel | `info` | NFS 代理日志级别 |

## 4. 实现细节

### 4.1 解析流程

```go
func Parse() (Config, error) {
    // 1. 从环境变量解析所有字段（包含嵌套结构体）
    config, err := env.ParseAsWithOptions[Config](env.Options{
        FuncMap: map[reflect.Type]env.ParserFunc{
            // 自定义 NFS LogLevel 的解析器
            reflect.TypeFor[nfs.LogLevel](): func(s string) (any, error) {
                return nfs.Log.ParseLevel(strings.ToLower(s))
            },
        },
    })

    // 2. 将所有路径转为绝对路径
    makePathsAbsolute(&config.BuilderConfig)

    // 3. 验证持久化卷挂载（清理路径 + 检查目录存在性）
    for name, path := range config.PersistentVolumeMounts {
        path = filepath.Clean(path)
        path, _ = filepath.Abs(path)
        os.Stat(path) // 验证路径可访问
    }

    return config, nil
}
```

**关键技术点：**

1. **`caarlos0/env` 库**：通过 struct tag（`env:"VAR_NAME"`, `envDefault:"value"`）声明式绑定环境变量，支持嵌套 struct 自动递归解析。

2. **变量展开**：`env:"TEMPLATES_DIR,expand"` 标记的字段会自动展开 `${ORCHESTRATOR_BASE_PATH}` 等引用，实现路径的级联派生。展开使用环境变量的当前值，因此如果 `ORCHESTRATOR_BASE_PATH` 被覆盖，所有依赖它的路径都会自动更新。

3. **绝对路径标准化**：`makePathsAbsolute()` 遍历所有文件系统路径字段，将相对路径转为绝对路径。这保证后续代码无需处理路径计算的边界情况。

4. **自定义类型解析**：通过 `FuncMap` 注册 `nfs.LogLevel` 的自定义解析器，支持大小写不敏感的日志级别字符串。

### 4.2 服务类型系统

`service.go` 定义了 Orchestrator 二进制可以运行的服务模式：

```go
type ServiceType string

const (
    UnknownService  ServiceType = "orch-unknown"
    Orchestrator    ServiceType = "orchestrator"       // VM 编排服务
    TemplateManager ServiceType = "template-manager"   // 模板管理服务
)
```

通过 `ORCHESTRATOR_SERVICES` 环境变量控制，支持在同一个二进制中启用多个服务：

```bash
# 仅运行编排器
ORCHESTRATOR_SERVICES=orchestrator

# 仅运行模板管理器
ORCHESTRATOR_SERVICES=template-manager

# 同时运行两者（逗号分隔）
ORCHESTRATOR_SERVICES=orchestrator,template-manager
```

`GetServices()` 将字符串列表解析为类型安全的 `[]ServiceType`，自动过滤未知的服务名。`GetServiceName()` 将服务列表拼接为单个标识符（用下划线连接），用于遥测和日志标记。

### 4.3 NodeAddress 辅助方法

```go
func (c Config) NodeAddress() *string {
    if c.NodeIP == "localhost" {
        return nil  // 本地开发模式，无需注册地址
    }
    addr := fmt.Sprintf("%s:%d", c.NodeIP, c.GRPCPort)
    return &addr    // 生产模式，返回 IP:Port 格式的节点地址
}
```

返回 `nil` 表示本地模式（不需要向集群注册），返回地址字符串表示集群模式（需要可被其他节点访问）。

## 5. 使用方式

### 5.1 在 Orchestrator 主进程中

```go
// packages/orchestrator/pkg/factories/run.go
func Run(opts Options) bool {
    config, err := cfg.Parse()     // 解析完整配置
    services := cfg.GetServices(config)  // 获取启用的服务列表
    serviceName := cfg.GetServiceName(services)  // 用于日志/遥测
    // ...
}
```

### 5.2 在构建工具中

```go
// packages/orchestrator/cmd/create-build/main.go
func main() {
    config, err := cfg.ParseBuilder()  // 仅解析构建相关配置
    // 使用 config.SandboxDir, config.HostEnvdPath 等
}
```

### 5.3 本地开发

创建 `.env` 文件并设置必要的环境变量：

```bash
# 最小配置（大部分有默认值）
ORCHESTRATOR_BASE_PATH=/tmp/orchestrator
NODE_IP=localhost
REDIS_URL=redis://localhost:6379

# 覆盖默认值
SANDBOX_DIR=/tmp/fc-vm
GRPC_PORT=5008
```

## 6. 设计决策

| 决策 | 原因 |
|------|------|
| 环境变量驱动而非配置文件 | 符合 12-Factor App 原则，天然适配容器化和 Nomad 部署 |
| struct 嵌套组合 | BuilderConfig 可独立使用，避免构建工具加载不相关的 Redis/ClickHouse 配置 |
| 变量展开（`${VAR}`） | 大量路径派生自 `ORCHESTRATOR_BASE_PATH`，展开机制避免手动维护多个路径 |
| 路径自动绝对化 | 消除相对路径在不同工作目录下的歧义，防止运行时路径错误 |
| 持久卷启动时验证 | 在服务启动阶段 fail-fast，而非在运行时遇到挂载问题 |
| 服务类型枚举 | 同一二进制支持多模式运行，减少构建产物，简化部署 |
| 自定义类型解析器 | 让 NFS LogLevel 等非标准类型也能从环境变量直接解析 |
