#Requires -Version 7.2
#Requires -Modules Az.Accounts, Az.Resources, Az.Storage
[CmdletBinding()]
param(
    [Alias('Env', 'EnvironmentName')]
    [ValidatePattern('(?-i)^[a-z0-9]{1,10}$')]
    [string] $Environment
)

if (-not $PSBoundParameters.ContainsKey('Environment')) {
    throw 'The -Env parameter is required (for example: -Env dev).'
}

$SubscriptionId = 'b8d7fc1c-6003-4425-baf0-15d8db0e1714'
$Location = 'eastus'
$ResourceGroupName = "rg-mongo-bench-$Environment"
$StorageAccountName = "mbtf${Environment}8d7fc1c"
$ContainerName = "tfstate-$Environment"

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-BootstrapLog {
    param(
        [ValidateSet('info', 'verbose')]
        [string] $Level,
        [string] $Event,
        [string] $Message,
        [hashtable] $Details = @{}
    )

    $entry = [ordered]@{
        timestamp = [DateTimeOffset]::UtcNow.ToString('o')
        level     = $Level
        event     = $Event
        message   = $Message
    }
    if ($Details.Count -gt 0) { $entry.details = $Details }
    $json = $entry | ConvertTo-Json -Compress -Depth 5
    if ($Level -eq 'verbose') { Write-Verbose $json } else { Write-Host $json }
}

$step = 'authentication'
try {
    Write-BootstrapLog info 'bootstrap.start' 'Starting Terraform storage bootstrap.' @{ subscription_id = $SubscriptionId; storage_account = $StorageAccountName }
    Write-BootstrapLog verbose 'authentication.check' 'Checking the Az PowerShell sign-in and selecting the subscription.'
    if (-not (Get-AzContext -Verbose:$false)) {
        throw 'Sign in first with Connect-AzAccount.'
    }
    $context = Set-AzContext -SubscriptionId $SubscriptionId -Verbose:$false
    Write-BootstrapLog verbose 'subscription.selected' 'Selected Azure subscription.' @{ name = $context.Subscription.Name; id = $context.Subscription.Id; tenant_id = $context.Tenant.Id }
    Write-BootstrapLog verbose 'principal.lookup' 'Looking up the signed-in Azure PowerShell user.'
    $signedInUser = Get-AzADUser -SignedIn -Verbose:$false
    if (-not $signedInUser -or -not $signedInUser.Id) {
        throw 'Unable to determine the signed-in user. Sign in with a user account using Connect-AzAccount.'
    }
    $TerraformPrincipalObjectId = [guid]$signedInUser.Id
    Write-BootstrapLog verbose 'principal.selected' 'Selected Terraform principal.' @{ principal_object_id = $TerraformPrincipalObjectId.ToString() }

    $step = 'name_availability'
    Write-BootstrapLog verbose 'storage.name_check' 'Checking global storage account name availability.' @{ name = $StorageAccountName }
    $availability = Get-AzStorageAccountNameAvailability -Name $StorageAccountName -Verbose:$false
    if (-not $availability.NameAvailable) {
        throw 'Storage account name is unavailable. The generated name is unavailable; existing accounts are not modified.'
    }
    Write-BootstrapLog verbose 'storage.name_available' 'Storage account name is available.'

    $step = 'resource_group'
    Write-BootstrapLog verbose 'resource_group.check' 'Checking for an existing resource group.' @{ name = $ResourceGroupName }
    $group = Get-AzResourceGroup -Verbose:$false | Where-Object ResourceGroupName -eq $ResourceGroupName
    if (-not $group) {
        Write-BootstrapLog info 'resource_group.create' 'Creating resource group.' @{ name = $ResourceGroupName; location = $Location }
        New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Confirm:$false -Verbose:$false | Out-Null
        Write-BootstrapLog verbose 'resource_group.created' 'Resource group created.' @{ name = $ResourceGroupName }
    } else {
        Write-BootstrapLog verbose 'resource_group.reused' 'Using existing resource group without modification.' @{ name = $ResourceGroupName; location = $group.Location }
    }

    $step = 'storage_account'
    Write-BootstrapLog info 'storage.create' 'Creating storage account.' @{ name = $StorageAccountName; location = $Location }
    Write-BootstrapLog verbose 'storage.configuration' 'Using StorageV2 with local redundancy, HTTPS, TLS 1.2, and no anonymous blob or shared-key access.' @{ sku = 'Standard_LRS'; kind = 'StorageV2' }
    $account = New-AzStorageAccount -ResourceGroupName $ResourceGroupName `
        -Name $StorageAccountName -Location $Location -SkuName Standard_LRS -Kind StorageV2 `
        -EnableHttpsTrafficOnly $true -MinimumTlsVersion TLS1_2 `
        -AllowBlobPublicAccess $false -AllowSharedKeyAccess $false -Verbose:$false
    Write-BootstrapLog verbose 'storage.created' 'Storage account created.' @{ resource_id = $account.Id }

    $step = 'blob_versioning'
    Write-BootstrapLog verbose 'versioning.enable' 'Enabling blob versioning.' @{ storage_account = $StorageAccountName }
    Update-AzStorageBlobServiceProperty -ResourceGroupName $ResourceGroupName `
        -StorageAccountName $StorageAccountName -IsVersioningEnabled $true -Confirm:$false -Verbose:$false | Out-Null
    Write-BootstrapLog verbose 'versioning.enabled' 'Blob versioning enabled.'

    $step = 'container'
    Write-BootstrapLog info 'container.create' 'Creating private state container.' @{ name = $ContainerName }
    Write-BootstrapLog verbose 'container.configuration' 'Creating container through the Azure management plane with public access disabled.'
    New-AzRmStorageContainer -ResourceGroupName $ResourceGroupName -StorageAccountName $StorageAccountName `
        -Name $ContainerName -PublicAccess None -Confirm:$false -Verbose:$false | Out-Null
    $containerScope = "$($account.Id)/blobServices/default/containers/$ContainerName"
    Write-BootstrapLog verbose 'container.created' 'Container created.' @{ resource_id = $containerScope }

    $step = 'role_assignment'
    Write-BootstrapLog info 'role.assign' 'Assigning Terraform principal access to the container.'
    Write-BootstrapLog verbose 'role.configuration' 'Assigning Storage Blob Data Contributor.' @{ principal_object_id = $TerraformPrincipalObjectId.ToString(); scope = $containerScope }
    New-AzRoleAssignment -ObjectId $TerraformPrincipalObjectId.ToString() `
        -RoleDefinitionName 'Storage Blob Data Contributor' -Scope $containerScope -Verbose:$false | Out-Null
    Write-BootstrapLog verbose 'role.assigned' 'Role assignment created.'

    Write-BootstrapLog info 'bootstrap.complete' 'Bootstrap complete. RBAC propagation may take several minutes.' @{ storage_account = $StorageAccountName; container = $ContainerName }
    Write-BootstrapLog info 'backend.ready' 'Use these resource names in the environment Terraform backend. The dev backend is already configured.' @{ storage_account = $StorageAccountName; container = $ContainerName }
} catch {
    Write-BootstrapLog info 'bootstrap.failed' 'Bootstrap failed; inspect the error and any resources already created.' @{ step = $step }
    throw
}
