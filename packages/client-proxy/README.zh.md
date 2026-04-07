# packages/client-proxy 原理、代码实现和使用方式

`packages/client-proxy` 是 E2B 用户流量进入 sandbox 的第一跳。它本身不直接连到 sandbox，也不负责启动 VM；它做的事情更像一个“边缘路由器”：

1. 从 HTTP 请求里解析出目标 `sandboxID` 和端口。
2. 去 sandbox catalog 查询这个 sandbox 当前在哪个 orchestrator 节点上。
3. 如果 catalog 没命中，并且允许自动恢复，就通过 API 的 gRPC 接口触发恢复。
4. 把请求转发到对应 orchestrator 节点上的 orchestrator proxy。

从代码结构上看，这个包本身很薄，真正通用的反向代理、连接池、错误模板和连接跟踪能力都在 `packages/shared/pkg/proxy`。`client-proxy` 主要负责把这些能力和 Redis catalog、feature flags、API gRPC 自动恢复装配起来。

有一个容易混淆的点：目录叫 `packages/client-proxy`，但它的 `go.mod` 模块名仍然是 `github.com/e2b-dev/infra/packages/proxy`。所以在 `main.go` 里你会看到 `packages/proxy/internal/...` 这样的 import，这和目录名不完全一致，是当前仓库里的历史命名结果。

## 一、它在整体架构里的位置

一次典型请求的路径如下：

```text
Client
  -> client-proxy (:3002)
  -> sandbox catalog (Redis / memory fallback)
  -> orchestrator proxy (<node-ip>:5007)
  -> sandbox hostIP:<sandbox-port>
```

如果 sandbox 当前是暂停态，而且 catalog 查不到，但系统允许自动恢复，请求链路会变成：

```text
Client
  -> client-proxy
  -> catalog miss
  -> API gRPC ResumeSandbox
  -> 返回 orchestrator IP
  -> orchestrator proxy
  -> sandbox
```

这意味着 `client-proxy` 的定位非常明确：

- 它负责“路由到哪台 orchestrator”。
- 它不负责“沙箱内部端口是否已经可达”，这个问题交给 orchestrator proxy 处理。
- 它不直接管理 sandbox 生命周期，只在必要时调用 API 发起 resume。

## 二、目录和核心文件

`packages/client-proxy` 只有几个核心文件：

- `main.go`
  负责启动流程、依赖初始化、健康检查和优雅关闭。
- `internal/cfg/model.go`
  定义运行时环境变量。
- `internal/proxy/proxy.go`
  定义 client proxy 的核心路由逻辑。
- `internal/proxy/paused_sandbox_resumer_grpc.go`
  定义 catalog miss 时如何通过 gRPC 调 API 恢复 sandbox。
- `internal/info.go`
  管理服务健康状态。

而关键的共享基础设施来自：

- `packages/shared/pkg/proxy`
  通用 HTTP reverse proxy、错误处理、连接池、连接跟踪。
- `packages/shared/pkg/sandbox-catalog`
  Redis / 内存 catalog。
- `packages/shared/pkg/grpc/proxy`
  client-proxy 和 API 之间的 gRPC 协议。

## 三、请求是如何被路由的

### 1. 从请求中提取 sandboxID 和端口

client-proxy 创建时会调用 `reverseproxy.GetTargetFromRequest(env.IsLocal())`。这一步决定了它如何从请求中定位目标 sandbox。

当前逻辑有两种输入方式：

1. Host 路由
2. Header 路由

其中 Header 路由只在 `ENVIRONMENT=local` 时开启。

#### Host 路由

Host 解析逻辑在 `packages/shared/pkg/proxy/host.go`。它会取 host 第一个 `.` 之前的部分，再按 `-` 切开：

```text
<port>-<sandboxID>-<extra>.<routing-domain>
```

实际只会用到前两个片段：

- 第 1 段是 sandbox port
- 第 2 段是 sandboxID

也就是说，请求 host 即使长成下面这样也没问题：

```text
49983-sbx12345-clientabc.example.com
```

解析时真正使用的是：

- 端口：`49983`
- sandboxID：`sbx12345`

测试代码里也是这么构造请求的，格式是：

```text
<port>-<sandboxID>-<clientID>.<routing-domain>
```

这说明 `clientID` 对 client-proxy 自身并不是路由必需信息，它更多是为了完整保留上游请求格式。

#### Header 路由

本地环境下，也可以直接传这两个头：

- `E2b-Sandbox-Id`
- `E2b-Sandbox-Port`

这样就不需要构造动态 Host。这个能力主要是为了本地开发和测试方便。

### 2. 读取附加认证信息

在拿到 `sandboxID` 和端口之后，client-proxy 还会从请求头里取出两类 token：

- `e2b-traffic-access-token`
- `X-Access-Token`

其中：

- `e2b-traffic-access-token` 用于普通 ingress 流量的访问控制。
- `X-Access-Token` 是 envd HTTP 鉴权头，client-proxy 在 auto-resume 场景里会把它转换后转给 API。

注意一点：当 sandbox 已经在运行、catalog 能直接命中时，client-proxy 不会自己校验这些 token；真正的流量 token 校验是在下一跳 orchestrator proxy 中进行的。client-proxy 只在“catalog miss -> 尝试恢复 paused sandbox”这条路径上，把 token 透传给 API，让 API 判断是否允许恢复。

### 3. 查 catalog，决定目标 orchestrator

核心函数是 `catalogResolution`。逻辑很简单：

1. 从 catalog 读取 sandbox 信息。
2. 如果读到了，就直接返回 `OrchestratorIP`。
3. 如果返回 `ErrSandboxNotFound`，说明当前没有活动路由信息，此时再进入 auto-resume 分支。

这里的关键结论是：

- client-proxy 的第一优先级是查 catalog。
- 只有 catalog miss 才会考虑自动恢复。
- 所以自动恢复不是“每次请求都检查一次暂停状态”，而是“路由信息缺失时的补救路径”。

### 4. 把请求转发到 orchestrator proxy

拿到节点 IP 后，client-proxy 并不是直接把流量打到 sandbox 端口，而是统一打到：

```text
http://<orchestrator-ip>:5007
```

这里的 `5007` 是 orchestrator proxy 端口。也就是说，client-proxy 只负责把请求送到正确的 orchestrator 节点；真正再往下的一跳，由 orchestrator proxy 再根据同样的 host / header 信息，把请求转到 sandbox 对应端口。

这样做有两个好处：

1. client-proxy 不需要知道 sandbox 在宿主机上的实际 host IP。
2. sandbox 内部端口刚启动、端口映射延迟、连接数限制、端口关闭错误等问题，都可以在 orchestrator 本地统一处理。

## 四、catalog 设计：为什么依赖 Redis

client-proxy 本身不保存全局 sandbox 路由表。它依赖 `SandboxesCatalog` 接口读取路由信息。

这个接口有两种实现：

1. `RedisSandboxCatalog`
2. `MemorySandboxCatalog`

### Redis catalog

生产主路径是 Redis。每条记录以 `sandbox:catalog:<sandboxID>` 为 key，值里至少包含：

- `OrchestratorID`
- `OrchestratorIP`
- `ExecutionID`
- 启动时间和最长运行时间等信息

读取时还带了一个很短的本地 TTL cache，默认 500ms，可通过 feature flag `SandboxCatalogLocalCacheFlag` 开关控制。这个缓存的目的不是长期缓存，而是减少极高频请求下的 Redis 读取压力；TTL 很短，是为了降低 sandbox 已经迁移到新 orchestrator 时的错误路由概率。

### Memory catalog

如果 Redis 没配，`main.go` 会退回到内存 catalog。这个模式只适合单实例开发或简单本地调试，因为多实例之间不会共享路由数据。

所以可以把这里理解为：

- Redis catalog 是真正的分布式服务发现层。
- Memory catalog 只是开发兜底。

## 五、paused sandbox 自动恢复是怎么工作的

### 1. 触发条件

自动恢复只有同时满足以下条件才会发生：

1. catalog miss
2. `API_GRPC_ADDRESS` 已配置
3. feature flag `sandbox-auto-resume` 对当前 sandbox 生效

如果少了任何一项，请求都会直接落成 “sandbox not found”。

另外，这个 flag 的默认值是 `env.IsDevelopment()`，也就是在 `local` / `dev` 环境默认开启，而在生产环境里通常要依赖 LaunchDarkly 显式开启。

### 2. gRPC 协议

client-proxy 调 API 使用的协议很小，只有一个 RPC：

- `proxy.SandboxService.ResumeSandbox`

请求体里只有 `sandbox_id`，其它上下文通过 gRPC metadata 传递：

- `e2b-sandbox-request-port`
- `e2b-traffic-access-token`
- `e2b-envd-access-token`

这很重要，因为 API 要根据请求访问的端口类型判断鉴权逻辑：

- 非 envd 流量：校验 traffic access token
- envd 流量：如果 sandbox 是 secure envd，就校验 envd access token

### 3. API 端会做什么

API 的 `ResumeSandbox` 处理逻辑大致是：

1. 校验 sandboxID。
2. 从 snapshot cache 找到可恢复快照，并确认 auto-resume policy 允许恢复。
3. 如果 sandbox 其实已经存在，优先尝试“接管已有 sandbox”的路由结果。
4. 读取 team 和 timeout 等配置。
5. 根据请求端口判断是普通 ingress 还是 envd 流量。
6. 校验 traffic token 或 envd token。
7. 真正调用内部逻辑恢复 sandbox。
8. 返回新 sandbox 所在 orchestrator 的 IP。

这个设计把“是否允许恢复”放在 API 里做，而不是在 client-proxy 做，原因很合理：

- token 的正确值是 API 更清楚。
- auto-resume policy、team 限额、snapshot 状态都属于业务侧数据。
- client-proxy 应该尽量保持为一个无状态的边缘转发器。

### 4. 错误如何映射回 HTTP

如果 gRPC resume 返回不同错误码，client-proxy 会把它们转换成语义化的代理错误：

- `PermissionDenied` -> sandbox resume permission denied
- `NotFound` -> 视为不可自动恢复
- `FailedPrecondition` 且消息为 “still transitioning” -> sandbox 仍在切换中
- `ResourceExhausted` -> 团队配额或资源不足

这些错误最终不是简单返回一段纯文本，而是交给共享 proxy handler 输出浏览器友好的 HTML 或程序友好的 JSON。

## 六、共享 proxy 层做了什么

虽然 `packages/client-proxy` 代码量不大，但底下的共享 proxy 层做了不少关键工作。

### 1. HTTP server 和连接统计

`packages/shared/pkg/proxy.New` 会创建一个带连接池的 `http.Server`。它做了几件事：

- 为下游客户端配置更长的 idle timeout
- 用包装过的 listener 统计当前 server 连接数
- 为每个 destination 维护复用的 `ProxyClient`

### 2. 连接池和 keep-alive

client-proxy 创建 destination 时，`ConnectionKey` 被固定写成 `pool.ClientProxyConnectionKey`。这意味着 client-proxy 侧会复用一组共享连接池，而不是为每个 sandbox 单独建池。

这和 orchestrator proxy 不一样。orchestrator proxy 连接的是 sandbox 本身，网络槽位可能被复用，所以它必须更细粒度地区分连接；但 client-proxy 只连 orchestrator proxy，复用一组连接通常是安全且更高效的。

连接池内部又做了几件事：

- 限制每个 host 的 idle 连接上限，避免把所有端口资源耗在单机上。
- 支持有限次数的连接重试。
- 跟踪当前活跃连接和累计建连次数。

### 3. 为什么 client-proxy 只重试 1 次

`client-proxy` 用的是 `ClientProxyRetries = 1`。注释写得很明确：sandbox envd 的端口转发延迟，由 orchestrator proxy 这一层处理。

也就是说，client-proxy 不承担“等端口起来”的职责；它只负责把请求送到正确 orchestrator 节点。真正需要对 sandbox 端口就绪做重试的是 orchestrator proxy，因此它的重试次数更高。

### 4. 错误模板

共享 `handler` 会把各种路由错误转成统一输出：

- 无效 host / header / sandboxID / port -> `400`
- sandbox not found
- resume permission denied
- sandbox still transitioning
- resource exhausted

输出格式会根据请求像不像浏览器来选择 HTML 或 JSON。这对 SDK / API 客户端和浏览器访问场景都比较友好。

## 七、启动流程和优雅关闭

### 1. 启动流程

`main.go` 的启动步骤可以概括成：

1. 解析环境变量配置。
2. 初始化 telemetry 和 logger。
3. 初始化 feature flags 客户端。
4. 创建 Redis 或 memory catalog。
5. 如果配置了 `API_GRPC_ADDRESS`，创建 paused sandbox resumer。
6. 创建 HTTP proxy server。
7. 创建 health server。
8. 启动两个 goroutine 分别监听 proxy 和 health。

这说明 `client-proxy` 实际上对外暴露两个端口：

- 代理流量端口：默认 `3002`
- 健康检查端口：默认 `3003`

### 2. 健康状态

内部健康状态有三个：

- `healthy`
- `draining`
- `unhealthy`

健康检查接口只认 `healthy`。当服务准备下线时，不会直接退出，而是先切成 `draining`，等待一段时间让上游感知，再开始真正关闭。

### 3. 优雅关闭为什么分两段

关闭流程是：

1. 收到信号后状态变为 `draining`
2. 等 15 秒，让依赖方停止送新流量
3. 用最长 24 小时的上下文优雅关闭 proxy
4. 状态切为 `unhealthy`
5. 再等 15 秒，让 health check 感知
6. 关闭 health server
7. 关闭 feature flags、catalog、gRPC client 等资源

这种设计是为了配合负载均衡和 service discovery，尽量避免连接还没 drain 完就被硬切掉。

## 八、如何使用

### 1. 运行所需配置

代码层面直接读取的核心环境变量只有这些：

```text
HEALTH_PORT=3003
PROXY_PORT=3002
REDIS_URL=
REDIS_CLUSTER_URL=
REDIS_TLS_CA_BASE64=
REDIS_POOL_SIZE=40
API_GRPC_ADDRESS=
```

除此之外，还需要一些共享基础设施依赖的环境变量，例如：

- `NODE_ID`
- `ENVIRONMENT`
- telemetry / logging 相关变量
- LaunchDarkly 相关变量

`Makefile` 的 `run-local` 已经帮你自动加载 `packages/client-proxy/.env.local`，并把本机 hostname 作为 `NODE_ID`。

### 2. 本地运行

在仓库根目录执行：

```bash
make -C packages/client-proxy run-local
```

默认端口：

- 代理流量：`http://localhost:3002`
- 健康检查：`http://localhost:3003`

如果你只是想验证服务起来了，可以直接：

```bash
curl http://localhost:3003/health
```

### 3. 本地请求示例

#### 方式 A：Header 路由（仅本地环境）

```bash
curl \
  -H 'E2b-Sandbox-Id: <sandbox-id>' \
  -H 'E2b-Sandbox-Port: 49983' \
  http://localhost:3002/
```

如果是 private ingress sandbox，再加：

```bash
-H 'e2b-traffic-access-token: <traffic-token>'
```

如果访问的是 secure envd，再加：

```bash
-H 'X-Access-Token: <envd-access-token>'
```

#### 方式 B：Host 路由

```bash
curl \
  -H 'Host: 49983-<sandbox-id>-<client-id>.localhost' \
  http://localhost:3002/
```

这个格式和测试里构造请求的方式一致。

### 4. 生产环境接入方式

在 Nomad job 里，client-proxy 被注册成一个 Traefik fallback 路由，规则是 `PathPrefix(`/`)`。这不是说它只看 path；真正的 sandbox 路由信息仍然在 `Host` 上，Traefik 只是把请求整体转发给 client-proxy。

实际生产接入通常意味着：

1. 给 client-proxy 配一个泛域名入口。
2. 客户端请求使用动态子域名编码 sandbox 端口和 sandboxID。
3. client-proxy 根据 host 查 catalog，并转到正确 orchestrator。

### 5. 测试

当前包的测试可以直接跑：

```bash
go test ./packages/client-proxy/...
```

这组测试主要覆盖：

- catalog hit / miss
- auto-resume 开关逻辑
- gRPC 错误到 proxy 错误的映射
- token 和端口参数是否正确透传给 resumer

## 九、几个实现细节上的关键结论

读完这套实现后，可以把 `packages/client-proxy` 总结成下面几句话：

1. 它是边缘路由层，不是 sandbox 生命周期管理器。
2. 它的第一职责是“按 sandboxID 找 orchestrator”，不是“直接找 sandbox”。
3. 它把 paused sandbox 恢复能力做成了 catalog miss 时的兜底路径。
4. 它依赖 Redis 作为分布式路由目录，本地内存 catalog 只是开发模式兜底。
5. 它故意把更靠近 sandbox 的问题，比如端口就绪、连接限制、端口关闭，留给 orchestrator proxy 处理。

如果你要继续读下一层代码，最值得跟进的是两个位置：

- `packages/orchestrator/pkg/proxy/proxy.go`
- `packages/api/internal/handlers/proxy_grpc.go`

前者解释“请求到了 orchestrator 节点以后怎么进 sandbox”，后者解释“catalog miss 时 paused sandbox 为什么能被安全地恢复”。
