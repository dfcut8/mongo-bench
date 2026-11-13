# Infrastructure monorepo

`infra/` is the infrastructure repository root. Each project below is an independent Terraform root with its own providers, lock file, initialization, and Azure Blob state. All currently target dev in `northcentralus`. Production will get a separate cluster and states later.

```text
infra/
  terraform-core-compute/  AKS, ACR, managed identities, permissions, Azure disk
  terraform-db/            MongoDB, DB namespace, users, persistent volume bindings
  terraform-app/           App namespace, connection Secret, image publishing, service
  Invoke-BootstrapTerraformStorage.ps1
```

Apply in order: **core-compute → db → app**. Routine service releases run only `terraform-app`; that project reads database outputs without planning or changing database resources. Database image/configuration changes run `terraform-db` separately. These can be independent CI jobs/pipelines, with ordering required only when their prerequisites change.

| Project | State blob in `mbtfdev8d7fc1c` / `tfstate-dev` |
| --- | --- |
| `terraform-core-compute` | `mongo-bench/dev/core-compute.tfstate` |
| `terraform-db` | `mongo-bench/dev/db.tfstate` |
| `terraform-app` | `mongo-bench/dev/app.tfstate` |

## Resources

| Resource | Configuration |
| --- | --- |
| AKS | `aks-mongo-bench-dev`, Free control-plane tier, two `Standard_D4s_v5` Ubuntu nodes |
| ACR | Basic, deterministic subscription-specific name, admin password disabled |
| Database | Official `mongo:8.0.38` image, authenticated single-member `rs0` in `mongo-bench-db-dev` |
| Application | `mongo-bench-app-dev`; service deployment disabled until an image is configured |
| MongoDB data | 32 GiB Standard SSD Azure disk in `rg-mongo-bench-dev-data`, mounted at `/data/db` |

Core-compute owns the physical disk; db owns its Kubernetes PV/PVC and MongoDB. App owns only its namespace, connection Secret, optional service Deployment/Service, and local image publishing. Kubernetes API configuration comes from core-compute outputs. App obtains a database-scoped connection URI from db outputs, not database administrator credentials.

AKS Free refers to the control-plane tier. Nodes, node OS disks, database disk, ACR, networking, and state storage incur charges. Check North Central US VM availability and subscription quota before applying; rolling node upgrades need capacity for one extra node. The dev system node pool also hosts the workloads.

## Authentication and access

Core-compute configures these roles:

- AKS **kubelet user-assigned identity**: `AcrPull` on ACR, with no image-pull Secret or registry admin password.
- AKS **control-plane user-assigned identity**: `Managed Identity Operator` on the kubelet identity and `Contributor` on the dedicated data group for Azure Disk CSI attachment.
- Signed-in **Terraform caller**: `AcrPush`, `Azure Kubernetes Service Cluster User Role`, and `Azure Kubernetes Service RBAC Cluster Admin`, allowing initial namespace and cluster-scoped PV creation.
- Additional `developer_object_ids`: `AcrPush`, cluster-user credentials, and namespace-scoped `Azure Kubernetes Service RBAC Writer` in both dev namespaces. Writers can read Secrets and execute into pods; these are trusted dev operators.

AKS uses Microsoft Entra authentication and Azure RBAC; local accounts are disabled. Kubernetes providers use `kubelogin --login azurecli` for short-lived tokens. OIDC/Workload Identity are enabled for future Azure service access; image pulls use the kubelet identity.

The AKS API is public and requires Entra sign-in. Restrict it with `aks_api_allowed_cidrs` in core-compute if desired; an empty set leaves the authenticated endpoint publicly reachable. MongoDB has no public service. Its network policy permits TCP 27017 only from the app and database namespaces, enforced by Azure CNI Overlay with Cilium.

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

## Initial dev deployment

All inputs have dev defaults. Local `terraform.tfvars` files and saved plans are Git-ignored. Remove obsolete Atlas variables from existing local settings. Use each project's `terraform.tfvars.example` for its inputs; copy only if no local settings file exists.

```powershell
az login
az account set --subscription b8d7fc1c-6003-4425-baf0-15d8db0e1714

terraform -chdir=terraform-core-compute init
terraform -chdir=terraform-core-compute validate
terraform -chdir=terraform-core-compute plan -out=core-compute.tfplan
terraform -chdir=terraform-core-compute apply core-compute.tfplan

$aksName = terraform -chdir=terraform-core-compute output -raw aks_name
$resourceGroup = terraform -chdir=terraform-core-compute output -raw resource_group_name
az aks get-credentials --resource-group $resourceGroup --name $aksName --overwrite-existing
kubelogin convert-kubeconfig -l azurecli
kubectl get nodes

terraform -chdir=terraform-db init
terraform -chdir=terraform-db validate
terraform -chdir=terraform-db plan -out=db.tfplan
terraform -chdir=terraform-db apply db.tfplan
kubectl -n mongo-bench-db-dev get pods,pvc,jobs
kubectl -n mongo-bench-db-dev rollout status statefulset/mongodb --timeout=600s

terraform -chdir=terraform-app init
terraform -chdir=terraform-app validate
terraform -chdir=terraform-app plan -out=app.tfplan
terraform -chdir=terraform-app apply app.tfplan
```

Db initializes the root account on an empty disk, then runs a Job to initiate `rs0` and create the `mongo-bench` user with `readWrite` on `mongo_bench`. The job retries startup and preserves existing users/data when rerun. Db apply must complete before app reads its connection output. Inspect failed bootstrap logs with `kubectl -n mongo-bench-db-dev logs job/<bootstrap-job-name>`.

## Routine application releases

There is no Go service or Dockerfile yet. App creates its namespace and database connection Secret without a service image. The future service must listen on `HTTP_ADDR` (default `:8080`) and read `MONGODB_URI` and `MONGODB_DATABASE`.

Once the service has a Dockerfile at the service repository root, configure `terraform-app/terraform.tfvars`:

```hcl
application = {
  image_tag       = "dev-<git-commit-sha>"
  source_revision = "<git-commit-sha>"
  build_context   = "../.."
  port            = 8080
}
```

The build context is relative to the `terraform-app` project, so `../..` reaches the service repository root. For each release, update its unique tag/source revision, then run:

```powershell
terraform -chdir=terraform-app plan -out=app.tfplan
terraform -chdir=terraform-app apply app.tfplan
```

The optional local-exec provisioner signs into ACR using Azure CLI, builds Linux amd64, pushes `<acr-login-server>/mongo-bench:<image_tag>`, and only then updates the app Deployment. Build/push failure stops deployment; Terraform waits for the app rollout. Apply runs on the machine performing the build. Change tag/revision for every source change, including uncommitted changes; Terraform does not scan the build context and saved plans do not snapshot source files. App runs do not initialize, plan, or apply the database project.

For a manually built/pushed image, omit `build_context` and use the matching image tag:

```powershell
$acrName = terraform -chdir=terraform-core-compute output -raw acr_name
$acrServer = terraform -chdir=terraform-core-compute output -raw acr_login_server
az acr login --name $acrName
$image = "${acrServer}/mongo-bench:dev-<git-commit-sha>"
docker build --platform linux/amd64 --tag $image ..
docker push $image
# Set application.image_tag in terraform-app/terraform.tfvars, then apply app only.
```

The app exposes an internal ClusterIP service: `kubectl -n mongo-bench-app-dev port-forward service/mongo-bench 8080:80`. Public ingress/HTTPS are future work.

## Database updates and persistence

Change MongoDB image/configuration in `terraform-db`, then plan/apply **that project**. Image upgrades recreate the bootstrap Job while preserving the disk and users. Review MongoDB upgrade compatibility before changing versions. A regular app release does not run this project.

MongoDB mounts the same `mongodb-data` claim at `/data/db`. Its statically bound PV points to the Azure disk from core-compute, uses `Retain`, and has `ReadWriteOnce` access. Pod restarts, rescheduling, and image changes reuse the disk. One member owns the disk; scaling the StatefulSet is not a replication strategy.

`prevent_destroy` protects the data resource group and disk in core-compute and the DB namespace, PV, PVC, and bootstrap Secret in db. Normal full destroys are intentionally blocked. The disk lives outside `rg-mongo-bench-dev-nodes`, so cluster deletion does not delete it. Cluster recreation still requires recovery of Kubernetes resources and state/credentials against that disk. Clear a retained PV's old claim binding before manually rebinding a deleted PVC; never attach one disk to two live MongoDB instances. Disk expansion requires planned disk/PV/PVC/filesystem maintenance; do not shrink it.

Db state holds generated root/app passwords and the replica-set key. Its sensitive application URI output is copied by app into the app namespace's `mongo-bench-database` Secret. Both states therefore contain application credentials. App's remote-state access technically grants access to the entire db state, including administrator credentials; sensitivity hides normal CLI output, not backend contents. Keep backend access limited to trusted operators and preserve state/version history. Losing db state can regenerate credentials that do not match users on the retained disk. Updating a Secret alone is not a MongoDB password rotation.

Retention is not backup or high availability. Dev has one replica-set member, no automatic backups, restart/rescheduling downtime, and authenticated internal TCP without TLS. Production requires separate infrastructure, replication, tested backups/restores, TLS, and monitoring. To verify a live deployment, insert a test document, restart `mongodb-0`, wait for readiness, and read it again; also test committed and aborted multi-document transactions. Local mock tests do not prove Azure provisioning or disk reattachment.

## Local validation

Run from `infra/`. Isolated `TF_DATA_DIR` directories avoid touching configured backends, and `-backend=false` installs providers without reading/changing Azure state:

```powershell
foreach ($project in @('terraform-core-compute', 'terraform-db', 'terraform-app')) {
    $env:TF_DATA_DIR = Join-Path ([System.IO.Path]::GetTempPath()) "mongo-bench-check-$project"
    terraform "-chdir=$project" init -backend=false
    terraform "-chdir=$project" validate
    terraform "-chdir=$project" test
}
Remove-Item Env:TF_DATA_DIR
terraform fmt -check -recursive .
node --test terraform-db/tests/bootstrap-mongodb.test.cjs
```

Tests cover identity wiring, data isolation, retained static volume binding, MongoDB bootstrap ordering/retry/idempotency, separate app credentials, optional local publishing, and app-only deployment plans.
