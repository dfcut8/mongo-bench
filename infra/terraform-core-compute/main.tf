locals {
  environment = "dev"
  namespaces  = toset(["mongo-bench-db-dev", "mongo-bench-app-dev"])
  developers  = setunion(var.developer_object_ids, toset([data.azurerm_client_config.current.object_id]))
  namespace_developers = {
    for pair in setproduct(local.developers, local.namespaces) : "${pair[0]}/${pair[1]}" => {
      object_id = pair[0]
      namespace = pair[1]
    }
  }
  tags = {
    project     = "mongo-bench"
    environment = local.environment
    managed_by  = "terraform"
  }
}

data "azurerm_client_config" "current" {}

# Bootstrap owns this group and the state storage; Terraform must not delete them.
data "azurerm_resource_group" "environment" {
  name = "rg-mongo-bench-${local.environment}"
}

resource "azurerm_container_registry" "dev" {
  name                = "mbacr${local.environment}${substr(sha256(var.subscription_id), 0, 8)}"
  resource_group_name = data.azurerm_resource_group.environment.name
  location            = var.location
  sku                 = "Basic"
  admin_enabled       = false
  # AcrPull/AcrPush require registry RBAC rather than repository ABAC mode.
  role_assignment_mode = "LegacyRegistryPermissions"
  tags                 = local.tags
}

resource "azurerm_kubernetes_cluster" "dev" {
  name                = "aks-mongo-bench-${local.environment}"
  resource_group_name = data.azurerm_resource_group.environment.name
  location            = var.location
  dns_prefix          = "mongo-bench-${local.environment}"
  node_resource_group = "rg-mongo-bench-${local.environment}-nodes"
  sku_tier            = "Free"

  role_based_access_control_enabled = true
  local_account_disabled            = true
  automatic_upgrade_channel         = "patch"
  node_os_upgrade_channel           = "NodeImage"
  oidc_issuer_enabled               = true
  workload_identity_enabled         = true

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.control_plane.id]
  }

  kubelet_identity {
    client_id                 = azurerm_user_assigned_identity.kubelet.client_id
    object_id                 = azurerm_user_assigned_identity.kubelet.principal_id
    user_assigned_identity_id = azurerm_user_assigned_identity.kubelet.id
  }

  azure_active_directory_role_based_access_control {
    tenant_id          = data.azurerm_client_config.current.tenant_id
    azure_rbac_enabled = true
  }

  api_server_access_profile {
    authorized_ip_ranges = length(var.aks_api_allowed_cidrs) == 0 ? null : var.aks_api_allowed_cidrs
  }

  default_node_pool {
    name                        = "system"
    node_count                  = var.node_count
    vm_size                     = var.node_vm_size
    os_sku                      = "Ubuntu"
    os_disk_type                = "Managed"
    os_disk_size_gb             = 64
    max_pods                    = 50
    temporary_name_for_rotation = "systemtemp"

    upgrade_settings {
      max_surge = "1"
    }
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    pod_cidr            = "10.244.0.0/16"
    service_cidr        = "10.0.0.0/16"
    dns_service_ip      = "10.0.0.10"
    load_balancer_sku   = "standard"
    outbound_type       = "loadBalancer"
  }

  storage_profile {
    disk_driver_enabled = true
  }

  tags = local.tags
  depends_on = [
    azurerm_role_assignment.aks_kubelet_operator,
    azurerm_role_assignment.aks_acr_pull,
    azurerm_role_assignment.aks_disk_access,
  ]
}

resource "azurerm_user_assigned_identity" "control_plane" {
  name                = "id-mongo-bench-dev-control-plane"
  resource_group_name = data.azurerm_resource_group.environment.name
  location            = var.location
  tags                = local.tags
}

resource "azurerm_user_assigned_identity" "kubelet" {
  name                = "id-mongo-bench-dev-kubelet"
  resource_group_name = data.azurerm_resource_group.environment.name
  location            = var.location
  tags                = local.tags
}

resource "azurerm_role_assignment" "aks_kubelet_operator" {
  scope                            = azurerm_user_assigned_identity.kubelet.id
  role_definition_name             = "Managed Identity Operator"
  principal_id                     = azurerm_user_assigned_identity.control_plane.principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                            = azurerm_container_registry.dev.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_user_assigned_identity.kubelet.principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "developer_acr_push" {
  for_each             = local.developers
  scope                = azurerm_container_registry.dev.id
  role_definition_name = "AcrPush"
  principal_id         = each.value
}

resource "azurerm_role_assignment" "developer_cluster_user" {
  for_each             = local.developers
  scope                = azurerm_kubernetes_cluster.dev.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = each.value
}

# The infrastructure owner also manages namespaces and the cluster-scoped PV.
resource "azurerm_role_assignment" "terraform_cluster_admin" {
  scope                = azurerm_kubernetes_cluster.dev.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "developer_namespace_writer" {
  for_each             = local.namespace_developers
  scope                = "${azurerm_kubernetes_cluster.dev.id}/namespaces/${each.value.namespace}"
  role_definition_name = "Azure Kubernetes Service RBAC Writer"
  principal_id         = each.value.object_id
}

# This group survives cluster/node replacements. It contains only database data.
resource "azurerm_resource_group" "data" {
  name     = "rg-mongo-bench-${local.environment}-data"
  location = var.location
  tags     = local.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_managed_disk" "mongodb" {
  name                 = "mongo-bench-db-${local.environment}"
  resource_group_name  = azurerm_resource_group.data.name
  location             = var.location
  storage_account_type = "StandardSSD_LRS"
  create_option        = "Empty"
  disk_size_gb         = var.mongodb_disk_size_gb
  tags                 = local.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_role_assignment" "aks_disk_access" {
  scope                            = azurerm_resource_group.data.id
  role_definition_name             = "Contributor"
  principal_id                     = azurerm_user_assigned_identity.control_plane.principal_id
  skip_service_principal_aad_check = true
}
