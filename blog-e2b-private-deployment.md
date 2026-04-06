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
10. [深入：NBD——E2B 磁盘 I/O 的核心机制](#10-nbd)
11. [存储架构：如何脱离云存储](#11-存储架构)
12. [网络架构：每个 VM 的网络是怎么建的](#12-网络架构)
13. [生产环境扩展](#13-生产环境扩展)

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

### 初始化数据库和环境

基础设施服务启动后，需要初始化数据库 schema 和种子数据。以下逐一拆解每条命令。

#### 3.1 `make -C packages/db migrate-local` — 初始化 PostgreSQL

```makefile
# packages/db/Makefile
goose-local := GOOSE_DBSTRING=postgres://postgres:postgres@localhost:5432/postgres?sslmode=disable \
               go tool goose -table "_migrations" -dir "migrations" postgres

migrate-local:
	@$(goose-local) up
```

使用 [goose](https://github.com/pressly/goose) 迁移工具，连接本地 PostgreSQL，按顺序执行 `packages/db/migrations/` 下的所有 SQL 迁移文件。

迁移文件按时间戳排序，从最早的建表语句到最新的 schema 变更：

```
packages/db/migrations/
  ├── 20000101000000_auth.sql                          ← 认证 schema
  ├── 20231124185944_create_schemas_and_tables.sql      ← 核心表：teams, envs, snapshots...
  ├── 20250606213446_deployment_cluster.sql             ← clusters 表
  ├── ...（共 60+ 个迁移文件）
  └── 20260316130000_repoint_user_fks_to_public_users.sql ← 最新迁移
```

迁移记录存储在 `_migrations` 表中，已执行过的不会重复执行。如果你中途新增了迁移文件，再次运行 `migrate-local` 只会执行新增的部分。

**如果报错**：通常是 PostgreSQL 还没启动完成。等 Docker 容器 healthy 后再执行。

#### 3.2 `make -C packages/clickhouse migrate-local` — 初始化 ClickHouse

```makefile
# packages/clickhouse/Makefile
migrate-local:
	GOOSE_DBSTRING="clickhouse://clickhouse:clickhouse@localhost:9000/default" \
	go tool goose -table "_migrations" -dir "migrations" clickhouse up
```

同样使用 goose，但驱动切换为 `clickhouse`。ClickHouse 用于存储沙箱运行指标和分析数据：

```
packages/clickhouse/migrations/
  ├── 20250521131545_add_metrics_local.sql       ← 本地环境指标表
  ├── 20250725223340_add_sandbox_events_local.sql ← 沙箱事件表
  ├── 20250801113224_team_metrics.sql             ← 团队级别指标
  ├── 20260209152327_add_sandbox_host_stats.sql   ← 宿主机资源统计
  └── ...（共 20 个迁移文件）
```

ClickHouse 的迁移文件中带 `_local` 后缀的是专门为本地单节点环境设计的（使用 `MergeTree` 引擎而非分布式引擎）。

#### 3.3 `make -C packages/envd build` — 构建 Envd

```makefile
# packages/envd/Makefile
build:
	CGO_ENABLED=0 GOOS=linux GOARCH=$(BUILD_ARCH) go build -a -o bin/envd ${LDFLAGS}
```

编译 Envd——运行在每个 Firecracker VM 内部的守护进程。关键编译参数：

- `CGO_ENABLED=0`：纯静态链接，不依赖 glibc。因为 Firecracker VM 内是最小化 Linux 环境，可能没有标准 C 库
- `GOOS=linux GOARCH=$(BUILD_ARCH)`：交叉编译为 Linux（Firecracker 只支持 Linux 客户机）
- `-a`：强制重新编译所有包（确保静态链接完整）

编译产物 `bin/envd` 需要复制到 Orchestrator 可以访问的路径：

```bash
# Orchestrator 期望 envd 在这个路径（默认值）
HOST_ENVD_PATH=/fc-envd/envd
```

Envd 启动后在 VM 内监听 49983 端口，通过 Connect-RPC（HTTP + Protobuf）提供进程管理和文件系统 API。它是沙箱能力的核心——用户通过 SDK 执行代码、读写文件，最终都是 Envd 在 VM 内完成的。

#### 3.4 `make -C packages/local-dev seed-database` — 创建种子数据

```makefile
# packages/local-dev/Makefile
seed-database:
	go run seed-local-database.go
```

执行 `packages/local-dev/seed-local-database.go`，向 PostgreSQL 写入本地开发所需的用户、团队和认证令牌。

**创建的实体**：

```go
// packages/local-dev/seed-local-database.go
var (
    teamID         = uuid.MustParse("0b8a3ded-4489-4722-afd1-1d82e64ec2d5")
    userID         = uuid.MustParse("fb69f46f-eb51-4a87-a14e-306f7a3fd89c")
    userTokenValue = "89215020937a4c989cde33d7bc647715"
    teamTokenValue = "53ae1fed82754c17ad8077fbc8bcdd90"
)
```

具体流程：

```
1. upsertUser()       → 创建用户 user@e2b-dev.local
2. upsertTeam()       → 创建团队 "local-dev team"（slug: local-dev-team, tier: base_v1）
3. ensureUserIsOnTeam()→ 将用户加入团队，并设为默认团队
4. upsertUserToken()  → 创建 Access Token（SHA256 哈希后存储）
5. upsertTeamAPIKey() → 创建 Team API Key（SHA256 哈希后存储）
```

**安全细节**：令牌不是明文存储的。seed 程序会对令牌做 SHA256 哈希后才写入数据库，和生产环境使用相同的 `keys.NewSHA256Hashing()` 逻辑：

```go
func createTokenHash(prefix, accessToken string) (string, keys.MaskedIdentifier, error) {
    hasher := keys.NewSHA256Hashing()
    accessTokenBytes, _ := hex.DecodeString(tokenWithoutPrefix)
    accessTokenHash := hasher.Hash(accessTokenBytes)  // ← 数据库只存哈希
    accessTokenMask, _ := keys.MaskKey(prefix, tokenWithoutPrefix)
    return accessTokenHash, accessTokenMask, nil
}
```

所有 upsert 操作都使用 `ON CONFLICT DO NOTHING` 或 `ON CONFLICT DO UPDATE`，因此可以安全地多次执行。

**生成的凭证**（用于 SDK 连接）：

| 凭证 | 值 | 用途 |
|------|------|------|
| API Key | `e2b_53ae1fed82754c17ad8077fbc8bcdd90` | 团队级别的 API 认证 |
| Access Token | `sk_e2b_89215020937a4c989cde33d7bc647715` | 用户级别的访问令牌 |

> `e2b_` 和 `sk_e2b_` 前缀由 `keys.ApiKeyPrefix` 和 `keys.AccessTokenPrefix` 定义，SDK 会自动识别。

---

## 4. Firecracker 和内核

E2B 使用定制版本的 Firecracker 和预编译的 Linux 内核：

```bash
make download-public-kernels        # Guest 内核: vmlinux-6.1.158
make download-public-firecrackers   # Firecracker: v1.12.1
```

### 这两条命令做了什么？

**`make download-public-kernels`**：

```makefile
# Makefile:122
download-public-kernels:
	mkdir -p ./packages/fc-kernels
	gsutil cp -r gs://e2b-prod-public-builds/kernels/* ./packages/fc-kernels/
```

从 E2B 的公开 GCS 存储桶（`e2b-prod-public-builds`）下载预编译的 Linux 客户机内核。这些内核是 E2B 团队基于 Linux 6.1.158 源码定制编译的，包含 Firecracker 运行所需的最小化内核配置（virtio 驱动、ext4 文件系统等），去掉了不需要的模块以减小体积和启动时间。

下载后目录结构：

```
packages/fc-kernels/
  └── vmlinux-6.1.158/
        └── vmlinux.bin     # 未压缩的 ELF 内核镜像（Firecracker 要求 uncompressed）
```

> **注意**：Firecracker 不支持 bzImage/zImage 等压缩格式，必须使用未压缩的 `vmlinux` 格式。这也是为什么要用定制编译而不是直接用发行版内核。

**`make download-public-firecrackers`**：

```makefile
# Makefile:127
download-public-firecrackers:
	mkdir -p ./packages/fc-versions/builds/
	gsutil -m cp -r gs://e2b-prod-public-builds/firecrackers/* ./packages/fc-versions/builds/
	find ./packages/fc-versions/builds/ -name firecracker -exec chmod +x {} \;
```

下载 E2B 定制的 Firecracker 二进制文件（基于 v1.12.1），下载后自动 `chmod +x` 添加可执行权限。

这条命令做了三件事：
1. `mkdir -p` 创建目标目录
2. `gsutil -m cp -r` 并行（`-m`）递归下载所有 Firecracker 版本
3. `find ... -exec chmod +x` 遍历所有下载的 `firecracker` 文件，添加可执行权限

下载后目录结构：

```
packages/fc-versions/builds/
  └── v1.12.1_<commit>/
        └── firecracker     # Firecracker VMM 二进制（~5MB）
```

**什么是 Firecracker？** Firecracker 是一个用 Rust 编写的轻量级 VMM（Virtual Machine Monitor），通过 KVM 提供硬件级虚拟化隔离。它只有约 5MB，不包含 BIOS/UEFI、USB、显卡等传统 VM 组件——**只保留启动 Linux 内核所需的最小功能集**。E2B 在官方版本基础上做了定制，主要涉及快照恢复（UFFD）和内存管理方面的优化。

Firecracker 启动后通过 Unix socket 暴露 HTTP API，Orchestrator 通过这个 API 配置和控制 VM：

```
PUT /boot-source          ← 指定内核
PUT /drives/rootfs        ← 指定磁盘
PUT /network-interfaces   ← 指定网络
PUT /machine-config       ← 指定 CPU/内存
PUT /actions              ← 启动/暂停 VM
```

### 没有 `gsutil` 怎么办？

`gsutil` 是 Google Cloud SDK 的一部分。如果你的机房无法安装或不想安装 GCP 工具链，这个公开 GCS 桶也支持 HTTP 直接访问：

```bash
# 手动下载内核（替代 gsutil）
mkdir -p ./packages/fc-kernels/vmlinux-6.1.158
curl -o ./packages/fc-kernels/vmlinux-6.1.158/vmlinux.bin \
  "https://storage.googleapis.com/e2b-prod-public-builds/kernels/vmlinux-6.1.158/vmlinux.bin"

# 手动下载 Firecracker（查看可用版本后替换 VERSION）
mkdir -p ./packages/fc-versions/builds/<VERSION>
curl -o ./packages/fc-versions/builds/<VERSION>/firecracker \
  "https://storage.googleapis.com/e2b-prod-public-builds/firecrackers/<VERSION>/firecracker"
chmod +x ./packages/fc-versions/builds/<VERSION>/firecracker
```

或者你也可以自行从源码编译：
- **内核**：从 [kernel.org](https://kernel.org) 下载 6.1.x 源码，使用 Firecracker 推荐的 `.config` 编译
- **Firecracker**：从 [E2B 的 fc-versions 仓库](https://github.com/e2b-dev/fc-versions) 构建

### 下载了多个版本，E2B 怎么选？

GCS 桶里有多个 Firecracker 和内核版本，`gsutil cp -r` 会全部下载。那 E2B 怎么决定用哪个？

#### 版本选择的完整链路

```
用户创建模板（SDK/CLI）
  ↓
API 层：从 feature flag 获取默认版本
  ↓ 写入数据库（模板构建记录）
模板构建：用指定版本的 FC + 内核创建快照
  ↓ 版本信息持久化到模板 metadata.json
用户创建沙箱
  ↓ 从模板的 Build 记录读取版本
API → Orchestrator gRPC 请求（携带版本号）
  ↓
Orchestrator：ResolveFirecrackerVersion() 解析短版本号
  ↓ 拼接文件路径 → os.Stat() 验证存在 → 启动 VM
```

#### 1. 默认版本定义

版本的"真相源"在 `packages/shared/pkg/featureflags/flags.go`：

```go
// 内核：只有一个默认版本
const DefaultKernelVersion = "vmlinux-6.1.158"

// Firecracker：支持多版本并存
const (
    DefaultFirecackerV1_10Version = "v1.10.1_30cbb07"
    DefaultFirecackerV1_12Version = "v1.12.1_210cbac"
    DefaultFirecrackerVersion     = DefaultFirecackerV1_12Version  // 当前默认
)
```

版本号格式是 `v{major}.{minor}.{patch}_{git_short_sha}`，包含 git commit 以区分同版本的不同构建。

#### 2. 版本别名映射

E2B 维护一个短版本号 → 完整版本号的映射表：

```go
var FirecrackerVersionMap = map[string]string{
    "v1.10": "v1.10.1_30cbb07",
    "v1.12": "v1.12.1_210cbac",
}
```

这个映射可以通过 LaunchDarkly feature flag（`firecracker-versions`）动态更新。本地部署没有 LaunchDarkly 时，使用上面的硬编码默认值。

#### 3. 模板构建时的版本选择

当用户构建模板时，API 从 feature flag 获取版本：

```go
// packages/api/internal/handlers/template_request_build_v3.go
firecrackerVersion := featureFlags.StringFlag(ctx, featureflags.BuildFirecrackerVersion)
// BuildFirecrackerVersion 的默认值 = DefaultFirecrackerVersion = "v1.12.1_210cbac"
```

版本号随后写入数据库的 Build 记录，与模板绑定。

#### 4. 沙箱创建时的版本解析

当用户从模板创建沙箱时，版本号从 Build 记录中读取，通过 gRPC 传给 Orchestrator：

```go
// packages/api/internal/orchestrator/create_instance.go
// 从数据库的 Build 记录读取版本
KernelVersion:      sbxData.Build.KernelVersion,       // "vmlinux-6.1.158"
FirecrackerVersion: sbxData.Build.FirecrackerVersion,   // "v1.12.1_210cbac"
```

Orchestrator 收到后，通过 `ResolveFirecrackerVersion()` 做一次版本解析：

```go
// packages/orchestrator/pkg/server/sandboxes.go:158
resolvedFCVersion := featureflags.ResolveFirecrackerVersion(
    ctx, s.featureFlags, req.GetSandbox().GetFirecrackerVersion(),
)

config := sandbox.Config{
    FirecrackerConfig: fc.Config{
        KernelVersion:      req.GetSandbox().GetKernelVersion(),
        FirecrackerVersion: resolvedFCVersion,  // 解析后的完整版本
    },
}
```

解析逻辑：从 `v1.12.1_210cbac` 提取 `v1.12`，在映射表中查找，如果映射表有新版本就用新版本，否则用原值：

```go
// packages/shared/pkg/featureflags/flags.go:263
func ResolveFirecrackerVersion(ctx context.Context, ff *Client, buildVersion string) string {
    // "v1.12.1_210cbac" → 提取 "v1.12"
    parts := strings.Split(buildVersion, "_")
    versionParts := strings.Split(strings.TrimPrefix(parts[0], "v"), ".")
    key := fmt.Sprintf("v%s.%s", versionParts[0], versionParts[1])  // "v1.12"

    // 在映射表中查找
    versions := ff.JSONFlag(ctx, FirecrackerVersions).AsValueMap()
    if resolved, ok := versions.Get(key).AsOptionalString().Get(); ok {
        return resolved  // 映射表中的版本（可能是更新的 patch 版本）
    }

    return buildVersion  // 映射表中没有，用原值
}
```

**这个机制的巧妙之处**：可以通过更新 feature flag 映射表，让所有 `v1.12` 系列的模板自动使用新的 Firecracker 补丁版本，而不需要重新构建模板。

#### 5. 最终路径拼接

版本号确定后，Orchestrator 拼接文件路径：

```go
// packages/orchestrator/pkg/sandbox/fc/config.go
func (c Config) HostKernelPath(builderConfig cfg.BuilderConfig) string {
    return filepath.Join(
        builderConfig.HostKernelsDir,    // 默认 /fc-kernels
        c.KernelVersion,                  // "vmlinux-6.1.158"
        "vmlinux.bin",
    )
    // → /fc-kernels/vmlinux-6.1.158/vmlinux.bin
}

func (c Config) FirecrackerPath(builderConfig cfg.BuilderConfig) string {
    return filepath.Join(
        builderConfig.FirecrackerVersionsDir,  // 默认 /fc-versions
        c.FirecrackerVersion,                   // "v1.12.1_210cbac"
        "firecracker",
    )
    // → /fc-versions/v1.12.1_210cbac/firecracker
}
```

在启动 Firecracker 进程前，会用 `os.Stat()` 验证文件确实存在：

```go
// packages/orchestrator/pkg/sandbox/fc/process.go
func NewProcess(...) (*Process, error) {
    _, err = os.Stat(versions.FirecrackerPath(config))
    if err != nil {
        return nil, fmt.Errorf("firecracker binary not found: %w", err)
    }

    _, err = os.Stat(versions.HostKernelPath(config))
    if err != nil {
        return nil, fmt.Errorf("kernel not found: %w", err)
    }
}
```

#### 总结

```
                     下载的文件（多版本并存）
                     ┌─────────────────────────────────────┐
                     │ /fc-kernels/                         │
                     │   └── vmlinux-6.1.158/vmlinux.bin    │
                     │ /fc-versions/                        │
                     │   ├── v1.10.1_30cbb07/firecracker   │
                     │   └── v1.12.1_210cbac/firecracker   │ ← 当前默认
                     └─────────────────────────────────────┘
                                    ↑
                                    │ os.Stat() 验证 + filepath.Join() 拼接
                                    │
              版本选择链路
              ┌──────────────────────────────────┐
              │ 1. 硬编码默认值                    │ DefaultFirecrackerVersion
              │    ↓ 可被覆盖                      │
              │ 2. 环境变量                        │ DEFAULT_FIRECRACKER_VERSION
              │    ↓ 可被覆盖                      │
              │ 3. LaunchDarkly feature flag      │ build-firecracker-version
              │    ↓ 写入数据库                     │
              │ 4. 模板 Build 记录                 │ 跟模板绑定
              │    ↓ gRPC 传递                     │
              │ 5. ResolveFirecrackerVersion()    │ 短版本别名解析
              │    ↓                              │
              │ 6. filepath.Join() → os.Stat()    │ 拼接路径 + 验证
              └──────────────────────────────────┘
```

**本地部署的简单情况**：没有 LaunchDarkly，没有自定义环境变量，所以直接使用硬编码默认值 `vmlinux-6.1.158` + `v1.12.1_210cbac`。你只需要确保这两个版本的文件在 `/fc-kernels/` 和 `/fc-versions/` 下存在即可。

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

## 10. 深入：NBD——E2B 磁盘 I/O 的核心机制

### 10.1 什么是 NBD？

NBD（Network Block Device）是 Linux 内核提供的一种机制：**将一个远程（或本地用户态程序）提供的存储，映射为一个标准的块设备（`/dev/nbdX`）**。

传统块设备（如 `/dev/sda`）背后是物理硬盘或 SSD。NBD 的核心思想是：

```
普通块设备:   应用程序 → 内核文件系统 → 块设备驱动 → 物理磁盘
NBD 块设备:   应用程序 → 内核文件系统 → NBD 内核客户端 → Socket → 用户态 NBD 服务端
```

当内核需要读写 `/dev/nbd0` 上的某个块时，它不会去访问物理磁盘，而是通过 socket 把请求发给一个用户态程序。这个用户态程序可以从**任何地方**（内存、文件、网络、另一个设备）读取数据并返回。

### 10.2 为什么 E2B 使用 NBD？

Firecracker VM 需要一个 rootfs 块设备。E2B 面临的挑战是：

1. **模板共享**：同一个模板可能被数百个沙箱同时使用，不能每个沙箱都复制一份完整的磁盘镜像
2. **写入隔离**：每个沙箱的文件修改不能影响其他沙箱
3. **按需加载**：模板可能有几 GB，不应该在沙箱启动时全部加载到内存

NBD 完美解决了这些问题——E2B 在用户态实现了一个 **Copy-on-Write overlay**：

```
VM 读取 /dev/nbd0 上的块
  ↓ 内核发送 NBD 读请求
  ↓ Socket
Dispatch（E2B 的用户态 NBD 服务端）
  ↓ 调用 Overlay.ReadAt()
  ├── 先查 Cache（mmap 稀疏文件，存放写入的脏块）
  │   ├── 命中 → 返回缓存数据
  │   └── 未命中 → 继续
  └── 回退到 Template（只读的模板镜像）
      └── 从 GCS/本地文件系统按需加载对应的块

VM 写入 /dev/nbd0 上的块
  ↓ 内核发送 NBD 写请求
  ↓ Socket
Dispatch
  ↓ 调用 Overlay.WriteAt()
  └── 直接写入 Cache（不修改模板）
```

### 10.3 E2B 的 NBD 实现细节

#### Socket Pair 连接

E2B 不使用 TCP 网络，而是使用 **Unix Socket Pair** 在同一台机器上建立 NBD 连接：

```go
// packages/orchestrator/pkg/sandbox/nbd/path_direct.go
func (d *DirectPathMount) Open(ctx context.Context) (uint32, error) {
    // 1. 创建 Unix socket pair（进程内通信，零网络开销）
    sockPair, _ := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM, 0)

    client := os.NewFile(uintptr(sockPair[0]), "client")   // 给内核 NBD 客户端
    server := os.NewFile(uintptr(sockPair[1]), "server")   // 给用户态 Dispatch

    // 2. 启动用户态 NBD 服务端（处理读写请求）
    dispatch := NewDispatch(serverConn, d.Backend)  // Backend = Overlay
    go dispatch.Handle(ctx)

    // 3. 通过 Netlink 将 socket 的客户端连接到 /dev/nbdX
    nbdnl.Connect(deviceIndex, []*os.File{client}, size, 0, serverFlags, opts...)

    // 4. 等待连接就绪
    for {
        s, _ := nbdnl.Status(deviceIndex)
        if s.Connected { break }
    }
    return deviceIndex, nil
}
```

关键点：`nbdnl.Connect()` 是通过 **Linux Netlink**（内核通信接口）告诉 NBD 内核模块："请使用这个 socket 来处理 `/dev/nbdX` 的所有 I/O 请求"。

#### NBD 协议解析

`Dispatch.Handle()` 实现了 NBD 线级协议（wire protocol）：

```go
// packages/orchestrator/pkg/sandbox/nbd/dispatch.go
type Request struct {
    Magic  uint32   // 0x25609513（NBD 魔数）
    Type   uint32   // 0=Read, 1=Write, 2=Disconnect
    Handle uint64   // 请求标识符（用于异步响应匹配）
    From   uint64   // 偏移量（从磁盘的第几个字节开始）
    Length uint32   // 要读/写的字节数
}

func (d *Dispatch) Handle(ctx context.Context) error {
    buffer := make([]byte, 4*1024*1024)  // 4MB 缓冲区
    for {
        n, _ := d.fp.Read(buffer[wp:])   // 从 socket 读取请求

        // 解析 28 字节的请求头
        request.Magic  = binary.BigEndian.Uint32(header)
        request.Type   = binary.BigEndian.Uint32(header[4:8])
        request.Handle = binary.BigEndian.Uint64(header[8:16])
        request.From   = binary.BigEndian.Uint64(header[16:24])
        request.Length  = binary.BigEndian.Uint32(header[24:28])

        switch request.Type {
        case NBDCmdRead:       // → Overlay.ReadAt(offset, length)
            d.cmdRead(ctx, request.Handle, request.From, request.Length)
        case NBDCmdWrite:      // → Overlay.WriteAt(data, offset)
            d.cmdWrite(ctx, request.Handle, request.From, data)
        case NBDCmdDisconnect: // VM 关闭或断开
            return nil
        }
    }
}
```

每个读请求在**单独的 goroutine** 中处理，允许并行 I/O。写请求同样异步执行。响应通过 `writeResponse()` 发回 socket：

```go
type Response struct {
    Magic  uint32   // 0x67446698（NBD 响应魔数）
    Error  uint32   // 0=成功, 1=错误
    Handle uint64   // 匹配对应的请求
}
// 读响应：Response + 数据
// 写响应：仅 Response（无数据）
```

#### Overlay 层：Copy-on-Write 的核心

```go
// packages/orchestrator/pkg/sandbox/block/overlay.go
type Overlay struct {
    device    ReadonlyDevice   // 只读模板（从 GCS/本地文件按需加载）
    cache     *Cache           // 可写缓存（mmap 稀疏文件）
    blockSize int64            // 块大小（通常 4KB）
}

func (o *Overlay) ReadAt(ctx context.Context, p []byte, off int64) (int, error) {
    // 逐块读取
    for _, blockOff := range header.BlocksOffsets(len(p), o.blockSize) {
        // 先尝试 Cache（O(1) 查找 dirty map）
        n, err := o.cache.ReadAt(p[blockOff:blockOff+o.blockSize], off+blockOff)
        if err == nil {
            continue  // Cache 命中，这个块用缓存的数据
        }
        // Cache 未命中（BytesNotAvailableError）→ 从模板读
        o.device.ReadAt(ctx, p[blockOff:blockOff+o.blockSize], off+blockOff)
    }
    return len(p), nil
}

func (o *Overlay) WriteAt(p []byte, off int64) (int, error) {
    return o.cache.WriteAt(p, off)  // 所有写入只进 Cache，不修改模板
}
```

Cache 层使用 **mmap 稀疏文件** + `sync.Map` 跟踪脏块：
- 写入时：`copy(mmap[off:], data)` + `dirty.Store(offset, struct{}{})`
- 读取时：检查 `dirty.Load(offset)`，存在则返回 mmap 数据，否则返回 `BytesNotAvailableError`

#### NBD 设备生命周期

```
创建沙箱:
  DevicePool.GetDevice()          ← 从池中获取空闲 /dev/nbdX
  DirectPathMount.Open()          ← socketpair + Dispatch + nbdnl.Connect
  NBDProvider.Start()             ← 返回设备路径给 Firecracker

沙箱运行中:
  Firecracker VM 读写 /dev/nbdX   ← 内核 → socket → Dispatch → Overlay

关闭沙箱:
  NBDProvider.sync()              ← ioctl(BLKFLSBUF) 刷新内核缓冲
  DirectPathMount.Close()         ← 取消 context → 关闭 socket → Drain 等待
                                     nbdnl.Disconnect(deviceIndex)
                                     等待 /sys/block/nbdX/pid 消失
  DevicePool.ReleaseDevice()      ← 归还到设备池
```

### 10.4 为什么不用其他方案？

| 方案 | 缺点 |
|------|------|
| 直接文件 | 每个沙箱复制完整镜像（慢、占空间） |
| Loop 设备 | 不支持 CoW，需要预复制 |
| Device Mapper thin-provisioning | 需要 LVM 设置，运维复杂 |
| Overlay FS | 是文件系统级别的，不是块设备级别的，Firecracker 需要块设备 |
| FUSE | 内核态→用户态切换开销大 |
| **NBD + 用户态 Overlay** | **✓** 块设备接口、CoW、按需加载、无需预复制 |

E2B 选择 NBD 是因为它提供了**块设备接口**（Firecracker 需要）+ **用户态灵活性**（可以实现任意的读写逻辑），同时避免了每个沙箱复制完整磁盘镜像的开销。

### 10.5 系统配置要点

```bash
# 加载 NBD 模块（指定最大设备数）
sudo modprobe nbd nbds_max=4096   # 生产环境
sudo modprobe nbd nbds_max=64     # 本地开发

# 减少 inotify 噪音（4096 个设备会产生大量事件）
echo 'ACTION=="add|change", KERNEL=="nbd*", OPTIONS:="nowatch"' | \
  sudo tee /etc/udev/rules.d/97-nbd-device.rules

# 验证
cat /sys/module/nbd/parameters/nbds_max  # 应输出你设置的值
ls /dev/nbd0                              # 设备节点应存在
```

`nbds_max` 决定了系统中最多有多少个 `/dev/nbdX` 设备可用。每个运行中的沙箱占用一个 NBD 设备，所以这个值限制了**单台服务器上的最大并发沙箱数**。

---

## 11. 存储架构：如何脱离云存储

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

## 12. 网络架构：每个 VM 的网络是怎么建的

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

## 13. 生产环境扩展

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
