# 自建机房部署 E2B 指南

本文档描述在自建机房（bare metal / on-premises）环境下部署 E2B 平台所需的变更，涵盖基础设施层和应用层的改造方案。

## 概述

自建机房意味着没有 GCP/AWS 的托管服务，需要自行替换所有云厂商依赖。当前 `iac/` 目录包含约 **140+ GCP 资源定义**，主要分布在：

- 计算（GCE 实例模板、托管实例组、自动扩缩）
- 网络（负载均衡、Cloud Armor、防火墙、NAT）
- 存储（GCS 存储桶、Filestore NFS）
- 数据库（Memorystore Redis/Valkey）
- 密钥管理（Secret Manager）
- 容器镜像（Artifact Registry）

---

## 一、基础设施层变更（`iac/`）

### 1. 计算资源

| GCP 资源 | 自建替代方案 |
|---|---|
| `google_compute_instance_template` | 裸金属服务器 + PXE/cloud-init 装机 |
| `google_compute_region_instance_group_manager` | 静态服务器池或自定义编排 |
| `google_compute_region_autoscaler` | 基于 Nomad metrics 的自定义 autoscaler |
| Packer GCE Image Builder | Packer QEMU/VMware/ISO Builder |

> **关键要求**：Firecracker 需要 **裸金属或支持嵌套虚拟化** 的服务器，必须有 `/dev/kvm` 访问权限。

### 2. 网络与负载均衡

| GCP 资源 | 自建替代方案 |
|---|---|
| `google_compute_global_forwarding_rule` | HAProxy / Nginx / Traefik |
| `google_compute_url_map` | HAProxy ACL / Nginx location |
| `google_compute_backend_service` | HAProxy backend / Nginx upstream |
| `google_compute_security_policy` (Cloud Armor) | ModSecurity / Fail2Ban / 硬件防火墙 |
| `google_certificate_manager_*` | Let's Encrypt + cert-manager / acme.sh |
| `google_compute_firewall` | iptables / nftables / 物理防火墙 |
| `google_compute_router_nat` | 自建 NAT 网关或直接公网出口 |
| `google_compute_ssl_policy` | HAProxy/Nginx TLS 配置 |

#### 推荐网络架构

```
                    ┌─────────────────┐
                    │   HAProxy/LB    │ ← TLS 终止 + 路由
                    │  (高可用部署)    │
                    └────────┬────────┘
                             │
        ┌────────────────────┼────────────────────┐
        │                    │                    │
   ┌────▼────┐         ┌─────▼─────┐        ┌─────▼─────┐
   │ API Pool │         │ Worker Pool│        │ Infra Pool │
   │ (Nomad)  │         │ (Nomad)    │        │ (Nomad)    │
   └──────────┘         └───────────┘        └───────────┘
```

### 3. 对象存储

| GCP 资源 | 用途 | 自建替代方案 |
|---|---|---|
| `loki_storage_bucket` | Loki 日志存储 | MinIO |
| `fc_template_bucket` | Firecracker 模板 | MinIO |
| `fc_kernels_bucket` | Firecracker 内核 | MinIO |
| `fc_versions_bucket` | Firecracker 版本 | MinIO |
| `fc_build_cache_bucket` | 构建缓存 | MinIO |
| `clickhouse_backups_bucket` | ClickHouse 备份 | MinIO |
| `envs_docker_context` | Docker 构建上下文 | MinIO |
| `setup_bucket` | 实例初始化脚本 | MinIO / NFS |
| `fc_env_pipeline_bucket` | 环境流水线 | MinIO |

**推荐方案**：部署 [MinIO](https://min.io/)（S3 兼容），应用层已支持 S3 API。

```bash
# MinIO 部署示例（生产环境建议分布式部署）
docker run -d \
  -p 9000:9000 -p 9001:9001 \
  -v /data/minio:/data \
  -e MINIO_ROOT_USER=admin \
  -e MINIO_ROOT_PASSWORD=<password> \
  minio/minio server /data --console-address ":9001"
```

### 4. 文件存储（NFS）

| GCP 资源 | 用途 | 自建替代方案 |
|---|---|---|
| `google_filestore_instance` | 共享 chunk 缓存 | NFS Server / Ceph / GlusterFS |

```bash
# NFS Server 配置示例
# /etc/exports
/data/e2b-cache  10.0.0.0/8(rw,sync,no_subtree_check,no_root_squash)
```

### 5. 数据库与缓存

| GCP 资源 | 自建替代方案 |
|---|---|
| `google_memorystore_instance` (Valkey/Redis) | 自建 Redis/Valkey 集群 |
| PostgreSQL (via Supabase) | 自建 PostgreSQL + 自行管理认证 |

#### Redis 集群部署

```yaml
# docker-compose.yml 示例
services:
  redis:
    image: redis:7.4-alpine
    command: redis-server --appendonly yes --requirepass <password>
    ports:
      - "6379:6379"
    volumes:
      - redis-data:/data
```

#### PostgreSQL 部署

```yaml
services:
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: e2b
      POSTGRES_PASSWORD: <password>
      POSTGRES_DB: e2b
    ports:
      - "5432:5432"
    volumes:
      - pg-data:/var/lib/postgresql/data
```

### 6. 密钥管理

| GCP 资源 | 自建替代方案 |
|---|---|
| `google_secret_manager_secret` (~30 个) | HashiCorp Vault / Nomad Variables / 环境变量 |

**需要管理的密钥清单**：

| 类别 | 密钥名 |
|---|---|
| 基础设施 | `consul_acl_token`, `consul_gossip_encryption_key`, `nomad_acl_token` |
| 可观测性 | `grafana_api_key`, `grafana_otlp_url`, `grafana_otel_collector_token` |
| 数据库 | `postgres_connection_string`, `clickhouse_password` |
| 缓存 | `redis_cluster_url`, `redis_tls_ca_base64` |
| 认证 | `supabase_jwt_secrets` |
| 外部服务 | `cloudflare_api_token`, `posthog_api_key`, `launch_darkly_api_key` |

#### Vault 部署示例

```bash
# 开发模式
vault server -dev

# 生产模式需要配置存储后端（Consul/Raft）
```

### 7. 容器镜像仓库

| GCP 资源 | 自建替代方案 |
|---|---|
| `google_artifact_registry_repository` (5 个) | Harbor / Docker Registry v2 |

**推荐方案**：[Harbor](https://goharbor.io/)（支持漏洞扫描、镜像签名、RBAC）

```bash
# Harbor 安装
wget https://github.com/goharbor/harbor/releases/download/v2.11.0/harbor-offline-installer-v2.11.0.tgz
tar xvf harbor-offline-installer-v2.11.0.tgz
cd harbor
cp harbor.yml.tmpl harbor.yml
# 编辑 harbor.yml 配置域名、HTTPS、存储
./install.sh
```

### 8. Terraform 状态存储

| GCP 资源 | 自建替代方案 |
|---|---|
| GCS backend | Consul backend / S3 (MinIO) backend / 本地文件 + 锁 |

```hcl
# 使用 Consul 作为 Terraform backend
terraform {
  backend "consul" {
    address = "consul.example.com:8500"
    scheme  = "https"
    path    = "terraform/e2b"
    lock    = true
  }
}

# 或使用 MinIO (S3 兼容)
terraform {
  backend "s3" {
    bucket                      = "terraform-state"
    key                         = "e2b/terraform.tfstate"
    endpoint                    = "https://minio.example.com"
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    force_path_style            = true
  }
}
```

---

## 二、应用层变更（`packages/`）

应用代码已有 provider 抽象，通过环境变量切换：

### 1. 对象存储 Provider

```bash
# 默认为 GCPBucket，改为 S3 兼容（MinIO）
export STORAGE_PROVIDER=AWSBucket
export AWS_REGION=us-east-1           # 任意值，MinIO 不校验
export AWS_ACCESS_KEY_ID=<minio-key>
export AWS_SECRET_ACCESS_KEY=<minio-secret>
export AWS_ENDPOINT_URL=https://minio.example.com  # MinIO 端点

export TEMPLATE_BUCKET_NAME=e2b-templates
export BUILD_CACHE_BUCKET_NAME=e2b-build-cache
```

### 2. 容器镜像仓库 Provider

```bash
# 默认为 GCP_ARTIFACTS
export ARTIFACTS_REGISTRY_PROVIDER=AWS_ECR  # 或新增 Harbor provider

# Harbor 认证
export DOCKER_AUTH_BASE64=<base64(username:password)>
```

### 3. DockerHub 代理

```bash
# 默认为 GCP_REMOTE_REPOSITORY
# 改为直接使用 Harbor proxy cache 或 Docker mirror
export DOCKERHUB_REMOTE_REPOSITORY_PROVIDER=...
```

### 4. 需要修改的硬编码

以下 CLI 工具硬编码了 `GCPBucket`，需要改为可配置：

| 文件 | 当前状态 |
|---|---|
| `packages/orchestrator/cmd/create-build/main.go` | 硬编码 `STORAGE_PROVIDER=GCPBucket` |
| `packages/orchestrator/cmd/resume-build/main.go` | 硬编码 `STORAGE_PROVIDER=GCPBucket` |
| `packages/orchestrator/cmd/copy-build/main.go` | 直接调用 `storage.NewGCP()` |

---

## 三、Nomad Job 模块变更

### 无需改动的模块（云无关）

| 模块 | 说明 |
|---|---|
| `job-api` | 纯 Docker，通用连接串 |
| `job-redis` | 纯 Docker |
| `job-ingress` | Traefik Docker |
| `job-client-proxy` | 纯 Docker |
| `job-dashboard-api` | 纯 Docker |
| `job-logs-collector` | Vector Docker，支持 `vector_config_override` |
| `job-template-manager-autoscaler` | Nomad 内部 |

### 需要配置的模块

| 模块 | 变更方式 |
|---|---|
| `job-orchestrator` | 设置 `provider_name`，配置 S3/Harbor 凭证 |
| `job-template-manager` | 设置 `provider_name`，配置 S3/Harbor 凭证 |
| `job-loki` | 使用 `loki_config_override` 配置 S3 存储后端 |
| `job-otel-collector` | 使用 `otel_collector_config_override` 移除云检测 |
| `job-otel-collector-nomad-server` | 使用 `otel_collector_config_override` 移除云检测 |
| `job-clickhouse` | 备份配置改为 S3 (MinIO) |

### Loki S3 配置示例

```yaml
# loki_config_override
storage_config:
  aws:
    endpoint: minio.example.com
    bucketnames: loki-logs
    access_key_id: ${AWS_ACCESS_KEY_ID}
    secret_access_key: ${AWS_SECRET_ACCESS_KEY}
    s3forcepathstyle: true
    insecure: false

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: aws
      schema: v13
      index:
        prefix: index_
        period: 24h
```

### OTel Collector 配置示例

```yaml
# otel_collector_config_override
# 移除 GCP/EC2 资源检测，改为手动配置
processors:
  resource:
    attributes:
      - key: host.name
        value: ${HOSTNAME}
        action: upsert
      - key: service.namespace
        value: e2b
        action: upsert
```

---

## 四、实施路线

### 阶段 1：基础设施搭建

1. **服务器准备**
   - 准备裸金属服务器（需要 `/dev/kvm`）
   - 配置网络（VLAN、防火墙规则）
   - 安装基础系统（Ubuntu 22.04 LTS 推荐）

2. **核心服务部署**
   - Nomad + Consul 集群
   - MinIO（S3 兼容存储）
   - PostgreSQL
   - Redis/Valkey
   - NFS Server
   - Harbor（容器镜像仓库）
   - HashiCorp Vault（密钥管理）

3. **网络层部署**
   - HAProxy / Nginx 负载均衡
   - Let's Encrypt 证书自动化
   - 防火墙规则配置

### 阶段 2：Terraform 改造

1. **创建 `iac/provider-baremetal/`**
   - 参考 `provider-aws/` 结构
   - 只保留 Nomad Job 定义
   - 移除所有云基础设施资源

2. **配置 Terraform backend**
   - 使用 Consul 或 MinIO 作为状态存储

3. **调整 Job 模块参数**
   - 配置 `provider_name` 和 `*_config_override`

### 阶段 3：应用部署

1. **配置环境变量**

```bash
# .env.baremetal
PROVIDER=baremetal
STORAGE_PROVIDER=AWSBucket
AWS_ENDPOINT_URL=https://minio.example.com
ARTIFACTS_REGISTRY_PROVIDER=Harbor  # 需要新增
TEMPLATE_BUCKET_NAME=e2b-templates
# ... 其他配置
```

2. **构建并推送镜像**

```bash
make build-and-upload
```

3. **部署 Nomad Jobs**

```bash
make plan-only-jobs
make apply
```

### 阶段 4：验证测试

1. **Firecracker 验证**
   - 检查 `/dev/kvm` 权限
   - 测试 VM 创建和网络连通性

2. **存储验证**
   - MinIO 读写测试
   - NFS 挂载测试

3. **端到端测试**
   - 创建沙箱
   - 执行代码
   - 快照和恢复

---

## 五、工作量评估

| 部分 | 工作量 | 复杂度 |
|---|---|---|
| 基础设施搭建（Nomad/Consul/MinIO/Redis/PG/NFS） | 40% | 中 |
| 网络层（LB + TLS + 防火墙） | 20% | 高 |
| Terraform 改造 | 15% | 中 |
| 应用配置调整 | 10% | 低 |
| 测试验证 | 15% | 中 |

**关键挑战**：

1. **Firecracker 网络**：需要正确配置 iptables 和网桥
2. **存储性能**：MinIO 和 NFS 需要足够的 IOPS
3. **高可用**：所有组件需要考虑冗余部署
4. **监控告警**：需要自建完整的可观测性栈

---

## 六、参考资源

- [Nomad 生产部署指南](https://developer.hashicorp.com/nomad/tutorials/enterprise/production-deployment-guide)
- [Consul 生产部署](https://developer.hashicorp.com/consul/tutorials/production-deploy)
- [MinIO 高可用部署](https://min.io/docs/minio/linux/operations/install-deploy-manage/deploy-minio-multi-node-multi-drive.html)
- [Harbor 安装指南](https://goharbor.io/docs/latest/install-config/)
- [Firecracker 文档](https://github.com/firecracker-microvm/firecracker/blob/main/docs/getting-started.md)
- [E2B 本地开发指南](./DEV-LOCAL.md)
