output "application_namespace" {
  value = kubernetes_namespace_v1.app.metadata[0].name
}

output "application_image" {
  value = local.application_image
}
