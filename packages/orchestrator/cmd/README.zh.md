# Orchestrator CLI 工具集深度解析

## 1. 概述

`packages/orchestrator/cmd/` 目录包含了 E2B Orchestrator 的一系列命令行工具，用于构建、检查、调试和基准测试 Firecracker microVM 模板。这些工具覆盖了从模板创建到性能优化的完整生命周期。

### 在整体架构中的位置

```
┌─────────────────────────────────────────────────────┐
│                  Orchestrator CLI                     │
│                                                       │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐│
│  │ create-build │  │ resume-build │  │ copy-build   ││
│  │ (模板创建)    │  │ (沙箱恢复)    │  │ (构建复制)    ││
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘│
│         │                 │                 │         │
│  ┌──────┴─────────────────┴─────────────────┴───────┐│
│  │              pkg/sandbox (核心引擎)                ││
│  │  block / build / cgroup / network / nbd           ││
│  └───────────────────────────────────────────────────┘│
│                                                       │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐│
│  │inspect-build │  │show-build-diff│ │mount-rootfs  ││
│  │ (构建检查)    │  │ (差异可视化)  │  │ (rootfs 挂载)││
│  └──────────────┘  └──────────────┘  └──────────────┘│
│                                                       │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐│
│  │simulate-gcs  │  │simulate-nfs  │  │clean-nfs-cache│
│  │ (GCS 基准测试)│  │ (NFS 基准测试)│  │ (缓存清理)   ││
│  └──────────────┘  └──────────────┘  └──────────────┘│
└─────────────────────────────────────────────────────┘
```

### 核心工具一览

| 工具 | 用途 | 分类 |
|------|------|------|
| `create-build` | 创建新的环境模板 | 构建 |
| `resume-build` | 从已有构建恢复/测试沙箱 | 构建 |
| `copy-build` | 在本地与 GCS 之间复制构建产物 | 构建 |
| `inspect-build` | 检查构建产物内部结构 | 诊断 |
| `show-build-diff` | 可视化两个构建之间的差异 | 诊断 |
| `mount-build-rootfs` | 将 rootfs 挂载为本地设备 | 诊断 |
| `clean-nfs-cache` | 清理 NFS 缓存中的过期文件 | 运维 |
| `simulate-gcs-traffic` | 基准测试 GCS 客户端性能 | 性能 |
| `simulate-nfs-traffic` | 基准测试 NFS 读取性能 | 性能 |
| `hammer-file` | GCS 读取延迟基准测试 | 性能 |
| `smoketest` | 端到端集成冒烟测试 | 测试 |

---

## 2. 共享工具库 (`cmd/internal/cmdutil`)

所有 CLI 工具共享的基础设施代码。

### cmdutil.go

```go
// 抑制第三方库（如 GCS 客户端）的冗余日志
SuppressNoisyLogs()

// 获取文件的逻辑大小和实际磁盘大小（支持稀疏文件）
GetFileSizes(path string) (logical int64, ondisk int64, err error)
```

### storage.go

提供对本地存储和 GCS 存储的透明访问：

- 将 `-storage` 标志映射为内部 `STORAGE_PROVIDER` 和 `TEMPLATE_BUCKET_NAME` 环境变量
- 提供 `DataReader`，支持 `ReadAt` 进行高效的随机读取

```
-storage 标志格式：
  本地: /path/to/dir
  GCS:  gs://bucket-name
```

---

## 3. 构建类工具

### 3.1 create-build — 模板创建

创建新的 Firecracker microVM 环境模板。这是整个工具集中最复杂的命令。

**工作流程：**

```
   输入参数
      │
      ▼
┌──────────────┐
│ 下载 Kernel  │ ← 如本地不存在，从公共存储下载
│ 下载 FC 二进制 │
└──────┬───────┘
       │
       ▼
┌──────────────┐
│ 初始化基础设施 │ ← NBD 池、网络池、代理、防火墙
└──────┬───────┘
       │
       ▼
┌──────────────┐
│ 启动 FC VM   │ ← 使用 build.Builder 在 VM 中执行构建
└──────┬───────┘
       │
       ▼
┌──────────────┐
│ 生成模板快照  │ ← 内存快照 + rootfs 快照
└──────────────┘
```

**常用参数：**

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `-template` | 模板标识 | 必需 |
| `-setup-cmd` | 构建时执行的命令 | - |
| `-start-cmd` | 启动时执行的命令 | - |
| `-vcpu` | 虚拟 CPU 数量 | - |
| `-memory` | 内存大小（MB） | - |
| `-hugepages` | 启用大页 | false |

### 3.2 resume-build — 沙箱恢复

从已有构建恢复沙箱，支持交互式调试和性能优化。

**三种运行模式：**

1. **交互模式**：恢复 VM 后提供 SSH 连接命令
2. **命令模式**：通过 envd 在 VM 中执行指定命令后退出
3. **暂停模式**：恢复 → 运行 → 创建新快照（快照的快照）

**性能优化功能：**

```bash
# -optimize 模式：多次运行 VM 收集常用页面访问信息
# 然后上传 prefetch 映射到元数据，加速后续恢复
resume-build -build <id> -optimize -iterations 5

# -cold 模式：清除 OS 页面缓存，测试冷启动性能
resume-build -build <id> -cold
```

**关键参数：**

| 参数 | 说明 |
|------|------|
| `-build` | 构建 ID |
| `-cold` | 清除页面缓存 |
| `-iterations` | 运行次数 |
| `-no-prefetch` | 禁用预取 |
| `-optimize` | 启用优化模式 |

### 3.3 copy-build — 构建复制

在本地存储和 GCS 之间智能复制构建产物。

**智能复制机制：**

不是简单的目录级复制，而是解析 `memfile.header` 和 `rootfs.header`，仅复制构建实际引用的数据块（chunks）。

```
复制内容：
  ├── headers (memfile.header, rootfs.header)
  ├── metadata (构建元信息)
  ├── snapfile (快照文件)
  └── referenced data chunks (被引用的数据块)
```

**效率优化：**
- 使用 CRC32C 校验跳过已存在的文件
- `-team` 参数可生成数据库填充 SQL

```bash
copy-build -build <id> -from gs://bucket -to /local/path
copy-build -build <id> -from /local/path -to gs://bucket -team <team-id>
```

---

## 4. 诊断类工具

### 4.1 inspect-build — 构建检查

分析构建产物的内部结构，展示块映射和层级关系。

**输出信息包括：**
- 构建元数据（Build ID、Base ID、版本号）
- 块映射（哪些块是稀疏的、属于当前构建的、继承自父构建的）
- 使用 `-data` 时读取并报告各块的非零字节数

```bash
# 检查 memfile 结构
inspect-build -build <id> -memfile

# 检查 rootfs 结构，包含数据验证
inspect-build -build <id> -rootfs -data

# 通过模板别名解析构建 ID（调用 E2B API）
inspect-build -template <alias> -rootfs
```

### 4.2 show-build-diff — 差异可视化

比较基础构建和子构建之间的差异，展示每一层的块分配。

```bash
# 可视化两个构建的差异
show-build-diff -from-build <base-id> -to-build <diff-id> -visualize
```

输出一个文本形式的块映射图，标注各块属于哪个层级。

### 4.3 mount-build-rootfs — Rootfs 挂载

通过 NBD (Network Block Device) 将模板的 rootfs 镜像挂载为本地块设备。

**安全机制：** 使用 Copy-on-Write (COW) 覆盖层，修改不会影响原始模板。

```bash
# 挂载并手动检查
mount-build-rootfs -build <id> -mount /mnt/sandbox

# 挂载并自动验证文件系统完整性
mount-build-rootfs -build <id> -mount /mnt/sandbox -verify

# 创建空白 ext4 设备
mount-build-rootfs -empty -mount /mnt/empty
```

`-verify` 会执行：
- `e2fsck` 文件系统检查
- `journalctl --verify` 日志验证

---

## 5. 性能基准测试工具

### 5.1 simulate-gcs-traffic — GCS 性能测试

通过笛卡尔积组合测试多种 GCS 客户端配置，寻找最优参数。

**测试维度：**
- gRPC 连接池大小
- 窗口大小
- 并发请求数
- 缓冲方法

**输出：** P50/P95/P99 延迟数据，写入 CSV 供分析。

```bash
simulate-gcs-traffic -repeat 10 -min-file-size 1048576 -csv-path results.csv
```

### 5.2 simulate-nfs-traffic — NFS 性能测试

聚焦于内核级网络调优参数的 NFS 读取性能测试。

**测试调优项：**
- `nfs read_ahead_kb`
- `sunrpc.tcp_slot_table_entries`
- TCP 接收缓冲区 (`rmem_max`)

```bash
# 带 NFS 统计信息采集
simulate-nfs-traffic -nfs-stat
```

`-nfs-stat` 会捕获 `/proc/self/mountstats`（测试前后），统计 RPC 调用次数和重传。

### 5.3 hammer-file — GCS 延迟测试

GCS 对象读取延迟的精确测量工具。

**两种测试场景：**
1. **顺序读取**：逐块读取
2. **并行读取**：默认 10 并发

**输出：** 均值/P50 延迟 + Mermaid Gantt 图（`scenario1.mmd`, `scenario2.mmd`），可视化读取时序。

---

## 6. 运维工具

### clean-nfs-cache — NFS 缓存清理

基于 atime（访问时间）的 NFS 缓存清理器，支持按磁盘使用率或删除目标进行清理。

**并发流水线架构：**

```
Scanner ──→ Statter ──→ Deleter
 (扫描)       (stat)      (删除)
```

**分批算法：**
1. 收集一批文件（默认 10,000 个）
2. 按 atime 排序
3. 删除最旧的 N 个文件
4. 剩余文件重新放回目录树

**配置参数：**

| 参数 | 说明 |
|------|------|
| `-target-files-to-delete` | 目标删除文件数 |
| `-target-bytes-to-delete` | 目标删除字节数 |
| `-disk-usage-target-percent` | 磁盘使用率目标 |
| `-max-concurrent-delete` | 最大并发删除数 |

支持通过 LaunchDarkly feature flags 动态覆盖配置。

---

## 7. 测试

### smoketest — 冒烟测试

端到端集成测试，需要 root 权限和 Linux 环境（KVM + NBD）。

**测试流程：**

```
遍历所有支持的 Firecracker 版本
    │
    ├── 下载内核和 FC 二进制
    │
    ├── 从基础镜像创建新模板
    │
    └── 从该构建恢复沙箱并验证
```

覆盖几乎所有 orchestrator 子包的集成。

---

## 8. 开发指南

### 本地构建

```bash
cd packages/orchestrator

# 构建特定工具
go build -o bin/create-build ./cmd/create-build
go build -o bin/resume-build ./cmd/resume-build
go build -o bin/inspect-build ./cmd/inspect-build
```

### 运行测试

```bash
# 冒烟测试（需要 root + Linux + KVM）
sudo go test -v ./cmd/smoketest/ -timeout 30m

# GCS 流量模拟测试
go test -v ./cmd/simulate-gcs-traffic/
```

### 调试技巧

1. 使用 `inspect-build` 检查构建产物结构
2. 使用 `show-build-diff` 理解构建层级关系
3. 使用 `mount-build-rootfs -verify` 验证文件系统完整性
4. 使用 `resume-build -cold` 测试冷启动性能

---

## 9. 设计决策

### 构建感知的复制策略

`copy-build` 不做目录级复制，而是解析 header 文件确定需要复制的精确数据块。这避免了复制未使用的块，在大型构建中可节省大量带宽和存储。

### 并发流水线

`clean-nfs-cache` 采用 Scanner → Statter → Deleter 流水线架构，各阶段独立并发执行，最大化磁盘 I/O 吞吐量。

### 分批 + 随机扫描

缓存清理器使用随机文件选取策略（而非顺序扫描），避免在大型目录树中产生文件系统锁竞争。

### Copy-on-Write 挂载

`mount-build-rootfs` 使用 COW 覆盖层保护原始模板数据，确保调试检查不会意外修改模板。

### Prefetch 优化

`resume-build -optimize` 通过多次运行收集访问模式，生成预取映射。后续恢复时按访问顺序预加载数据块，显著减少冷启动时间。
