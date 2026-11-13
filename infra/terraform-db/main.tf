locals {
  db_namespace  = "mongo-bench-db-dev"
  app_namespace = "mongo-bench-app-dev"
  mongodb_host  = "mongodb-0.mongodb.${local.db_namespace}.svc.cluster.local:27017"
  database      = "mongo_bench"
  labels = {
    "app.kubernetes.io/name"      = "mongodb"
    "app.kubernetes.io/part-of"   = "mongo-bench"
    "app.kubernetes.io/component" = "database"
  }
  bootstrap_script = file("${path.module}/scripts/bootstrap-mongodb.js")
}

resource "kubernetes_namespace_v1" "db" {
  metadata {
    name = local.db_namespace
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "random_password" "root" {
  length  = 32
  special = false
}

resource "random_password" "app" {
  length  = 32
  special = false
}

resource "random_password" "replica_key" {
  length  = 128
  special = false
}

resource "kubernetes_secret_v1" "mongodb" {
  metadata {
    name      = "mongodb-bootstrap"
    namespace = kubernetes_namespace_v1.db.metadata[0].name
  }
  data = {
    MONGO_INITDB_ROOT_USERNAME = "mongo-bench-admin"
    MONGO_INITDB_ROOT_PASSWORD = random_password.root.result
    MONGO_APP_PASSWORD         = random_password.app.result
    keyfile                    = random_password.replica_key.result
  }

  lifecycle {
    prevent_destroy = true
  }
}

# Static binding to the protected Azure disk; never dynamically delete data.
resource "kubernetes_persistent_volume_v1" "mongodb" {
  metadata {
    name = "mongo-bench-db-dev"
  }
  spec {
    capacity = {
      storage = "${data.terraform_remote_state.infrastructure.outputs.mongodb_disk_size_gb}Gi"
    }
    access_modes                     = ["ReadWriteOnce"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = ""

    claim_ref {
      namespace = kubernetes_namespace_v1.db.metadata[0].name
      name      = "mongodb-data"
    }

    persistent_volume_source {
      csi {
        driver        = "disk.csi.azure.com"
        volume_handle = data.terraform_remote_state.infrastructure.outputs.mongodb_disk_id
        fs_type       = "ext4"
        volume_attributes = {
          cachingMode = "None"
        }
      }
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "kubernetes_persistent_volume_claim_v1" "mongodb" {
  metadata {
    name      = "mongodb-data"
    namespace = kubernetes_namespace_v1.db.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = ""
    volume_name        = kubernetes_persistent_volume_v1.mongodb.metadata[0].name
    resources {
      requests = {
        storage = "${data.terraform_remote_state.infrastructure.outputs.mongodb_disk_size_gb}Gi"
      }
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "kubernetes_service_v1" "mongodb" {
  metadata {
    name      = "mongodb"
    namespace = kubernetes_namespace_v1.db.metadata[0].name
  }
  spec {
    cluster_ip                  = "None"
    publish_not_ready_addresses = true
    selector                    = local.labels
    port {
      name        = "mongodb"
      port        = 27017
      target_port = 27017
    }
    type = "ClusterIP"
  }
}

resource "kubernetes_network_policy_v1" "mongodb" {
  metadata {
    name      = "mongodb-ingress"
    namespace = kubernetes_namespace_v1.db.metadata[0].name
  }
  spec {
    pod_selector {
      match_labels = local.labels
    }
    policy_types = ["Ingress"]
    ingress {
      ports {
        port     = "27017"
        protocol = "TCP"
      }
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = local.app_namespace }
        }
      }
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = local.db_namespace }
        }
      }
    }
  }
}
