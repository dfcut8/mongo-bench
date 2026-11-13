locals {
  application_image = var.application == null ? null : "${data.terraform_remote_state.infrastructure.outputs.acr_login_server}/mongo-bench:${var.application.image_tag}"
}

# Explicit opt-in until the Go service and its Dockerfile exist. No Azure passwords:
# az acr login obtains a short-lived Entra token for the caller's AcrPush role.
resource "terraform_data" "publish_application" {
  count = var.application == null ? 0 : (var.application.build_context == null ? 0 : 1)
  triggers_replace = [
    local.application_image,
    var.application.source_revision,
    abspath(var.application.build_context),
    filesha256("${path.module}/scripts/Publish-AppImage.ps1"),
  ]
  provisioner "local-exec" {
    interpreter = ["pwsh", "-NoProfile", "-NonInteractive", "-Command"]
    command     = file("${path.module}/scripts/Publish-AppImage.ps1")
    environment = {
      MONGO_BENCH_BUILD_CONTEXT = abspath(var.application.build_context)
      MONGO_BENCH_ACR_NAME      = data.terraform_remote_state.infrastructure.outputs.acr_name
      MONGO_BENCH_IMAGE         = local.application_image
    }
  }
}

resource "kubernetes_deployment_v1" "application" {
  count = var.application == null ? 0 : 1
  metadata {
    name      = "mongo-bench"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
  spec {
    replicas = var.application.replicas
    selector {
      match_labels = { "app.kubernetes.io/name" = "mongo-bench" }
    }
    template {
      metadata {
        labels = { "app.kubernetes.io/name" = "mongo-bench" }
        annotations = {
          "mongo-bench/source-revision" = coalesce(var.application.source_revision, var.application.image_tag)
        }
      }
      spec {
        automount_service_account_token = false
        container {
          name              = "mongo-bench"
          image             = local.application_image
          image_pull_policy = "Always"
          port {
            name           = "http"
            container_port = var.application.port
          }
          env {
            name  = "HTTP_ADDR"
            value = ":${var.application.port}"
          }
          env_from {
            secret_ref {
              name = kubernetes_secret_v1.app_database.metadata[0].name
            }
          }
          resources {
            requests = { cpu = "100m", memory = "128Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }
          readiness_probe {
            tcp_socket { port = var.application.port }
            initial_delay_seconds = 5
            period_seconds        = 5
          }
        }
      }
    }
  }
  depends_on = [terraform_data.publish_application]
}

resource "kubernetes_service_v1" "application" {
  count = var.application == null ? 0 : 1
  metadata {
    name      = "mongo-bench"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
  spec {
    type     = "ClusterIP"
    selector = { "app.kubernetes.io/name" = "mongo-bench" }
    port {
      name        = "http"
      port        = 80
      target_port = var.application.port
    }
  }
}
