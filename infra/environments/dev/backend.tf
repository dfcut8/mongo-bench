terraform {
  backend "azurerm" {
    storage_account_name = "mbtfdev8d7fc1c"
    container_name       = "tfstate-dev"
    use_azuread_auth     = true
    key                  = "mongo-bench/dev/terraform.tfstate"
  }
}
