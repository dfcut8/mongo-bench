mock_provider "kubernetes" {}

override_data {
  target = data.terraform_remote_state.core
  values = {
    outputs = {
      aks_host                   = "https://aks.example.test"
      aks_cluster_ca_certificate = "dGVzdA=="
      tenant_id                  = "22222222-2222-2222-2222-222222222222"
      acr_name                   = "mbacrdevtest"
      acr_login_server           = "mbacrdevtest.azurecr.io"
    }
  }
}

override_data {
  target = data.terraform_remote_state.db
  values = {
    outputs = {
      database_name           = "mongo_bench"
      application_mongodb_uri = "mongodb://mongo-bench:test-only@mongodb-0.mongodb.mongo-bench-db-dev.svc.cluster.local:27017/mongo_bench?authSource=mongo_bench&replicaSet=rs0"
    }
  }
}

run "application_namespace_without_image" {
  command = plan
  assert {
    condition     = data.terraform_remote_state.core.config.key == regex("key\\s*=\\s*\"([^\"]+)\"", file("${path.module}/../core/backend.tf"))[0]
    error_message = "App must read the state written by the core project."
  }
  assert {
    condition     = data.terraform_remote_state.db.config.key == regex("key\\s*=\\s*\"([^\"]+)\"", file("${path.module}/../db/backend.tf"))[0]
    error_message = "App must read the state written by the db project."
  }
  assert {
    condition     = kubernetes_namespace_v1.app.metadata[0].name == "mongo-bench-app-dev" && length(kubernetes_deployment_v1.application) == 0 && length(terraform_data.publish_application) == 0
    error_message = "Create the application namespace without requiring a service image or Docker build."
  }
  assert {
    condition     = kubernetes_secret_v1.app_database.data.MONGODB_DATABASE == "mongo_bench" && strcontains(nonsensitive(kubernetes_secret_v1.app_database.data.MONGODB_URI), "mongodb://mongo-bench:")
    error_message = "Application credentials must come from the separate database project."
  }
}

run "deploy_prebuilt_image" {
  command = plan
  variables {
    application = { image_tag = "dev-test123" }
  }
  assert {
    condition     = kubernetes_deployment_v1.application[0].spec[0].template[0].spec[0].container[0].image == "mbacrdevtest.azurecr.io/mongo-bench:dev-test123" && length(terraform_data.publish_application) == 0
    error_message = "Deploy the selected ACR tag without requiring a local Docker build."
  }
}

run "build_before_deployment" {
  command = plan
  variables {
    application = { image_tag = "dev-test456", source_revision = "test456", build_context = "../.." }
  }
  assert {
    condition     = length(terraform_data.publish_application) == 1 && length(kubernetes_deployment_v1.application) == 1 && terraform_data.publish_application[0].triggers_replace[2] == abspath("${path.module}/../..")
    error_message = "Local builds must publish before deployment and resolve the build context to the service repository."
  }
}
