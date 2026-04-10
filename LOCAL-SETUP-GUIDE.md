# E2B 本地环境搭建指南

本文档记录了在 Linux 系统上从零搭建 E2B 本地开发环境的完整过程。

## 系统要求

- **操作系统**: Linux (Ubuntu/Debian 推荐)
- **必需软件**:
  - Docker
  - Go 1.25.4+
  - Make
  - sudo 权限

## 环境准备

### 1. 系统内核配置

E2B 使用 Firecracker 微虚拟机，需要配置内核模块和 hugepages：

```bash
# 加载 NBD (Network Block Device) 模块
sudo modprobe nbd nbds_max=64

# 配置 hugepages
sudo sysctl -w vm.nr_hugepages=2048

# 验证配置
lsmod | grep nbd
```

### 2. Docker 镜像加速配置

由于需要拉取大量 Docker 镜像，建议配置镜像加速器：

**对于 snap 安装的 Docker:**

编辑 `/var/snap/docker/current/config/daemon.json`:

```json
{
    "log-level": "error",
    "registry-mirrors": [
        "https://docker.m.daocloud.io",
        "https://docker.1panel.live",
        "https://hub.rat.dev"
    ]
}
```

重启 Docker:

```bash
sudo snap restart docker
```

**对于系统安装的 Docker:**

编辑 `/etc/docker/daemon.json` 并重启服务。

### 3. 停止冲突的系统服务

E2B 需要使用 PostgreSQL 和 Redis 的默认端口，需要停止系统服务：

```bash
# 停止并禁用 PostgreSQL
sudo systemctl stop postgresql
sudo systemctl disable postgresql

# 停止并禁用 Redis
sudo systemctl stop redis-server
sudo systemctl disable redis-server

# 如果端口仍被占用，强制结束进程
sudo pkill -9 postgres
sudo pkill -9 redis-server
```

## 部署步骤

### 步骤 1: 启动基础设施服务

启动 PostgreSQL、Redis、ClickHouse、Grafana 等基础服务：

```bash
make local-infra
```

这个命令会启动以下容器（约需 5-10 分钟下载镜像）：
- PostgreSQL (端口 5432)
- Redis (端口 6379)
- ClickHouse (端口 8123, 9000)
- Grafana (端口 53000)
- Loki, Tempo, Mimir, Vector, Memcached, OTEL Collector

验证容器状态：

```bash
docker ps | grep -E "(postgres|redis|clickhouse|grafana)"
```

### 步骤 2: 初始化数据库

**PostgreSQL 迁移:**

```bash
make -C packages/db migrate-local
```

首次运行会下载 Go 依赖，需要 3-5 分钟。

**ClickHouse 迁移:**

```bash
make -C packages/clickhouse migrate-local
```

**生成开发用户和 Token:**

```bash
make -C packages/local-dev seed-database
```

### 步骤 3: 构建组件

**构建 envd (VM 内守护进程):**

```bash
make -C packages/envd build
```

**构建 Orchestrator:**

```bash
make -C packages/orchestrator build-local
```

### 步骤 4: 启动应用服务

**启动 API 服务 (后台运行):**

```bash
cd packages/api
make run-local &
```

API 会在端口 3000 启动，首次运行需要下载依赖（2-3 分钟）。

**启动 Orchestrator (需要 sudo):**

```bash
cd packages/orchestrator
sudo -E make run-local &
```

Orchestrator 会在端口 5008 启动。

**验证服务状态:**

```bash
# 检查端口监听
netstat -tlnp | grep -E ":(3000|5008)"

# 或使用 ss
ss -tlnp | grep -E ":(3000|5008)"
```

## 访问和使用

### 服务地址

- **API**: http://localhost:3000
- **Grafana 监控**: http://localhost:53000
- **ClickHouse HTTP**: http://localhost:8123
- **PostgreSQL**: localhost:5432
- **Redis**: localhost:6379

### 开发凭证

```bash
E2B_API_KEY=e2b_53ae1fed82754c17ad8077fbc8bcdd90
E2B_ACCESS_TOKEN=sk_e2b_89215020937a4c989cde33d7bc647715
E2B_API_URL=http://localhost:3000
```

### 数据库连接

**PostgreSQL:**
```bash
psql postgresql://postgres:postgres@localhost:5432/postgres
```

**ClickHouse:**
```bash
clickhouse-client --host localhost --port 9000 --user clickhouse --password clickhouse
```

## 常见问题

### 1. Docker 镜像拉取失败

**问题**: `Error: Get "https://registry-1.docker.io/v2/": connection reset`

**解决方案**: 配置 Docker 镜像加速器（见环境准备部分）

### 2. 端口被占用

**问题**: `address already in use`

**解决方案**:
```bash
# 查找占用端口的进程
sudo lsof -i :5432  # PostgreSQL
sudo lsof -i :6379  # Redis

# 停止系统服务
sudo systemctl stop postgresql redis-server
```

### 3. Orchestrator 启动警告

**问题**: `[nbd pool]: failed to create network - no free slots`

**说明**: 这是非关键警告，不影响基本功能。Orchestrator 正在尝试预分配网络资源。

### 4. LaunchDarkly SDK 错误

**问题**: `Received HTTP error 401 (invalid SDK key)`

**说明**: 本地开发不需要 LaunchDarkly，可以忽略此警告。

## 验证部署

### 检查所有服务状态

```bash
# 检查容器
docker ps | grep -v safeline

# 检查应用进程
ps aux | grep -E "(api|orchestrator)" | grep -v grep

# 检查端口
netstat -tlnp | grep -E ":(3000|5008|5432|6379|8123)"
```

### 测试 API

```bash
# 健康检查（可能返回 HTML，但服务正常）
curl http://localhost:3000/health

# 查看 API 日志
tail -f packages/api/logs/*.log
```

## 停止服务

```bash
# 停止容器
docker compose -f packages/local-dev/docker-compose.yaml down

# 停止应用进程
pkill -f "./bin/api"
sudo pkill -f "./bin/orchestrator"
```

## 清理环境

```bash
# 删除容器和数据卷
docker compose -f packages/local-dev/docker-compose.yaml down -v

# 清理构建产物
make clean
```

## 参考文档

- [DEV-LOCAL.md](./DEV-LOCAL.md) - 官方本地开发文档
- [CLAUDE.md](./CLAUDE.md) - 项目架构和开发指南
- [self-host.md](./self-host.md) - 自托管部署指南

## 总结

完成以上步骤后，你将拥有一个完整的 E2B 本地开发环境：

✅ 10 个基础设施容器运行中
✅ API 服务 (端口 3000)
✅ Orchestrator 服务 (端口 5008)
✅ 数据库已初始化并填充测试数据
✅ 监控面板可访问 (Grafana)

现在可以开始开发了！
