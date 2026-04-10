# 构建与部署流程

## Orchestrator 构建上传流程

执行命令：`make build-and-upload/orchestrator`

### 整体流程

```
make build-and-upload/orchestrator (根 Makefile)
  │
  ├─ 1. confirm.sh              # 环境安全检查
  ├─ 2. build                   # Docker 多阶段构建 → 输出二进制到 bin/
  └─ 3. upload/orchestrator     # gsutil/aws s3 上传到云存储桶
```

### 阶段一：环境确认

入口：根 `Makefile:96-98` → `scripts/confirm.sh`

根 Makefile 先调用 `confirm.sh` 做部署安全检查：

- 如果环境变量 `AUTO_CONFIRM_DEPLOY=true`，直接跳过确认
- 如果目标环境不是 `dev`（如 staging/prod），要求：
  - 当前 Git 分支必须是 `main`
  - 手动输入 "production" 进行二次确认
- `dev` 环境直接放行，无需确认

### 阶段二：Docker 多阶段构建

入口：`packages/orchestrator/Makefile:26-28` → `packages/orchestrator/Dockerfile`

执行命令：

```bash
docker build --platform linux/$(BUILD_ARCH) --output=bin \
  --build-arg COMMIT_SHA="$(COMMIT_SHA)" -f ./Dockerfile ..
```

Dockerfile 使用两阶段构建：

**Builder 阶段** — 基于 `golang:1.25.4-bookworm`：

1. 分别下载 `shared`、`clickhouse`、`orchestrator` 三个 Go 模块的依赖（利用 Docker 层缓存加速）
2. 拷贝源码：
   - `shared/pkg` — 公共库
   - `clickhouse/pkg` — ClickHouse 相关
   - `orchestrator/pkg`、`cmd`、`main.go` — orchestrator 本体
3. 执行 `make build-local`，编译出两个二进制文件：
   - `bin/orchestrator` — 主服务
   - `bin/clean-nfs-cache` — NFS 缓存清理工具
4. 通过 `-ldflags "-X=main.commitSHA=$(COMMIT_SHA)"` 注入 Git commit SHA

**Scratch 阶段** — 仅提取编译产物。配合 `--output=bin`，将二进制文件直接输出到宿主机的 `packages/orchestrator/bin/` 目录，不生成 Docker 镜像。

### 阶段三：上传到云存储

入口：`packages/orchestrator/Makefile:76-83`

根据 `PROVIDER` 变量选择上传目标：

| Provider | 命令 | 目标路径 |
|----------|------|----------|
| GCP（默认） | `gsutil cp` | `gs://{GCP_PROJECT_ID}-fc-env-pipeline/orchestrator` |
| AWS | `aws s3 cp` | `s3://{PREFIX}{AWS_ACCOUNT_ID}-fc-env-pipeline/orchestrator` |

上传时设置 `Cache-Control: no-cache, max-age=0`，确保每次拉取都获取最新版本。

## Nomad 部署阶段

上传完成后，通过 Terraform + Nomad 部署。Nomad job 定义在 `iac/modules/job-orchestrator/jobs/orchestrator.hcl`。

关键配置：

- **Job 类型**：`system`（在每个匹配节点上运行一个实例）
- **执行方式**：`raw_exec` 驱动，直接运行二进制
- **二进制获取**：通过 `artifact` stanza 从云存储桶下载 orchestrator 二进制
- **启动命令**：`chmod +x local/orchestrator && local/orchestrator`
- **健康检查**：HTTP `/health` 端点，每 20s 检查一次
- **服务注册**：通过 Nomad 服务发现注册 `orchestrator` 和 `orchestrator-proxy` 两个服务
- **节点约束**：非 dev 环境通过 `meta.orchestrator_job_version` 约束部署到指定版本的节点

### 关键环境变量

| 变量 | 用途 |
|------|------|
| `NODE_ID` | 节点唯一标识 |
| `TEMPLATE_BUCKET_NAME` | 模板存储桶 |
| `REDIS_CLUSTER_URL` / `REDIS_URL` | Redis 连接 |
| `CLICKHOUSE_CONNECTION_STRING` | ClickHouse 连接 |
| `OTEL_COLLECTOR_GRPC_ENDPOINT` | OpenTelemetry 采集器 |
| `ORCHESTRATOR_SERVICES` | 启用的服务列表 |
| `STORAGE_PROVIDER` | 存储后端（GCPBucket / AWSBucket） |
