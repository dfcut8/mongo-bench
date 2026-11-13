# Infrastructure monorepo

`infra/` is the infrastructure repository root. Each project below is an independent Terraform root with its own providers, lock file, initialization, and Azure Blob state. All currently target dev in `northcentralus`. Production will get a separate cluster and states later.

```text
infra/
  core/  AKS, ACR, managed identities, permissions, Azure disk
  db/    MongoDB, DB namespace, users, persistent volume bindings
  app/   App namespace, connection Secret, image publishing, service
  Invoke-BootstrapTerraformStorage.ps1
  Invoke-TerraformDeploy.ps1
  Invoke-DestroyInfrastructure.ps1
```

Apply in order: **core → db → app**. Routine service releases run only `app`; that project reads database outputs without planning or changing database resources. Database image/configuration changes run `db` separately. These can be independent CI jobs/pipelines, with ordering required only when their prerequisites change.

| Project | State blob in `mbtfdev8d7fc1c` / `tfstate-dev` |
| --- | --- |
| `core` | `mongo-bench/dev/core.tfstate` |
| `db` | `mongo-bench/dev/db.tfstate` |
| `app` | `mongo-bench/dev/app.tfstate` |

State keys match the project names. Existing deployments using `core-compute.tfstate` need the [one-time state migration](#migrate-the-legacy-core-state-key) below before deployment or teardown.

## Migrate the legacy core state key

Skip this section for a fresh deployment. If core was already deployed using `mongo-bench/dev/core-compute.tfstate`, migrate that state to `mongo-bench/dev/core.tfstate` **before running the deployment wrapper or teardown**. Pause all infrastructure runs for the migration. The wrapper uses `init -reconfigure`, which selects a backend without copying existing state; using it first would select an empty state at the new key.

Use the intended Azure CLI account/subscription and the default Terraform workspace, with `TF_DATA_DIR`, `TF_WORKSPACE`, and `TF_CLI_ARGS*` unset in this shell. From `infra/`, first initialize core against the old key explicitly, even if its local `.terraform/` cache is missing:

```powershell
az account set --subscription b8d7fc1c-6003-4425-baf0-15d8db0e1714
terraform -chdir=core init -reconfigure -lockfile=readonly -backend-config="key=mongo-bench/dev/core-compute.tfstate"
terraform -chdir=core state list
```

Stop if either command fails or the expected existing Azure resource addresses are absent. Back up the old state securely before continuing; it can contain credentials. If `core.tfstate` already contains resources, stop and reconcile both states instead of overwriting either.

Then let Terraform migrate to the new key checked into `core/backend.tf`, confirming its state-copy prompt:

```powershell
terraform -chdir=core init -migrate-state -lock-timeout=5m -lockfile=readonly
terraform -chdir=core state list
```

Both state listings must contain the same resource addresses. Do not use `-reconfigure` for this second init: [Terraform requires `-migrate-state` to copy the state](https://developer.hashicorp.com/terraform/cli/commands/init#backend-initialization). Discard any saved `dev.tfplan` files in all three projects, then generate fresh plans with the wrapper in core → db → app order. A state-key rename should not create or replace managed resources. Db and app now read core's new key; their own keys stay unchanged. Remote-state data-source labels also match their projects (`core` and `db`); these reads do not rename managed resources.

Keep the legacy blobs/version history until the migration and plans are verified. The older `mongo-bench/dev/terraform.tfstate` key predates the split into projects; it is not a fourth current project. Inspect its resource addresses before deciding how to archive or migrate it; do not merge it into core or delete it solely because its name is old.

## Resources

| Resource | Configuration |
| --- | --- |
| AKS | `aks-mongo-bench-dev`, Free control-plane tier, two `Standard_D4s_v5` Ubuntu nodes |
| ACR | Basic, deterministic subscription-specific name, admin password disabled |
| Database | Official `mongo:8.0.38` image, authenticated single-member `rs0` in `mongo-bench-db-dev` |
| Application | `mongo-bench-app-dev`; service deployment disabled until an image is configured |
| MongoDB data | 32 GiB Standard SSD Azure disk in `rg-mongo-bench-dev-data`, mounted at `/data/db` |

Core owns the physical disk; db owns its Kubernetes PV/PVC and MongoDB. App owns only its namespace, connection Secret, optional service Deployment/Service, and local image publishing. Kubernetes API configuration comes from core outputs. App obtains a database-scoped connection URI from db outputs, not database administrator credentials.

AKS Free refers to the control-plane tier. Nodes, node OS disks, database disk, ACR, networking, and state storage incur charges. Check North Central US VM availability and subscription quota before applying; rolling node upgrades need capacity for one extra node. The dev system node pool also hosts the workloads.

## Authentication and access

Core configures these roles:

- AKS **kubelet user-assigned identity**: `AcrPull` on ACR, with no image-pull Secret or registry admin password.
- AKS **control-plane user-assigned identity**: `Managed Identity Operator` on the kubelet identity and `Contributor` on the dedicated data group for Azure Disk CSI attachment.
- Signed-in **Terraform caller**: `AcrPush`, `Azure Kubernetes Service Cluster User Role`, and `Azure Kubernetes Service RBAC Cluster Admin`, allowing initial namespace and cluster-scoped PV creation.
- Additional `developer_object_ids`: `AcrPush`, cluster-user credentials, and namespace-scoped `Azure Kubernetes Service RBAC Writer` in both dev namespaces. Writers can read Secrets and execute into pods; these are trusted dev operators.

AKS uses Microsoft Entra authentication and Azure RBAC; local accounts are disabled. Kubernetes providers use `kubelogin --login azurecli` for short-lived tokens. OIDC/Workload Identity are enabled for future Azure service access; image pulls use the kubelet identity.

The AKS API is public and requires Entra sign-in. Restrict it with `aks_api_allowed_cidrs` in core if desired; an empty set leaves the authenticated endpoint publicly reachable. MongoDB has no public service. Its network policy permits TCP 27017 only from the app and database namespaces, enforced by Azure CNI Overlay with Cilium.

References: [AKS/ACR integration](https://learn.microsoft.com/azure/aks/cluster-container-registry-integration), [Azure RBAC for AKS](https://learn.microsoft.com/azure/aks/manage-azure-rbac), [static Azure Disk volumes](https://learn.microsoft.com/azure/aks/create-volume-azure-disk).

## Prerequisites and bootstrap

Install Terraform 1.7 or later (below 2.0), Azure CLI, kubectl, kubelogin, and PowerShell 7.2 or later. `az aks install-cli` can install kubectl/kubelogin; ensure they are on PATH. Local image builds also require Docker with a running Linux container engine. Node.js is needed only for bootstrap-script unit tests.

The infrastructure owner needs resource-creation and role-assignment permissions (for example, Contributor plus User Access Administrator at appropriate scopes), and Storage Blob Data Contributor on the private state container. Role assignments may take several minutes to propagate; retry the next stage after propagation if access is initially denied.

Commands in this document run **from `infra/`**. From the service repository root, first run `Set-Location infra`.

Skip bootstrap if state storage already exists. Otherwise:

```powershell
Install-Module -Name Az -Repository PSGallery -Scope CurrentUser
Connect-AzAccount
./Invoke-BootstrapTerraformStorage.ps1 -Env dev
```

Bootstrap selects subscription `b8d7fc1c-6003-4425-baf0-15d8db0e1714`, creates/reuses `rg-mongo-bench-dev`, creates state account `mbtfdev8d7fc1c` and private container `tfstate-dev`, and assigns the signed-in Az PowerShell user container-scoped Storage Blob Data Contributor. Storage uses HTTPS, TLS 1.2, blob versioning, no anonymous blobs, and no shared-key access. The script stops if its generated account name is unavailable and does not modify existing accounts; inspect partial creation before retrying. `-Env` is required; `-Verbose` adds detailed structured logs.

New bootstrap storage uses `northcentralus`; existing storage in `eastus` stays there. Compute/data locations are configured independently. Az PowerShell and Azure CLI have separate sessions; sign into both using the intended identity. Bootstrap stays outside the projects whose state it stores.

## Terraform deployment wrapper

Load the command once per PowerShell session (from `infra/`):

```powershell
. ./Invoke-TerraformDeploy.ps1
Invoke-TerraformDeploy -Env dev -Project core -Plan
Invoke-TerraformDeploy -Env dev -Project core -Apply
```

After loading, the command works from any directory without changing your current location. You can also run the script directly, for example `./infra/Invoke-TerraformDeploy.ps1 -Env dev -Project app -Plan` from the service repository root.

| `-Project` | Terraform root |
| --- | --- |
| `core` (also `core-infra`) | `core` |
| `db` | `db` |
| `app` | `app` |

`-Env` and `-Project` are required, with exactly one of `-Plan` or `-Apply`. Only `dev` is accepted because the Terraform backends and resources currently target dev; production needs separate configuration first. Each invocation initializes and validates only the selected project, using its committed provider lock file, checked-in backend, project-local `.terraform/` directory, and default workspace. Temporary `TF_DATA_DIR` and `TF_WORKSPACE` changes are restored afterward. Unset `TF_CLI_ARGS*` overrides before using the wrapper.

`-Plan` saves a Git-ignored `dev.tfplan` inside the selected project. Review the displayed plan, then use `-Apply` to apply that exact saved plan **without another approval prompt**. Apply requires a plan for that project and removes it after success. Planning removes any older plan first; failed planning leaves no saved plan to apply. Run `-Plan` again after changing inputs/configuration or recovering from a failed apply. Plans can contain credentials; protect them like Terraform state. Local `terraform.tfvars` and `*.auto.tfvars` files load normally from the project directory.

The wrapper deploys one project at a time. For initial setup, run plan/apply pairs in **core → db → app** order. For routine service releases, select only `app`.

## Initial dev deployment

All inputs have dev defaults. Local `terraform.tfvars` files and saved plans are Git-ignored. Remove obsolete Atlas variables from existing local settings. Use each project's `terraform.tfvars.example` for its inputs; copy only if no local settings file exists.

```powershell
az login
az account set --subscription b8d7fc1c-6003-4425-baf0-15d8db0e1714
. ./Invoke-TerraformDeploy.ps1

Invoke-TerraformDeploy -Env dev -Project core -Plan
Invoke-TerraformDeploy -Env dev -Project core -Apply

$aksName = terraform -chdir=core output -raw aks_name
$resourceGroup = terraform -chdir=core output -raw resource_group_name
az aks get-credentials --resource-group $resourceGroup --name $aksName --overwrite-existing
kubelogin convert-kubeconfig -l azurecli
kubectl get nodes

Invoke-TerraformDeploy -Env dev -Project db -Plan
Invoke-TerraformDeploy -Env dev -Project db -Apply
kubectl -n mongo-bench-db-dev get pods,pvc,jobs
kubectl -n mongo-bench-db-dev rollout status statefulset/mongodb --timeout=600s

Invoke-TerraformDeploy -Env dev -Project app -Plan
Invoke-TerraformDeploy -Env dev -Project app -Apply
```

Db initializes the root account on an empty disk, then runs a Job to initiate `rs0` and create the `mongo-bench` user with `readWrite` on `mongo_bench`. The job retries startup and preserves existing users/data when rerun. Db apply must complete before app reads its connection output. Inspect failed bootstrap logs with `kubectl -n mongo-bench-db-dev logs job/<bootstrap-job-name>`.

## Routine application releases

There is no Go service or Dockerfile yet. App creates its namespace and database connection Secret without a service image. The future service must listen on `HTTP_ADDR` (default `:8080`) and read `MONGODB_URI` and `MONGODB_DATABASE`.

Once the service has a Dockerfile at the service repository root, configure `app/terraform.tfvars`:

```hcl
application = {
  image_tag       = "dev-<git-commit-sha>"
  source_revision = "<git-commit-sha>"
  build_context   = "../.."
  port            = 8080
}
```

The build context is relative to the `app` project, so `../..` reaches the service repository root. For each release, update its unique tag/source revision, then run:

```powershell
. ./Invoke-TerraformDeploy.ps1
Invoke-TerraformDeploy -Env dev -Project app -Plan
Invoke-TerraformDeploy -Env dev -Project app -Apply
```

The optional local-exec provisioner signs into ACR using Azure CLI, builds Linux amd64, pushes `<acr-login-server>/mongo-bench:<image_tag>`, and only then updates the app Deployment. Build/push failure stops deployment; Terraform waits for the app rollout. Apply runs on the machine performing the build. Change tag/revision for every source change, including uncommitted changes; Terraform does not scan the build context and saved plans do not snapshot source files. App runs do not initialize, plan, or apply the database project.

For a manually built/pushed image, omit `build_context` and use the matching image tag:

```powershell
$acrName = terraform -chdir=core output -raw acr_name
$acrServer = terraform -chdir=core output -raw acr_login_server
az acr login --name $acrName
$image = "${acrServer}/mongo-bench:dev-<git-commit-sha>"
docker build --platform linux/amd64 --tag $image ..
docker push $image
# Set application.image_tag in app/terraform.tfvars, then apply app only.
```

The app exposes an internal ClusterIP service: `kubectl -n mongo-bench-app-dev port-forward service/mongo-bench 8080:80`. Public ingress/HTTPS are future work.

## Database updates and persistence

Change MongoDB image/configuration in `db`, then plan/apply **that project**. Image upgrades recreate the bootstrap Job while preserving the disk and users. Review MongoDB upgrade compatibility before changing versions. A regular app release does not run this project.

MongoDB mounts the same `mongodb-data` claim at `/data/db`. Its statically bound PV points to the Azure disk from core, uses `Retain`, and has `ReadWriteOnce` access. Pod restarts, rescheduling, and image changes reuse the disk. One member owns the disk; scaling the StatefulSet is not a replication strategy.

`prevent_destroy` protects the data resource group and disk in core and the DB namespace, PV, PVC, and bootstrap Secret in db. Normal full destroys are intentionally blocked; the explicit teardown script below overrides these guards in temporary copies. The disk lives outside `rg-mongo-bench-dev-nodes`, so cluster deletion does not delete it. Cluster recreation still requires recovery of Kubernetes resources and state/credentials against that disk. Clear a retained PV's old claim binding before manually rebinding a deleted PVC; never attach one disk to two live MongoDB instances. Disk expansion requires planned disk/PV/PVC/filesystem maintenance; do not shrink it.

Db state holds generated root/app passwords and the replica-set key. Its sensitive application URI output is copied by app into the app namespace's `mongo-bench-database` Secret. Both states therefore contain application credentials. App's remote-state access technically grants access to the entire db state, including administrator credentials; sensitivity hides normal CLI output, not backend contents. Keep backend access limited to trusted operators and preserve state/version history. Losing db state can regenerate credentials that do not match users on the retained disk. Updating a Secret alone is not a MongoDB password rotation.

Retention is not backup or high availability. Dev has one replica-set member, no automatic backups, restart/rescheduling downtime, and authenticated internal TCP without TLS. Production requires separate infrastructure, replication, tested backups/restores, TLS, and monitoring. To verify a live deployment, insert a test document, restart `mongodb-0`, wait for readiness, and read it again; also test committed and aborted multi-document transactions. Local mock tests do not prove Azure provisioning or disk reattachment.

## Complete dev teardown

From `infra/`, run:

```powershell
./Invoke-DestroyInfrastructure.ps1
```

The script displays subscription `b8d7fc1c-6003-4425-baf0-15d8db0e1714` and the three dev resource groups, then requires the exact confirmation `DELETE mongo-bench-dev`. This permanently deletes **all MongoDB data, ACR images, credentials, and Terraform state/version history**. It is scoped to this repository's dev environment: `rg-mongo-bench-dev`, `rg-mongo-bench-dev-data`, and `rg-mongo-bench-dev-nodes`. Other subscription resources are outside its scope. Do not run deployments concurrently with teardown.

Use PowerShell 7.2+, Terraform, Azure CLI signed in with `az login`, and kubelogin, with the same state/container permissions and AKS access used for deployment, plus permission to delete the bootstrap storage and resource group. Az PowerShell modules are not required. Keep the same local `terraform.tfvars` / `*.auto.tfvars` inputs used for deployment; inputs supplied previously with `-var-file` must be copied into an auto-loaded variable file first. The script supports the checked-in dev backends and default workspace, rejects `TF_CLI_ARGS*`, pins the Azure subscription, and restores any temporary environment-variable changes afterward.

After confirmation, it:

1. Creates isolated temporary copies of each project, including local auto-loaded inputs and scripts, and initializes their backends using the committed provider locks. Cached `.terraform/` settings and local state/plans are excluded.
2. Overrides `prevent_destroy` only in the temporary copies using Terraform [override files](https://developer.hashicorp.com/terraform/language/files/override); the repository's protections remain enabled.
3. Runs `terraform destroy` with automatic approval in **app → db → core** order, checking that each state is empty before continuing. AKS and upstream outputs remain available until their dependents have been destroyed.
4. Checks that no resources remain except the bootstrap state account. Unexpected resources stop cleanup and preserve state for recovery.
5. Deletes any empty data/node resource groups, then [deletes the bootstrap resource group synchronously](https://learn.microsoft.com/cli/azure/group#az-group-delete). Its storage account `mbtfdev8d7fc1c`, container, state blobs/history, and container role assignment go last. Each group's absence is verified before continuing.

On any command failure, the script stops before later stages. Empty or missing state blobs are skipped so you can rerun after a partial deployment or interrupted teardown; remaining untracked Azure resources still block storage deletion. Temporary files are removed on success and retained with their path on failure for recovery (they may contain credentials or emergency local state; protect them and remove them after recovery). If storage is already missing while other dev groups remain, recover state before retrying. Rebuilding after complete teardown starts with the storage bootstrap again.

## Local validation

Run from `infra/`. Isolated `TF_DATA_DIR` directories avoid touching configured backends, and `-backend=false` installs providers without reading/changing Azure state:

```powershell
foreach ($project in @('core', 'db', 'app')) {
    $env:TF_DATA_DIR = Join-Path ([System.IO.Path]::GetTempPath()) "mongo-bench-check-$project"
    terraform "-chdir=$project" init -backend=false
    terraform "-chdir=$project" validate
    terraform "-chdir=$project" test
}
Remove-Item Env:TF_DATA_DIR
terraform fmt -check -recursive .
node --test db/tests/bootstrap-mongodb.test.cjs
pwsh -NoProfile -File tests/terraform-deploy.Tests.ps1
pwsh -NoProfile -File tests/destroy-infrastructure.Tests.ps1
```

Tests cover identity wiring, data isolation, retained static volume binding, MongoDB bootstrap ordering/retry/idempotency, separate app credentials, optional local publishing, app-only deployment plans, deployment-wrapper project selection/saved plans/failure handling, and teardown confirmation/ordering/failure recovery. The PowerShell tests mock all Azure and Terraform commands and make no cloud changes.
