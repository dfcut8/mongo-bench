# Core

Independent Terraform project for dev AKS, ACR, Azure identities/permissions, and the protected MongoDB disk. State storage is bootstrapped separately. Apply before `db` and `app`.

From `infra/`: `./Invoke-TerraformDeploy.ps1 -Env dev -Project core -Plan`, review the plan, then run the same command with `-Apply`.

See the [infrastructure guide](../README.md) for deployment, access, and validation.
