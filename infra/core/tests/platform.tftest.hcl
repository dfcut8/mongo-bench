mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      object_id       = "11111111-1111-1111-1111-111111111111"
      tenant_id       = "22222222-2222-2222-2222-222222222222"
      subscription_id = "b8d7fc1c-6003-4425-baf0-15d8db0e1714"
    }
  }
  mock_data "azurerm_resource_group" {
    defaults = {
      id       = "/subscriptions/b8d7fc1c-6003-4425-baf0-15d8db0e1714/resourceGroups/rg-mongo-bench-dev"
      location = "northcentralus"
    }
  }
  mock_resource "azurerm_container_registry" {
    defaults = {
      id = "/subscriptions/b8d7fc1c-6003-4425-baf0-15d8db0e1714/resourceGroups/rg-mongo-bench-dev/providers/Microsoft.ContainerRegistry/registries/mbacrdevtest"
    }
  }
  mock_resource "azurerm_resource_group" {
    defaults = {
      id = "/subscriptions/b8d7fc1c-6003-4425-baf0-15d8db0e1714/resourceGroups/rg-mongo-bench-dev-data"
    }
  }
}

override_resource {
  target = azurerm_user_assigned_identity.control_plane
  values = {
    id           = "/subscriptions/b8d7fc1c-6003-4425-baf0-15d8db0e1714/resourceGroups/rg-mongo-bench-dev/providers/Microsoft.ManagedIdentity/userAssignedIdentities/control-plane"
    principal_id = "33333333-3333-3333-3333-333333333333"
    client_id    = "55555555-5555-5555-5555-555555555555"
  }
}

override_resource {
  target = azurerm_user_assigned_identity.kubelet
  values = {
    id           = "/subscriptions/b8d7fc1c-6003-4425-baf0-15d8db0e1714/resourceGroups/rg-mongo-bench-dev/providers/Microsoft.ManagedIdentity/userAssignedIdentities/kubelet"
    principal_id = "44444444-4444-4444-4444-444444444444"
    client_id    = "77777777-7777-7777-7777-777777777777"
  }
}

override_resource {
  target = azurerm_kubernetes_cluster.dev
  values = {
    id          = "/subscriptions/b8d7fc1c-6003-4425-baf0-15d8db0e1714/resourceGroups/rg-mongo-bench-dev/providers/Microsoft.ContainerService/managedClusters/aks-mongo-bench-dev"
    kube_config = [{ host = "https://aks.example.test", cluster_ca_certificate = "dGVzdA==", client_certificate = "", client_key = "", username = "", password = "" }]
  }
}

run "azure_identity_and_data_isolation" {
  command = apply

  assert {
    condition     = azurerm_role_assignment.aks_acr_pull.principal_id == azurerm_user_assigned_identity.kubelet.principal_id && azurerm_role_assignment.aks_acr_pull.role_definition_name == "AcrPull" && azurerm_kubernetes_cluster.dev.kubelet_identity[0].object_id == azurerm_user_assigned_identity.kubelet.principal_id
    error_message = "Image pulls must use the kubelet identity, not the control-plane identity or a registry password."
  }
  assert {
    condition     = azurerm_role_assignment.aks_disk_access.principal_id == azurerm_user_assigned_identity.control_plane.principal_id && azurerm_role_assignment.aks_disk_access.scope == azurerm_resource_group.data.id
    error_message = "The control-plane identity needs disk access in the separate data resource group."
  }
  assert {
    condition     = azurerm_managed_disk.mongodb.resource_group_name != azurerm_kubernetes_cluster.dev.node_resource_group
    error_message = "Database data must not live in the disposable AKS node resource group."
  }
  assert {
    condition     = !azurerm_container_registry.dev.admin_enabled && azurerm_container_registry.dev.role_assignment_mode == "LegacyRegistryPermissions" && azurerm_kubernetes_cluster.dev.local_account_disabled
    error_message = "Use Entra sign-in with registry RBAC and no static admin credentials."
  }
  assert {
    condition     = length(azurerm_role_assignment.developer_namespace_writer) == 2 && length(azurerm_role_assignment.developer_acr_push) == 1
    error_message = "The local Terraform caller must get image-push and both namespace deployment permissions."
  }
}

run "additional_developer" {
  command = plan
  variables {
    developer_object_ids = ["66666666-6666-6666-6666-666666666666"]
  }
  assert {
    condition     = length(azurerm_role_assignment.developer_namespace_writer) == 4 && length(azurerm_role_assignment.developer_cluster_user) == 2 && length(azurerm_role_assignment.developer_acr_push) == 2
    error_message = "Additional developers need image-push, cluster-user, and namespace-scoped deployment permissions."
  }
}
