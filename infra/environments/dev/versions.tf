terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    mongodbatlas = {
      source  = "mongodb/mongodbatlas"
      version = "~> 2.17.0"
    }
  }
}

provider "mongodbatlas" {}
