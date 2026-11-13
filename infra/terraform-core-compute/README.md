# Core compute

Independent Terraform project for dev AKS, ACR, Azure identities/permissions, and the protected MongoDB disk. State storage is bootstrapped separately. Apply before `terraform-db` and `terraform-app`.

From `infra/`: `terraform -chdir=terraform-core-compute init`, then `plan` and `apply`.

See the [infrastructure guide](../README.md) for deployment, access, and validation.
