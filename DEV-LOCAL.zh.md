# 本地开发应用

> 注意：裸机开发需要 Linux 系统。此文档仍在完善中，部分功能可能无法按预期工作。

## 系统准备
1. `sudo modprobe nbd nbds_max=64` — 加载 NBD（网络块设备）内核模块
2. `sudo sysctl -w vm.nr_hugepages=2048` — 启用大页内存

## 下载预构建产物（定制版 Firecracker 和 Linux 内核）

1. `make download-public-kernels` — 下载 Linux 内核
2. `make download-public-firecrackers` — 下载 Firecracker 版本

## 启动本地基础设施
1. `make local-infra` — 启动 ClickHouse、Grafana、Loki、Memcached、Mimir、OpenTelemetry、PostgreSQL、Redis、Tempo

## 准备本地环境

1. `make -C packages/db migrate-local` — 初始化 PostgreSQL 数据库
2. `make -C packages/clickhouse migrate-local` — 初始化 ClickHouse 数据库
3. `make -C packages/envd build` — 构建 envd（将嵌入到模板中的虚拟机内守护进程）
4. `make -C packages/local-dev seed-database` — 生成本地开发用的用户、团队和令牌

## 本地运行应用

以下命令会在前台启动各个服务，需要多个终端窗口。

- `make -C packages/api run-local` — 本地运行 API 服务
- `make -C packages/orchestrator build-debug && sudo make -C packages/orchestrator run-local` — 本地运行 Orchestrator 和 Template Manager（需要 sudo 权限）
- `make -C packages/client-proxy run-local` — 本地运行客户端代理

## 构建基础模板
- `make -C packages/shared/scripts local-build-base-template` — 指示 Orchestrator 创建 'base' 基础模板

# 服务地址
- Grafana（监控面板）: http://localhost:53000
- PostgreSQL: postgres:postgres@127.0.0.1:5432
- ClickHouse (HTTP): http://localhost:8123
- ClickHouse (原生协议): clickhouse:clickhouse@localhost:9000
- Redis: localhost:6379
- OpenTelemetry Collector (gRPC): localhost:4317
- OpenTelemetry Collector (HTTP): localhost:4318
- Vector: localhost:30006
- E2B API: http://localhost:3000
- E2B 客户端代理: http://localhost:3002
- E2B Orchestrator: http://localhost:5008
- MinIO API: http://localhost:19000
- MinIO Console: http://localhost:19001

# MinIO 对象存储配置

## 启动 MinIO

```bash
./minio server --address :19000 --console-address :19001 /root/ya/e2b/minio_data
```

启动后默认 root 凭据为 `minioadmin` / `minioadmin`（可通过 `MINIO_ROOT_USER` 和 `MINIO_ROOT_PASSWORD` 环境变量自定义）。

## 配置 mc 命令行工具

```bash
# 添加本地 MinIO 别名
./mc alias set local http://localhost:19000 minioadmin minioadmin

# 验证连接
./mc admin info local
```

## 创建 Bucket

```bash
# 查看已有 bucket
./mc ls local/

# 创建新 bucket（如需要）
./mc mb local/e2b
```

## 创建 Service Account（S3 SDK 用）

```bash
./mc admin user svcacct add local minioadmin --json
```

输出示例：

```json
{
  "accessKey": "97DERZQR0JHGJG31DVHA",
  "secretKey": "94tKyWjSGy5yOe+R1QQ+tr1+A0VgHWrMbJrwI9vL"
}
```

## S3 SDK 连接配置

| 参数 | 值 |
|---|---|
| Endpoint | `http://localhost:19000` |
| Region | `us-east-1` |
| Force Path Style | `true`（MinIO 必须） |
| Access Key | 上一步生成的 accessKey |
| Secret Key | 上一步生成的 secretKey |
| Bucket | `e2b` |

### Python (boto3)

```python
import boto3

s3 = boto3.client('s3',
    endpoint_url='http://localhost:19000',
    aws_access_key_id='<ACCESS_KEY>',
    aws_secret_access_key='<SECRET_KEY>',
    region_name='us-east-1',
)

# 上传文件
s3.upload_file('local_file.txt', 'e2b', 'remote_key.txt')
```

### Node.js (AWS SDK v3)

```javascript
import { S3Client, PutObjectCommand } from '@aws-sdk/client-s3';

const s3 = new S3Client({
  endpoint: 'http://localhost:19000',
  region: 'us-east-1',
  credentials: {
    accessKeyId: '<ACCESS_KEY>',
    secretAccessKey: '<SECRET_KEY>',
  },
  forcePathStyle: true,
});
```

### Go (MinIO SDK)

```go
client, _ := minio.New("localhost:19000", &minio.Options{
    Creds:  credentials.NewStaticV4("<ACCESS_KEY>", "<SECRET_KEY>", ""),
    Secure: false,
})
```

# 客户端配置
```dotenv
E2B_API_KEY=e2b_53ae1fed82754c17ad8077fbc8bcdd90
E2B_ACCESS_TOKEN=sk_e2b_89215020937a4c989cde33d7bc647715
E2B_API_URL=http://localhost:3000
E2B_SANDBOX_URL=http://localhost:3002
```
