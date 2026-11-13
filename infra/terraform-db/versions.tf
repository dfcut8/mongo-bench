terraform {
  required_version = ">= 1.7.0, < 2.0.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}

data "terraform_remote_state" "infrastructure" {
  backend = "azurerm"
  config = {
    storage_account_name = "mbtfdev8d7fc1c"
    container_name       = "tfstate-dev"
    use_azuread_auth     = true
    key                  = "mongo-bench/dev/core-compute.tfstate"
  }
}

provider "kubernetes" {
  host                   = data.terraform_remote_state.infrastructure.outputs.aks_host
  cluster_ca_certificate = base64decode(data.terraform_remote_state.infrastructure.outputs.aks_cluster_ca_certificate)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "kubelogin"
    args = [
      "get-token", "--login", "azurecli",
      "--server-id", "6dae42f8-4368-4678-94ff-3960e28e3630",
      "--tenant-id", data.terraform_remote_state.infrastructure.outputs.tenant_id,
    ]
  }
}
