# Infrastructure

`environments/dev` is the Terraform root for the development environment. It creates an Atlas project, one Azure-backed Atlas Free (M0) replica set, and optional IP access-list entries. Future Azure resources such as ACR and AKS can be added as requirements are decided; none are created now.

## Prerequisites

- Terraform 1.5 or later, below 2.0, and Azure CLI signed into the correct tenant.
- An existing Azure Storage account and private blob container for Terraform state, provisioned separately from this Terraform root. The signed-in identity needs the Storage Blob Data Contributor role on the container (or an appropriate broader scope) and network access to the blob endpoint. The backend uses Microsoft Entra ID and Azure CLI authentication; see [backend documentation](https://developer.hashicorp.com/terraform/language/backend/azurerm).
- An existing MongoDB Atlas organization and a service account with permission to create and manage projects and their clusters and access lists. See [Atlas provider authentication](https://registry.terraform.io/providers/mongodb/mongodbatlas/latest/docs/guides/provider-configuration).
- An Azure region supported by Atlas Free, expressed as an Atlas region name. Check the [Atlas Azure region list](https://www.mongodb.com/docs/atlas/reference/microsoft-azure/) and choose the region with future service hosting in mind.

## Bootstrap Azure state storage

The bootstrap script creates a separate, locally redundant StorageV2 account, private container, and a container-scoped Storage Blob Data Contributor role assignment. It requires permission to create resource groups and storage accounts and to create role assignments. Storage has ongoing charges. The script enables HTTPS, TLS 1.2, blob versioning, and disables anonymous blob and shared-key access. The public storage endpoint remains enabled; access requires authorization and network connectivity.

Install [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell) (7.2 or later) and the [Az PowerShell modules](https://learn.microsoft.com/powershell/azure/install-azps-windows), then sign in. Run in PowerShell 7:

```powershell
Install-Module -Name Az -Repository PSGallery -Scope CurrentUser
Connect-AzAccount
```

From the repository root, run the script for an environment:

```powershell
./infra/Invoke-BootstrapTerraformStorage.ps1 -Env dev
```

`-Environment` (aliases `-Env` and `-EnvironmentName`) is the only project-specific parameter and is required. Environment names must contain 1–10 lowercase letters or digits. For `dev`, the script uses the Visual Studio Enterprise subscription (`b8d7fc1c-6003-4425-baf0-15d8db0e1714`) and `eastus`, and creates:

- Resource group `rg-mongo-bench-dev` (reused without modification if it already exists). This is the shared resource group for the dev environment and can also hold future Terraform-managed resources.
- Storage account `mbtfdev8d7fc1c` with container `tfstate-dev`.
- A Storage Blob Data Contributor role assignment for the signed-in Az PowerShell user, scoped to that container.

The environment name replaces `dev` in each name. Storage account names are globally unique; the dev name was available when checked but availability can change. The script stops if a generated name is unavailable, rather than modifying an existing account. If it fails partway through, inspect the created resources and finish setup or remove them explicitly before retrying. RBAC changes can take several minutes to propagate.

The script looks up the signed-in user's Entra object ID before creating resources. It exits with an error if the required environment is omitted, without prompting. Az PowerShell and Azure CLI use separate sign-in sessions, so sign in to both with the intended user identity before bootstrapping and initializing Terraform. The script logs backend resource names and does not run Terraform or migrate state. Only the `dev` Terraform root exists currently. Progress logs are JSON records; add `-Verbose` for detailed step and resource information. PowerShell prefixes verbose records with `VERBOSE:`.

## Deploy dev

From `infra/environments/dev`:

1. Copy `terraform.tfvars.example` to `terraform.tfvars`. Fill in the organization ID and Atlas region. Add specific trusted client CIDRs if database access is needed; the default empty list allows no client IPs. Do not use a public-wide CIDR.
2. Set `MONGODB_ATLAS_CLIENT_ID` and `MONGODB_ATLAS_CLIENT_SECRET` in your environment using your secret manager or shell. Do not put credentials in Terraform files or source control.
3. Sign in with `az login` and select the intended subscription with `az account set --subscription <subscription-id>`. The dev backend already contains the bootstrap storage account and container names. Run `terraform init`, `terraform validate`, and `terraform plan`. Review the plan, region, and current Atlas pricing, then run `terraform apply`.
4. Create a least-privilege database user separately in Atlas and store its credentials securely. Database users are not provisioned here to avoid putting their passwords in Terraform state. Add the actual client egress CIDR to the access list and apply before connecting. `terraform output connection_string_srv` prints the credential-free SRV address; configure the application with credentials securely.

Terraform stores dev state in an Azure Blob named `mongo-bench/dev/terraform.tfstate` and uses blob leases for locking. The backend storage account and container must exist before initialization: Terraform cannot create its own backend in this root. State can contain sensitive information; restrict access, protect the storage account, and configure suitable recovery; the bootstrap script enables blob versioning. Azure Storage may incur charges. Do not put secrets in backend configuration, as Terraform caches it and embeds it in saved plans. The provider lock file should be committed.

If an existing local state has resources, back it up securely first, then run `terraform init -migrate-state` and confirm migration. Verify `terraform state list` and a plan before removing the local backup. Do not use `-reconfigure` as a substitute for migration. If no state exists, use the normal initialization above.

Atlas Free has limitations: it permits only one free cluster per project, has no managed backups or private endpoints, and may pause after inactivity. Review [Free cluster limits](https://www.mongodb.com/docs/atlas/reference/free-shared-limitations/) and test transactions, indexes, and concurrent borrowing against the actual deployment before relying on it. It is intended for development, not production. A future tier upgrade can incur costs and require configuration changes.

`terraform destroy` deletes the dev project and cluster and their data. Review its plan carefully before running it.
