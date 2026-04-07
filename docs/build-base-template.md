# `make -C packages/shared/scripts local-build-base-template` 代码流程详解

本文档详细记录了 E2B 基础模板构建命令的完整代码流程，涵盖从 Makefile 入口到 Firecracker VM 快照生成的每一个环节。

---

## 目录

- [第一层：Makefile 入口](#第一层makefile-入口)
- [第二层：环境变量与 TypeScript 入口](#第二层环境变量与-typescript-入口)
- [第三层：SDK 到 API 服务器 (HTTP)](#第三层sdk-到-api-服务器-http)
- [第四层：API 到 Orchestrator (gRPC)](#第四层api-到-orchestrator-grpc)
- [第五层：Builder.Build() 构建核心](#第五层builderbuild-构建核心)
- [第六层：runBuild() 构建流水线编排](#第六层runbuild-构建流水线编排)
- [第七层：Base 阶段详解](#第七层base-阶段详解)
- [第八层：镜像拉取详细流程](#第八层镜像拉取详细流程)
  - [8.1 入口函数 constructLayerFilesFromOCI](#81-入口函数-constructlayerfilesfromoci)
  - [8.2 镜像拉取路由分发](#82-镜像拉取路由分发)
  - [8.3 GetPublicImage 公共镜像拉取](#83-getpublicimage-公共镜像拉取)
  - [8.4 GetImage 从 Artifact Registry 拉取](#84-getimage-从-artifact-registry-拉取)
  - [8.5 注入附加 OCI 层](#85-注入附加-oci-层)
  - [8.6 OCI 转 ext4](#86-oci-转-ext4)
  - [8.7 后处理：扩容到目标磁盘大小](#87-后处理扩容到目标磁盘大小)
  - [8.8 创建块设备](#88-创建块设备)
- [第九层：后续构建阶段](#第九层后续构建阶段)
- [第十层：完成与回调](#第十层完成与回调)
- [附录](#附录)
  - [关键产物](#关键产物)
  - [Firecracker VM 启动次数](#firecracker-vm-启动次数)
  - [关键 Go 源文件索引](#关键-go-源文件索引)
  - [镜像拉取完整流程图](#镜像拉取完整流程图)

---

## 第一层：Makefile 入口

**文件：`packages/shared/scripts/Makefile:1-8`**

```makefile
.PHONY: local-build-base-template
local-build-base-template:
	echo "Building base template for local dev..."
	npm install
	DOTENV_CONFIG_PATH=./.env.local \
		npx tsx \
			--import dotenv/config \
			build.prod.ts
```

做了两件事：

1. `npm install` — 安装 `e2b` SDK (^2.9.0) 和 `dotenv`
2. 通过 `tsx` 运行 `build.prod.ts`，`--import dotenv/config` 在执行前加载 `.env.local` 中的环境变量

---

## 第二层：环境变量与 TypeScript 入口

### 环境变量

**文件：`packages/shared/scripts/.env.local`**

| 变量 | 值 | 用途 |
|---|---|---|
| `E2B_ACCESS_TOKEN` | `sk_e2b_89215020937a4c989cde33d7bc647715` | E2B SDK 认证令牌 |
| `E2B_API_KEY` | `e2b_53ae1fed82754c17ad8077fbc8bcdd90` | E2B SDK API Key |
| `E2B_API_URL` | `http://localhost:3000` | 指向**本地** API 服务器 |

这些由 `dotenv/config` 通过 `--import dotenv/config` 和 `DOTENV_CONFIG_PATH=./.env.local` 加载。

### Node.js 依赖

**文件：`packages/shared/scripts/package.json`**

```json
{
  "name": "base-template",
  "version": "1.0.0",
  "dependencies": {
    "e2b": "^2.9.0"
  },
  "devDependencies": {
    "dotenv": "^16.0.3"
  }
}
```

唯一的运行时依赖是官方 `e2b` npm SDK (v2.9.0+)。

### TypeScript 入口

**文件：`packages/shared/scripts/build.prod.ts:1-13`**

```typescript
import { Template } from "e2b";
import { template } from "./template.js";

async function main() {
  await Template.build(template, {
    alias: "base",       // 模板别名
    memoryMB: 512,       // VM 内存 512MB
    skipCache: true,     // 强制完整重建
    onBuildLogs: (it) => console.log(it.toString()),
  });
}

main().catch((err) => console.error(err));
```

**文件：`packages/shared/scripts/template.ts:1-3`**

```typescript
import { Template } from "e2b";
export const template = Template().fromBaseImage();
```

这创建了一个**最简模板定义** — 使用 E2B 默认基础镜像 (`e2bdev/base:latest`)，没有额外的 RUN/COPY 步骤。

---

## 第三层：SDK 到 API 服务器 (HTTP)

`Template.build()` 内部对本地 API (`localhost:3000`) 发起两个 HTTP 请求：

### 请求 1：注册构建

**`POST /v3/templates`**

- 处理器：`packages/api/internal/handlers/template_request_build_v3.go`
- 调用 `template.RegisterBuild()`（`packages/api/internal/template/register_build.go`）
- 在**单个 DB 事务**中完成：
  - 检查团队并发构建限制
  - 生成随机 `buildID`
  - 创建/更新 `templates` 表记录
  - 作废同模板的未开始构建
  - 创建 `template_builds` 记录（状态：`Waiting`）
  - 创建/更新别名 `"base"` -> `templateID` 映射
  - 创建 `active_template_builds` 记录
- 返回 `{ templateID, buildID }` + HTTP 202

### 请求 2：启动构建

**`POST /v2/templates/{templateID}/builds/{buildID}`**

- 处理器：`packages/api/internal/handlers/template_start_build_v2.go`
- 验证构建状态为 `Waiting`
- 查找可用的 Builder 节点
- 调用 `templateManager.CreateTemplate()`（`packages/api/internal/template-manager/create_template.go`）

---

## 第四层：API 到 Orchestrator (gRPC)

`templateManager.CreateTemplate()` 构造 `TemplateConfig` protobuf 消息，通过 gRPC 调用 Orchestrator。

**Orchestrator 端：`packages/orchestrator/pkg/template/server/create_template.go:23-162`**

`TemplateCreate()` 的关键逻辑：

1. 解析模板配置（templateID, buildID, memoryMB=512, fromImage="e2bdev/base:latest" 等）
2. 创建构建缓存条目和日志系统
3. **启动后台 goroutine** 调用 `s.builder.Build(ctx, metadata, template, core)`
4. **立即返回**给 API（构建异步执行）

---

## 第五层：Builder.Build() 构建核心

**文件：`packages/orchestrator/pkg/template/build/builder.go:115-227`**

```
Build() -> runBuild()
```

`Build()` 做的准备工作：

1. 设置 LaunchDarkly feature flag 上下文
2. 记录构建开始时间（用于 metrics）
3. 获取 envd 版本号（从宿主机 envd 二进制文件）
4. 创建 `errgroup` 用于并行上传层数据
5. 构建 `BuildContext` 后调用 `runBuild()`

---

## 第六层：runBuild() 构建流水线编排

**文件：`packages/orchestrator/pkg/template/build/builder.go:241-382`**

组装 **5 个构建阶段**（每个实现 `BuilderPhase` 接口）：

| 顺序 | 阶段 | 包路径 | 功能 |
|------|------|--------|------|
| 1 | **Base** | `phases/base/` | 拉取 OCI 镜像，创建 ext4 根文件系统，BusyBox 引导安装 systemd |
| 2 | **User** | `phases/user/` | 创建默认用户 `user`（仅 v2.1.0+） |
| 3 | **Steps** | `phases/steps/` | 执行模板定义的 RUN/COPY 步骤（base 模板无步骤，空操作） |
| 4 | **Finalize** | `phases/finalize/` | 运行 start/ready 命令，配置脚本，拍摄最终快照 |
| 5 | **Optimize** | `phases/optimize/` | 启动 VM 2 次，采集预取页映射以加速冷启动 |

执行器 `phases.Run()` 按顺序迭代每个阶段，每阶段执行：`Hash()` -> `Layer()` -> `Build()`。

---

## 第七层：Base 阶段详解

**文件：`packages/orchestrator/pkg/template/build/phases/base/builder.go`**

### 7.1 Hash() — 计算缓存键

基于：索引版本 + provision 脚本哈希 + 磁盘大小 + 基础镜像源 (`e2bdev/base:latest`)。

### 7.2 Layer() — 检查缓存

由于 `skipCache=true` / `Force=true`，直接返回 `Cached=false`，必须完整构建。

### 7.3 Build() -> buildLayerFromOCI()

**`builder.go:160-302`** 的关键步骤：

**a) 构造层文件** (`constructLayerFilesFromOCI` in `phases/base/files.go`)：

- **拉取 OCI 镜像** `e2bdev/base:latest`（通过 `oci.GetPublicImage()`）
- **注入额外 OCI 层**（详见[第八层](#第八层镜像拉取详细流程)）
- **转换为 ext4 文件系统**（`oci.ToExt4()`）
- **创建空内存文件** (512MB, hugepages 2MB 页)

**b) 配置 VM** (`provisionSandbox`, `provision.go`)：

- 使用 **BusyBox init**（不是 systemd）启动第一个 Firecracker VM
- BusyBox init 执行 `rcS.sh`（挂载 proc/sys/dev/tmp/run），然后运行 `provision.sh`
- **`provision.sh`** 安装：`systemd systemd-sysv openssh-server sudo chrony socat curl ca-certificates fuse3 iptables git nfs-common`
- 配置：shell、chrony(NTP)、SSH、inotify limits，屏蔽有问题的 systemd 服务，将 systemd 链接到 `/usr/sbin/init`，清理 machine-id
- 成功后写入 `/provision.result`，sync 磁盘，冻结文件系统
- Orchestrator 从 Firecracker stdout 读取退出码，关闭 VM

**c) 扩大磁盘** (`enlargeDiskAfterProvisioning`)：provisioning 消耗了空间后按 `diskSizeMB` 扩容

**d) 检查 ext4 完整性** (`e2fsck`)

**e) 创建 Base Layer**：使用 **systemd init** 启动第二个 Firecracker VM，同步磁盘变更，拍摄快照

---

## 第八层：镜像拉取详细流程

### 总览：数据流

```
constructLayerFilesFromOCI()                    [files.go:23]
  |
  +-> rootfs.New()                               [rootfs.go:70]
  |     |
  |     +-> CreateExt4Filesystem()               [rootfs.go:84]
  |           |
  |           +-- 1. 拉取 OCI 镜像               [oci.go:90 / oci.go:148]
  |           +-- 2. 注入附加 OCI 层              [rootfs.go:193]
  |           +-- 3. mutate.AppendLayers()        [rootfs.go:128]
  |           +-- 4. ToExt4() 转换为 ext4         [oci.go:188]
  |           +-- 5. MakeWritable()               [ext4.go:109]
  |           +-- 6. 计算 + 扩展磁盘              [ext4.go:124]
  |           +-- 7. CheckIntegrity()             [ext4.go:220]
  |
  +-> block.NewLocal(rootfsPath)                  -> rootfs 块设备
  +-> block.NewEmpty(memorySize)                  -> 空 memfile
```

---

### 8.1 入口函数 `constructLayerFilesFromOCI`

**文件：`packages/orchestrator/pkg/template/build/phases/base/files.go:23-80`**

```go
func constructLayerFilesFromOCI(ctx, userLogger, buildContext, phaseMetadata, baseBuildID,
    artifactRegistry, dockerhubRepository, featureFlags, rootfsPath)
```

三步走：

1. 创建 `Rootfs` 对象 + 生成 `provisionScript`（从 `provision.sh` Go 模板渲染，注入 BusyBox 路径 `/usr/bin/busybox` 和结果路径 `/provision.result`）
2. 调用 `rtfs.CreateExt4Filesystem()` — 拉镜像、注层、转 ext4
3. 包装返回值：`block.NewLocal(rootfsPath)` 创建 rootfs 块设备，`block.NewEmpty(512MB)` 创建零填充 memfile

---

### 8.2 镜像拉取路由分发

**文件：`packages/orchestrator/pkg/template/build/core/rootfs/rootfs.go:106-112`**

```go
if template.FromImage != "" {
    img, err = oci.GetPublicImage(ctx, r.dockerhubRepository, template.FromImage, template.RegistryAuthProvider)
} else {
    img, err = oci.GetImage(ctx, r.artifactRegistry, template.TemplateID, r.buildContext.Template.BuildID)
}
```

对于 base 模板，`FromImage = "e2bdev/base:latest"`，走 `GetPublicImage` 路径。

---

### 8.3 GetPublicImage 公共镜像拉取

**文件：`packages/orchestrator/pkg/template/build/core/oci/oci.go:90-146`**

```go
func GetPublicImage(ctx context.Context, dockerhubRepository dockerhub.RemoteRepository,
    tag string, authProvider auth.RegistryAuthProvider) (containerregistry.Image, error)
```

#### a) 解析镜像引用

```go
ref, err := name.ParseReference(tag)  // "e2bdev/base:latest"
```

使用 `go-containerregistry` 的 `name.ParseReference` 解析。`e2bdev/base:latest` 会被规范化为 `index.docker.io/e2bdev/base:latest`。

#### b) 设置目标平台

```go
platform := DefaultPlatform  // {OS: "linux", Architecture: "amd64"}
```

强制 `linux/amd64`，因为 Firecracker 只支持 x86_64。

#### c) 分支选择拉取方式

```go
if authProvider == nil && ref.Context().RegistryStr() == name.DefaultRegistry {
    // 路径 A: Docker Hub 默认注册表 + 无自定义认证 -> 走代理
    img, err := dockerhubRepository.GetImage(ctx, tag, platform)
} else {
    // 路径 B: 自定义注册表或带认证 -> 直接拉取
    opts := []remote.Option{remote.WithPlatform(platform)}
    if authProvider != nil {
        authOption, _ := authProvider.GetAuthOption(ctx)
        opts = append(opts, authOption)
    }
    img, err := remote.Image(ref, opts...)
}
```

**路径 A（base 模板的默认路径）：通过 DockerHub 代理仓库拉取**

由 `DOCKERHUB_REMOTE_REPOSITORY_PROVIDER` 环境变量决定代理实现（`packages/shared/pkg/dockerhub/repository.go`）：

| Provider | 行为 |
|---|---|
| **GCP** (`repository_gcp.go`) | 将 `e2bdev/base:latest` 转换为 `{GCP_PROXY_URL}/e2bdev/base:latest`，使用 GCP 服务账号认证拉取 |
| **AWS** (`repository_aws.go`) | 转换为 ECR 代理 URL，使用 ECR `GetAuthorizationToken` 认证 |
| **Noop** (`repository_noop.go`) | 直接从 Docker Hub 拉取，无认证。用于 `DOCKERHUB_REMOTE_REPOSITORY_URL` 为空时（本地开发） |

代理机制的目的：避免 Docker Hub 限速（rate limit），通过 GCP Artifact Registry / AWS ECR 的远程仓库代理缓存公共镜像。

**路径 B：直接拉取 + 认证**

认证提供者由 `auth.NewAuthProvider()` 工厂函数创建（`packages/orchestrator/pkg/template/build/core/oci/auth/auth.go:18-33`）：

| 类型 | 实现 | 认证方式 |
|---|---|---|
| **General** | `auth/general.go` | `remote.WithAuth(&authn.Basic{Username, Password})` |
| **AWS ECR** | `auth/aws.go` | 加载 AWS 静态凭证 -> `ecr.GetAuthorizationToken()` -> Base64 解码 -> `authn.Basic` |
| **GCP** | `auth/gcp.go` | `google.NewJSONKeyAuthenticator(serviceAccountJson)` |

#### d) 平台验证

```go
err = verifyImagePlatform(img, platform)  // 检查 config.Architecture == "amd64"
```

确保拉到的镜像确实是 amd64 架构。

#### e) 错误友好化

`wrapImagePullError()`（`oci.go:65-88`）将 `transport.Error` 转换为用户可读错误：

| Registry 错误码 | 用户消息 |
|---|---|
| `ManifestUnknownErrorCode` | "image not found: the image or tag does not exist" |
| `NameUnknownErrorCode` | "repository not found: verify the image name" |
| `UnauthorizedErrorCode` | "access denied: authentication required" |
| `DeniedErrorCode` | "access denied: insufficient permissions" |

---

### 8.4 GetImage 从 Artifact Registry 拉取

**文件：`oci.go:148-167`**

用于 v1 模板构建（`FromImage` 为空时），从内部 Artifact Registry 拉取之前上传的模板镜像：

```go
func GetImage(ctx, artifactRegistry, templateId, buildId) (Image, error) {
    img, err := artifactRegistry.GetImage(ctx, templateId, buildId, DefaultPlatform)
}
```

Artifact Registry 实现（`packages/shared/pkg/artifacts-registry/`）：

- **GCP**: tag = `{region}-docker.pkg.dev/{project}/{dockerRegistry}/{templateId}:{buildId}`
- **AWS**: `DescribeRepositories` + ECR auth，tag = `{repositoryUri}:{buildId}`
- **Local**: `daemon.Image(ref)` 从本地 Docker daemon 拉取

---

### 8.5 注入附加 OCI 层

**文件：`packages/orchestrator/pkg/template/build/core/rootfs/rootfs.go:193-253`**

在拉取到的基础镜像之上，追加两个 OCI 层：

#### 8.5.1 Files Layer（`oci.LayerFile`）

**读取宿主机 envd 二进制：**

```go
envdFileData, err := os.ReadFile(buildContext.BuilderConfig.HostEnvdPath)
```

**构建文件映射：**

```go
filesMap := map[string]oci.File{
    "usr/bin/envd":              {Bytes: envdFileData, Mode: 0o777},
    "usr/local/bin/provision.sh": {Bytes: []byte(provisionScript), Mode: 0o777},
    "usr/bin/busybox":           {Bytes: systeminit.BusyboxBinary, Mode: 0o755},  // //go:embed
    "usr/bin/init":              {Bytes: systeminit.BusyboxBinary, Mode: 0o755},
}
```

**渲染 8 个 `.tpl` 模板文件**（共产出 13 个文件路径）：

```go
for _, t := range fileTemplates.Templates() {
    model := newTemplateModel(buildContext, provisionLogPrefix, provisionResultPath)
    data, _ := generateFile(t, model)
    for _, path := range model.paths {
        filesMap[path.path] = oci.File{Bytes: data, Mode: path.mode}
    }
}
```

模板文件与输出路径：

| 模板 | 输出路径 | 内容 |
|------|---------|------|
| `hostname.tpl` | `etc/hostname` | `e2b.local` |
| `hosts.tpl` | `etc/hosts` | 标准 hosts + `127.0.1.1 e2b.local` |
| `resolv.conf.tpl` | `etc/resolv.conf` | `nameserver 8.8.8.8` |
| `envd.service.tpl` | `etc/systemd/system/envd.service` | envd systemd 单元，设置 `GOMEMLIMIT` |
| `inittab.tpl` | `etc/inittab` | BusyBox init 配置：rcS -> provision -> sync -> fsfreeze |
| `rcS.sh.tpl` | `etc/init.d/rcS` | 挂载 proc/sys/dev/tmp/run |
| `disable-watchdog.service.tpl` | `systemd-journald.service.d/override.conf` + `systemd-networkd.service.d/override.conf` | `WatchdogSec=0` |
| `serial-getty-autologin.service.tpl` | `serial-getty@ttyS0.service.d/autologin.conf` | root 自动登录串口 |

**`LayerFile` 实现**（`packages/orchestrator/pkg/template/build/core/oci/layer_file.go:20-51`）：

```go
func LayerFile(filemap map[string]File) (Layer, error) {
    b := &bytes.Buffer{}
    w := tar.NewWriter(b)
    names := sorted(filemap keys)  // 排序保证可重现
    for _, f := range names {
        w.WriteHeader(&tar.Header{Name: f, Size: len(c.Bytes), Mode: c.Mode})
        w.Write(c.Bytes)
    }
    w.Close()
    return tarball.LayerFromOpener(func() (io.ReadCloser, error) {
        return io.NopCloser(bytes.NewBuffer(b.Bytes())), nil
    })
}
```

关键特性：文件名排序确保 tar 档案可重现（相同输入 -> 相同哈希）。

#### 8.5.2 Symlinks Layer（`oci.LayerSymlink`）

```go
symlinkLayer, _ := oci.LayerSymlink(map[string]string{
    "etc/systemd/system/multi-user.target.wants/envd.service":   "etc/systemd/system/envd.service",
    "etc/systemd/system/multi-user.target.wants/chrony.service": "etc/systemd/system/chrony.service",
})
```

使 `envd` 和 `chrony` 在 systemd `multi-user.target` 下自启动。实现与 `LayerFile` 类似，只是 tar header 类型为 `tar.TypeSymlink`。

#### 8.5.3 合并到镜像

```go
img, err = mutate.AppendLayers(img, layers...)  // [filesLayer, symlinkLayer]
```

使用 `go-containerregistry` 的 `mutate.AppendLayers` 将两层追加到基础镜像之上。

---

### 8.6 OCI 转 ext4

**文件：`packages/orchestrator/pkg/template/build/core/oci/oci.go:188-221`**

五步流水线：

#### 8.6.1 创建 ext4 空文件

```go
filesystem.Make(ctx, rootfsPath, units.BytesToMB(maxSize), blockSize)
```

**`packages/orchestrator/pkg/template/build/core/filesystem/ext4.go:33-73`** 执行：

```bash
mkfs.ext4 \
  -O ^64bit,^dir_index,^dir_nlink,ext_attr,extent,extra_isize,filetype,flex_bg,huge_file,large_file,sparse_super2 \
  -b 4096 \       # 块大小
  -m 0 \          # 保留块百分比 = 0
  -i 4096 \       # 每 4096 字节一个 inode
  rootfs.filesystem.build \
  {maxSize}M      # 最大尺寸（由 feature flag BuildBaseRootfsSizeLimitMB 控制）
```

#### 8.6.2 提取镜像到 ext4

```go
ExtractToExt4(ctx, logger, img, rootfsPath, maxSize)
```

**`oci.go:223-258`** 的流程：

```
创建临时目录 -> mount -o loop ext4文件 -> unpackRootfs() -> umount
```

**`unpackRootfs`（`oci.go:280-337`）** 是核心：

**a) 并行提取所有 OCI 层**

```go
layers, _ := srcImage.Layers()
layerPaths := make([]string, len(layers))

for i, l := range layers {
    eg.Go(func() error {
        os.MkdirAll(layerPath, 0o755)
        rc, _ := l.Uncompressed()     // 解压层
        archive.Untar(rc, layerPath, &archive.TarOptions{
            IgnoreChownErrors: true,
            WhiteoutFormat:    archive.OverlayWhiteoutFormat,  // .wh.* -> OverlayFS 字符设备
        })
    })
    layerPaths[len(layers)-i-1] = layerPath  // 注意：倒序！
}
```

关键细节：

- 每层并行解压（`errgroup`）
- `OverlayWhiteoutFormat` 将 OCI 的 `.wh.*` whiteout 文件转换为 OverlayFS 的 character device（`c 0 0`），这样 OverlayFS 能正确处理层间删除
- 路径数组**倒序存储** — OverlayFS 要求最新层在 `lowerdir` 列表最前面

**b) 挂载 OverlayFS**

```go
filesystem.MountOverlayFS(ctx, layers, mountPath)
```

**`ext4.go:281-321`** 使用 Linux 6.8+ 的 `fsconfig` 系统调用接口（而非传统 `mount` 系统调用，后者有 4096 字符的 lowerdirs 限制）：

```go
fsfd, _ := unix.Fsopen("overlay", unix.FSOPEN_CLOEXEC)
for _, layer := range layers {
    unix.FsconfigSetString(fsfd, "lowerdir+", layer)  // 逐个添加层
}
unix.FsconfigCreate(fsfd)               // 完成配置
mfd, _ := unix.Fsmount(fsfd, 0, 0)      // 创建挂载
unix.MoveMount(mfd, "", -1, mountPoint, unix.MOVE_MOUNT_F_EMPTY_PATH)  // 移动到目标
```

**c) rsync 复制到 ext4**

```go
func copyFiles(ctx, src, dest string) error {
    cmd := exec.CommandContext(ctx, "rsync", "-aH", "--whole-file", "--inplace", src+"/", dest)
}
```

- `-a`：归档模式（递归、符号链接、权限、时间、组/所有者、设备文件）
- `-H`：保留硬链接
- `--whole-file`：不使用 delta 算法（本地复制更快）
- `--inplace`：原地更新（不创建临时文件）

如果遇到 "No space left on device"，用 `du -sb` 测量实际镜像大小并返回 `ImageTooLargeError`。

#### 8.6.3 完整性检查 + 收缩 + 再检查

```go
filesystem.CheckIntegrity(ctx, rootfsPath, true)    // e2fsck -pfv
filesystem.Shrink(ctx, rootfsPath)                   // resize2fs -M (收缩到最小)
filesystem.CheckIntegrity(ctx, rootfsPath, true)    // 再次检查
```

`resize2fs -M` 将 ext4 文件系统收缩到实际占用的最小尺寸，减少存储和传输开销。

---

### 8.7 后处理：扩容到目标磁盘大小

**文件：`packages/orchestrator/pkg/template/build/core/rootfs/rootfs.go:147-183`**

回到 `CreateExt4Filesystem` 中：

```go
// 1. 解除只读
filesystem.MakeWritable(ctx, rootfsPath)   // tune2fs -O ^read-only

// 2. 计算当前可用空间
rootfsFreeSpace, _ := filesystem.GetFreeSpace(ctx, rootfsPath, blockSize)
// GetFreeSpace 用 debugfs -R stats 解析 Free blocks 和 Reserved blocks

// 3. 按需扩容
diskAdd := units.MBToBytes(template.DiskSizeMB) - rootfsFreeSpace  // 512MB - 当前空闲
if diskAdd > 0 {
    filesystem.Enlarge(ctx, rootfsPath, diskAdd)  // resize2fs rootfsPath {targetMB}M
}

// 4. 最终完整性检查
filesystem.CheckIntegrity(ctx, rootfsPath, true)

// 5. 提取镜像 OCI config（env vars、cmd 等）
config, _ := img.ConfigFile()
return config.Config, nil
```

---

### 8.8 创建块设备

回到 `constructLayerFilesFromOCI`（`files.go:57-79`）：

**Rootfs 块设备：**

```go
rootfs, _ := block.NewLocal(rootfsPath, buildContext.Config.RootfsBlockSize(), buildIDParsed)
// 以只读方式打开 ext4 文件，创建 header{buildID, blockSize=4096, size}
```

**Memfile（空）：**

```go
memfile, _ := block.NewEmpty(
    units.MBToBytes(buildContext.Config.MemoryMB),  // 512MB
    config.MemfilePageSize(buildContext.Config.HugePages),  // 4KiB 或 2MiB
    buildIDParsed,
)
// 虚拟零填充块设备，ReadAt 返回全零字节，无磁盘文件
```

---

## 第九层：后续构建阶段

| 阶段 | 对于 base 模板的行为 |
|------|-------------------|
| **User** | 创建默认 `user` 账户、home 目录、权限设置 |
| **Steps** | 无步骤，空操作 |
| **Finalize** | 再启动一次 VM，执行配置脚本（swap、用户设置、目录权限），无 start/ready 命令，拍摄最终快照并上传 |
| **Optimize** | 启动 VM **2 次**（`prefetchIterations=2`），等待 envd 就绪，采集每次启动访问的内存/磁盘页，取交集作为**预取映射** — 用于后续沙箱冷启动加速 |

---

## 第十层：完成与回调

1. **Orchestrator**: 所有阶段完成后，等待层上传 (`errgroup.Wait()`)，获取最终 rootfs 大小，返回 `Result{EnvdVersion, RootfsSizeMB}`。构建结果存入 build cache，状态设为 `Completed`。

2. **API**: 后台 goroutine 通过 `BuildStatusSync` gRPC 轮询 Orchestrator 构建状态。当状态变为 `Completed`，更新 DB（`FinishTemplateBuild`），记录 rootfs 大小、envd 版本，刷新模板缓存。

3. **SDK Client**: `Template.build()` 轮询 `GET /templates/{templateID}/builds/{buildID}/status`，通过 `onBuildLogs` 回调输出日志。构建完成后返回。

---

## 附录

### 关键产物

构建产生并上传到存储（本地或 GCS）的文件：

| 文件 | 内容 |
|------|------|
| `{buildID}/rootfs` | ext4 根文件系统差异块 |
| `{buildID}/rootfs.header` | rootfs 元数据（大小、块信息） |
| `{buildID}/memfile` | VM 内存快照差异块 |
| `{buildID}/memfile.header` | memfile 元数据 |
| `{buildID}/snapshot` | Firecracker VM 状态快照 |
| `{buildID}/metadata.json` | 构建元数据 + 预取映射 |

数据库记录（PostgreSQL）：

| 表 | 内容 |
|---|---|
| `templates` | 模板行创建/更新 |
| `template_builds` | 构建记录（状态：Waiting -> InProgress -> Completed/Failed） |
| `template_aliases` | 别名 `"base"` -> templateID 映射 |
| `template_build_assignments` | 构建标签分配 |
| `active_template_builds` | 跟踪运行中的构建（完成后移除） |

---

### Firecracker VM 启动次数

整个 base 模板构建过程中，Firecracker VM 总共启动 **5 次**：

1. **Provisioning 启动**（BusyBox init） — 安装 systemd 和核心包
2. **Base Layer 启动**（systemd init） — 同步磁盘，拍摄 base 快照
3. **Finalize 启动**（systemd init） — 运行配置脚本，拍摄最终快照
4. **Optimize 启动 #1**（systemd init） — 采集预取页映射
5. **Optimize 启动 #2**（systemd init） — 再次采集，取交集

最终快照可用于**毫秒级恢复**新沙箱实例。

---

### 关键 Go 源文件索引

| 文件 | 角色 |
|---|---|
| `packages/api/internal/handlers/template_request_build_v3.go` | API 处理器：POST /v3/templates（注册构建） |
| `packages/api/internal/handlers/template_start_build_v2.go` | API 处理器：POST /v2/templates/{id}/builds/{id}（启动构建） |
| `packages/api/internal/template/register_build.go` | DB 事务：创建模板 + 构建记录 |
| `packages/api/internal/template-manager/create_template.go` | API -> Orchestrator gRPC 桥接 |
| `packages/api/internal/template-manager/template_status.go` | 构建状态轮询循环 |
| `packages/orchestrator/pkg/template/server/create_template.go` | Orchestrator gRPC 处理器 |
| `packages/orchestrator/pkg/template/build/builder.go` | 核心构建编排（组装阶段） |
| `packages/orchestrator/pkg/template/build/phases/phase.go` | 阶段运行器（Hash -> Layer -> Build 循环） |
| `packages/orchestrator/pkg/template/build/phases/base/builder.go` | Base 阶段：OCI 拉取、rootfs 创建、provisioning |
| `packages/orchestrator/pkg/template/build/phases/base/files.go` | 入口：构造 rootfs + memfile |
| `packages/orchestrator/pkg/template/build/phases/base/provision.go` | Firecracker VM provisioning（BusyBox init） |
| `packages/orchestrator/pkg/template/build/phases/base/provision.sh` | Shell 脚本：安装 systemd，配置 VM |
| `packages/orchestrator/pkg/template/build/core/rootfs/rootfs.go` | OCI 镜像 -> ext4 转换，注入 envd/busybox/配置 |
| `packages/orchestrator/pkg/template/build/core/oci/oci.go` | OCI 镜像拉取、层提取、ext4 转换 |
| `packages/orchestrator/pkg/template/build/core/oci/layer_file.go` | OCI 层创建（文件层 + 符号链接层） |
| `packages/orchestrator/pkg/template/build/core/oci/auth/auth.go` | 注册表认证工厂 |
| `packages/orchestrator/pkg/template/build/core/filesystem/ext4.go` | ext4 文件系统操作（mkfs、mount、resize、e2fsck） |
| `packages/orchestrator/pkg/template/build/phases/user/builder.go` | User 阶段：创建默认用户 |
| `packages/orchestrator/pkg/template/build/phases/finalize/builder.go` | Finalize 阶段：start/ready 命令，最终快照 |
| `packages/orchestrator/pkg/template/build/phases/optimize/builder.go` | Optimize 阶段：预取页采集 |
| `packages/shared/pkg/dockerhub/repository.go` | Docker Hub 代理仓库接口与路由 |
| `packages/shared/pkg/artifacts-registry/registry.go` | Artifact Registry 接口（GCP/AWS/Local） |

---

### 镜像拉取完整流程图

```
GetPublicImage("e2bdev/base:latest", authProvider=nil)
|
+-- name.ParseReference("e2bdev/base:latest")
|     -> ref = index.docker.io/e2bdev/base:latest
|
+-- authProvider == nil && registry == "index.docker.io"? -> YES
|     |
|     +-- dockerhubRepository.GetImage(tag, linux/amd64)
|           |
|           +-- DOCKERHUB_REMOTE_REPOSITORY_URL 为空？
|           |     -> NoopRepository: remote.Image(ref, WithPlatform) 直接拉
|           |
|           +-- GCP Provider:
|           |     tag -> "{GCP_PROXY_URL}/e2bdev/base:latest"
|           |     auth -> _json_key_base64 / DOCKER_AUTH_CONFIG
|           |     remote.Image(proxyRef, WithAuth, WithPlatform)
|           |
|           +-- AWS Provider:
|                 tag -> "{ECR_URL}/e2bdev/base:latest"
|                 auth -> ECR.GetAuthorizationToken
|                 remote.Image(proxyRef, WithAuth, WithPlatform)
|
+-- verifyImagePlatform(img, amd64)  <- 确认架构
|
+-- GetImageSize(img) -> log "Base Docker image size: XXX"
|
+-- additionalOCILayers()
|     +-- LayerFile: 13 个文件 -> tar -> OCI Layer
|     +-- LayerSymlink: 2 个符号链接 -> tar -> OCI Layer
|
+-- mutate.AppendLayers(img, [filesLayer, symlinkLayer])
|
+-- ToExt4(img, rootfsPath, maxSize, blockSize=4096)
      +-- mkfs.ext4 -b 4096 -m 0 -i 4096 rootfs {maxSize}M
      +-- mount -o loop rootfs tmpMount
      +-- 并行解压所有 OCI 层 (Uncompressed -> Untar)
      +-- MountOverlayFS (fsconfig/lowerdir+)
      +-- rsync -aH --whole-file --inplace overlay/ -> ext4/
      +-- umount (overlay + ext4)
      +-- e2fsck -pfv
      +-- resize2fs -M (收缩)
      +-- e2fsck -pfv
```
