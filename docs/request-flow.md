API (:3000)
Orchestrator (:5008) 

请求

```
POST /process.Process/Start HTTP/1.1
host: localhost:5007
connection: keep-alive
User-Agent: e2b-js-sdk/2.18.0
connect-protocol-version: 1
connect-timeout-ms: 60000
content-type: application/connect+json
keepalive-ping-interval: 50
e2b-sandbox-id: ionfec0uaozpu5jacvfkz
e2b-sandbox-port: 49983
X-Access-Token: 541bacf5b7716eb610b9cc40cd9caf3865115081fc7c8d8e9ff4a8bb758983d8
accept: */*
accept-language: *
sec-fetch-mode: cors
accept-encoding: gzip, deflate
content-length: 96
```
```json
{
  "process": {
    "cmd": "/bin/bash",
    "args": [
      "-l",
      "-c",
      "echo \"Hello from E2B!\""
    ]
  },
  "stdin": false
}
```

响应:

```
HTTP/1.1 200 OK
Connect-Accept-Encoding: gzip
Content-Type: application/connect+json
Date: Wed, 08 Apr 2026 02:45:16 GMT
Vary: Origin
Transfer-Encoding: chunked
```
```json
{
  "event": {
    "start": {
      "pid": 405
    }
  }
}
{
  "event": {
    "data": {
      "stdout": "SGVsbG8gZnJvbSBFMkIhCg=="
    }
  }
}
{
  "event": {
    "end": {
      "exited": true,
      "status": "exit status 0"
    }
  }
}
{}
```

```
POST /sandboxes HTTP/1.1
host: localhost:3000
connection: keep-alive
Content-Type: application/json
browser: unknown
lang: js
lang_version: 22.19.0
package_version: 2.18.0
publisher: e2b
sdk_runtime: node
system: Linux
X-API-KEY: e2b_53ae1fed82754c17ad8077fbc8bcdd90
User-Agent: e2b-js-sdk/2.18.0
accept: */*
accept-language: *
sec-fetch-mode: cors
accept-encoding: gzip, deflate
content-length: 96

{
  "templateID": "base",
  "timeout": 300,
  "secure": true,
  "allow_internet_access": true,
  "autoPause": false
}


HTTP/1.1 201 Created
Content-Type: application/json; charset=utf-8
Date: Wed, 08 Apr 2026 04:31:25 GMT
Content-Length: 257

{
  "alias": "base",
  "clientID": "6532622b",
  "domain": null,
  "envdAccessToken": "d6c6924e864a2809cfa4eb3e1b66724024e03067b743f79d92603fe92a128c3d",
  "envdVersion": "0.5.8",
  "sandboxID": "ikpda5wr83e4pav42bqw5",
  "templateID": "4u5f5e393rle2b3x70m1",
  "trafficAccessToken": null
}

DELETE /sandboxes/ikpda5wr83e4pav42bqw5 HTTP/1.1
host: localhost:3000
connection: keep-alive
browser: unknown
lang: js
lang_version: 22.19.0
package_version: 2.18.0
publisher: e2b
sdk_runtime: node
system: Linux
X-API-KEY: e2b_53ae1fed82754c17ad8077fbc8bcdd90
User-Agent: e2b-js-sdk/2.18.0
accept: */*
accept-language: *
sec-fetch-mode: cors
accept-encoding: gzip, deflate


HTTP/1.1 204 No Content
Date: Wed, 08 Apr 2026 04:31:26 GMT

```

## Redis 通信

沙箱完整生命周期的 Redis 交互记录：模板解析 → 创建沙箱 → 注册到目录 → 清理销毁。

### 1. 模板别名解析

通过团队名/别名查找模板 ID。

```
GET template:alias:local-dev-team/base
```
```json
{
  "template_id": "4u5f5e393rle2b3x70m1",
  "team_id": "0b8a3ded-4489-4722-afd1-1d82e64ec2d5",
  "not_found": false
}
```

```
PTTL template:alias:local-dev-team/base
```
```
273960
```

### 2. 模板详情获取

获取模板的构建详情（Dockerfile 基于 `e2bdev/base`，2 vCPU，512MB RAM，512MB 磁盘，内核 `vmlinux-6.1.158`，Firecracker `v1.12.1`）。

```
GET template:info:{4u5f5e393rle2b3x70m1}:default
```
```json
{
  "template": {
    "aliases": ["base"],
    "buildCount": 0,
    "buildID": "4643c4fa-6c2f-42d1-8996-55f19633e630",
    "buildStatus": "",
    "cpuCount": 0,
    "createdAt": "0001-01-01T00:00:00Z",
    "createdBy": null,
    "diskSizeMB": 0,
    "envdVersion": "",
    "lastSpawnedAt": null,
    "memoryMB": 0,
    "names": ["local-dev-team/base"],
    "public": false,
    "spawnCount": 0,
    "templateID": "4u5f5e393rle2b3x70m1",
    "updatedAt": "0001-01-01T00:00:00Z"
  },
  "team_id": "0b8a3ded-4489-4722-afd1-1d82e64ec2d5",
  "cluster_id": "00000000-0000-0000-0000-000000000000",
  "build": {
    "ID": "4643c4fa-6c2f-42d1-8996-55f19633e630",
    "CreatedAt": "2026-04-07T14:24:36.296987Z",
    "UpdatedAt": "2026-04-07T14:24:36.296987Z",
    "FinishedAt": "2026-04-07T14:27:41.849403Z",
    "Status": "uploaded",
    "Dockerfile": "{\"from_image\":\"e2bdev/base\",\"from_template\":null,\"steps\":[]}",
    "StartCmd": null,
    "Vcpu": 2,
    "RamMb": 512,
    "FreeDiskSizeMb": 512,
    "TotalDiskSizeMb": 2743,
    "KernelVersion": "vmlinux-6.1.158",
    "FirecrackerVersion": "v1.12.1_210cbac",
    "EnvID": "4u5f5e393rle2b3x70m1",
    "EnvdVersion": "0.5.8",
    "ReadyCmd": null,
    "ClusterNodeID": "local",
    "Reason": {"message": ""},
    "Version": null,
    "CpuArchitecture": "amd64",
    "CpuFamily": "6",
    "CpuModel": "165",
    "CpuModelName": "Intel(R) Core(TM) i7-10700 CPU @ 2.90GHz",
    "CpuFlags": ["fpu","vme","de","pse","tsc","msr","pae","mce","cx8","apic","sep","mtrr","pge","mca","cmov","pat","pse36","clflush","dts","acpi","mmx","fxsr","sse","sse2","ss","ht","tm","pbe","syscall","nx","pdpe1gb","rdtscp","lm","constant_tsc","art","arch_perfmon","pebs","bts","rep_good","nopl","xtopology","nonstop_tsc","cpuid","aperfmperf","pni","pclmulqdq","dtes64","monitor","ds_cpl","vmx","smx","est","tm2","ssse3","sdbg","fma","cx16","xtpr","pdcm","pcid","sse4_1","sse4_2","x2apic","movbe","popcnt","tsc_deadline_timer","aes","xsave","avx","f16c","rdrand","lahf_lm","abm","3dnowprefetch","cpuid_fault","ssbd","ibrs","ibpb","stibp","ibrs_enhanced","tpr_shadow","flexpriority","ept","vpid","ept_ad","fsgsbase","tsc_adjust","bmi1","avx2","smep","bmi2","erms","invpcid","mpx","rdseed","adx","smap","clflushopt","intel_pt","xsaveopt","xsavec","xgetbv1","xsaves","dtherm","ida","arat","pln","pts","hwp","hwp_notify","hwp_act_window","hwp_epp","vnmi","pku","ospke","md_clear","flush_l1d","arch_capabilities","ibpb_exit_to_user"],
    "StatusGroup": "ready",
    "TeamID": "0b8a3ded-4489-4722-afd1-1d82e64ec2d5"
  },
  "tag": "default"
}
```

```
PTTL template:info:{4u5f5e393rle2b3x70m1}:default
```
```
273962
```

### 3. 沙箱创建与注册

以过期时间戳为 score，记录沙箱到全局过期有序集合中。

```
ZADD sandbox:storage:global:expiration 1775700969323 0b8a3ded-4489-4722-afd1-1d82e64ec2d5:imnytrqb8maa19hdar5ce
```
```
(integer) 1
```

通过 Lua 脚本原子写入沙箱详情到沙箱数据 key 和团队索引 key。

```
EVALSHA 53a85b44e211f900069fd425a687be4d7a70b6ce 2
  sandbox:storage:{0b8a3ded-4489-4722-afd1-1d82e64ec2d5}:sandboxes:imnytrqb8maa19hdar5ce
  sandbox:storage:{0b8a3ded-4489-4722-afd1-1d82e64ec2d5}:index
  <sandbox_json>
  imnytrqb8maa19hdar5ce
```

sandbox_json 内容：

```json
{
  "sandboxID": "imnytrqb8maa19hdar5ce",
  "templateID": "4u5f5e393rle2b3x70m1",
  "clientID": "6532622b",
  "alias": "base",
  "executionID": "672c7f32-403b-4e60-b2ce-881913c82e29",
  "teamID": "0b8a3ded-4489-4722-afd1-1d82e64ec2d5",
  "buildID": "4643c4fa-6c2f-42d1-8996-55f19633e630",
  "baseTemplateID": "4u5f5e393rle2b3x70m1",
  "metadata": null,
  "maxInstanceLength": 3600000000000,
  "startTime": "2026-04-09T10:11:09.323724706+08:00",
  "endTime": "2026-04-09T10:16:09.323724706+08:00",
  "vCpu": 2,
  "totalDiskSizeMB": 2743,
  "ramMB": 512,
  "kernelVersion": "vmlinux-6.1.158",
  "firecrackerVersion": "v1.12.1_210cbac",
  "envdVersion": "0.5.8",
  "envdAccessToken": "6607b19a1f2e9a39ea746b91c3c8e816fc81b20bd932d56e2ac7abe390ed80a9",
  "trafficAccessToken": null,
  "allowInternetAccess": true,
  "nodeID": "local",
  "clusterID": "00000000-0000-0000-0000-000000000000",
  "autoPause": false,
  "network": null,
  "volumeMounts": null,
  "state": "running"
}
```

```
(integer) 1
```

记录团队活跃时间戳。

```
ZADD sandbox:storage:global:teams 1775700669 0b8a3ded-4489-4722-afd1-1d82e64ec2d5
```
```
(integer) 0
```

### 4. 服务目录注册与注销

将沙箱注册到服务目录（TTL 3600 秒），记录 orchestrator 路由信息。

```
SET sandbox:catalog:imnytrqb8maa19hdar5ce
  '{"orchestrator_id":"4f156bff-1593-4746-b769-78ffc8c0a4fa","orchestrator_ip":"","execution_id":"672c7f32-403b-4e60-b2ce-881913c82e29","sandbox_started_at":"2026-04-09T10:11:09.323724706+08:00","sandbox_max_length_in_hours":1}'
  EX 3600
```
```
OK
```

验证写入：

```
GET sandbox:catalog:imnytrqb8maa19hdar5ce
```
```json
{
  "orchestrator_id": "4f156bff-1593-4746-b769-78ffc8c0a4fa",
  "orchestrator_ip": "",
  "execution_id": "672c7f32-403b-4e60-b2ce-881913c82e29",
  "sandbox_started_at": "2026-04-09T10:11:09.323724706+08:00",
  "sandbox_max_length_in_hours": 1
}
```

沙箱被停止后，从服务目录中删除：

```
DEL sandbox:catalog:imnytrqb8maa19hdar5ce
```
```
(integer) 1
```

### 5. 沙箱清理（分布式锁 + 删除）

获取分布式锁（60 秒超时，带唯一 token 防止误释放）：

```
EVALSHA 80a1b5f2cfccec3b7119ba7721d2127682b691a7 1
  lock:sandbox:storage:{0b8a3ded-4489-4722-afd1-1d82e64ec2d5}:sandboxes:imnytrqb8maa19hdar5ce
  fTTm6lqJ1LbBRvQd2ZARvw
  22
  60000
```
```
OK
```

通过 Lua 脚本原子删除沙箱数据和团队索引：

```
EVALSHA ce3785275218237c4caeced53953a4d00b69f879 2
  sandbox:storage:{0b8a3ded-4489-4722-afd1-1d82e64ec2d5}:sandboxes:imnytrqb8maa19hdar5ce
  sandbox:storage:{0b8a3ded-4489-4722-afd1-1d82e64ec2d5}:index
  imnytrqb8maa19hdar5ce
```
```
(integer) 1
```

从全局过期有序集合中移除：

```
ZREM sandbox:storage:global:expiration 0b8a3ded-4489-4722-afd1-1d82e64ec2d5:imnytrqb8maa19hdar5ce
```
```
(integer) 1
```

用相同 token 释放分布式锁：

```
EVALSHA cf0e94b2e9ffc7e04395cf88f7583fc309985910 1
  lock:sandbox:storage:{0b8a3ded-4489-4722-afd1-1d82e64ec2d5}:sandboxes:imnytrqb8maa19hdar5ce
  fTTm6lqJ1LbBRvQd2ZARvw
```
```
(integer) 1
```

### 总结

这是一个沙箱的完整生命周期：模板解析 → 创建沙箱 → 注册到目录 → 清理销毁。使用了 Lua 脚本保证原子性，分布式锁防止并发清理竞争。沙箱 ID 为 `imnytrqb8maa19hdar5ce`，基于 `base` 模板，运行在本地节点（`nodeID: "local"`）。

## Firecracker 虚拟机暂停与恢复

整个机制基于 **Firecracker 快照** + **UFFD（Userfaultfd）惰性内存加载** + **Rootfs 差异**，分为三层：

```
用户请求
  ↓
API 层 (Gin handlers)
  ↓ gRPC
Orchestrator 层 (gRPC server)
  ↓
Sandbox/FC 层 (Firecracker API + UFFD)
```

### VM 状态组成

一个运行中的 Firecracker VM 的状态由三部分组成：

```
┌─────────────────────────────────┐
│          VM 完整状态              │
│                                 │
│  1. vCPU 状态                    │
│     - 通用寄存器 (RAX, RBX...)   │
│     - 特殊寄存器 (CR0, CR3...)   │
│     - MSR 寄存器                 │
│     - FPU/SSE/AVX 状态          │
│     - LAPIC 状态                │
│                                 │
│  2. 设备状态                     │
│     - virtio-net (网卡)          │
│     - virtio-block (磁盘)        │
│     - serial console            │
│     - i8042 (键盘控制器)          │
│     - RTC (实时时钟)             │
│                                 │
│  3. 内存                         │
│     - Guest 全部物理内存          │
│     - 通常 512MB - 数 GB          │
│                                 │
└─────────────────────────────────┘
```

### 暂停流程（Pause）

#### API 层

`packages/api/internal/handlers/sandbox_pause.go:25`

```
POST /sandboxes/{sandboxID}/pause
```

1. 认证 + 获取 teamID
2. 调用 `orchestrator.RemoveSandbox()` 并指定 `Action: sandbox.StateActionPause`
3. 如果沙箱已暂停（快照已存在），返回 `409 Conflict`

#### Orchestrator gRPC 层

`packages/orchestrator/pkg/server/sandboxes.go:474`

```go
func (s *Server) Pause(ctx, in *orchestrator.SandboxPauseRequest)
```

1. `acquireSandboxForSnapshot()` — 从沙箱 map 中获取并锁定沙箱
2. `snapshotAndCacheSandbox()` — 执行快照 + 本地缓存
3. `uploadSnapshotAsync()` — 异步上传到远端存储（GCS）
4. `stopSandboxAsync()` — 后台停止旧沙箱进程
5. 发布 `SandboxPausedEvent` 事件

#### 核心快照逻辑

`packages/orchestrator/pkg/sandbox/sandbox.go:1024`

```go
func (s *Sandbox) Pause(ctx, m metadata.Template) (*Snapshot, error)
```

| 步骤 | 操作 | 说明 |
|------|------|------|
| 1 | `s.Checks.Stop()` | 停止健康检查 |
| 2 | `s.process.Pause(ctx)` | 调用 Firecracker API 暂停 VM |
| 3 | `s.process.CreateSnapshot(ctx, snapfilePath)` | 创建 Firecracker 全量快照（CPU 状态、设备状态） |
| 4 | `pauseProcessMemory()` | 通过自定义 FC 端点获取脏页信息，从 FC 进程直接导出内存页到本地缓存 |
| 5 | `pauseProcessRootfs()` | 生成 rootfs 差异文件 |
| 6 | 返回 `Snapshot` | 包含 snapfile、memfile diff、rootfs diff、metadata |

#### 暂停 vCPU

`packages/orchestrator/pkg/sandbox/fc/client.go:104`

```go
func (c *apiClient) pauseVM(ctx) error {
    state := models.VMStatePaused
    c.client.Operations.PatchVM(...)
}
```

底层流程：

```
PATCH /vm  { "state": "Paused" }
       ↓
Firecracker VMM
       ↓
KVM_SET_MP_STATE → MP_STATE_STOPPED
       ↓
vCPU 线程退出 KVM_RUN ioctl
       ↓
Guest 内核完全冻结（时钟停止、中断停止）
```

通过 KVM 的 `KVM_SET_MP_STATE` ioctl 实现。vCPU 线程从 `KVM_RUN` 循环中退出，Guest 中的所有代码（包括内核）都停止执行。从 Guest 视角看，时间完全冻结。

#### 创建快照

`packages/orchestrator/pkg/sandbox/fc/client.go:121`

```go
func (c *apiClient) createSnapshot(ctx, snapfilePath) error {
    c.client.Operations.CreateSnapshot(&operations.CreateSnapshotParams{
        Body: &models.SnapshotCreateParams{
            SnapshotType: models.SnapshotCreateParamsSnapshotTypeFull,
            SnapshotPath: &snapfilePath,
        },
    })
}
```

Firecracker 保存快照时写入一个 snapfile，包含：

```
snapfile 二进制格式：
┌────────────────────────────┐
│ Magic Number + Version     │  文件头
├────────────────────────────┤
│ vCPU 状态 (每个 vCPU)       │
│  ├─ KVM_GET_REGS           │  通用寄存器
│  ├─ KVM_GET_SREGS          │  段寄存器、控制寄存器
│  ├─ KVM_GET_MSRS           │  MSR
│  ├─ KVM_GET_FPU            │  浮点状态
│  ├─ KVM_GET_LAPIC          │  本地 APIC
│  ├─ KVM_GET_XCRS           │  扩展控制寄存器
│  └─ KVM_GET_CPUID          │  CPUID 信息
├────────────────────────────┤
│ 设备状态                    │
│  ├─ virtio-net 队列状态     │  网卡收发队列、中断状态
│  ├─ virtio-block 队列状态   │  磁盘 I/O 队列
│  ├─ serial port 缓冲区      │
│  ├─ i8042 状态              │
│  └─ RTC 时间                │
├────────────────────────────┤
│ VM config                  │  内存布局、设备配置
└────────────────────────────┘
```

注意：snapfile 不包含内存数据，内存单独处理。

#### 导出内存差异

`packages/orchestrator/pkg/sandbox/sandbox.go:1084`

E2B 对 Firecracker 做了自定义扩展（非上游功能）：

```
内存差异导出流程：

1. 获取脏页位图
   - UFFD 模式: 从 UFFD handler 获取已服务页
   - Noop 模式: 调用自定义 FC 端点获取 resident + dirty pages 位图

2. 计算差异
   DiffMetadata = {
     Dirty:     bitset   // 脏页位图
     BlockSize: int      // 页大小 (4KB)
   }

3. 从 FC 进程内存空间直接复制脏页
   fc.ExportMemory(dirty_bitmap, output_path)
   通过 /proc/<fc_pid>/mem 或 process_vm_readv 只复制变化的页

4. 生成 memfile diff
   只存储相对于原始模板发生变化的页，大幅减小快照体积
```

#### 导出 Rootfs 差异

Rootfs 使用 overlay 架构，只需保存相对于基础模板的增量：

```
┌─────────────────────┐
│ 用户写入的文件变化     │ ← rootfs diff（只存差异）
├─────────────────────┤
│ 基础模板 rootfs       │ ← 不变，共享
└─────────────────────┘
```

### 恢复流程（Resume）

#### API 层

`packages/api/internal/handlers/sandbox_resume.go:28`

```
POST /sandboxes/{sandboxID}/resume
```

1. 检查沙箱当前状态：
   - `Pausing` → 等待暂停完成后继续恢复
   - `Killing` → 返回 404
   - `Snapshotting` → 返回 409
   - `Running` → 返回 409（已经在运行）
2. 从 `snapshotCache` 获取最近的快照
3. 调用 `startSandbox()` + `buildResumeSandboxData()` 恢复沙箱
4. 支持 `autoPause` 覆盖（恢复时可修改 autoPause 设置）

#### Orchestrator 层

`packages/orchestrator/pkg/sandbox/sandbox.go:549`

```go
func (f *Factory) ResumeSandbox(ctx, t template.Template, config, ...) (*Sandbox, error)
```

并行初始化资源：

| 并行任务 | 说明 |
|---------|------|
| UFFD 初始化 | 创建 Unix socket，准备接收 Firecracker 的 page fault 请求 |
| 内存预取（Prefetch） | 如果有 prefetch mapping，提前从存储加载热点内存页 |
| Rootfs 准备 | 通过 NBD 或文件 provider 准备文件系统 |
| 网络配置 | 分配网络 slot、配置 iptables |

#### Firecracker 恢复过程

`packages/orchestrator/pkg/sandbox/fc/process.go:452`

```go
func (p *Process) Resume(ctx, ..., uffdSocketPath, snapfile, ...) error
```

通过 `errgroup` 并行执行：

```
┌──────────────────────────────┐
│  errgroup 并行任务            │
│                              │
│  1. configure() → 启动 FC 进程│
│  2. socket.Wait() → 等待 UFFD│
│  3. SymlinkForce() → 挂载rootfs│
└──────────────────────────────┘
         ↓ 全部完成
  setMetrics()
         ↓
  loadSnapshot()    ← 加载快照，使用 UFFD 作为内存后端
         ↓
  等待 UFFD ready
         ↓
  setTxRateLimit()  ← 重置网络速率限制
         ↓
  resumeVM()        ← PATCH /vm {"state":"Resumed"}
         ↓
  KVM_RUN → vCPU 从暂停处继续执行
         ↓
  setMmds()         ← 更新 MMDS 元数据（sandboxID、accessToken等）
         ↓
  Guest 内的 envd 读取 MMDS 获取新身份
```

#### 加载快照

`packages/orchestrator/pkg/sandbox/fc/client.go:36`

```go
func (c *apiClient) loadSnapshot(ctx, uffdSocketPath, uffdReady, snapfile) error {
    backendType := models.MemoryBackendBackendTypeUffd  // 关键：使用 UFFD 惰性加载
    c.client.Operations.LoadSnapshot(&operations.LoadSnapshotParams{
        Body: &models.SnapshotLoadParams{
            ResumeVM:    false,          // 不自动恢复，后续手动调用 resumeVM
            MemBackend:  &models.MemoryBackend{
                BackendPath: &uffdSocketPath,
                BackendType: &backendType,
            },
            SnapshotPath: &snapfilePath,
        },
    })
    <-uffdReady  // 等待 UFFD handler 准备就绪
}
```

### UFFD 惰性内存加载

这是恢复速度的关键。UFFD（Userfaultfd）是 Linux 内核提供的用户态缺页处理机制。

传统方式 vs UFFD 方式对比：

```
传统方式:
  加载 512MB 内存 → 恢复 VM      总耗时: ~200ms + 恢复时间

UFFD 方式:
  注册 UFFD → 立即恢复 VM → 按需加载    首次恢复: ~10ms
```

UFFD 缺页处理流程：

```
Firecracker VM 访问内存页
       ↓ 该页未加载，触发缺页
KVM / Linux 内核缺页处理
       ↓ 检测到 UFFD 注册，通过 UFFD fd 通知用户态
UFFD Handler (orchestrator 进程, uffd/uffd.go)
       │
       │ 1. 收到 page fault 事件
       │ 2. 计算该页在 memfile 中的偏移量
       │ 3. 从 memfile (本地/GCS) 读取 4KB 数据
       │ 4. UFFDIO_COPY 写回 VM 内存
       ↓
VM 继续执行（Guest 无感知）
```

对应代码 `packages/orchestrator/pkg/sandbox/uffd/uffd.go:117`：

```go
func (u *Uffd) handle(ctx, sandboxId, fdExit) error {
    // 1. 接受 Firecracker 连接
    conn := u.lis.Accept()

    // 2. 接收内存区域映射 + UFFD 文件描述符
    unixConn.ReadMsgUnix(regionMappingsBuf, uffdBuf)
    // regionMappings: [{base: 0x0, size: 0x20000000}]
    // fds[0]: UFFD file descriptor

    // 3. 创建 userfaultfd handler
    uffd := userfaultfd.NewUserfaultfdFromFd(fds[0], memfile, mapping)

    // 4. 进入服务循环，处理 page faults
    uffd.Serve(ctx, fdExit)
}
```

#### 内存分层结构

恢复时的内存来源是分层的，UFFD handler 在处理 page fault 时按优先级查找：

```
┌───────────────────────────┐  优先级高
│  Memfile Diff (快照差异)    │  ← 暂停时保存的脏页
├───────────────────────────┤
│  Base Memfile (模板内存)    │  ← 模板构建时的基础内存
├───────────────────────────┤
│  Zero Page                │  ← 从未写入的页返回全零
└───────────────────────────┘  优先级低
```

先查 diff（快照时的修改），再查 base（模板原始状态），最后返回零页。

#### Prefetch 优化

纯惰性加载虽然启动快，但运行时的 page fault 开销大。E2B 通过记录历史 page fault 模式来预加载热点页：

```go
// sandbox.go:618 — 恢复时启动预取
if meta.Prefetch != nil && meta.Prefetch.Memory != nil {
    go func() {
        p := prefetch.New(l, memfile, fcUffd, meta.Prefetch.Memory, ...)
        p.Start(execCtx)
    }()
}
```

```
暂停时:  记录 page fault 顺序 → 保存到 metadata.Prefetch.Memory
恢复时:  后台 goroutine 按历史顺序预加载热点页
效果:    VM 恢复后大部分访问不触发 page fault，接近零延迟
```

### Checkpoint（运行中快照）

`packages/orchestrator/pkg/server/sandboxes.go:533`

与 Pause 不同，Checkpoint 在快照后立即恢复沙箱：

```
Checkpoint = Pause + 立即 Resume（同一沙箱，保持 ExecutionID 不变）
```

| | Pause | Checkpoint |
|---|---|---|
| 快照后 | 停止 VM | 立即恢复新 VM |
| 用途 | 休眠沙箱 | 运行中保存存档 |
| ExecutionID | 保留（恢复时复用） | 保留（新 VM 继承） |
| 旧 VM | 销毁 | 销毁（新 VM 接管） |

### AutoPause

当 `autoPause: true` 时，沙箱到期（timeout）后不会被直接 kill，而是触发暂停流程自动保存快照。在 `RemoveSandbox` 中根据 `StateActionPause` 决定走暂停还是销毁路径。恢复时可通过请求参数 `autoPause` 覆盖这个设置。

### Guest 视角

从虚拟机内部来看，暂停和恢复是完全透明的：

```
Guest 时间线:
  ... 执行代码 ...
  ─── 暂停点（Guest 完全不知道）──────
  │                                │
  │  可能过了几小时甚至几天           │
  │  Guest 的时钟被冻结              │
  │                                │
  ─── 恢复点 ─────────────────────── 
  ... 继续执行代码 ...
```

恢复后 Firecracker 通过 MMDS（Microvm Metadata Service）更新沙箱元数据，VM 内的 envd 可以通过 `169.254.169.254` 读取新的 sandboxID 和 accessToken，完成身份切换。

---

## 各服务中间件依赖分析

### 依赖矩阵

| 服务 | Redis | PostgreSQL | ClickHouse | Nomad | Consul | GCS/S3 | LaunchDarkly | PostHog | Loki | Supabase |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| API | ✅ | ✅ | ✅ | ✅ | - | - | ✅ | ✅ | ✅ | ✅ |
| Orchestrator | ✅ | - | ✅ | - | ✅ | ✅ | ✅ | - | - | - |
| Client-Proxy | ✅ | - | - | - | - | - | ✅ | - | - | - |
| Auth | ✅ | ✅ | - | - | - | - | - | - | - | - |
| Dashboard-API | - | ✅ | ✅ | - | - | - | - | - | - | - |
| Envd | - | - | - | - | - | - | - | - | - | - |
| Nomad-APM | - | - | - | ✅ | - | - | - | - | - | - |

> 所有服务（除 Envd）都接入了 OpenTelemetry（Traces/Metrics/Logs）。

### 按中间件分类

#### Redis

**依赖服务：** API、Orchestrator、Client-Proxy、Auth

| 服务 | 用途 | 关键环境变量 |
|---|---|---|
| API | 限流（redis_rate）、sandbox 状态存储、模板/快照缓存 | `REDIS_URL`, `REDIS_POOL_SIZE`(默认 160) |
| Orchestrator | 模板缓存 peer registry、sandbox 事件流（Redis Streams） | `REDIS_URL`, `REDIS_POOL_SIZE`(默认 10) |
| Client-Proxy | sandbox catalog 查找（定位 sandbox 所在节点）、本地 TTL 缓存(500ms) | `REDIS_URL`, `REDIS_POOL_SIZE`(默认 40) |
| Auth | 分布式锁（bsm/redislock） | `REDIS_URL` |

通用 Redis 环境变量：
- `REDIS_URL` — 单实例连接串
- `REDIS_CLUSTER_URL` — Redis Cluster 连接串（GCP Memorystore）
- `REDIS_TLS_CA_BASE64` — TLS CA 证书（Base64）

#### PostgreSQL

**依赖服务：** API、Auth、Dashboard-API

| 服务 | 用途 | 关键环境变量 |
|---|---|---|
| API | 主数据存储（sqlc），支持独立 Auth DB 和读写分离 | `POSTGRES_CONNECTION_STRING`, `AUTH_DB_CONNECTION_STRING`, `AUTH_DB_READ_REPLICA_CONNECTION_STRING` |
| Auth | 用户认证数据 | `POSTGRES_CONNECTION_STRING` |
| Dashboard-API | Dashboard 数据查询 | `POSTGRES_CONNECTION_STRING` |

连接池配置：`DB_MAX_OPEN_CONNECTIONS`(默认 40)、`DB_MIN_IDLE_CONNECTIONS`(默认 5)

#### ClickHouse

**依赖服务：** API、Orchestrator、Dashboard-API（均为可选，未配置时优雅降级）

| 服务 | 用途 | 关键环境变量 |
|---|---|---|
| API | 分析和指标存储 | `CLICKHOUSE_CONNECTION_STRING` |
| Orchestrator | 写入 sandbox 事件和主机统计 | `CLICKHOUSE_CONNECTION_STRING` |
| Dashboard-API | 分析数据查询 | `CLICKHOUSE_CONNECTION_STRING` |

#### GCS / S3

**依赖服务：** 仅 Orchestrator

用途：模板存储和构建缓存。支持三种 provider：

| Provider | 环境变量 |
|---|---|
| GCPBucket（默认） | `TEMPLATE_BUCKET_NAME`, `BUILD_CACHE_BUCKET_NAME` |
| AWSBucket | `TEMPLATE_BUCKET_NAME`, `BUILD_CACHE_BUCKET_NAME` |
| Local | `LOCAL_TEMPLATE_STORAGE_BASE_PATH`(默认 `/tmp/templates`) |

通过 `STORAGE_PROVIDER` 环境变量切换。

#### Nomad

**依赖服务：** API、Nomad-APM

| 服务 | 用途 | 关键环境变量 |
|---|---|---|
| API | 调度和管理 sandbox 任务 | `NOMAD_ADDRESS`(默认 `http://localhost:4646`), `NOMAD_TOKEN` |
| Nomad-APM | 自动扩缩容插件 | Nomad SDK 内置配置 |

#### Consul

**依赖服务：** 仅 Orchestrator

用途：服务发现，用于 orchestrator 节点间的互相发现。

#### LaunchDarkly

**依赖服务：** API、Orchestrator、Client-Proxy

用途：Feature flags 控制（sandbox auto-resume、限流策略、功能灰度发布等）。未配置 `LAUNCH_DARKLY_API_KEY` 时降级为离线测试数据源。

#### Supabase

**依赖服务：** 仅 API

用途：JWT Token 验证，用于用户和团队认证。环境变量：`SUPABASE_JWT_SECRETS`（支持 key 轮换）。

#### PostHog

**依赖服务：** 仅 API（可选）

用途：产品分析和事件追踪。环境变量：`POSTHOG_API_KEY`。

#### Loki

**依赖服务：** 仅 API

用途：日志聚合和查询，用于获取 sandbox 运行日志。环境变量：`LOKI_URL`, `LOKI_USER`, `LOKI_PASSWORD`。

#### OpenTelemetry

**依赖服务：** 除 Envd 外的所有服务

用途：分布式追踪、指标采集、日志导出（Grafana Loki + Tempo + Mimir）。

| 环境变量 | 说明 |
|---|---|
| `OTEL_COLLECTOR_GRPC_ENDPOINT` | OTEL Collector gRPC 端点 |
| `LOGS_COLLECTOR_ADDRESS` | 日志收集地址 |

### Envd — 零外部依赖

Envd 运行在 Firecracker VM 内部，是纯本地的轻量级 daemon，仅做进程管理、文件系统操作和端口转发，不连接任何外部中间件。