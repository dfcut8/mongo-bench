resource "mongodbatlas_project" "dev" {
  name   = "mongo-bench-dev"
  org_id = var.atlas_org_id
}

resource "mongodbatlas_advanced_cluster" "dev" {
  project_id   = mongodbatlas_project.dev.id
  name         = "mongo-bench-dev"
  cluster_type = "REPLICASET"

  replication_specs = [{
    region_configs = [{
      provider_name         = "TENANT"
      backing_provider_name = "AZURE"
      region_name           = var.atlas_region
      priority              = 7
      electable_specs = {
        instance_size = "M0"
      }
    }]
  }]
}

resource "mongodbatlas_project_ip_access_list" "allowed" {
  for_each = var.allowed_cidrs

  project_id = mongodbatlas_project.dev.id
  cidr_block = each.key
  comment    = each.value
}
