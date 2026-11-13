# mongo-bench

The infrastructure monorepo lives under [infra/](infra/README.md), with `terraform-core-compute` for Azure resources, `terraform-db` for MongoDB, and `terraform-app` for service deployment. Setup for the dedicated dev AKS cluster, ACR, and persistent MongoDB is documented there. The proposed Go service design is in [docs/architecture.md](docs/architecture.md).
