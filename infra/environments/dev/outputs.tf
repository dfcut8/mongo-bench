output "atlas_project_id" {
  description = "Atlas dev project ID."
  value       = mongodbatlas_project.dev.id
}

output "cluster_name" {
  description = "Atlas dev cluster name."
  value       = mongodbatlas_advanced_cluster.dev.name
}

output "connection_string_srv" {
  description = "MongoDB SRV connection string without database credentials."
  value       = mongodbatlas_advanced_cluster.dev.connection_strings.standard_srv
}
