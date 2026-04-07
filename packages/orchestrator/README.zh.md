# Orchestrator 项目概述

Orchestrator 是 E2B 基础设施的核心组件，负责管理和编排 **Firecracker microVM**（微虚拟机）的生命周期。它是一个用 Go 编写的高性能服务，提供沙箱环境的创建、快照、恢复和资源管理。

## 核心职责

1. **VM 生命周期管理** - 创建、启动、暂停、恢复、销毁 Firecracker 虚拟机
2. **快照系统** - 支持 VM 内存和磁盘的快照/恢复，实现快速冷启动
3. **网络管理** - 为每个 VM 配置隔离的网络环境（通过 iptables 和 netlink）
4. **存储管理** - 使用 NBD（Network Block Device）提供块设备支持
5. **模板缓存** - 管理预构建的 VM 模板，加速沙箱创建
6. **资源监控** - 通过 cgroup 进行资源限制和统计

## 架构组成

### 主要模块（pkg/ 目录）

- **sandbox/** - 核心沙箱管理逻辑
  - `fc/` - Firecracker 集成
  - `network/` - 网络配置（IP 分配、路由）
  - `nbd/` - 块设备管理
  - `template/` - 模板缓存和加载
  - `block/` - 块设备 I/O 和缓存
  - `cgroup/` - 资源限制

- **server/** - gRPC 服务端，暴露 orchestrator API
- **tcpfirewall/** - TCP 出口流量代理和防火墙
- **nfsproxy/** - NFS 代理（用于文件系统共享）
- **portmap/** - 端口映射服务
- **hyperloopserver/** - Hyperloop 协议服务器（快速数据传输）
- **template/** - 模板管理服务
- **volumes/** - 卷管理
- **metrics/** - 监控指标收集
- **factories/** - 服务初始化和依赖注入

## 工作流程

```
API 请求 → gRPC Server → Sandbox Manager
                              ↓
                    创建 Firecracker VM
                              ↓
                    配置网络 (network/)
                              ↓
                    挂载存储 (nbd/)
                              ↓
                    加载模板快照 (template/)
                              ↓
                    启动 VM + Envd (in-VM daemon)
                              ↓
                    返回沙箱连接信息
```

## 关键特性

### 快照系统
- 支持内存快照（memfile）和磁盘快照（rootfs）
- 增量快照（基于父快照构建）
- 块级去重和压缩
- 支持本地存储和 GCS 远程存储

### 命令行工具（cmd/ 目录）
- `create-build` - 创建新的 VM 构建/快照
- `resume-build` - 从快照恢复 VM
- `copy-build` - 在存储间复制构建
- `mount-build-rootfs` - 挂载构建的根文件系统
- `inspect-build` - 检查构建元数据
- `show-build-diff` - 显示两个构建的差异

## 技术栈

- **Firecracker** - AWS 开源的轻量级虚拟化技术
- **gRPC** - 服务间通信
- **NBD** - 网络块设备协议
- **Cgroup v2** - 资源隔离和限制
- **OpenTelemetry** - 可观测性（traces/metrics/logs）
- **HugePages** - 2MB 大页内存优化性能

## 运行要求

- **需要 root 权限**（Firecracker 需要）
- **NBD 内核模块**（`modprobe nbd`）
- **HugePages 配置**（用于内存快照）
- **Linux 内核** 支持 netlink、iptables

## 性能优化

这个项目是 E2B 实现"秒级启动隔离代码执行环境"的核心技术，通过快照技术将传统需要几秒的 VM 启动时间压缩到毫秒级。

详细的技术文档请参考：
- [fc 目录技术细节](pkg/sandbox/fc/README.zh.md)
