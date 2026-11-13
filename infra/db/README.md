# Database

Independent Terraform project for MongoDB in an existing dev AKS cluster. Owns the DB namespace, retained PV/PVC, MongoDB StatefulSet/Service/network policy, bootstrap Job, users, and generated credentials. The physical Azure disk belongs to `core`.

Apply core first. Db publishes the database name and a sensitive, database-scoped application URI for `app`. App releases do not apply this project.

From `infra/`: `./Invoke-TerraformDeploy.ps1 -Env dev -Project db -Plan`, review the plan, then run the same command with `-Apply`.

See the [infrastructure guide](../README.md) for deployment and persistence/recovery.
