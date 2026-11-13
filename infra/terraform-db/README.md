# Database

Independent Terraform project for MongoDB in an existing dev AKS cluster. Owns the DB namespace, retained PV/PVC, MongoDB StatefulSet/Service/network policy, bootstrap Job, users, and generated credentials. The physical Azure disk belongs to `terraform-core-compute`.

Apply core-compute first. Db publishes the database name and a sensitive, database-scoped application URI for `terraform-app`. App releases do not apply this project.

From `infra/`: `terraform -chdir=terraform-db init`, then `plan` and `apply`.

See the [infrastructure guide](../README.md) for deployment and persistence/recovery.
