# 自建托管 E2B

## 前置条件

**工具**

- [Packer](https://developer.hashicorp.com/packer/tutorials/docker-get-started/get-started-install-cli#installing-packer)
  - 用于构建 orchestrator 客户端与服务器的磁盘镜像

- [Terraform](https://developer.hashicorp.com/terraform/tutorials/aws-get-started/install-cli)（v1.5.x）
  - 要求 v1.5.x，因为从 v1.6 起 Terraform 将许可证从 Mozilla Public License 改为了 Business Source License（[变更说明](https://github.com/hashicorp/terraform/commit/b145fbcaadf0fa7d0e7040eac641d9aef2a26433)）。
  - 最后一个仍采用 Mozilla Public License 的 Terraform 版本是 **v1.5.7**
    - 二进制下载见[此处](https://developer.hashicorp.com/terraform/install/versions#binary-downloads)
    - 也可通过 [tfenv](https://github.com/tfutils/tfenv) 安装：
      ```sh
      brew install tfenv
      tfenv install 1.5.7
      tfenv use 1.5.7
      ```

- [Golang](https://go.dev/doc/install)

- [Docker](https://docs.docker.com/engine/install/)

- [NPM](https://docs.npmjs.com/downloading-and-installing-node-js-and-npm)

**账号**

- Cloudflare 账号
- 托管在 Cloudflare 上的域名
- PostgreSQL 数据库（目前仅支持 Supabase 的数据库）

**可选**

建议用于监控与日志：

- Grafana 账号与 Stack
- Posthog 账号

---

## Google Cloud

### 额外前置条件

- [Google Cloud CLI](https://cloud.google.com/sdk/docs/install)
  - 用于在 Google Cloud 上管理基础设施
  - 请务必完成登录：
    ```sh
    gcloud auth login
    gcloud auth application-default login
    ```
- GCP 账号与项目

### 步骤

确认你可以使用 Terraform 状态管理所需的配置。

1. 打开 `console.cloud.google.com` 并新建 GCP 项目  
   > 请确认配额至少允许：`Persistent Disk SSD (GB)` 不少于 2500G，`CPUs` 不少于 24  
2. 根据 [`.env.gcp.template`](.env.gcp.template) 创建 `.env.prod`、`.env.staging` 或 `.env.dev`，任选其一即可。请填写所有值；除非另有说明，否则均为必填。  
   > 从数据库获取 Postgres 连接串，例如[从 Supabase](https://supabase.com/docs/guides/database/connecting-to-postgres#direct-connection)：在 Supabase 新建项目后，进入 Project -> Settings -> Database -> Connection Strings -> Postgres -> Direct 或 Shared  
   > 须兼容 IPv4。可使用 Shared，或在 Connect 界面使用 IPv4 附加组件  
3. 运行 `make set-env ENV={prod,staging,dev}` 以启用对应环境  
4. 运行 `make provider-login` 登录 `gcloud`  
5. 运行 `make init`。若报错，可再执行一次——这是由于 Terraform 为各 GCP 服务启用 API 时存在竞态，可能需要数秒。将为以下服务启用 API（完整列表）：  
   - [Secret Manager API](https://console.cloud.google.com/apis/library/secretmanager.googleapis.com)  
   - [Certificate Manager API](https://console.cloud.google.com/apis/library/certificatemanager.googleapis.com)  
   - [Compute Engine API](https://console.cloud.google.com/apis/library/compute.googleapis.com)  
   - [Artifact Registry API](https://console.cloud.google.com/apis/library/artifactregistry.googleapis.com)  
   - [OS Config API](https://console.cloud.google.com/apis/library/osconfig.googleapis.com)  
   - [Stackdriver Monitoring API](https://console.cloud.google.com/apis/library/monitoring.googleapis.com)  
   - [Stackdriver Logging API](https://console.cloud.google.com/apis/library/logging.googleapis.com)  
   - [Filestore API](https://console.cloud.google.com/apis/library/file.googleapis.com)  
6. 运行 `make build-and-upload`  
7. 运行 `make copy-public-builds`。会将 Firecracker 的内核与 rootfs 构建复制到你的存储桶。你也可以[自行构建](#从源码构建-firecracker-与-uffd)内核与 Firecracker root。  
8. 以下密钥 Terraform 仅在 GCP Secrets Manager 中创建**空的密钥容器**。你需要为每个密钥添加**密钥版本**（实际值）。打开 [GCP Secrets Manager](https://console.cloud.google.com/security/secret-manager)，点开对应密钥，点击「New Version」填入下列密钥的值：  
   - e2b-cloudflare-api-token  
     > 获取 Cloudflare API Token：[Cloudflare 控制台](https://dash.cloudflare.com/) -> Manage Account -> Account API Tokens -> Create Token -> Edit Zone DNS -> 在「Zone Resources」中选择你的域名并生成 token  
   - e2b-postgres-connection-string（**必填**）  
   - e2b-supabase-jwt-secrets（可选；若[自建 E2B 控制台](https://github.com/e2b-dev/dashboard)则必填）  
     > 获取 Supabase JWT Secret：[Supabase 控制台](https://supabase.com/dashboard) -> 选择项目 -> Project Settings -> Data API -> JWT Settings  
   - e2b-posthog-api-key（可选，用于监控）  
9. 先运行 `make plan-without-jobs`，再运行 `make apply`  
10. 再运行 `make plan`，然后 `make apply`。注意：须在 TLS 证书签发完成后才能成功；可能需要一些时间，可在 Google Cloud 控制台查看状态。数据库迁移会通过 API 的 db-migrator 任务自动执行。  
11. 在集群中准备数据：在 `packages/shared` 运行 `make prep-cluster`，创建初始用户、团队并构建基础模板。  
   - 也可在 `packages/db` 运行 `make seed-db` 以创建更多用户与团队。

### GCP 故障排查

**配额不可用**

若在 GCP 控制台的「All Quotas」中找不到某项配额，请先创建并删除一台临时虚拟机，再继续自建流程的步骤 2。这会在 GCP 中生成额外配额与策略：

```
gcloud compute instances create dummy-init   --project=YOUR-PROJECT-ID   --zone=YOUR-ZONE   --machine-type=e2-medium   --boot-disk-type=pd-ssd   --no-address
```

等待约一分钟后销毁该虚拟机：

```
gcloud compute instances delete dummy-init --zone=YOUR-ZONE --quiet
```

之后应在「All Quotas」中看到正确的配额选项，并能申请到所需大小。

---

## AWS

### 额外前置条件

- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)  
  - 用于在 AWS 上管理基础设施  
  - 请务必配置 profile：  
    ```sh
    aws configure --profile <your-profile>  
    ```  
- [gsutil](https://cloud.google.com/storage/docs/gsutil_install)（用于复制公开的 Firecracker 构建）  
- AWS 账号  

### 步骤

1. 根据 [`.env.template`](.env.template) 创建 `.env.prod`、`.env.staging` 或 `.env.dev`，填写 AWS 相关变量：  
   - `PROVIDER=aws`  
   - `AWS_PROFILE`：AWS CLI profile 名称  
   - `AWS_ACCOUNT_ID`：AWS 账号 ID  
   - `AWS_REGION`：部署区域（须支持用于 Firecracker 的裸金属实例）  
   - `PREFIX`：所有资源名称前缀（例如 `e2b-`）  
   - `DOMAIN_NAME`：由 Cloudflare 管理的域名  
   - `TERRAFORM_ENVIRONMENT`：`prod`、`staging` 或 `dev` 之一  
2. 运行 `make set-env ENV={prod,staging,dev}`  
3. 运行 `make provider-login` 登录 AWS ECR  
4. 运行 `make init`。将创建：  
   - 用于 Terraform 状态的 S3 存储桶  
   - VPC、子网与网络  
   - 容器镜像的 ECR 仓库  
   - 模板、内核、构建与备份的 S3 存储桶  
   - AWS Secrets Manager 中的密钥（占位值）  
   - Cloudflare DNS 记录与 TLS 证书  
5. 在 [AWS Secrets Manager](https://console.aws.amazon.com/secretsmanager) 中更新以下密钥为实际值：  
   - `{prefix}cloudflare`：含 `TOKEN` 键的 JSON  
     > 获取 Cloudflare API Token：[Cloudflare 控制台](https://dash.cloudflare.com/) -> Manage Account -> Account API Tokens -> Create Token -> Edit Zone DNS -> 在「Zone Resources」中选择你的域名并生成 token  
   - `{prefix}postgres-connection-string`：PostgreSQL 连接串（**必填**）  
   - `{prefix}supabase-jwt-secrets`：Supabase JWT 密钥（可选；[E2B 控制台](https://github.com/e2b-dev/dashboard)需要时则必填）  
   - `{prefix}grafana`：含 `API_KEY`、`OTLP_URL`、`OTEL_COLLECTOR_TOKEN`、`USERNAME` 键的 JSON（可选，用于监控）  
   - `{prefix}launch-darkly-api-key`：LaunchDarkly SDK 密钥（可选，用于功能开关）  
6. 使用 Packer 构建集群节点 AMI（所有节点类型共用一个 AMI）：  
   ```sh  
   cd iac/provider-aws/nomad-cluster-disk-image  
   make init   # 安装 Packer 插件  
   make build  # 构建 AMI（约 5 分钟，会启动一台 t3.large）  
   ```  
7. 运行 `make build-and-upload` 构建并推送容器镜像与二进制  
8. 运行 `make copy-public-builds`，将 Firecracker 内核与 rootfs 复制到你的 S3 存储桶  
9. 运行 `make plan-without-jobs`，再 `make apply`，以创建集群基础设施  
10. 运行 `make plan`，再 `make apply`，部署全部 Nomad 任务（数据库迁移同样通过 API 的 db-migrator 任务自动执行）  
11. 在 `packages/shared` 运行 `make prep-cluster`，创建初始用户、团队并构建基础模板  

### AWS 架构

AWS 部署会创建如下资源：

**节点池（EC2 Auto Scaling Groups）：**

- **Control Server**：Nomad/Consul 服务器（默认：3 台 `t3.medium`）  
- **API**：API 服务、ingress、client proxy、otel、loki、日志采集等（默认：`t3.xlarge`）  
- **Client**：带嵌套虚拟化的 Firecracker orchestrator 节点（默认：`m8i.4xlarge`）  
- **Build**：用于构建沙箱模板的 template manager（默认：`m8i.2xlarge`）  
- **ClickHouse**：分析数据库（默认：`t3.xlarge`）  

**托管服务（可选）：**

- ElastiCache Redis（设置 `REDIS_MANAGED=true`）

### AWS 故障排查

**裸金属实例不可用**

Firecracker 需要裸金属或嵌套虚拟化支持。请确认所选区域支持你配置的实例类型（例如带嵌套虚拟化的 `m8i.4xlarge`）。可能需要为该实例类型申请服务配额提升。

**ECR 认证错误**

运行 `make provider-login` 刷新 ECR 认证 token。Token 约 12 小时过期。

---

## 通用说明

### 与集群交互

#### SDK

使用 JS/TS SDK 创建 `Sandbox` 时传入域名：

```js
import { Sandbox } from "e2b";

const sandbox = await Sandbox.create({
  domain: "<your-domain>",
});
```

Python SDK：

```python
from e2b import Sandbox

sandbox = Sandbox.create(domain="<your-domain>")
```

#### CLI

使用 CLI 时也可传入域名：

```sh
E2B_DOMAIN=<your-domain> e2b <command>
```

#### 监控与日志相关任务

访问 Nomad Web UI：`https://nomad.<your-domain.com>`。登录时若需要 API token，可在云厂商的 Secrets Manager（GCP 或 AWS）中查找。由此可查看 client 与 server 上的 Nomad 任务与日志等。

### 故障排查

若遇到问题，请在[本仓库提交 Github Issue](https://github.com/e2b-dev/infra/issues)，我们会跟进处理。

---

### 从源码构建 Firecracker 与 UFFD

E2B 使用 [Firecracker](https://github.com/firecracker-microvm/firecracker) 作为沙箱运行时。  
可在 Linux 上执行 `make build-and-upload-fc-components` 自行从源码构建内核与 Firecracker 版本。

- 注意：须在 Linux 上执行，因文件系统大小写敏感——在自动化 git 步骤中否则会报错提示有未保存更改。内核与版本也可从其他来源获取。

### Make 命令速查

- `make init`：初始化 Terraform 环境  
- `make plan`：生成 Terraform 变更计划  
- `make apply`：应用 Terraform 变更；须先执行 `make plan`  
- `make plan-without-jobs`：计划变更但不包含 Nomad 任务  
- `make plan-only-jobs`：仅计划 Nomad 相关变更  
- `make destroy`：销毁集群  
- `make version`：递增仓库版本号  
- `make build-and-upload`：构建并上传 Docker 镜像、二进制与集群磁盘镜像  
- `make copy-public-builds`：从公开存储桶复制旧版 envd 二进制、内核与 Firecracker 版本到你的存储桶  
- `make migrate`：对数据库执行迁移  
- `make provider-login`：登录云厂商  
- `make switch-env ENV={prod,staging,dev}`：切换环境  
- `make import TARGET={resource} ID={resource_id}`：将已创建资源导入 Terraform state  
- `make setup-ssh`：为当前环境配置 SSH（便于远程调试）  
- `make connect-orchestrator`：建立到远程 orchestrator 的 SSH 连接（便于在本地测试 API）
