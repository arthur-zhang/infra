job "orchestrator" {
  type      = "system"
  node_pool = "default"
  priority  = 91

  group "client-orchestrator" {
    network {
      port "orchestrator" {
        static = 5008
      }

      port "orchestrator-proxy" {
        static = 5009
      }
    }

    service {
      name = "orchestrator"
      port = "orchestrator"

      provider = "nomad"

      check {
        type     = "http"
        path     = "/health"
        name     = "health"
        interval = "20s"
        timeout  = "5s"
      }
    }

    service {
      name = "orchestrator-proxy"
      port = "orchestrator-proxy"

      provider = "nomad"

      check {
        type     = "tcp"
        name     = "health"
        interval = "30s"
        timeout  = "1s"
      }
    }

    task "start" {
      driver = "raw_exec"

      restart {
        attempts = 0
      }

      env {
        NODE_ID     = "${node.unique.name}"
        NODE_IP     = "${attr.unique.network.ip-address}"

        GRPC_PORT                    = "5008"
        PROXY_PORT                   = "5009"
        ENVIRONMENT                  = "production"
        GIN_MODE                     = "release"

        # Consul
        CONSUL_TOKEN                 = "<your-consul-token>"
        DOMAIN_NAME                  = "<your-domain>"

        # Redis
        REDIS_URL                    = "redis.service.consul:6379"
        REDIS_CLUSTER_URL            = ""
        REDIS_POOL_SIZE              = "10"
        REDIS_TLS_CA_BASE64          = ""

        # ClickHouse (可选)
        CLICKHOUSE_CONNECTION_STRING = ""

        # 对象存储
        TEMPLATE_BUCKET_NAME         = "<your-bucket>"
        STORAGE_PROVIDER             = "GCPBucket"
        ARTIFACTS_REGISTRY_PROVIDER  = "GCP_ARTIFACTS"

        # 可观测性
        OTEL_COLLECTOR_GRPC_ENDPOINT = "localhost:4317"
        LOGS_COLLECTOR_ADDRESS       = "http://localhost:3100"

        # Sandbox 配置
        ENVD_TIMEOUT                 = "15s"
        ALLOW_SANDBOX_INTERNET       = "true"
        ORCHESTRATOR_SERVICES        = "orchestrator"
      }

      config {
        command = "/bin/bash"
        args    = ["-c", "chmod +x local/orchestrator && local/orchestrator"]
      }

      artifact {
        source = "<orchestrator 二进制的下载地址>"
      }
    }
  }
}
