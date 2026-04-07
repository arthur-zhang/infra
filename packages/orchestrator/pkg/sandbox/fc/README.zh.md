# fc 目录技术细节

`fc` 目录是 Orchestrator 与 **Firecracker VMM** 交互的核心封装层，负责管理 Firecracker 虚拟机的完整生命周期。

## 核心组件

### 1. client.go - Firecracker API 客户端

封装了所有与 Firecracker HTTP API 的交互。

#### 关键 API 操作

- `loadSnapshot()` - 加载快照，使用 **UFFD (userfaultfd)** 后端实现按需内存加载
- `resumeVM()` / `pauseVM()` - 控制 VM 运行状态
- `createSnapshot()` - 创建全量快照
- `setMachineConfig()` - 配置 vCPU、内存、HugePages
- `setBootSource()` - 设置内核路径和启动参数
- `setRootfsDrive()` - 配置根文件系统块设备
- `setNetworkInterface()` - 配置网络接口（TAP 设备）
- `setTxRateLimit()` - 设置网络发送速率限制（Token Bucket 算法）
- `setMmds()` - 设置 MMDS（Microvm Metadata Service）元数据
- `setEntropyDevice()` - 配置熵设备（随机数生成器）

#### 速率限制机制

```go
type TxRateLimiterConfig struct {
    Ops       TokenBucketConfig  // 包速率限制
    Bandwidth TokenBucketConfig  // 带宽限制
}
```

使用 Token Bucket 算法，支持突发流量（OneTimeBurst）和持续速率控制。

### 2. process.go - Firecracker 进程管理

管理 Firecracker 进程的完整生命周期。

#### 启动流程

```
1. 创建 mount namespace (unshare -m)
2. 创建 metrics FIFO 管道
3. 启动 Firecracker 进程（在网络 namespace 中）
4. 等待 Unix socket 就绪
5. 通过 API 配置 VM（CPU/内存/网络/存储）
6. 启动或恢复 VM
```

#### 关键特性

- **Cgroup 集成**：使用 `CLONE_INTO_CGROUP` 原子性地将进程放入 cgroup
- **日志过滤**：`fcLogFilter` 过滤掉高频的 FlushMetrics 日志噪音
- **优雅关闭**：先发送 SIGTERM，10 秒后强制 SIGKILL
- **D 状态检测**：监控进程是否进入不可中断睡眠状态（通常表示 I/O 问题）

#### 两种启动模式

**1. Create - 从头创建 VM（冷启动）**
- 配置内核、rootfs、网络、机器参数
- 调用 `startVM()` 启动

**2. Resume - 从快照恢复（热启动）**
- 并行等待：FC socket + UFFD socket + rootfs 符号链接
- 加载快照（通过 UFFD 后端）
- 应用速率限制（覆盖快照中的配置）
- 恢复 VM 并设置 MMDS 元数据

### 3. memory.go - 内存管理

提供内存快照和导出功能。

#### 主要功能

- `MemoryInfo()` - 获取内存页状态（resident/empty）
- `DirtyMemory()` - 获取脏页位图（用于增量快照）
- `ExportMemory()` - 从进程内存导出指定页到缓存
  - 通过 `/proc/<pid>/mem` 读取 Firecracker 进程内存
  - 使用 `bitset` 高效表示页状态

### 4. script_builder.go - 启动脚本生成

生成 Firecracker 启动的 bash 脚本。

#### V1 脚本（旧版）

```bash
mount --make-rprivate / &&
mount -t tmpfs tmpfs /mnt/disks/fc-envs/v1/<template>/<build> -o X-mount.mkdir &&
ln -s <host-rootfs> <sandbox-rootfs> &&
mount -t tmpfs tmpfs /fc-vm/<kernel-version> -o X-mount.mkdir &&
ln -s <host-kernel> <sandbox-kernel> &&
ip netns exec <namespace> firecracker --api-sock <socket>
```

#### V2 脚本（新版，统一路径）

```bash
mount --make-rprivate / &&
mount -t tmpfs tmpfs /fc-vm -o X-mount.mkdir &&
ln -s <host-rootfs> /fc-vm/rootfs.ext4 &&
mkdir -p /fc-vm/<kernel-version> &&
ln -s <host-kernel> /fc-vm/<kernel-version>/vmlinux.bin &&
ip netns exec <namespace> firecracker --api-sock <socket>
```

#### 关键技术

- `mount --make-rprivate /` - 防止挂载传播到宿主机
- `tmpfs` - 内存文件系统，快速且隔离
- `ip netns exec` - 在指定网络 namespace 中运行 Firecracker

### 5. mmds.go - 元数据服务

MMDS（Microvm Metadata Service）类似 AWS EC2 的 IMDS。

```go
type MmdsMetadata struct {
    SandboxID            string  // 沙箱 ID
    TemplateID           string  // 模板 ID
    LogsCollectorAddress string  // 日志收集器地址
    AccessTokenHash      string  // 访问令牌哈希
}
```

VM 内部可通过 HTTP 访问 `169.254.169.254` 获取这些元数据。

### 6. kernel_args.go - 内核参数

构建 Linux 内核启动参数。

#### 默认参数

```go
KernelArgs{
    "quiet":    "",           // 静默启动
    "loglevel": "1",          // 最小日志级别
    "init":     "/init.sh",   // 初始化脚本
    "ip":       "10.0.0.2::10.0.0.1:255.255.255.0:instance:eth0:off:8.8.8.8",
    "panic":    "1",          // panic 后 1 秒退出
    "reboot":   "k",          // 重启时杀死 VM
    "pci":      "off",        // 禁用 PCI
    "random.trust_cpu": "on", // 信任 CPU 随机数
}
```

#### 可选参数

- `clocksource=kvm-clock` - 使用 KVM 时钟源
- `console=ttyS0` - 内核日志输出到串口
- `systemd.journald.forward_to_console` - systemd 日志转发

### 7. fc_metrics.go - 指标收集

从 Firecracker 的 metrics FIFO 读取性能指标。

#### 工作机制

1. 创建 FIFO 管道（`mkfifo`）
2. 以 `O_RDWR` 打开防止阻塞
3. 启动定时器每 5 秒调用 `FlushMetrics` API
4. 解析 JSON 格式的指标数据
5. 导出到 OpenTelemetry

#### 收集的指标

- **网络**：TX/RX 字节数、包数、失败数
- **速率限制**：throttled 次数、剩余配额
- **错误**：buffer 不足、TAP 设备 I/O 失败

**优化**：只在非零时记录，避免污染直方图。

## 技术亮点

1. **UFFD 按需加载** - 快照恢复时不需要预加载全部内存，通过 userfaultfd 按需加载页面
2. **HugePages 支持** - 使用 2MB 大页减少 TLB miss，提升性能
3. **Cgroup 原子放置** - 使用 `CLONE_INTO_CGROUP` 避免竞态条件
4. **速率限制持久化** - 快照会保存速率限制配置，恢复时需显式覆盖
5. **Mount Namespace 隔离** - 每个 VM 有独立的挂载命名空间
6. **FIFO 双端打开** - 巧妙使用 O_RDWR + O_RDONLY 避免阻塞
7. **日志过滤** - 状态机过滤高频日志，减少噪音

## 性能优化

- **并行初始化**：使用 `errgroup` 并行等待 socket、rootfs、UFFD
- **符号链接延迟**：先链接 `/dev/null`，后期再链接真实 rootfs
- **Metrics 批量读取**：1MB 缓冲区，减少系统调用
- **Token Bucket**：支持突发流量，避免过度限制

## 总结

这个模块是 E2B 实现"毫秒级启动"的核心，通过快照 + UFFD + HugePages 的组合，将传统 VM 启动时间从秒级压缩到毫秒级。

## 相关文件

- `client.go` - Firecracker API 客户端封装
- `process.go` - 进程生命周期管理
- `memory.go` - 内存快照和导出
- `script_builder.go` - 启动脚本生成
- `mmds.go` - 元数据服务定义
- `kernel_args.go` - 内核参数构建
- `fc_metrics.go` - 性能指标收集
- `config.go` - 配置定义
