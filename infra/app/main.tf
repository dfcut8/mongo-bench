resource "kubernetes_namespace_v1" "app" {
  metadata {
    name = "mongo-bench-app-dev"
  }
}

resource "kubernetes_secret_v1" "app_database" {
  metadata {
    name      = "mongo-bench-database"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
  data = {
    # terraform_remote_state does not propagate output sensitivity annotations.
    MONGODB_URI      = sensitive(data.terraform_remote_state.database.outputs.application_mongodb_uri)
    MONGODB_DATABASE = data.terraform_remote_state.database.outputs.database_name
  }
}
