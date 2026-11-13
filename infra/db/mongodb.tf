resource "kubernetes_stateful_set_v1" "mongodb" {
  metadata {
    name      = "mongodb"
    namespace = kubernetes_namespace_v1.db.metadata[0].name
  }
  # The bootstrap Job must initialize the replica set before readiness succeeds.
  wait_for_rollout = false
  spec {
    service_name = kubernetes_service_v1.mongodb.metadata[0].name
    replicas     = 1
    selector {
      match_labels = local.labels
    }
    template {
      metadata {
        labels = local.labels
      }
      spec {
        automount_service_account_token  = false
        termination_grace_period_seconds = 60

        # MongoDB requires a keyfile readable only by its owner, not a 0444 Secret mount.
        init_container {
          name    = "prepare-keyfile"
          image   = var.mongodb_image
          command = ["sh", "-ec", "cp /secrets/keyfile /keyfile/keyfile; chown 999:999 /keyfile/keyfile; chmod 400 /keyfile/keyfile"]
          security_context {
            run_as_user = 0
          }
          volume_mount {
            name       = "bootstrap"
            mount_path = "/secrets"
            read_only  = true
          }
          volume_mount {
            name       = "keyfile"
            mount_path = "/keyfile"
          }
        }

        container {
          name  = "mongodb"
          image = var.mongodb_image
          args  = ["mongod", "--bind_ip_all", "--replSet", "rs0", "--keyFile", "/keyfile/keyfile", "--wiredTigerCacheSizeGB", "0.5"]
          port {
            name           = "mongodb"
            container_port = 27017
          }
          env {
            name = "MONGO_INITDB_ROOT_USERNAME"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.mongodb.metadata[0].name
                key  = "MONGO_INITDB_ROOT_USERNAME"
              }
            }
          }
          env {
            name = "MONGO_INITDB_ROOT_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.mongodb.metadata[0].name
                key  = "MONGO_INITDB_ROOT_PASSWORD"
              }
            }
          }
          resources {
            requests = { cpu = "250m", memory = "1Gi" }
            limits   = { cpu = "1", memory = "2Gi" }
          }
          startup_probe {
            tcp_socket { port = 27017 }
            period_seconds    = 5
            failure_threshold = 120
          }
          liveness_probe {
            tcp_socket { port = 27017 }
            period_seconds    = 10
            failure_threshold = 6
          }
          readiness_probe {
            exec {
              command = ["mongosh", "--quiet", "--host", "127.0.0.1", "--eval", "quit(db.hello().isWritablePrimary ? 0 : 1)"]
            }
            period_seconds    = 10
            timeout_seconds   = 5
            failure_threshold = 3
          }
          volume_mount {
            name       = "data"
            mount_path = "/data/db"
          }
          volume_mount {
            name       = "keyfile"
            mount_path = "/keyfile"
            read_only  = true
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.mongodb.metadata[0].name
          }
        }
        volume {
          name = "bootstrap"
          secret {
            secret_name = kubernetes_secret_v1.mongodb.metadata[0].name
            items {
              key  = "keyfile"
              path = "keyfile"
            }
          }
        }
        volume {
          name = "keyfile"
          empty_dir { medium = "Memory" }
        }
      }
    }
  }
  depends_on = [kubernetes_network_policy_v1.mongodb]
}

resource "kubernetes_config_map_v1" "mongodb_bootstrap" {
  metadata {
    name      = "mongodb-bootstrap"
    namespace = kubernetes_namespace_v1.db.metadata[0].name
  }
  data = { "bootstrap.js" = local.bootstrap_script }
}

resource "kubernetes_job_v1" "mongodb_bootstrap" {
  metadata {
    name      = "mongodb-bootstrap-${substr(sha256("${local.bootstrap_script}:${var.mongodb_image}"), 0, 8)}"
    namespace = kubernetes_namespace_v1.db.metadata[0].name
  }
  wait_for_completion = true
  spec {
    backoff_limit           = 3
    active_deadline_seconds = 600
    template {
      metadata {
        labels = { "app.kubernetes.io/name" = "mongodb-bootstrap" }
      }
      spec {
        automount_service_account_token = false
        restart_policy                  = "OnFailure"
        container {
          name    = "bootstrap"
          image   = var.mongodb_image
          command = ["mongosh", "--nodb", "--quiet", "/scripts/bootstrap.js"]
          env_from {
            secret_ref {
              name = kubernetes_secret_v1.mongodb.metadata[0].name
            }
          }
          env {
            name  = "MONGO_HOST"
            value = local.mongodb_host
          }
          resources {
            requests = { cpu = "100m", memory = "128Mi" }
            limits   = { cpu = "500m", memory = "256Mi" }
          }
          volume_mount {
            name       = "scripts"
            mount_path = "/scripts"
            read_only  = true
          }
        }
        volume {
          name = "scripts"
          config_map {
            name = kubernetes_config_map_v1.mongodb_bootstrap.metadata[0].name
          }
        }
      }
    }
  }
  timeouts {
    create = "15m"
    update = "15m"
  }
  depends_on = [kubernetes_stateful_set_v1.mongodb]
}
