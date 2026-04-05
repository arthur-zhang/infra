# E2B 底层原理深度解析

---

## Slide 1: 什么是 E2B

- E2B = "Environment to Binary"，开源云端 AI 代码执行平台
- 核心能力：为 AI Agent 提供安全、隔离的沙箱执行环境
- 底层基于 Firecracker microVM —— 与 AWS Lambda 同源的虚拟化技术
- 每个沙箱是一个独立的轻量级虚拟机，启动时间 < 1 秒

---

## Slide 2: 整体架构总览

```
用户 SDK
  ↓ HTTPS
Client Proxy（边缘路由层）
  ↓ Redis 查询沙箱位置
  ↓ HTTP 转发
API 服务（REST, Gin 框架）
  ↓ gRPC                    ⟷ PostgreSQL（集群/团队/模板）
Orchestrator 集群             ⟷ Redis（沙箱路由表）
  ↓                          ⟷ ClickHouse（分析指标）
Firecracker microVM           ⟷ GCS（模板/快照存储）
  ↓
Envd（VM 内守护进程）
```

---

## Slide 3: 核心组件一览

| 组件 | 职责 | 技术栈 |
|------|------|--------|
| API | REST 网关，认证，调度决策 | Go + Gin |
| Orchestrator | VM 生命周期管理 | Go + Firecracker |
| Envd | VM 内进程/文件系统管理 | Go + Connect-RPC |
| Client Proxy | 用户流量路由 | Go + Redis |
| DB | 持久化存储 | PostgreSQL + sqlc |

---

## Slide 4: 为什么选择 Firecracker

**传统容器（Docker）的问题：**
- 共享内核，隔离性弱（容器逃逸风险）
- 不适合运行不可信的 AI 生成代码

**传统虚拟机（QEMU/KVM）的问题：**
- 启动慢（秒级到分钟级）
- 资源开销大（每个 VM 数百 MB）

**Firecracker 的优势：**
- 轻量级 VMM（Virtual Machine Monitor），< 5MB 内存开销
- 启动时间 < 125ms（冷启动）
- 强隔离：每个 VM 独立内核，独立网络命名空间
- 支持快照（snapshot）：恢复时间 < 50ms
- AWS Lambda / Fargate 的底层技术，经过大规模生产验证

---

## Slide 5: Firecracker VM 创建流程

```
Factory.CreateSandbox()
  │
  ├─ 1. 分配网络资源
  │     └─ 从网络池获取 Slot（IP + TAP + veth + 命名空间）
  │
  ├─ 2. 准备存储
  │     ├─ 模板 Rootfs（只读层）
  │     ├─ Cache 层（写入层，Copy-on-Write）
  │     └─ NBD 设备挂载（按需加载磁盘块）
  │
  ├─ 3. 启动 Firecracker 进程
  │     ├─ 配置内核镜像 + 启动参数
  │     ├─ 配置 rootfs 驱动
  │     ├─ 配置网络接口（TAP + 限速）
  │     ├─ 配置 vCPU / 内存 / 熵源
  │     └─ startVM() → 内核启动
  │
  ├─ 4. 等待 Envd 就绪
  │     └─ HTTP 轮询 :49983/init
  │
  └─ 5. 注册到沙箱目录（Redis）
```

---

## Slide 6: VM 网络架构

每个沙箱拥有独立的 Linux 网络命名空间：

```
宿主机命名空间 (10.11.0.0/16)
  │
  ├─ veth (宿主侧) [10.12.X.Y/31]
  │     │
  │     └─ 路由到沙箱
  │
  └─ 沙箱网络命名空间 (独立)
       ├─ vpeer [10.12.X.(Y+1)/31] ← 网关
       ├─ TAP 设备 [169.254.0.22/30] ← Firecracker 使用
       └─ nftables 防火墙规则
            ├─ 全局拒绝列表
            ├─ 全局允许列表
            ├─ 用户自定义拒绝列表
            └─ 用户自定义允许列表
```

**网络池化**：预创建 32 个新 Slot + 100 个回收 Slot，避免创建时的延迟。

---

## Slide 7: 存储架构 — Copy-on-Write

```
┌─────────────────────────────────┐
│  模板 Rootfs（只读，共享）        │  ← GCS 下载，多 VM 共享
└──────────────┬──────────────────┘
               │
┌──────────────▼──────────────────┐
│  Overlay 设备（CoW 合并层）      │  ← 读：先查 Cache，miss 回退模板
└──────────────┬──────────────────┘     写：全部写入 Cache
               │
┌──────────────▼──────────────────┐
│  Cache 层（mmap 稀疏文件）       │  ← 跟踪 dirty blocks
└──────────────┬──────────────────┘
               │
┌──────────────▼──────────────────┐
│  NBD 设备 (/dev/nbdX)           │  ← 内核块设备接口
└──────────────┬──────────────────┘
               │
┌──────────────▼──────────────────┐
│  Firecracker VM                  │  ← 看到的是普通磁盘
└─────────────────────────────────┘
```

**两种 Rootfs 提供者**：
- **Direct**：全内存，用于构建模板（快但耗内存）
- **NBD**：按需加载，用于运行沙箱（省内存）

---

## Slide 8: 快照与恢复 — 亚秒级启动的秘密

**快照 = 冻结一个正在运行的 VM 的完整状态**

```
暂停流程 (Pause)：
  1. Firecracker PATCH /vm → state=paused
  2. 创建快照 → snapfile（VM 状态机）
  3. 导出内存差异 → memfile（仅 dirty pages）
  4. 导出磁盘差异 → rootfs diff（仅修改的块）
  5. 上传到 GCS（带 header 用于懒加载）

恢复流程 (Resume)：
  1. 启动 Firecracker 进程
  2. 创建 UFFD socket（用户态缺页处理）
  3. 加载快照 → loadSnapshot（UFFD 后端）
  4. 启动预取器（后台异步加载热页）
  5. resumeVM → VM 立即恢复执行
  6. 缺页时 → UFFD 从 memfile 按需加载
```

**关键技术：UFFD（userfaultfd）**
- Linux 内核特性，允许用户态处理缺页异常
- VM 恢复时不需要加载全部内存，只加载访问到的页
- 配合预取器（Prefetcher），提前加载高频访问的页
- 实现效果：恢复时间从"加载全部内存"降低到"几乎零等待"

---

## Slide 9: 模板构建流程

```
用户提交 Dockerfile / 配置
  ↓
1. 拉取 Docker 镜像，提取文件系统
  ↓
2. 注入 E2B 组件
   ├─ envd 守护进程
   ├─ DNS 配置
   └─ 引导脚本
  ↓
3. 第一次启动（BusyBox init）
   └─ 安装 systemd
  ↓
4. 第二次启动（systemd init）
   └─ 等待 envd 在 :49983 就绪
  ↓
5. 执行构建层（用户的 RUN 命令）
  ↓
6. 运行就绪检查（health check）
  ↓
7. 暂停 VM → 生成快照
   ├─ memfile.bin（内存状态）
   ├─ rootfs.squashfs（文件系统）
   ├─ snapfile.bin（VM 状态）
   └─ metadata.json（元数据）
  ↓
8. 上传到 GCS → 成为可复用模板
```

**Diff 链**：快照支持增量存储，多层继承：
```
Base Template → Snapshot 1 (diff) → Snapshot 2 (diff) → ...
```
恢复时按链回溯，只加载需要的块。

---

## Slide 10: Envd — VM 内的守护进程

运行在每个 Firecracker VM 内部，端口 49983。

**两大核心 API（Connect-RPC over HTTP）**：

**进程管理**：
```
Start(cmd, args, env, cwd)  → 创建进程，流式返回 stdout/stderr
Connect(pid)                → 连接到已有进程
SendInput(data)             → 发送 stdin
SendSignal(SIGTERM/SIGKILL) → 发送信号
Update(cols, rows)          → 调整终端大小
```

**文件系统**：
```
Stat(path)                  → 获取文件信息
MakeDir(path)               → 创建目录
ListDir(path, depth)        → 递归列目录
WatchDir(path, recursive)   → 监听文件变化（流式）
Read/Write                  → 读写文件内容
```

**设计要点**：
- 完全无状态，生命周期由 Orchestrator 管理
- 通过 MMDS（Firecracker 元数据服务）获取沙箱 ID、模板 ID
- 支持 PTY（交互式终端）和非 PTY（批处理）两种模式
- 每 15 秒发送心跳，防止连接超时

---

## Slide 11: 分布式节点管理

**两层同步循环，中心化注册**：

```
PostgreSQL
  │ 每15秒查询活跃集群
  ↓
Pool（集群池）
  ├─ Cluster A（本地）──→ 每5秒查询 Nomad Allocations API
  │    ├─ node-1: Healthy (CPU 30%)
  │    ├─ node-2: Draining
  │    └─ node-3: Healthy (CPU 60%)
  │
  └─ Cluster B（远程）──→ 每5秒查询 Edge API
       ├─ node-x: Healthy
       └─ node-y: Standby
```

**节点状态机**：
```
Healthy ──→ Draining ──→ 下线（不接新沙箱，等现有结束）
   ↕
Standby（待机，可随时恢复）
   ↓
Unhealthy（3次探测失败，排除出调度）
```

**通用同步引擎**（泛型框架）：
- `syncDiscovered`：并行处理新发现的节点 → Insert
- `syncOutdated`：并行处理已有节点 → Update（健康检查）或 Remove

---

## Slide 12: 调度算法 — Best-of-K

**目标**：为新沙箱选择最优节点

```
1. 随机采样 K=3 个节点（Power of K Choices）

2. 过滤不合格节点：
   ✗ 状态不是 Ready
   ✗ CPU 架构不兼容
   ✗ 标签不匹配
   ✗ 容量不足（allocated + requested > R × cpuCount）
   ✗ 正在启动的实例 > 3 个

3. 对候选节点评分：
   Score = (cpuRequested + cpuAllocated + α × cpuUsage) / (R × cpuCount)
   
   R = 4.0（超分比，每个物理 CPU 承载 4 个 vCPU）
   α = 0.5（实际使用率权重）

4. 得分最低（最空闲）的节点胜出
```

**重试机制**：
- 创建失败 → 排除该节点，重选（最多 3 次）
- ResourceExhausted → 不计重试次数，直接重选
- 有 preferredNode（快照亲和性）→ 优先使用原节点

---

## Slide 13: 流量路由 — Client Proxy

**用户请求如何到达正确的沙箱？**

```
用户 SDK: POST /sandboxes/{sandbox-id}/process/start
  ↓
Client Proxy (端口 3002)
  ↓
1. 从 URL 提取 sandbox_id
  ↓
2. 查询 Redis 沙箱目录
   Key: sandbox:catalog:{sandboxId}
   Value: { orchestrator_ip, execution_id, started_at }
  ↓
3a. 命中 → 转发到 http://{orchestrator_ip}:5007/...
  ↓
3b. 未命中 → 沙箱可能已暂停
    ↓
    调用 API gRPC ResumeSandbox()
    ↓
    API 加载快照 → 在某个节点恢复 VM
    ↓
    返回 orchestrator_ip → 写入 Redis → 转发请求
```

**性能优化**：
- 本地缓存 500ms TTL（减少 Redis 压力）
- 连接池复用 TCP 连接
- 优雅关闭：Draining → 等 15s → Unhealthy → 等 15s → 关闭

---

## Slide 14: 数据存储策略

**"节点是短暂的，不存数据库"**

| 存储位置 | 存什么 | 为什么 |
|----------|--------|--------|
| PostgreSQL | 集群配置、团队绑定、模板元数据 | 相对稳定，需要持久化 |
| Redis | 沙箱→节点的路由映射 | 高频读写，需要低延迟 |
| API 内存 | 节点列表、健康状态、CPU/内存指标 | 实时变化，轮询刷新 |
| GCS | 模板快照（memfile/rootfs/snapfile） | 大文件，需要持久存储 |
| ClickHouse | 运行指标、日志分析 | 时序数据，高写入吞吐 |

**节点信息只在 API 内存中维护**，通过每 5 秒轮询 Nomad/Edge API 保持同步。
节点 ID 仅作为引用出现在 `snapshots.origin_node_id`（用于恢复亲和调度）。

---

## Slide 15: 可观测性体系

```
所有服务
  ↓ OpenTelemetry SDK
  ├─ Traces → Grafana Tempo（分布式追踪）
  ├─ Metrics → Grafana Mimir（指标监控）
  └─ Logs → Grafana Loki（日志聚合）
       ↓
  Grafana Dashboard（统一可视化）
```

**关键指标**：
- `orchestrator.network.slots_pool.new/reused` — 网络池可用量
- `orchestrator.nbd.slots_pool.ready/acquired` — NBD 设备池
- `orchestrator.templates.cache.hits/misses` — 模板缓存命中率
- `wait_for_envd_duration_histogram` — Envd 初始化耗时
- 每节点：CPU 分配量、使用率、内存、磁盘、沙箱数

---

## Slide 16: 安全隔离模型

```
┌─────────────────────────────────────────┐
│  层级 1: Firecracker VMM               │
│  独立内核，独立内存空间，硬件级隔离       │
├─────────────────────────────────────────┤
│  层级 2: Linux 网络命名空间             │
│  独立网络栈，nftables 防火墙            │
├─────────────────────────────────────────┤
│  层级 3: cgroup v2 资源限制             │
│  CPU/内存配额，OOM 优先级               │
├─────────────────────────────────────────┤
│  层级 4: Envd 认证                     │
│  Basic Auth + Access Token + MMDS 验证  │
├─────────────────────────────────────────┤
│  层级 5: 网络防火墙                     │
│  全局拒绝列表 + 用户自定义规则           │
└─────────────────────────────────────────┘
```

每个沙箱 = 独立 VM + 独立网络 + 独立资源配额 + 独立认证

---

## Slide 17: 一个沙箱的完整生命周期

```
① 创建请求到达 API
     ↓
② Best-of-K 选择目标节点
     ↓
③ Orchestrator 启动 Firecracker VM
   ├─ 分配网络（命名空间 + TAP + veth）
   ├─ 挂载存储（模板 + CoW overlay + NBD）
   ├─ 配置 VM（vCPU + 内存 + 内核）
   └─ 启动 VM → 等待 Envd 就绪
     ↓
④ 注册到 Redis 沙箱目录
     ↓
⑤ 用户通过 SDK 执行代码
   Client Proxy → Redis 查路由 → Orchestrator → Envd
     ↓
⑥ 空闲超时 → 暂停
   冻结 VM → 导出快照 → 上传 GCS → 从 Redis 移除
     ↓
⑦ 用户再次访问 → 自动恢复
   Client Proxy → Redis miss → API Resume → 加载快照 → 恢复 VM
     ↓
⑧ 到期销毁
   停止 Firecracker → 回收网络/存储/NBD → 从目录移除
```

---

## Slide 18: 关键设计决策总结

| 决策 | 选择 | 原因 |
|------|------|------|
| 虚拟化 | Firecracker（非 Docker） | 强隔离 + 快照支持 + 亚秒启动 |
| 内存恢复 | UFFD 懒加载（非全量加载） | 恢复时间从秒级降到毫秒级 |
| 磁盘 | NBD + CoW overlay（非全量复制） | 节省内存，按需加载 |
| 防火墙 | nftables（非 iptables） | 原子更新，低开销 |
| 节点发现 | 中心化轮询 Nomad（非 gossip） | 简单可靠，API 统一管控 |
| 调度 | Best-of-K（非全局最优） | O(K) 复杂度，避免全局锁 |
| 路由 | Redis 目录（非 DNS） | 低延迟，支持自动恢复 |
| 存储 | 增量 Diff 链（非全量快照） | 节省存储空间和传输时间 |

---

## Slide 19: 技术栈全景

```
语言:        Go 1.25.4（workspace 模式）
虚拟化:      Firecracker microVM
编排:        Nomad + Nomad Autoscaler
基础设施:    Terraform + GCP
数据库:      PostgreSQL (sqlc) + ClickHouse + Redis
通信:        gRPC + Connect-RPC + REST (Gin)
可观测性:    OpenTelemetry → Grafana (Loki + Tempo + Mimir)
存储:        GCS (模板/快照)
认证:        JWT (Supabase) + Basic Auth
特性开关:    LaunchDarkly
代码生成:    protoc + oapi-codegen + sqlc + mockery
```

---

## Slide 20: 总结

**E2B 的核心创新**：

1. **Firecracker + UFFD 快照** = 亚秒级沙箱启动/恢复
2. **CoW + NBD + Diff 链** = 高效存储，按需加载
3. **中心化调度 + Best-of-K** = 简单高效的负载均衡
4. **Redis 路由 + 自动恢复** = 对用户透明的暂停/恢复
5. **多层安全隔离** = 安全执行不可信代码

**一句话总结**：
E2B 通过 Firecracker 虚拟化 + 快照技术 + 智能调度，
实现了"像启动容器一样快地启动虚拟机"的云端代码执行平台。

---

# 附录：自建机房从零部署 E2B

> 以下 6 页讲解如何在没有 GCP / AWS 的裸金属 Linux 服务器上，一步步运行完整的 E2B 平台。

---

## Slide 21: 自建机房部署 — 硬件与系统要求

**没有 GCP / AWS，只有裸金属服务器，能跑 E2B 吗？可以。**

### 硬件要求

| 项目 | 最低要求 | 推荐配置 |
|------|---------|---------|
| CPU | x86_64 + VT-x/AMD-V | 32+ 核，支持 AES-NI |
| 内存 | 32 GB | 128+ GB（沙箱数 x 内存配额） |
| 磁盘 | 200 GB SSD | NVMe SSD（快照缓存性能关键） |
| 网络 | 千兆 | 万兆（多沙箱并发网络 I/O） |

### 系统要求

```
✓ Linux 内核 5.10+（推荐 6.x）
  └─ 需要：cgroup v2, userfaultfd, CLONE_INTO_CGROUP

✓ 必需内核模块：
  ├─ kvm_intel 或 kvm_amd    ← 硬件虚拟化
  ├─ nbd                     ← 网络块设备（磁盘挂载）
  └─ tun                     ← TAP 设备（VM 网络）

✓ 必需设备节点：
  ├─ /dev/kvm                ← Firecracker 虚拟化入口
  ├─ /dev/nbd0 ~ /dev/nbd4095 ← 块设备池
  └─ /dev/net/tun            ← 网络设备

✓ cgroup v2 挂载于 /sys/fs/cgroup
  └─ 需启用 cpu + memory 控制器

✓ 权限：root 或 CAP_NET_ADMIN + CAP_SYS_ADMIN
```

---

## Slide 22: 自建机房部署 — 云服务替换方案

E2B 的每个云依赖都有自建替代品：

| 云服务 | 用途 | 自建替代方案 |
|--------|------|-------------|
| GCS / S3 | 模板快照存储 | `STORAGE_PROVIDER=Local` + 本地磁盘 / NFS / MinIO |
| GCP Secrets Manager | 密钥管理 | 环境变量 `.env` 文件 / HashiCorp Vault |
| Nomad | 服务编排 | 自建 Nomad 集群 **或** 单机直连模式 |
| Supabase | JWT 认证 | 本地开发模式自动跳过 / 自建 Supabase |
| Cloudflare | DNS + TLS | Traefik + Let's Encrypt + 本地 DNS |
| LaunchDarkly | 特性开关 | 不配置即可，自动使用 offline 默认值 |

**本地开发模式下**，认证和特性开关都会自动降级，
只需关注 4 个核心基础设施：**PostgreSQL、Redis、ClickHouse、本地存储**。

---

## Slide 23: 自建机房部署 — 第一步：系统初始化

```bash
# ① 加载内核模块
sudo modprobe kvm_intel          # Intel 处理器（或 kvm_amd）
sudo modprobe nbd nbds_max=64    # NBD 块设备，本地开发 64 个够用
                                 # 生产环境建议 nbds_max=4096

# ② 配置 HugePages（Firecracker 使用 2MB 大页提升性能）
sudo sysctl -w vm.nr_hugepages=2048   # ≈ 4GB，按实际内存调整

# ③ 添加 udev 规则（减少 NBD 设备的 inotify 噪音）
echo 'ACTION=="add|change", KERNEL=="nbd*", OPTIONS:="nowatch"' | \
  sudo tee /etc/udev/rules.d/97-nbd-device.rules
sudo udevadm control --reload-rules

# ④ 验证环境
ls -la /dev/kvm           # 确认 KVM 可用
cat /sys/fs/cgroup/cgroup.controllers  # 确认 cgroup v2
lsmod | grep -E "kvm|nbd" # 确认模块加载
```

**验证通过的标志**：
- `/dev/kvm` 存在且可读写
- cgroup.controllers 包含 `cpu memory`
- `nbd` 模块已加载

---

## Slide 24: 自建机房部署 — 第二步：启动基础设施

一条命令启动全部支撑服务（Docker Compose）：

```bash
make local-infra
```

**启动的服务**：

```
┌──────────────────────────────────────────────┐
│  Docker Compose 服务栈                        │
│                                              │
│  数据存储:                                    │
│    PostgreSQL 17.4     → localhost:5432       │
│    Redis 7.4.2         → localhost:6379       │
│    ClickHouse 25.4     → localhost:8123/9000  │
│                                              │
│  可观测性:                                    │
│    Grafana 12.0        → localhost:53000      │
│    Loki 3.4 (日志)     → localhost:3100       │
│    Tempo 2.8 (追踪)    → localhost:3200       │
│    Mimir 2.17 (指标)   → localhost:9009       │
│    OTel Collector      → localhost:4317/4318  │
│    Vector (日志路由)   → localhost:30006      │
└──────────────────────────────────────────────┘
```

**初始化数据库**：

```bash
make -C packages/db migrate-local         # PostgreSQL schema
make -C packages/clickhouse migrate-local  # ClickHouse schema
make -C packages/local-dev seed-database   # 创建默认用户、团队、API Key
```

---

## Slide 25: 自建机房部署 — 第三步：启动 E2B 核心服务

```bash
# ① 下载预编译的 Firecracker 和 Linux 内核
make download-public-kernels       # Guest 内核: vmlinux-6.1.158
make download-public-firecrackers  # Firecracker: v1.12.1

# ② 构建 Envd（运行在 VM 内的守护进程）
make -C packages/envd build

# ③ 启动 3 个核心服务（各开一个终端）

# 终端 1: API 服务（REST 网关，端口 3000）
make -C packages/api run-local

# 终端 2: Orchestrator（VM 管理，需要 sudo，端口 5008）
make -C packages/orchestrator build-debug
sudo make -C packages/orchestrator run-local

# 终端 3: Client Proxy（流量路由，端口 3002）
make -C packages/client-proxy run-local

# ④ 构建基础模板（首次运行必需）
make -C packages/shared/scripts local-build-base-template
```

**关键路径**（Orchestrator 启动后自动使用）：

```
/fc-versions/v1.12.1/firecracker    ← Firecracker 二进制
/fc-kernels/vmlinux-6.1.158/vmlinux.bin  ← Guest 内核
/fc-envd/envd                       ← VM 内守护进程
/mnt/disks/fc-envs/v1/              ← 模板存储（本地模式）
```

---

## Slide 26: 自建机房部署 — 第四步：验证与使用

**SDK 连接配置**：

```python
# Python SDK
from e2b import Sandbox

sandbox = Sandbox(
    api_key="e2b_53ae1fed82754c17ad8077fbc8bcdd90",
    api_url="http://localhost:3000",
    sandbox_url="http://localhost:3002",
)

# 执行代码
result = sandbox.run("echo 'Hello from Firecracker!'")
print(result.stdout)
```

**服务健康检查**：

```
http://localhost:3000/health   ← API
http://localhost:3002/health   ← Client Proxy
http://localhost:5008/health   ← Orchestrator
http://localhost:53000          ← Grafana 仪表盘
```

**自建部署架构图（无云服务）**：

```
用户 SDK
  ↓
Client Proxy (:3002) → Redis (:6379) → Orchestrator (:5008)
  ↓                                         ↓
API (:3000)                           Firecracker VM
  ↓                                         ↓
PostgreSQL (:5432)                    Envd (:49983)
ClickHouse (:8123)
  ↓
Grafana (:53000) ← Loki + Tempo + Mimir
```

**全部运行在一台裸金属 Linux 服务器上，零云服务依赖。**

---

## Slide 27: 自建机房部署 — 生产环境扩展指南

**单机跑通后，如何扩展到多节点生产集群？**

### 多节点架构

```
┌─────────────────────────────────────────────────┐
│  控制节点（1-3 台）                              │
│  ├─ Nomad Server + Consul Server                │
│  ├─ PostgreSQL（主从复制）                        │
│  ├─ Redis Cluster                                │
│  └─ ClickHouse                                   │
├─────────────────────────────────────────────────┤
│  API 节点（2+ 台，无状态，可水平扩展）             │
│  ├─ API 服务                                     │
│  └─ Client Proxy                                 │
├─────────────────────────────────────────────────┤
│  计算节点（N 台，运行 Firecracker VM）            │
│  ├─ Orchestrator（Nomad Client）                 │
│  ├─ /dev/kvm + cgroup v2 + nbd + hugepages      │
│  └─ NFS 挂载共享模板存储                          │
└─────────────────────────────────────────────────┘
```

### 关键步骤

| 步骤 | 说明 |
|------|------|
| 1. 部署 Nomad 集群 | 控制节点运行 Server，计算节点运行 Client |
| 2. 共享存储 | NFS / Ceph / MinIO 挂载到所有计算节点 |
| 3. 负载均衡 | Traefik / Nginx 前置 API 和 Client Proxy |
| 4. DNS 配置 | 泛域名 `*.sandbox.yourdomain.com` 指向 Proxy |
| 5. TLS | Let's Encrypt 或自签证书 |
| 6. 监控 | Grafana + Loki + Tempo 集中收集所有节点遥测 |

### 多节点后的自动调度

一旦 Nomad 集群运行起来，E2B 的节点发现和 Best-of-K 调度
会**自动生效**——API 每 5 秒轮询 Nomad 发现新节点，
沙箱创建请求自动分配到最空闲的计算节点。



