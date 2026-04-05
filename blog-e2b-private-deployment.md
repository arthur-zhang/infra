# 在私有化机房从零部署 E2B：从内核配置到第一个沙箱

E2B 是一个开源的 AI 代码执行平台，底层基于 Firecracker microVM 为每个沙箱提供独立的虚拟机级隔离。虽然 E2B 默认部署在 GCP/AWS 上，但它的代码中已经内置了完整的本地存储支持——**你可以在自建机房的裸金属服务器上，零云服务依赖地运行整个 E2B 平台**。

本文将从系统内核配置到启动第一个 Firecracker 沙箱，结合 E2B 源码逐步拆解每个环节的实现细节。

---

## 目录

1. [架构总览：私有化部署需要什么](#1-架构总览)
2. [第一步：系统内核准备](#2-系统内核准备)
3. [第二步：启动基础设施服务](#3-基础设施服务)
4. [第三步：下载 Firecracker 和内核](#4-firecracker-和内核)
5. [第四步：构建 Envd](#5-构建-envd)
6. [第五步：启动 E2B 核心服务](#6-启动核心服务)
7. [第六步：构建基础模板](#7-构建基础模板)
8. [第七步：验证与使用](#8-验证与使用)
9. [深入：一个沙箱是如何被创建的](#9-沙箱创建流程)
10. [存储架构：如何脱离云存储](#10-存储架构)
11. [网络架构：每个 VM 的网络是怎么建的](#11-网络架构)
12. [生产环境扩展](#12-生产环境扩展)

---

## 1. 架构总览

私有化部署后的 E2B 架构如下：

```
用户 SDK
  ↓ HTTP
Client Proxy (:3002)
  ↓ Redis 查询沙箱位置
API (:3000)
  ↓ gRPC                    ⟷ PostgreSQL (:5432)
Orchestrator (:5008)         ⟷ Redis (:6379)
  ↓                          ⟷ ClickHouse (:8123)
Firecracker microVM
  ↓
Envd (:49983, VM 内守护进程)
  ↓
OTel Collector (:4317) → Loki + Tempo + Mimir → Grafana (:53000)
```

**核心组件**：

| 组件 | 职责 | 端口 |
|------|------|------|
| API | REST 网关，认证，沙箱调度 | 3000 |
| Orchestrator | Firecracker VM 生命周期管理 | 5007 (proxy), 5008 (gRPC) |
| Client Proxy | 用户流量路由到正确的沙箱 | 3002 |
| Envd | VM 内的进程管理和文件系统 API | 49983 (VM 内) |

**关键洞察**：E2B 代码中通过 `STORAGE_PROVIDER` 环境变量区分云存储和本地存储。设置为 `Local` 后，所有模板和快照都存储在本地文件系统，不需要修改任何代码。

---

## 2. 系统内核准备

### 2.1 硬件要求

| 项目 | 最低要求 | 推荐配置 |
|------|----------|----------|
| CPU | x86_64 + VT-x/AMD-V | 32 核以上 |
| 内存 | 32 GB | 128 GB+ |
| 磁盘 | 200 GB SSD | NVMe SSD |
| OS | Ubuntu 22.04+ | 内核 6.x |

Firecracker 需要 KVM 硬件虚拟化支持。**不能在普通的云 VM（没有嵌套虚拟化）上运行**，必须是裸金属服务器或启用了嵌套虚拟化的 VM。

### 2.2 加载内核模块

```bash
# KVM 虚拟化模块
sudo modprobe kvm_intel    # Intel CPU
# 或
sudo modprobe kvm_amd      # AMD CPU

# NBD（网络块设备）—— E2B 用它挂载沙箱磁盘镜像
sudo modprobe nbd nbds_max=64    # 本地开发用 64 个
                                  # 生产环境建议 4096
```

**NBD 为什么重要？** 每个 Firecracker VM 的 rootfs 通过 NBD 设备（`/dev/nbdX`）挂载。E2B 维护一个 NBD 设备池，在 Orchestrator 启动时初始化：

```go
// packages/orchestrator/pkg/sandbox/nbd/pool.go
func getMaxDevices() (uint, error) {
    data, err := os.ReadFile("/sys/module/nbd/parameters/nbds_max")
    if errors.Is(err, os.ErrNotExist) {
        return 0, ErrNBDModuleNotLoaded  // ← 如果模块没加载，直接报错
    }
    maxDevices, _ := strconv.ParseUint(strings.TrimSpace(string(data)), 10, 0)
    return uint(maxDevices), nil
}
```

设备池启动时会预填充最多 64 个就绪 slot，通过 bitset 跟踪每个 NBD 设备的使用状态：

```go
func NewDevicePool() (*DevicePool, error) {
    maxDevices, err := getMaxDevices()
    // ...
    pool := &DevicePool{
        usedSlots: bitset.New(maxDevices),
        slots:     make(chan DeviceSlot, min(64, maxDevices)),
    }
    go pool.populate()  // 后台持续填充就绪设备
    return pool, nil
}
```

### 2.3 配置 HugePages

```bash
sudo sysctl -w vm.nr_hugepages=2048   # 分配约 4GB 的 2MB 大页
```

Firecracker 使用 HugePages 提升内存性能。在 `packages/orchestrator/pkg/sandbox/fc/client.go` 中配置 VM 时会启用：

```go
func (p *Process) setMachineConfig(ctx context.Context, vcpuCount int64, memSizeMib int64, hugePages bool) error {
    config := models.MachineConfiguration{
        VcpuCount:  &vcpuCount,
        MemSizeMib: &memSizeMib,
        HugePages:  hugePages ? models.HugePagesHugePagesSize2M : models.HugePagesNone,
    }
    // PUT /machine-config → Firecracker HTTP API
}
```

### 2.4 配置 udev 规则

```bash
echo 'ACTION=="add|change", KERNEL=="nbd*", OPTIONS:="nowatch"' | \
  sudo tee /etc/udev/rules.d/97-nbd-device.rules
sudo udevadm control --reload-rules
```

大量 NBD 设备会产生大量 inotify 事件，这条 udev 规则禁用对 NBD 设备的 inotify 监控，避免不必要的系统开销。

### 2.5 验证 Cgroup v2

```bash
cat /sys/fs/cgroup/cgroup.controllers
# 输出应包含: cpu memory
```

E2B 使用 cgroup v2 对每个沙箱进行资源隔离。Orchestrator 启动时会在 `/sys/fs/cgroup/e2b` 下创建根 cgroup：

```go
// packages/orchestrator/pkg/sandbox/cgroup/manager.go
func (m *managerImpl) Initialize() error {
    // 创建根 cgroup 目录
    err := os.MkdirAll(m.rootPath, 0o755)  // /sys/fs/cgroup/e2b

    // 启用 CPU 和内存控制器
    err = os.WriteFile(
        filepath.Join(m.rootPath, "cgroup.subtree_control"),
        []byte("+cpu +memory"),
        0o644,
    )
    return err
}
```

每个沙箱会创建自己的 cgroup 子目录，并通过 `CLONE_INTO_CGROUP` 在进程创建时原子地将 Firecracker 进程放入 cgroup：

```go
func (m *managerImpl) Create(name string) (*CgroupHandle, error) {
    path := filepath.Join(m.rootPath, name)
    os.MkdirAll(path, 0o755)
    file, _ := os.Open(path)  // 打开目录 FD

    return &CgroupHandle{
        path: path,
        file: file,  // 这个 FD 传给 SysProcAttr.CgroupFD
    }, nil
}
```

### 2.6 验证清单

```bash
ls -la /dev/kvm              # ✓ KVM 可用
lsmod | grep -E "kvm|nbd"    # ✓ 内核模块已加载
cat /sys/fs/cgroup/cgroup.controllers  # ✓ cgroup v2 启用
cat /proc/meminfo | grep Huge          # ✓ HugePages 已分配
ls /dev/nbd0                           # ✓ NBD 设备存在
```

---

## 3. 基础设施服务

E2B 需要 PostgreSQL、Redis、ClickHouse 和一套可观测性服务。本地开发使用 Docker Compose 一键启动：

```bash
make local-infra
```

这条命令实际执行 `packages/local-dev/docker-compose.yaml`，启动以下服务：

```yaml
services:
  postgres:
    image: postgres:17.4
    ports: ["5432:5432"]        # 主数据库：集群配置、团队、模板元数据

  redis:
    image: redis:7.4.2
    ports: ["6379:6379"]        # 沙箱路由表 + 缓存

  clickhouse:
    image: clickhouse:25.4.5.24
    ports: ["8123:8123", "9000:9000"]  # 分析指标

  grafana:
    image: grafana/grafana:12.0.0
    ports: ["53000:3000"]       # 可视化面板

  loki:
    image: grafana/loki:3.4.1
    ports: ["3100:3100"]        # 日志聚合

  tempo:
    image: grafana/tempo:2.8.2  # 分布式追踪

  mimir:
    image: grafana/mimir:2.17.1 # 指标存储

  otel-collector:
    image: otel/opentelemetry-collector-contrib:0.146.0
    ports: ["4317:4317", "4318:4318"]  # 遥测数据收集

  vector:
    image: timberio/vector:0.34.X-alpine
    ports: ["30006:30006"]      # 日志路由
```

### 初始化数据库

```bash
# PostgreSQL：创建表结构（使用 goose 迁移工��）
make -C packages/db migrate-local

# ClickHouse：创建分析表
make -C packages/clickhouse migrate-local

# 创建默认用户、团队和 API Key
make -C packages/local-dev seed-database
```

seed 命令执行 `packages/local-dev/seed-local-database.go`，会创建：

- 测试用户 UUID: `fb69f46f-eb51-4a87-a14e-306f7a3fd89c`
- 测试团队 UUID: `0b8a3ded-4489-4722-afd1-1d82e64ec2d5`
- API Key: `e2b_53ae1fed82754c17ad8077fbc8bcdd90`
- Access Token: `sk_e2b_89215020937a4c989cde33d7bc647715`

---

## 4. Firecracker 和内核

E2B 使用定制版本的 Firecracker 和预编译的 Linux 内核：

```bash
make download-public-kernels        # Guest 内核: vmlinux-6.1.158
make download-public-firecrackers   # Firecracker: v1.12.1
```

下载完成后，二进制文件存放在：

```
/fc-kernels/vmlinux-6.1.158/vmlinux.bin   ← Guest 内核
/fc-versions/v1.12.1/firecracker          ← Firecracker VMM
```

Orchestrator 启动时通过配置定位这些文件：

```go
// packages/orchestrator/pkg/sandbox/fc/config.go
func (c Config) HostKernelPath(builderConfig cfg.BuilderConfig) string {
    return filepath.Join(
        builderConfig.HostKernelsDir,    // 默认 /fc-kernels
        c.KernelVersion,                  // 如 vmlinux-6.1.158
        "vmlinux.bin",
    )
}

func (c Config) FirecrackerPath(builderConfig cfg.BuilderConfig) string {
    return filepath.Join(
        builderConfig.FirecrackerVersionsDir,  // 默认 /fc-versions
        c.FirecrackerVersion,                   // 如 v1.12.1
        "firecracker",
    )
}
```

在 `NewProcess()` 中会验证文件是否存在：

```go
// packages/orchestrator/pkg/sandbox/fc/process.go
func NewProcess(...) (*Process, error) {
    // 验证 Firecracker 二进制存在
    _, err = os.Stat(versions.FirecrackerPath(config))
    if err != nil {
        return nil, fmt.Errorf("firecracker binary not found: %w", err)
    }

    // 验证内核文件存在
    _, err = os.Stat(versions.HostKernelPath(config))
    if err != nil {
        return nil, fmt.Errorf("kernel not found: %w", err)
    }
    // ...
}
```

---

## 5. 构建 Envd

Envd 是运行在每个 Firecracker VM 内部的守护进程，提供进程管理和文件系统 API：

```bash
make -C packages/envd build
```

这会编译一个静态链接的 Go 二进制，放到 `/fc-envd/envd`：

```makefile
# packages/envd/Makefile
build:
    CGO_ENABLED=0 GOOS=linux GOARCH=$(BUILD_ARCH) go build \
        -a -o bin/envd \
        -ldflags "-X=main.commitSHA=$(BUILD)" .
```

`CGO_ENABLED=0` 确保生成纯静态二进制，可以在 Firecracker VM 的最小 Linux 环境中运行。

Envd 启动后��听端口 49983，通过 Connect-RPC（HTTP + Protobuf）提供两大 API：

- **进程管理**（`spec/process/process.proto`）：Start、Connect、SendInput、SendSignal
- **文件系统**（`spec/filesystem/filesystem.proto`）：Stat、MakeDir、ListDir、WatchDir

Envd 通过轮询 Firecracker 的 MMDS（MetaData Service，`169.254.169.254`）获取沙箱元数据：

```go
// packages/envd/internal/host/mmds.go
// 每 50ms 轮询一次，获取 SandboxID、TemplateID 等
```

---

## 6. 启动核心服务

三个服务需要分别在不同终端启动：

### 6.1 API 服务

```bash
make -C packages/api run-local    # → http://localhost:3000
```

API 服务是 REST 网关，使用 Gin 框架。它负责：
- JWT 认证
- 沙箱创建/删除请求处理
- **节点发现和调度**——通过轮询 Nomad（生产）或直连（本地）发现 Orchestrator 节点

本地模式下的关键配置（`packages/api/.env.local`）：

```bash
POSTGRES_CONNECTION_STRING=postgresql://postgres:postgres@127.0.0.1:5432/postgres
REDIS_URL=redis://localhost:6379
NOMAD_ADDRESS=http://localhost:4646
```

### 6.2 Orchestrator

```bash
make -C packages/orchestrator build-debug
sudo make -C packages/orchestrator run-local    # → http://localhost:5008
```

**需要 sudo**，因为 Firecracker 需要 root 权限来操作 KVM、网络命名空间和 cgroup。

Orchestrator 的启动序列非常关键（`packages/orchestrator/pkg/factories/run.go`），按顺序初始化 20+ 个子系统：

```
1.  遥测初始化（OpenTelemetry）
2.  日志系统（Zap + OTEL）
3.  特性开关（LaunchDarkly，可选）
4.  存储提供者（Local 或 GCS/S3）
5.  模板缓存
6.  Cgroup 管理器 → Initialize()
7.  NBD 设备池 → NewDevicePool()
8.  网络池 → NewPool(32, 100, ...)
9.  沙箱工厂
10. gRPC 服务器（SandboxService + InfoService）
11. HTTP 服务器（/health + /upload）
12. 沙箱代理（端口 5007）
```

每一步失败都会阻止启动。最常见的失败原因：

| 错误 | 原因 | 解决方案 |
|------|------|----------|
| `ErrNBDModuleNotLoaded` | NBD 模块未加载 | `sudo modprobe nbd nbds_max=64` |
| `permission denied: /dev/kvm` | 没有 KVM 权限 | 用 sudo 运行 |
| `cgroup.controllers not found` | cgroup v2 未启用 | 检查内核启动参数 |
| `firecracker binary not found` | FC 二进制未下载 | `make download-public-firecrackers` |

### 6.3 Client Proxy

```bash
make -C packages/client-proxy run-local    # → http://localhost:3002
```

Client Proxy 是用户流量的入口。它查询 Redis 获取沙箱所在的 Orchestrator IP，然后转发请求：

```go
// packages/client-proxy/internal/cfg/model.go
type Config struct {
    HealthPort       uint16 // 默认 3003
    ProxyPort        uint16 // 默认 3002
    RedisURL         string // Redis 连接
    ApiGrpcAddress   string // API gRPC 地址，用于自动恢复暂停的沙箱
}
```

---

## 7. 构建基础模板

```bash
make -C packages/shared/scripts local-build-base-template
```

这是**首次运行的关键步骤**——它创建第一个 Firecracker VM 快照，作为所有后续沙箱的基础模板。

构建过程（`packages/orchestrator/pkg/template/build/builder.go`）：

```
1. 拉取基础 Docker 镜像 → 提取文件系统
2. 注入 E2B 组件（envd、DNS 配置、引导脚本）
3. 第一次启动 Firecracker VM（BusyBox init）→ 安装 systemd
4. 第二次启动（systemd init）→ 等待 envd 在 :49983 就绪
5. 运行就绪检查
6. 暂停 VM → 生成快照
   ├─ memfile.bin    （内存状态）
   ├─ rootfs.ext4    （文件系统）
   ├─ snapfile.bin   （VM 状态）
   └─ metadata.json  （元数据）
7. 存储到本地文件系统
```

模板存储在 `LOCAL_TEMPLATE_STORAGE_BASE_PATH`（默认 `/tmp/templates`）下。

---

## 8. 验证与使用

### 健康检查

```bash
curl http://localhost:3000/health    # API
curl http://localhost:3002/health    # Client Proxy
curl http://localhost:5008/health    # Orchestrator
```

### SDK 连接

```python
from e2b import Sandbox
import os

os.environ["E2B_API_KEY"] = "e2b_53ae1fed82754c17ad8077fbc8bcdd90"
os.environ["E2B_ACCESS_TOKEN"] = "sk_e2b_89215020937a4c989cde33d7bc647715"
os.environ["E2B_API_URL"] = "http://localhost:3000"
os.environ["E2B_SANDBOX_URL"] = "http://localhost:3002"

sandbox = Sandbox()
result = sandbox.run("echo 'Hello from Firecracker!'")
print(result.stdout)  # Hello from Firecracker!
```

---

## 9. 深入：一个沙箱是如何被创建的

当用户调用 `Sandbox()` 时，背后发生了什么？

### 9.1 API 接收请求

API 收到 `POST /sandboxes` 请求后，使用 **Best-of-K 调度算法** 选择目标 Orchestrator 节点：

```go
// packages/api/internal/orchestrator/placement/placement_best_of_K.go
func (b *BestOfK) chooseNode(ctx context.Context, nodes []*nodemanager.Node, ...) (*nodemanager.Node, error) {
    // 1. 随机采样 K=3 个节点
    candidates := b.sample(nodes, config, excludedNodes, resources, ...)

    // 2. 对每个候选评分
    bestScore := math.MaxFloat64
    for _, node := range candidates {
        score := b.Score(node, resources, config)
        if score < bestScore {
            bestNode = node
            bestScore = score
        }
    }
    return bestNode, nil
}

// 评分公式
func (b *BestOfK) Score(node *nodemanager.Node, resources SandboxResources, config BestOfKConfig) float64 {
    metrics := node.Metrics()
    reserved := metrics.CpuAllocated
    usageAvg := float64(metrics.CpuPercent) / 100
    cpuCount := float64(metrics.CpuCount)
    totalCapacity := config.R * cpuCount  // R=4.0 超分比

    return (float64(resources.CPUs) + float64(reserved) + config.Alpha*usageAvg) / totalCapacity
}
```

本地开发只有一个节点，所以调度总是选它。但这套机制在多节点部署时自动生效。

### 9.2 Orchestrator 创建 VM

Orchestrator 收到 gRPC `SandboxCreate` 请求后，执行 `Factory.CreateSandbox()`：

**Step 1: 分配网络**

```go
// packages/orchestrator/pkg/sandbox/network/pool.go
slot, err := pool.Get(ctx)
// 从预创建的网络池中获取一个 slot
// 包含：网络命名空间、veth pair、TAP 设备、IP 地址
```

**Step 2: 准备存储**

```go
// 创建 Copy-on-Write overlay：模板（只读）+ Cache（写入层）
// 通过 NBD 设备挂载到 /dev/nbdX
rootfsProvider := rootfs.NewNBDProvider(template, nbdDevice, cache)
```

**Step 3: 生成启动脚本并启动 Firecracker**

```go
// packages/orchestrator/pkg/sandbox/fc/process.go
cmd := exec.CommandContext(execCtx,
    "unshare", "-m", "--",          // 新的 mount namespace
    "bash", "-c", startScript.Value, // 包含 ip netns exec 和 firecracker 命令
)
cmd.SysProcAttr = &syscall.SysProcAttr{
    Setsid:      true,
    UseCgroupFD: true,
    CgroupFD:    cgroupFD,  // 原子放入 cgroup
}
cmd.Start()
```

生成的启动脚本大致如下：

```bash
mount --make-rprivate / &&
mount -t tmpfs tmpfs /fc-vm -o X-mount.mkdir &&
ln -s /path/to/rootfs.ext4 /fc-vm/rootfs.ext4 &&
mkdir -p /fc-vm/kernel &&
ln -s /fc-kernels/vmlinux-6.1.158/vmlinux.bin /fc-vm/kernel/vmlinux &&
ip netns exec ns-1 /fc-versions/v1.12.1/firecracker --api-sock /tmp/fc.sock
```

**Step 4: 通过 Firecracker HTTP API 配置 VM**

Firecracker 启动后监听 Unix socket，Orchestrator 通过 HTTP API 配置：

```go
// packages/orchestrator/pkg/sandbox/fc/client.go
p.client.setBootSource(ctx, kernelPath, kernelArgs)       // PUT /boot-source
p.client.setRootfsDrive(ctx, rootfsPath)                   // PUT /drives/rootfs
p.client.setNetworkInterface(ctx, tapDevice, rateLimiter)  // PUT /network-interfaces/eth0
p.client.setMachineConfig(ctx, vcpu, memMB, hugePages)     // PUT /machine-config
p.client.setEntropyDevice(ctx)                             // PUT /entropy
p.client.startVM(ctx)                                      // PUT /actions {type: InstanceStart}
```

**Step 5: 等待 Envd 就绪**

```go
// VM 启动后，轮询 envd 的 /init 端点
// 超时由 ENVD_TIMEOUT 配置（默认 10s）
```

**Step 6: 注册到 Redis**

```go
// packages/shared/pkg/sandbox-catalog/catalog_redis.go
// Key: sandbox:catalog:{sandboxId}
// Value: { orchestrator_ip, execution_id, started_at, max_length_hours }
catalog.StoreSandbox(ctx, sandboxID, info, expiration)
```

---

## 10. 存储架构：如何脱离云存储

E2B 的存储抽象层位于 `packages/shared/pkg/storage/`，支持三种后端：

```go
// packages/shared/pkg/storage/storage.go
type Provider string

const (
    GCPStorageProvider   Provider = "GCPBucket"
    AWSStorageProvider   Provider = "AWSBucket"
    LocalStorageProvider Provider = "Local"
)
```

设置 `STORAGE_PROVIDER=Local` 后，所有存储操作走本地文件系统：

```go
// packages/shared/pkg/storage/storage_fs.go
type fsStorage struct {
    basePath  string   // 本地存储根目录
    uploadURL string   // 签名 URL 的基地址
    hmacKey   []byte   // HMAC 签名密钥
}

func (o *fsObject) Put(ctx context.Context, data []byte) error {
    dir := filepath.Dir(o.path)
    os.MkdirAll(dir, 0o755)
    return os.WriteFile(o.path, data, 0o644)
}

func (o *fsObject) ReadAt(ctx context.Context, buff []byte, off int64) (int, error) {
    f, _ := os.Open(o.path)
    defer f.Close()
    return f.ReadAt(buff, off)
}
```

两个关键存储配置：

```go
// 模板存储
var TemplateStorageConfig = StorageConfig{
    GetLocalBasePath: func() string {
        return env.GetEnv("LOCAL_TEMPLATE_STORAGE_BASE_PATH", "/tmp/templates")
    },
}

// 构建缓存
var BuildCacheStorageConfig = StorageConfig{
    GetLocalBasePath: func() string {
        return env.GetEnv("LOCAL_BUILD_CACHE_STORAGE_BASE_PATH", "/tmp/build-cache")
    },
}
```

**上传签名机制**：本地模式使用 HMAC-SHA256 生成签名 URL，防止未授权上传：

```go
func (s *fsStorage) UploadSignedURL(ctx context.Context, path string, ttl time.Duration) (string, error) {
    expires := time.Now().Add(ttl).Unix()
    token := ComputeUploadHMAC(s.hmacKey, path, expires)
    return fmt.Sprintf("%s/upload?path=%s&expires=%d&token=%s",
        s.uploadURL, url.QueryEscape(path), expires, token), nil
}
```

---

## 11. 网络架构：每个 VM 的网络是怎么建的

每个沙箱拥有独立的 Linux 网络命名空间。E2B 预创建了两个网络池（`packages/orchestrator/pkg/sandbox/network/pool.go`）：

```go
func NewPool(newSlotsPoolSize, reusedSlotsPoolSize int, ...) *Pool {
    newSlots := make(chan *Slot, 31)     // 32 个新建 slot
    reusedSlots := make(chan *Slot, 100) // 100 个回收 slot
}
```

获取 slot 时**优先使用回收池**（回收 slot 只需重置防火墙规则，比新建快得多）：

```go
func (p *Pool) Get(ctx context.Context) (*Slot, error) {
    select {
    case slot := <-p.reusedSlots:  // 优先回收池
        return slot, nil
    default:
    }
    select {
    case slot := <-p.newSlots:     // 其次新建池
        return slot, nil
    case slot := <-p.reusedSlots:
        return slot, nil
    }
}
```

### IP 地址分配

每个 slot 分配独立的 IP（`packages/orchestrator/pkg/sandbox/network/slot.go`）：

```go
const (
    defaultHostNetworkCIDR = "10.11.0.0/16"  // 宿主侧 IP
    defaultVrtNetworkCIDR  = "10.12.0.0/16"  // veth pair IP
)

// 第 N 个 slot 的 IP 分配：
// Host IP:  10.11.0.N/32
// Vpeer IP: 10.12.0.(N*2+1)/31    ← 沙箱网关
// Veth IP:  10.12.0.(N*2)/31      ← 宿主侧
// TAP IP:   169.254.0.22/30       ← Firecracker 使用（所有 slot 相同）
```

/16 网段支持最多 **32,766 个并发沙箱**。

### 命名空间创建过程

`Slot.CreateNetwork()`（`packages/orchestrator/pkg/sandbox/network/network.go`）的完整步骤：

```
1.  runtime.LockOSThread()                    ← 防止 goroutine 切线程
2.  netns.NewNamed("ns-{idx}")                ← 创建命名空间
3.  创建 veth pair（veth-{idx} ↔ eth0）
4.  �� veth-{idx} 移到宿主命名空间
5.  配置 vpeer IP（沙箱侧网关）
6.  配置 veth IP（宿主侧）
7.  创建 TAP 设备 tap0（Firecracker 用）
8.  设置 loopback up
9.  添加默认路由（经 veth → 宿主）
10. 配置 iptables NAT（SNAT + DNAT）
11. 初始化 nftables 防火墙
12. 在宿主添加到沙箱的路由
13. 配置代理重定向（HTTP→hyperloop, NFS→nfs-proxy）
```

---

## 12. 生产环境扩展

单机跑通后，扩展到多节点生产集群的关键步骤：

### 12.1 架构

```
控制节点（1-3 台）
  ├─ Nomad Server + Consul Server
  ├─ PostgreSQL（主从复制）
  ├─ Redis Cluster
  └─ ClickHouse

API 节点（2+ 台，无状态）
  ├─ API 服务
  └─ Client Proxy

计算节点（N 台）
  ├─ Orchestrator（作为 Nomad Client 运行）
  ├─ KVM + cgroup v2 + nbd + hugepages
  └─ NFS 挂载共享模板存储
```

### 12.2 共享存储

多节点部署时，所有计算节点需要访问相同的模板文件。两种方案：

1. **NFS 共享**：将 `LOCAL_TEMPLATE_STORAGE_BASE_PATH` 指向 NFS 挂载点
2. **MinIO**：设置 `STORAGE_PROVIDER=AWSBucket` 并指向自建的 MinIO

### 12.3 节点发现

部署 Nomad 集群后，API 会每 5 秒轮询 Nomad Allocations API 发现 Orchestrator 节点：

```go
// packages/shared/pkg/clusters/discovery/nomad.go
func ListOrchestratorAndTemplateBuilderAllocations(ctx, client, filter) {
    options := &nomadapi.QueryOptions{
        Filter: "ClientStatus == \"running\" and TaskGroup == \"client-orchestrator\"",
    }
    results, _, _ := client.Allocations().List(options)
    // 每个 allocation 对应一个 orchestrator 实例
}
```

新节点加入 Nomad 集群后，会在 5 秒内被自动发现并加入调度池。

### 12.4 环境变量参考

生产环境关键配置：

```bash
# 通用
STORAGE_PROVIDER=Local
DOMAIN_NAME=sandbox.yourdomain.com

# API
POSTGRES_CONNECTION_STRING=postgresql://user:pass@db:5432/e2b
REDIS_URL=redis://redis:6379
NOMAD_ADDRESS=http://nomad-server:4646
CLICKHOUSE_CONNECTION_STRING=clickhouse://ch:9000/default

# Orchestrator
ORCHESTRATOR_SERVICES=orchestrator,template-manager
GRPC_PORT=5008
PROXY_PORT=5007
NODE_IP=<本机IP>
LOCAL_TEMPLATE_STORAGE_BASE_PATH=/mnt/nfs/templates
FIRECRACKER_VERSIONS_DIR=/fc-versions
HOST_KERNELS_DIR=/fc-kernels
HOST_ENVD_PATH=/fc-envd/envd

# Client Proxy
PROXY_PORT=3002
REDIS_URL=redis://redis:6379
API_GRPC_ADDRESS=api:5009
```

---

## 总结

E2B 的私有化部署并不复杂——核心要求是一台支持 KVM 的 Linux 服务器和几个标准的开源服务（PostgreSQL、Redis、ClickHouse）。E2B 代码中已经内置了完整的本地存储支持（`STORAGE_PROVIDER=Local`），无需任何代码修改即可脱离云服务运行。

关键步骤回顾：

```
1. 系统准备：modprobe kvm/nbd, hugepages, cgroup v2
2. 基础设施：make local-infra（Docker Compose 一键启动）
3. 初始化：数据库迁移 + seed
4. 下载：Firecracker 二进制 + Linux 内核
5. 构建：envd（VM 内守护进程）
6. 启动：API + Orchestrator (sudo) + Client Proxy
7. 模板：构建基础模板（首次必需）
8. 验证：SDK 连接并创建第一个沙箱
```

从 `sudo modprobe nbd` 到 `sandbox.run("echo hello")`，整个过程不依赖任何云厂商账号。
