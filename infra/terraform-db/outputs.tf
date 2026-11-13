output "database_namespace" {
  value = kubernetes_namespace_v1.db.metadata[0].name
}

output "mongodb_host" {
  description = "Cluster-internal replica set member address."
  value       = local.mongodb_host
}

output "database_name" {
  value = local.database
}

output "application_mongodb_uri" {
  description = "Database-scoped application credentials consumed by terraform-app. Protect access to database and application state."
  value       = "mongodb://mongo-bench:${random_password.app.result}@${local.mongodb_host}/${local.database}?authSource=${local.database}&replicaSet=rs0"
  sensitive   = true
}
