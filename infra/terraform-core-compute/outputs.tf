output "resource_group_name" {
  value = data.azurerm_resource_group.environment.name
}

output "aks_name" {
  value = azurerm_kubernetes_cluster.dev.name
}

output "acr_name" {
  value = azurerm_container_registry.dev.name
}

output "acr_login_server" {
  value = azurerm_container_registry.dev.login_server
}

output "tenant_id" {
  value = data.azurerm_client_config.current.tenant_id
}

output "aks_host" {
  value = nonsensitive(azurerm_kubernetes_cluster.dev.kube_config[0].host)
}

output "aks_cluster_ca_certificate" {
  description = "Public CA certificate, not a client credential."
  value       = nonsensitive(azurerm_kubernetes_cluster.dev.kube_config[0].cluster_ca_certificate)
}

output "mongodb_disk_id" {
  value = azurerm_managed_disk.mongodb.id
}

output "mongodb_disk_size_gb" {
  value = azurerm_managed_disk.mongodb.disk_size_gb
}
