# Terraform 与 Nomad 的关系

本文档解释在 E2B 项目中 Terraform 和 Nomad 如何协同工作。

## 核心结论

**Terraform 是声明式配置管理工具，Nomad 是运行时调度器** —— Terraform 负责「定义」和「部署」，Nomad 负责「运行」和「调度」。

在本项目中，Terraform 同时管理：
1. **基础设施**（GCP 资源：VM、网络、存储等）
2. **Nomad Jobs**（通过 `nomad_job` 资源）

---

## 架构图

```
┌─────────────────────────────────────────────────────────────────────┐
│                         TERRAFORM                                   │
│                                                                     │
│   ┌─────────────────────────────────────────────────────────────┐   │
│   │                    provider-gcp/main.tf                     │   │
│   │                                                             │   │
│   │  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐    │   │
│   │  │ module "init" │  │module "cluster"│  │ module "redis"│    │   │
│   │  │  (GCS/Secrets)│  │ (GCE 实例)     │  │ (Memorystore) │    │   │
│   │  └───────────────┘  └───────────────┘  └───────────────┘    │   │
│   │                                                             │   │
│   │  ┌─────────────────────────────────────────────────────┐    │   │
│   │  │              module "nomad" (所有 Jobs)              │    │   │
│   │  │                                                     │    │   │
│   │  │  ┌──────────┐ ┌──────────┐ ┌──────────┐            │    │   │
│   │  │  │ job-api  │ │job-orch  │ │job-loki  │  ...       │    │   │
│   │  │  └────┬─────┘ └────┬─────┘ └────┬─────┘            │    │   │
│   │  │       │            │            │                   │    │   │
│   │  └───────┼────────────┼────────────┼───────────────────┘    │   │
│   └──────────┼────────────┼────────────┼────────────────────────┘   │
│              │            │            │                            │
│              │ nomad_job  │ nomad_job  │ nomad_job                  │
│              ▼            ▼            ▼                            │
└──────────────┬────────────┬────────────┬────────────────────────────┘
               │            │            │
               │   Nomad API (HTTPS)     │
               ▼            ▼            ▼
┌─────────────────────────────────────────────────────────────────────┐
│                         NOMAD CLUSTER                               │
│                                                                     │
│   ┌────────────────┐                                                │
│   │  Nomad Server  │  ← 接收 Terraform 提交的 Job 定义              │
│   └───────┬────────┘                                                │
│           │                                                         │
│           │ 调度                                                     │
│           ▼                                                         │
│   ┌────────────────┐  ┌────────────────┐  ┌────────────────┐        │
│   │  Nomad Client  │  │  Nomad Client  │  │  Nomad Client  │        │
│   │    (节点 1)     │  │    (节点 2)     │  │    (节点 3)     │        │
│   │                │  │                │  │                │        │
│   │ ┌────────────┐ │  │ ┌────────────┐ │  │ ┌────────────┐ │        │
│   │ │ API 容器   │ │  │ │Orchestrator│ │  │ │   Loki     │ │        │
│   │ └────────────┘ │  │ └────────────┘ │  │ └────────────┘ │        │
│   └────────────────┘  └────────────────┘  └────────────────┘        │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 职责分工

| 方面 | Terraform | Nomad |
|---|---|---|
| **定位** | 声明式配置管理 | 运行时调度器 |
| **作用时机** | 部署时（`terraform apply`） | 运行时（持续） |
| **管理对象** | 基础设施 + Job 定义 | 运行中的任务和分配 |
| **状态存储** | terraform.tfstate (GCS/S3) | Nomad Server (Raft) |
| **变更检测** | 比较期望状态与实际状态 | 监控任务健康和资源 |
| **故障恢复** | 不负责（一次性操作） | 自动重启、重调度 |

---

## Terraform 如何管理 Nomad Jobs

### 1. Nomad Provider 配置

Terraform 通过 Nomad Provider 连接到 Nomad 集群（`iac/provider-gcp/nomad/main.tf`）：

```hcl
provider "nomad" {
  address      = "https://nomad.${var.domain_name}"
  secret_id    = var.nomad_acl_token_secret
  consul_token = var.consul_acl_token_secret
}
```

### 2. nomad_job 资源

每个服务使用 `nomad_job` 资源，通过 `templatefile()` 渲染 HCL 模板：

```hcl
# iac/modules/job-api/main.tf
resource "nomad_job" "api" {
  jobspec = templatefile("${path.module}/jobs/api.hcl", {
    node_pool                  = var.node_pool
    port_number                = var.port_number
    postgres_connection_string = var.postgres_connection_string
    environment                = var.environment
    # ... 40+ 变量
  })
}
```

### 3. Job 模板（HCL）

Nomad Job 使用 HCL 格式定义，通过 `${}` 插入 Terraform 变量：

```hcl
# iac/modules/job-api/jobs/api.hcl
job "api" {
  type      = "service"
  node_pool = "${node_pool}"

  group "api" {
    count = 2

    task "start" {
      driver = "docker"

      config {
        image = "${api_image}"
      }

      env {
        POSTGRES_CONNECTION_STRING = "${postgres_connection_string}"
        ENVIRONMENT                = "${environment}"
        PORT                       = "${port_number}"
      }
    }
  }
}
```

---

## 变量传递流程

```
┌─────────────────┐
│  .env.{ENV}     │  环境配置文件
│  (DOMAIN=...)   │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   Makefile      │  tf_vars 提取环境变量
│  $(tf_vars)     │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Terraform      │
│  variables.tf   │  variable "domain_name" {}
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  module "api"   │  postgres_connection_string = var.pg_conn
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  templatefile() │  渲染 HCL 模板
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Nomad Job      │  实际运行的 Job 配置
└─────────────────┘
```

---

## 模块结构

```
iac/provider-gcp/
├── main.tf                    # 顶层模块编排
│   ├── module "init"          # GCP 基础设施（桶、密钥）
│   ├── module "cluster"       # Nomad 集群（GCE 实例）
│   ├── module "redis"         # 托管 Redis
│   └── module "nomad"         # 所有 Nomad Jobs
│
└── nomad/main.tf              # Nomad Jobs 模块
    ├── module "api"           → nomad_job.api
    ├── module "orchestrator"  → nomad_job.orchestrator
    ├── module "clickhouse"    → nomad_job.clickhouse
    ├── module "ingress"       → nomad_job.ingress
    ├── module "loki"          → nomad_job.loki
    ├── module "logs_collector"→ nomad_job.logs_collector
    ├── module "otel_collector"→ nomad_job.otel_collector
    ├── module "template_manager" → nomad_job.template_manager
    ├── module "client_proxy"  → nomad_job.client_proxy
    └── module "redis"         → nomad_job.redis (自建 Redis)
```

每个 Job 模块遵循统一结构：

```
iac/modules/job-api/
├── main.tf         # nomad_job 资源定义
├── variables.tf    # 输入变量
└── jobs/
    └── api.hcl     # Nomad Job 模板
```

---

## 部署命令

### Makefile 目标分离

| 命令 | 作用 | 使用场景 |
|---|---|---|
| `make plan` | 计划所有变更（基础设施 + Jobs） | 完整部署 |
| `make plan-without-jobs` | 只计划基础设施，排除 Jobs | 初始化集群 |
| `make plan-only-jobs` | 只计划 Nomad Jobs | 更新服务 |
| `make plan-only-jobs/api` | 只计划单个 Job | 定向更新 |
| `make apply` | 应用变更 | 执行部署 |

### 实现原理

```makefile
# iac/provider-gcp/Makefile

# 计划所有 Jobs
plan-only-jobs:
    $(tf_vars) $(TF) plan -target=module.nomad

# 计划单个 Job
plan-only-jobs/%:
    $(tf_vars) $(TF) plan -target=module.nomad.module.$(notdir $@)

# 计划基础设施（排除 nomad 模块）
plan-without-jobs:
    $(eval TARGET := $(shell cat main.tf | grep "^module" | grep -v "nomad" ...))
    $(tf_vars) $(TF) plan $(TARGET)
```

### 典型部署流程

```bash
# 首次部署（两阶段）
# 阶段 1：部署基础设施（Nomad 集群还不存在，无法提交 Jobs）
make plan-without-jobs
make apply

# 阶段 2：部署 Nomad Jobs（集群就绪后）
make plan-only-jobs
make apply

# 日常更新（单个服务）
make plan-only-jobs/orchestrator
make apply

# 完整更新
make plan
make apply
```

---

## 高级特性

### 蓝绿部署（Orchestrator）

Orchestrator 使用版本化 Job 名称实现蓝绿部署：

```hcl
# iac/modules/job-orchestrator/main.tf

# 基于内容哈希生成唯一 ID
resource "random_id" "orchestrator_job" {
  keepers = {
    orchestrator_job = sha256("${local.orchestrator_job_check}-${var.orchestrator_checksum}")
  }
}

# 存储最新 Job ID 到 Nomad Variables
resource "nomad_variable" "orchestrator_hash" {
  path = "nomad/jobs"
  items = {
    latest_orchestrator_job_id = local.latest_orchestrator_job_id
  }
}
```

Job 名称变为 `orchestrator-{hash}`，新版本部署时：
1. 创建新 Job（`orchestrator-abc123`）
2. 旧 Job 继续运行（`orchestrator-xyz789`）
3. 健康检查通过后，旧 Job 自动清理

### 镜像版本管理

Terraform 从 Artifact Registry 获取最新镜像版本：

```hcl
# iac/provider-gcp/nomad/images.tf
data "google_artifact_registry_docker_image" "api" {
  location      = var.gcp_region
  repository_id = var.core_repository_name
  image_name    = "api:latest"
}

# 传递完整镜像 URI 给 Job 模块
module "api" {
  source    = "../../modules/job-api"
  api_image = data.google_artifact_registry_docker_image.api.self_link
}
```

---

## Terraform vs Nomad 的职责边界

```
                    部署时                          运行时
                      │                               │
    ┌─────────────────┼───────────────────────────────┼─────────────────┐
    │                 │                               │                 │
    │   TERRAFORM     │         NOMAD                 │                 │
    │                 │                               │                 │
    │  ┌───────────┐  │  ┌───────────────────────────────────────────┐  │
    │  │ 定义 Job  │──┼─►│ 接收 Job 定义                             │  │
    │  │ 规格      │  │  │                                           │  │
    │  └───────────┘  │  │ ┌─────────────────────────────────────┐   │  │
    │                 │  │ │ 调度：选择节点                       │   │  │
    │  ┌───────────┐  │  │ ├─────────────────────────────────────┤   │  │
    │  │ 管理状态  │  │  │ │ 启动：拉取镜像、启动容器             │   │  │
    │  │ (tfstate) │  │  │ ├─────────────────────────────────────┤   │  │
    │  └───────────┘  │  │ │ 监控：健康检查、资源使用             │   │  │
    │                 │  │ ├─────────────────────────────────────┤   │  │
    │  ┌───────────┐  │  │ │ 自愈：重启失败任务                   │   │  │
    │  │ 计划变更  │  │  │ ├─────────────────────────────────────┤   │  │
    │  │ (diff)    │  │  │ │ 扩缩：调整实例数量                   │   │  │
    │  └───────────┘  │  │ └─────────────────────────────────────┘   │  │
    │                 │  └───────────────────────────────────────────┘  │
    └─────────────────┼───────────────────────────────┼─────────────────┘
                      │                               │
```

---

## 常见问题

### Q: 为什么用 Terraform 管理 Nomad Jobs，而不是直接用 `nomad job run`？

**A:** 使用 Terraform 的好处：
1. **统一工具链**：基础设施和应用用同一工具
2. **变量管理**：复杂的变量依赖关系（如从 GCP 密钥读取数据库密码）
3. **状态追踪**：知道当前部署了什么版本
4. **协作**：状态存储在远端，团队可协作
5. **回滚**：通过 `terraform apply -target` 精确控制

### Q: 如果 Nomad 挂了，Terraform apply 会失败吗？

**A:** 是的。`nomad_job` 资源需要连接到 Nomad Server。这就是为什么有 `plan-without-jobs` —— 先部署基础设施（包括 Nomad 集群），再部署 Jobs。

### Q: 运行时的故障恢复是谁负责？

**A:** Nomad。Terraform 只在 `apply` 时生效，之后 Nomad 独立运行，处理：
- 容器崩溃重启
- 节点故障重调度
- 健康检查失败重启
- 滚动更新

---

## 相关文档

- [Nomad 与 Orchestrator 的关系](./nomad-orchestrator-relationship.md)
- [自建机房部署指南](./self-host-baremetal.md)
- [Terraform Nomad Provider 文档](https://registry.terraform.io/providers/hashicorp/nomad/latest/docs)
- [Nomad Job 规格](https://developer.hashicorp.com/nomad/docs/job-specification)
