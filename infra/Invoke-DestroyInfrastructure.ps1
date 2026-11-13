#Requires -Version 7.2
<#
.SYNOPSIS
Permanently deletes the mongo-bench dev infrastructure, including MongoDB data and Terraform state.
.DESCRIPTION
Requires the same Azure CLI sign-in, Terraform inputs, and AKS access as deployment.
Always asks for confirmation. Does not delete resources outside the three dev resource groups.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$SubscriptionId = 'b8d7fc1c-6003-4425-baf0-15d8db0e1714'
$ResourceGroupName = 'rg-mongo-bench-dev'
$StorageAccountName = 'mbtfdev8d7fc1c'
$ContainerName = 'tfstate-dev'
$ResourceGroups = @('rg-mongo-bench-dev-data', 'rg-mongo-bench-dev-nodes', $ResourceGroupName)
$Projects = @(
    @{ Name = 'app'; Protected = @{} },
    @{ Name = 'db'; Protected = @{
        kubernetes_namespace_v1 = 'db'
        kubernetes_secret_v1 = 'mongodb'
        kubernetes_persistent_volume_v1 = 'mongodb'
        kubernetes_persistent_volume_claim_v1 = 'mongodb'
    } },
    @{ Name = 'core'; Protected = @{
        azurerm_resource_group = 'data'
        azurerm_managed_disk = 'mongodb'
    } }
)

function Invoke-Azure {
    param([string[]] $Arguments)
    $result = & az @Arguments --subscription $SubscriptionId --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: az $($Arguments -join ' ')" }
    if ($result) { ($result -join "`n") | ConvertFrom-Json }
}

function Invoke-Terraform {
    param([string] $Directory, [string[]] $Arguments)
    & terraform "-chdir=$Directory" @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Terraform failed in $Directory : $($Arguments -join ' '). State storage has not been deleted."
    }
}

function Test-ResourceGroup {
    param([string] $Name)
    Invoke-Azure @('group', 'exists', '--name', $Name)
}

foreach ($command in @('az', 'terraform', 'kubelogin')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $command"
    }
}
# Injected CLI arguments can change the backend or make a destroy partial.
if (@(Get-ChildItem Env: | Where-Object Name -Like 'TF_CLI_ARGS*').Count -gt 0) {
    throw 'Unset TF_CLI_ARGS and TF_CLI_ARGS_* before running teardown.'
}
if ($env:TF_WORKSPACE -and $env:TF_WORKSPACE -ne 'default') {
    throw 'Teardown supports only the default Terraform workspace. Unset TF_WORKSPACE first.'
}
$account = Invoke-Azure @('account', 'show')
if ($account.id -ne $SubscriptionId) { throw 'Unable to select the dev subscription. Run az login first.' }

Write-Host "Subscription: $($account.name) ($SubscriptionId)"
Write-Host "Permanently delete ALL contents of: $($ResourceGroups -join ', ')"
Write-Host 'Order: app -> db -> core -> state storage resource group.'
Write-Host 'This includes all MongoDB data, container images, credentials, and Terraform state/version history.'
$confirmation = Read-Host 'Type DELETE mongo-bench-dev to confirm'
if ($confirmation -cne 'DELETE mongo-bench-dev') {
    Write-Host 'Cancelled. No resources changed.'
    return
}

$originalEnvironment = @{}
foreach ($name in @('TF_DATA_DIR', 'TF_WORKSPACE', 'ARM_SUBSCRIPTION_ID')) {
    $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$temporaryRoot = $null
$completed = $false
try {
    $env:ARM_SUBSCRIPTION_ID = $SubscriptionId
    $env:TF_WORKSPACE = 'default'
    $existingGroups = @($ResourceGroups | Where-Object { Test-ResourceGroup $_ })
    if ($existingGroups.Count -eq 0) {
        Write-Host 'The mongo-bench dev resource groups are already gone.'
        $completed = $true
        return
    }
    if ($ResourceGroupName -notin $existingGroups) {
        throw 'The state storage resource group is missing, but other dev groups remain. Recover state before continuing.'
    }
    $storageAccounts = @(Invoke-Azure @('storage', 'account', 'list', '--resource-group', $ResourceGroupName))
    if ($storageAccounts.Count -eq 0 -or $StorageAccountName -notin $storageAccounts.name) {
        throw 'The state storage account is missing. Recover state before continuing.'
    }

    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "mongo-bench-destroy-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null

    # Initialize and inspect every state before deleting anything. Empty/missing states
    # are skipped so an interrupted teardown can resume after its dependencies are gone.
    foreach ($project in $Projects) {
        $project.HasResources = $false
        $blobExists = Invoke-Azure @('storage', 'blob', 'exists', '--auth-mode', 'login',
            '--account-name', $StorageAccountName, '--container-name', $ContainerName,
            '--name', "mongo-bench/dev/$($project.Name).tfstate")
        if (-not $blobExists.exists) {
            Write-Host "$($project.Name): no state blob; skipping Terraform."
            continue
        }
        $source = Join-Path $PSScriptRoot $project.Name
        $directory = Join-Path $temporaryRoot $project.Name
        New-Item -ItemType Directory -Path $directory | Out-Null
        # Include local auto-loaded variable files and scripts, but no local state,
        # saved plans, or cached backend/workspace selections from .terraform/.
        Get-ChildItem -LiteralPath $source -File -Force | Where-Object {
            $_.Name -match '(\.tf|\.tf\.json|\.tfvars|\.tfvars\.json)$' -or $_.Name -eq '.terraform.lock.hcl'
        } | Copy-Item -Destination $directory
        $scripts = Join-Path $source 'scripts'
        if (Test-Path -LiteralPath $scripts) { Copy-Item -LiteralPath $scripts -Destination $directory -Recurse }

        if ($project.Protected.Count -gt 0) {
            $resources = @{}
            foreach ($type in $project.Protected.Keys) {
                $resources[$type] = @{ $project.Protected[$type] = @{ lifecycle = @{ prevent_destroy = $false } } }
            }
            # Terraform merges lifecycle arguments from override files. Source guards stay enabled.
            $overridePath = Join-Path $directory 'teardown_override.tf.json'
            if (Test-Path -LiteralPath $overridePath) { throw "Reserved override file already exists: $overridePath" }
            @{ resource = $resources } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $overridePath
        }
        $project.Directory = $directory
        $env:TF_DATA_DIR = Join-Path $directory '.terraform'
        Invoke-Terraform $directory @('init', '-input=false', '-reconfigure', '-lockfile=readonly', '-no-color',
            "-backend-config=subscription_id=$SubscriptionId", "-backend-config=resource_group_name=$ResourceGroupName") | Out-Host
        $entries = @(Invoke-Terraform $directory @('state', 'list'))
        $project.HasResources = $entries.Count -gt 0
    }

    foreach ($project in $Projects) {
        if (-not $project.HasResources) { continue }
        Write-Host "Destroying $($project.Name)..."
        $env:TF_DATA_DIR = Join-Path $project.Directory '.terraform'
        $arguments = @('destroy', '-auto-approve', '-input=false', '-lock-timeout=5m', '-no-color')
        if ($project.Name -eq 'core') { $arguments += "-var=subscription_id=$SubscriptionId" }
        Invoke-Terraform $project.Directory $arguments | Out-Host
        if (@(Invoke-Terraform $project.Directory @('state', 'list')).Count -gt 0) {
            throw "$($project.Name) still has state entries. State storage has not been deleted."
        }
    }

    # A lost/incorrect state must not cause a raw resource-group deletion of live
    # infrastructure. Only the bootstrap account may remain after all destroys.
    foreach ($group in $ResourceGroups) {
        if (-not (Test-ResourceGroup $group)) { continue }
        $remaining = @(Invoke-Azure @('resource', 'list', '--resource-group', $group))
        $unexpected = @($remaining | Where-Object {
            -not ($group -eq $ResourceGroupName -and $_.type -eq 'Microsoft.Storage/storageAccounts' -and $_.name -eq $StorageAccountName)
        })
        if ($unexpected.Count -gt 0) {
            throw "Resources remain in $group : $($unexpected.id -join ', '). State storage has not been deleted. Recover/import their state and retry."
        }
    }
    foreach ($group in $ResourceGroups) {
        if (-not (Test-ResourceGroup $group)) { continue }
        Write-Host "Deleting resource group $group..."
        # Synchronous: storage is in the final group, after both other groups are gone.
        Invoke-Azure @('group', 'delete', '--name', $group, '--yes') | Out-Null
        if (Test-ResourceGroup $group) { throw "Resource group $group still exists after deletion." }
    }
    $completed = $true
    Write-Host 'Deleted all mongo-bench dev resource groups, including MongoDB data and Terraform state storage.'
} finally {
    foreach ($name in $originalEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name], 'Process')
    }
    if ($temporaryRoot) {
        if ($completed) {
            $resolvedRoot = [IO.Path]::GetFullPath($temporaryRoot)
            $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
            if (-not $resolvedRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing to remove a directory outside the temporary folder: $resolvedRoot"
            }
            Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
        } else {
            Write-Warning "Teardown stopped. Temporary files kept at $temporaryRoot for recovery; they can contain credentials or emergency state. Resolve the error and rerun the script."
        }
    }
}
