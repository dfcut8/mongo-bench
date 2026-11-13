mock_provider "kubernetes" {}
mock_provider "random" {}

override_data {
  target = data.terraform_remote_state.infrastructure
  values = {
    outputs = {
      aks_host                   = "https://aks.example.test"
      aks_cluster_ca_certificate = "dGVzdA=="
      tenant_id                  = "22222222-2222-2222-2222-222222222222"
      acr_name                   = "mbacrdevtest"
      acr_login_server           = "mbacrdevtest.azurecr.io"
      mongodb_disk_id            = "/subscriptions/b8d7fc1c-6003-4425-baf0-15d8db0e1714/resourceGroups/rg-mongo-bench-dev-data/providers/Microsoft.Compute/disks/mongo-bench-db-dev"
      mongodb_disk_size_gb       = 32
    }
  }
}

run "persistent_database" {
  command = plan

  assert {
    condition     = kubernetes_persistent_volume_v1.mongodb.spec[0].persistent_volume_reclaim_policy == "Retain" && kubernetes_persistent_volume_claim_v1.mongodb.spec[0].volume_name == "mongo-bench-db-dev"
    error_message = "The claim must reuse the retained static data volume."
  }
  assert {
    condition     = kubernetes_service_v1.mongodb.spec[0].type == "ClusterIP" && kubernetes_service_v1.mongodb.spec[0].cluster_ip == "None" && kubernetes_service_v1.mongodb.spec[0].publish_not_ready_addresses
    error_message = "Replica-set bootstrap needs internal DNS before primary readiness, without a public database endpoint."
  }
  assert {
    condition     = tonumber(kubernetes_stateful_set_v1.mongodb.spec[0].replicas) == 1 && contains(kubernetes_stateful_set_v1.mongodb.spec[0].template[0].spec[0].container[0].args, "--replSet") && !kubernetes_stateful_set_v1.mongodb.wait_for_rollout
    error_message = "Start one replica-set member without deadlocking Terraform on readiness before bootstrap."
  }
  assert {
    condition     = kubernetes_namespace_v1.db.metadata[0].name == "mongo-bench-db-dev"
    error_message = "Keep the database in its requested namespace."
  }
}
