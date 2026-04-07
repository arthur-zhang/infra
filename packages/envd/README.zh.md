# E2B envd 深度解析：沙箱内守护进程的设计与实现

## 1. 概述

envd（Environment Daemon）是 E2B 沙箱架构中运行在每个 Firecracker microVM 内部的守护进程。它是 SDK 与沙箱之间的桥梁，负责接收来自外部的 API 调用，在沙箱内执行进程管理、文件系统操作、端口转发等核心功能。

```
SDK (Python/JS/...) ──► Client Proxy ──► Orchestrator ──► Firecracker VM
                                                              │
                                                         ┌────▼────┐
                                                         │  envd   │ :49983
                                                         ├─────────┤
                                                         │ Process  │ Connect RPC (gRPC)
                                                         │ Service  │
                                                         ├─────────┤
                                                         │Filesystem│ Connect RPC (gRPC)
                                                         │ Service  │
                                                         ├─────────┤
                                                         │ REST API │ HTTP (OpenAPI)
                                                         │ (files/  │
                                                         │  init/   │
                                                         │  health) │
                                                         ├─────────┤
                                                         │  Port    │ socat 转发
                                                         │Forwarder │
                                                         └─────────┘
```

**关键特性：**

- 监听端口 `49983`，提供 HTTP + Connect RPC 混合协议
- 使用 chi 路由器组合多个服务到同一 HTTP 端点
- 通过 MMDS（Microvm Metadata Service）获取沙箱元数据
- cgroup v2 资源隔离与 OOM 保护
- 自动端口发现与转发（socat）
- 支持 PTY 和标准 stdin/stdout/stderr 双模式进程管理

## 2. 启动流程

入口文件：`main.go`

```go
func main() {
    parseFlags()                          // 1. 解析命令行参数
    
    // 2. 创建运行目录 /run/e2b
    os.MkdirAll(host.E2BRunDir, 0o755)
    
    // 3. 初始化默认上下文（默认用户 root + 环境变量）
    defaults := &execcontext.Defaults{
        User:    "root",
        EnvVars: utils.NewMap[string, string](),
    }
    
    // 4. 在 Firecracker 模式下，启动 MMDS 轮询
    if !isNotFC {
        go host.PollForMMDSOpts(ctx, mmdsChan, defaults.EnvVars)
    }
    
    // 5. 初始化日志系统
    l := logs.NewLogger(ctx, isNotFC, mmdsChan)
    
    // 6. 注册 Connect RPC 服务
    m := chi.NewRouter()
    filesystemRpc.Handle(m, &fsLogger, defaults)        // 文件系统服务
    processService := processRpc.Handle(m, &processLogger, defaults, cgroupManager) // 进程服务
    
    // 7. 注册 REST API（OpenAPI 生成）
    service := api.New(&envLogger, defaults, mmdsChan, isNotFC)
    handler := api.HandlerFromMux(service, m)
    
    // 8. 包装中间件：CORS → 授权 → 认证
    s := &http.Server{
        Handler: withCORS(service.WithAuthorization(middleware.Wrap(handler))),
        Addr:    "0.0.0.0:49983",
    }
    
    // 9. 启动端口扫描与转发
    portScanner := publicport.NewScanner(1000 * time.Millisecond)
    portForwarder := publicport.NewForwarder(&portLogger, portScanner, cgroupManager)
    go portForwarder.StartForwarding(ctx)
    go portScanner.ScanAndBroadcast()
    
    // 10. 启动 HTTP 服务
    s.ListenAndServe()
}
```

### 2.1 命令行参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-isnotfc` | `false` | 非 Firecracker 模式（开发调试用），日志输出到 stdout |
| `-port` | `49983` | 服务监听端口 |
| `-cmd` | `""` | 守护进程启动时执行的初始命令 |
| `-cgroup-root` | `/sys/fs/cgroup` | cgroup 根目录 |
| `-version` | - | 打印版本号 |
| `-commit` | - | 打印 Git commit SHA |

## 3. 双协议 API 设计

envd 在同一个端口上同时提供两种协议的 API：

### 3.1 Connect RPC 服务（gRPC over HTTP）

通过 Protocol Buffers 定义，由 `connectrpc.com/connect` 框架实现。

#### Process 服务

定义文件：`spec/process/process.proto`

```protobuf
service Process {
    rpc List(ListRequest) returns (ListResponse);       // 列出所有进程
    rpc Start(StartRequest) returns (stream StartResponse);  // 启动进程（流式）
    rpc Connect(ConnectRequest) returns (stream ConnectResponse); // 连接到已有进程
    rpc Update(UpdateRequest) returns (UpdateResponse); // 更新进程（如调整 PTY 大小）
    rpc StreamInput(stream StreamInputRequest) returns (StreamInputResponse); // 流式输入
    rpc SendInput(SendInputRequest) returns (SendInputResponse);   // 单次输入
    rpc SendSignal(SendSignalRequest) returns (SendSignalResponse); // 发送信号
    rpc CloseStdin(CloseStdinRequest) returns (CloseStdinResponse); // 关闭 stdin
}
```

#### Filesystem 服务

定义文件：`spec/filesystem/filesystem.proto`

```protobuf
service Filesystem {
    rpc Stat(StatRequest) returns (StatResponse);        // 获取文件信息
    rpc MakeDir(MakeDirRequest) returns (MakeDirResponse); // 创建目录
    rpc Move(MoveRequest) returns (MoveResponse);        // 移动/重命名
    rpc ListDir(ListDirRequest) returns (ListDirResponse); // 列出目录内容
    rpc Remove(RemoveRequest) returns (RemoveResponse);  // 删除文件/目录
    
    rpc WatchDir(WatchDirRequest) returns (stream WatchDirResponse); // 流式监听目录变化
    
    // 非流式版本的目录监听（轮询模式）
    rpc CreateWatcher(CreateWatcherRequest) returns (CreateWatcherResponse);
    rpc GetWatcherEvents(GetWatcherEventsRequest) returns (GetWatcherEventsResponse);
    rpc RemoveWatcher(RemoveWatcherRequest) returns (RemoveWatcherResponse);
}
```

### 3.2 REST API（OpenAPI 生成）

定义文件：`spec/envd.yaml`，使用 `oapi-codegen` 生成 Go 代码。

| 路径 | 方法 | 说明 |
|------|------|------|
| `/health` | GET | 健康检查 |
| `/metrics` | GET | 获取资源使用指标（CPU、内存） |
| `/init` | POST | 初始化沙箱：设置环境变量、时间同步、挂载卷、设置 access token |
| `/envs` | GET | 获取当前环境变量 |
| `/files` | GET | 下载文件（支持 gzip、Range 请求） |
| `/files` | POST | 上传文件（支持 multipart 和 octet-stream） |
| `/files/compose` | POST | 合并多个文件为一个（零拷贝 `copy_file_range`） |

## 4. 核心模块详解

### 4.1 进程管理（Process Service）

文件位置：`internal/services/process/`

这是 envd 最复杂的模块，支持在沙箱内启动、管理和监控进程。

#### 进程启动流程

```
Start RPC 请求
    │
    ▼
handler.New()
    ├── 解析用户身份（Basic Auth → os/user.User）
    ├── 构造 OOM wrapper shell 脚本
    │     echo 100 > /proc/$$/oom_score_adj && exec nice -n 0 "${@}"
    ├── 设置 SysProcAttr
    │     ├── UseCgroupFD: true  （直接放入对应 cgroup）
    │     └── Credential: {Uid, Gid, Groups}
    ├── 解析工作目录（ExpandAndResolve）
    ├── 合并环境变量（PATH/HOME/USER + defaults + request）
    │
    ├── PTY 模式？
    │     ├── Yes → pty.StartWithSize() → 创建伪终端
    │     │         读取 PTY 输出 → MultiplexedChannel
    │     └── No  → cmd.StdoutPipe() + cmd.StderrPipe()
    │               分别读取 → MultiplexedChannel
    │
    └── 返回 Handler
```

**关键设计：OOM Score 包装器**

每个用户进程启动时都被包装在一个 shell 脚本中，在 `exec` 实际命令之前先设置 OOM score 为 100（可被 OOM killer 杀死）并调整 nice 值。这消除了子进程继承 envd 自身受保护 OOM score（-1000）和高 CPU 优先级的竞态窗口：

```go
oomWrapperScript := fmt.Sprintf(
    `echo %d > /proc/$$/oom_score_adj && exec /usr/bin/nice -n %d "${@}"`,
    defaultOomScore, niceDelta,
)
cmd := exec.CommandContext(ctx, "/bin/sh", wrapperArgs...)
```

#### MultiplexedChannel：多订阅者广播

`internal/services/process/handler/multiplex.go`

这是一个泛型的 fan-out channel 实现，用于将进程的输出（stdout/stderr/pty）广播给所有连接的客户端：

```go
type MultiplexedChannel[T any] struct {
    Source   chan T        // 生产者写入端
    channels []chan T      // 消费者列表
    mu       sync.RWMutex
}

// Fork() 创建一个新的消费者 channel
func (m *MultiplexedChannel[T]) Fork() (chan T, func()) {
    consumer := make(chan T)
    m.channels = append(m.channels, consumer)
    return consumer, cancelFunc
}
```

当一个进程正在运行时，多个客户端可以通过 `Connect` RPC 同时订阅其输出。每个 `Fork()` 创建一个独立的 channel，Source 端收到的每条消息都会被广播到所有消费者。

#### 进程事件流

Start RPC 返回一个 Server-Side Streaming 流，事件类型包括：

```
StartEvent  → {pid}                      // 进程已启动
DataEvent   → {stdout | stderr | pty}    // 输出数据
KeepAlive   → {}                         // 保活心跳
EndEvent    → {exit_code, exited, status, error} // 进程结束
```

流的生命周期管理：
1. 发送 `StartEvent` 通知客户端进程已启动
2. 循环发送 `DataEvent`，中间穿插 `KeepAlive` 心跳
3. 数据流结束后发送 `EndEvent`
4. 客户端断开不会杀死进程（进程 context 使用 `context.Background()`）

### 4.2 文件系统服务（Filesystem Service）

文件位置：`internal/services/filesystem/`

#### 目录监听双模式

**流式模式（WatchDir）：** 使用 `fsnotify` 库监听文件系统事件，通过 Server-Side Streaming 实时推送。支持递归监听子目录，并检测网络文件系统挂载点（NFS）以避免无效监听。

**轮询模式（CreateWatcher/GetWatcherEvents）：** 对于不支持长连接的场景，提供创建 Watcher → 轮询事件 → 删除 Watcher 的三步式 API。事件在内存中累积，客户端按需拉取。

```go
// 轮询模式事件获取：获取后立即清空
func (s Service) GetWatcherEvents(...) {
    w.Lock.Lock()
    events := w.Events
    w.Events = []*rpc.FilesystemEvent{}  // 取走后清空
    w.Lock.Unlock()
    return events
}
```

支持的事件类型：CREATE、WRITE、REMOVE、RENAME、CHMOD

### 4.3 文件上传下载（REST API）

文件位置：`internal/api/upload.go`, `internal/api/download.go`

#### 文件上传

支持两种 Content-Type：

- **`multipart/form-data`**：传统多文件上传，每个 part 的 `filename` 字段决定目标路径
- **`application/octet-stream`**：raw body 单文件上传，路径由 `?path=` 查询参数指定

上传流程中的关键处理：
1. **用户身份解析** → 确定文件归属（uid/gid）
2. **路径解析** → `ExpandAndResolve` 支持 `~` 扩展和符号链接解析
3. **目录确保** → `EnsureDirs` 递归创建父目录并设置正确的 ownership
4. **文件写入** → 使用 `ReadFrom`（Linux 上底层调用 `copy_file_range` 实现零拷贝）
5. **所有权设置** → `os.Chown(path, uid, gid)`

#### 文件下载

- 支持 `Accept-Encoding: gzip` 压缩传输
- 支持 HTTP Range 请求（部分下载/断点续传）
- 支持条件请求（If-Modified-Since/If-None-Match）
- 对于 Range/条件请求，回退到 identity 编码以保持 `http.ServeContent` 的 206/304 语义

#### 文件合并（Compose）

`/files/compose` 接口将多个源文件拼接为一个目标文件：

```go
// 先写入临时文件，成功后原子 rename
tmpPath := destPath + ".e2b-compose." + uuid.New().String() + ".tmp"

for _, srcPath := range resolvedSources {
    // 使用 ReadFrom → copy_file_range 零拷贝
    n, err := destFile.ReadFrom(srcFile)
}

// 原子替换
os.Rename(tmpPath, destPath)

// 清理源文件
for _, srcPath := range resolvedSources {
    os.Remove(srcPath)
}
```

### 4.4 MMDS 元数据集成

文件位置：`internal/host/mmds.go`

MMDS（MicroVM Metadata Service）是 Firecracker 提供的实例元数据服务，类似 AWS EC2 的 Instance Metadata Service，通过 link-local 地址 `169.254.169.254` 访问。

envd 在启动时轮询 MMDS 获取沙箱配置：

```go
type MMDSOpts struct {
    SandboxID            string `json:"instanceID"`     // 沙箱实例 ID
    TemplateID           string `json:"envID"`          // 模板 ID
    LogsCollectorAddress string `json:"address"`        // 日志收集器地址
    AccessTokenHash      string `json:"accessTokenHash"` // 访问令牌哈希
}
```

访问 MMDS 需要先获取 token（PUT 请求），再使用 token 获取数据（GET 请求），类似 IMDSv2 的安全模式。获取到的 SandboxID 和 TemplateID 会写入 `/run/e2b/` 目录，同时注入到进程的环境变量中（`E2B_SANDBOX_ID`、`E2B_TEMPLATE_ID`）。

### 4.5 Cgroup v2 资源管理

文件位置：`internal/services/cgroups/`

envd 创建三个 cgroup 子组来隔离不同类型的进程：

| cgroup | 用途 | CPU 权重 | 内存限制 |
|--------|------|----------|----------|
| `ptys` | PTY 进程（终端会话） | 200（高优先） | memory.high/max = 总内存 - 保留 |
| `socats` | socat 端口转发进程 | 150 | memory.min=5MB, memory.low=8MB |
| `user` | 用户普通进程 | 50（低优先） | memory.high/max = 总内存 - 保留 |

内存保留策略：保留总内存的 1/8（上限 128MB）给系统，其余分配给用户进程。

进程通过 `SysProcAttr.UseCgroupFD` 在 `fork+exec` 时直接加入对应 cgroup，避免了先启动后迁移的竞态问题：

```go
cmd.SysProcAttr = &syscall.SysProcAttr{
    UseCgroupFD: ok,        // 使用 cgroup FD 直接加入
    CgroupFD:    cgroupFD,
    Credential:  &syscall.Credential{Uid: uid, Gid: gid, Groups: groups},
}
```

### 4.6 端口自动转发

文件位置：`internal/port/`

envd 持续扫描 VM 内部在 `127.0.0.1`/`localhost`/`::1` 上监听的 TCP 端口，并自动用 socat 将它们转发到网关 IP `169.254.0.21`，使得外部可以通过沙箱网络访问这些服务。

```
扫描周期：每 1000ms
工作原理：

1. Scanner 每秒扫描所有 TCP 连接
2. 过滤出 LISTEN 状态 + localhost 地址的连接
3. 对新发现的端口，启动 socat 进程：
   socat TCP4-LISTEN:${port},bind=169.254.0.21,reuseaddr,fork TCP4:localhost:${port}
4. 对已消失的端口，杀死对应的 socat 进程
```

socat 进程也被放入 `socats` cgroup，有独立的 CPU 和内存配额。

### 4.7 认证与授权

#### 双层认证机制

**1. Connect RPC 认证（Basic Auth）：**

```go
func AuthenticateUsername(_ context.Context, req authn.Request) (any, error) {
    username, _, ok := req.BasicAuth()
    // 用户名用于确定操作的 Linux 用户身份
    u, err := GetUser(username)
    return u, nil
}
```

username 决定了文件操作的 uid/gid 和进程的执行身份。

**2. REST API 认证（Access Token + Signature）：**

- `X-Access-Token` Header：直接比较 token
- URL 签名：`v1_sha256(path:operation:username:token[:expiration])`，支持带过期时间的签名 URL

#### /init 接口的 Token 验证

`/init` 接口用于 orchestrator 初始化沙箱，验证逻辑优先级：

1. 如果已有 token 且匹配请求 token → 通过
2. 检查 MMDS hash 是否匹配 → 通过（用于 Resume 场景的 token 更换）
3. 如果没有已有 token 且 MMDS 未配置 → 首次设置，通过
4. 其余情况 → 拒绝

### 4.8 初始化接口（/init）

`POST /init` 是 orchestrator 在沙箱创建/恢复时调用的核心接口：

```go
func (a *API) SetData(ctx context.Context, logger zerolog.Logger, data PostInitJSONBody) error {
    // 1. 验证 access token
    a.validateInitAccessToken(ctx, data.AccessToken)
    
    // 2. 同步系统时间（从快照恢复时时钟可能落后）
    if shouldSetSystemTime(sandboxTime, hostTime) {
        unix.ClockSettime(unix.CLOCK_REALTIME, &ts)
    }
    
    // 3. 设置环境变量
    for key, value := range *data.EnvVars {
        a.defaults.EnvVars.Store(key, value)
    }
    
    // 4. 设置/清除 access token
    a.accessToken.TakeFrom(data.AccessToken)
    
    // 5. 配置 Hyperloop（事件上报地址）
    if data.HyperloopIP != nil {
        go a.SetupHyperloop(*data.HyperloopIP) // 修改 /etc/hosts
    }
    
    // 6. 设置默认用户和工作目录
    a.defaults.User = *data.DefaultUser
    a.defaults.Workdir = data.DefaultWorkdir
    
    // 7. 挂载 NFS 卷
    for _, volume := range *data.VolumeMounts {
        a.setupNfs(ctx, volume.NfsTarget, volume.Path)
    }
}
```

时间同步的精确逻辑：当 sandbox 时间比 host 时间早超过 50ms 或晚超过 5s 时，才进行时钟校准。这对从快照恢复的 VM 尤其重要。

### 4.9 日志系统

文件位置：`internal/logs/`

- 使用 zerolog 作为结构化日志库
- Firecracker 模式下：同时输出到 stdout 和 HTTP 远程日志收集器
- 非 Firecracker 模式：仅输出到 stdout
- 日志收集器地址从 MMDS 获取
- 每个请求分配唯一的 `OperationID` 用于链路追踪

## 5. 开发与调试

### 5.1 本地开发

```bash
# 构建并启动 Docker 容器运行 envd
cd packages/envd
make start-docker

# SDK 连接本地 envd（设置环境变量）
E2B_DEBUG=true
```

### 5.2 代码生成

```bash
# 安装生成工具
make init-generate

# 从 spec/ 下的 proto 和 OpenAPI 定义生成代码
make generate
```

生成的代码：
- `internal/services/spec/process/` — Process proto 的 Go 代码
- `internal/services/spec/filesystem/` — Filesystem proto 的 Go 代码
- `internal/api/api.gen.go` — OpenAPI 路由和类型

### 5.3 远程调试

```bash
# 启动带 delve 调试器的 envd
make run-debug
# 然后连接到端口 2345 进行远程调试
```

## 6. 关键设计决策总结

| 决策 | 原因 |
|------|------|
| 同一端口提供 REST + gRPC | 简化网络配置，Firecracker VM 的端口资源有限 |
| 使用 Connect RPC 而非原生 gRPC | 兼容 HTTP/1.1，无需 HTTP/2；同时支持浏览器端调用 |
| OOM wrapper shell 脚本 | 消除子进程继承 envd 受保护 OOM score 的竞态窗口 |
| cgroup v2 直接 FD | 进程 fork 时立即加入 cgroup，避免"先启动后迁移"的不安全窗口 |
| socat 端口转发 | 简单可靠，自动发现 localhost 服务并暴露给外部 |
| MMDS 轮询而非推送 | Firecracker MMDS 是只读数据源，轮询是唯一可用方式 |
| 文件合并使用 copy_file_range | 零拷贝，数据不经过用户态，大文件场景性能优异 |
| MultiplexedChannel 广播 | 支持多个客户端同时连接同一进程（Connect RPC），不丢失任何输出 |
| SecureToken + memguard | token 在内存中加密存储，使用后安全擦除，防止内存泄露 |
| 签名 URL 支持过期 | 允许生成临时的文件访问链接，安全共享沙箱文件 |
