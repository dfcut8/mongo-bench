#Requires -Version 7.2
# Standalone tests: pwsh -NoProfile -File infra/tests/destroy-infrastructure.Tests.ps1
# All Azure and Terraform commands are mocked; no cloud access is performed.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$global:MongoBenchDestroyTest = @{}

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "mongo-bench-destroy-tests-$([guid]::NewGuid())"
$fixture = Join-Path $testRoot 'infra'
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$infra = Split-Path $PSScriptRoot -Parent
Copy-Item -LiteralPath (Join-Path $infra 'Invoke-DestroyInfrastructure.ps1') -Destination $fixture
foreach ($project in @('app', 'db', 'core')) {
    $destination = Join-Path $fixture $project
    New-Item -ItemType Directory -Path $destination | Out-Null
    Get-ChildItem -LiteralPath (Join-Path $infra $project) -File -Force |
        Where-Object { $_.Name -match '\.tf$|^\.terraform\.lock\.hcl$' } |
        Copy-Item -Destination $destination
    New-Item -ItemType Directory -Path (Join-Path $destination 'scripts') | Out-Null
    Set-Content -LiteralPath (Join-Path $destination 'scripts/fixture.js') -Value '// fixture'
    Set-Content -LiteralPath (Join-Path $destination 'terraform.tfvars') -Value '# local inputs'
    Set-Content -LiteralPath (Join-Path $destination 'fixture.auto.tfvars.json') -Value '{}'
    Set-Content -LiteralPath (Join-Path $destination 'terraform.tfstate') -Value 'DO NOT COPY'
    New-Item -ItemType Directory -Path (Join-Path $destination '.terraform') | Out-Null
    Set-Content -LiteralPath (Join-Path $destination '.terraform/environment') -Value 'production'
}

function Read-Host { $global:MongoBenchDestroyTest.Events.Add('confirm'); $global:MongoBenchDestroyTest.Confirmation }
function kubelogin { throw 'kubelogin must only be invoked by the real Kubernetes provider.' }
function az {
    $arguments = @($args)
    $global:LASTEXITCODE = 0
    Assert-True ($arguments -contains '--subscription') 'Every Azure command must pin its subscription.'
    $operation = $arguments[0..1] -join ' '
    if ($operation -eq 'account show') {
        return '{"id":"b8d7fc1c-6003-4425-baf0-15d8db0e1714","name":"Test subscription"}'
    }
    $global:MongoBenchDestroyTest.Events.Add("az $operation")
    switch ($operation) {
        'group exists' {
            $name = $arguments[[Array]::IndexOf($arguments, '--name') + 1]
            return ($global:MongoBenchDestroyTest.Groups[$name] | ConvertTo-Json)
        }
        'storage account' { return '[{"name":"mbtfdev8d7fc1c"}]' }
        'storage blob' {
            $key = $arguments[[Array]::IndexOf($arguments, '--name') + 1]
            Assert-True ($key -in @('mongo-bench/dev/app.tfstate', 'mongo-bench/dev/db.tfstate', 'mongo-bench/dev/core-compute.tfstate')) 'Project renames must preserve deployed state blob keys.'
            $exists = $key -notin $global:MongoBenchDestroyTest.MissingBlobs
            return (@{ exists = $exists } | ConvertTo-Json)
        }
        'resource list' {
            $name = $arguments[[Array]::IndexOf($arguments, '--resource-group') + 1]
            if ($global:MongoBenchDestroyTest.Residual -and $name -eq 'rg-mongo-bench-dev-data') {
                return '[{"name":"untracked","type":"Microsoft.Compute/disks","id":"/untracked"}]'
            }
            if ($name -eq 'rg-mongo-bench-dev') {
                return '[{"name":"mbtfdev8d7fc1c","type":"Microsoft.Storage/storageAccounts","id":"/storage"}]'
            }
            return '[]'
        }
        'group delete' {
            $name = $arguments[[Array]::IndexOf($arguments, '--name') + 1]
            Assert-True (-not ($global:MongoBenchDestroyTest.States.Values -contains $true)) 'Group deletion started before Terraform was finished.'
            $global:MongoBenchDestroyTest.DeletedGroups.Add($name)
            $global:MongoBenchDestroyTest.Groups[$name] = $false
            if ($name -eq $global:MongoBenchDestroyTest.DeleteFailure) { $global:LASTEXITCODE = 1 }
            return
        }
        default { throw "Unexpected Azure command: $arguments" }
    }
}

function terraform {
    $arguments = @($args)
    $global:LASTEXITCODE = 0
    $directory = $arguments[0].Substring('-chdir='.Length)
    $project = Split-Path $directory -Leaf
    $operation = $arguments[1]
    $global:MongoBenchDestroyTest.Events.Add("$project $operation")
    Assert-True ($env:TF_DATA_DIR -eq (Join-Path $directory '.terraform')) 'Terraform must use an isolated data directory.'
    Assert-True ($env:TF_WORKSPACE -eq 'default') 'Terraform must use the default workspace.'
    Assert-True ($env:ARM_SUBSCRIPTION_ID -eq 'b8d7fc1c-6003-4425-baf0-15d8db0e1714') 'Terraform subscription must be pinned.'
    if ($operation -eq 'init') {
        $global:MongoBenchDestroyTest.TemporaryRoots.Add((Split-Path $directory -Parent)) | Out-Null
        Assert-True ($directory.StartsWith($testRoot) -eq $false) 'Execution must use a fresh temporary copy.'
        Assert-True (Test-Path -LiteralPath (Join-Path $directory 'terraform.tfvars')) 'Local inputs were not copied.'
        Assert-True (Test-Path -LiteralPath (Join-Path $directory 'fixture.auto.tfvars.json')) 'Auto-loaded JSON inputs were not copied.'
        Assert-True (Test-Path -LiteralPath (Join-Path $directory 'scripts/fixture.js')) 'Project scripts were not copied.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $directory 'terraform.tfstate'))) 'Local state must not be copied.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $directory '.terraform/environment'))) 'Cached workspace must not be copied.'
        $override = Join-Path $directory 'teardown_override.tf.json'
        if ($project -ne 'app') {
            $resources = (Get-Content -LiteralPath $override -Raw | ConvertFrom-Json -AsHashtable).resource
            foreach ($type in $resources.Values) {
                foreach ($resource in $type.Values) { Assert-True ($resource.lifecycle.prevent_destroy -eq $false) 'Destroy protection must be overridden.' }
            }
        }
        if ($project -eq $global:MongoBenchDestroyTest.InitFailure) { $global:LASTEXITCODE = 1; return }
        return 'Initialized mock backend'
    }
    if ($operation -eq 'state') {
        if ($global:MongoBenchDestroyTest.States[$project]) { return 'mock_resource.active' }
        return
    }
    if ($operation -eq 'destroy') {
        $global:MongoBenchDestroyTest.Destroyed.Add($project)
        Assert-True ($arguments -contains '-auto-approve') 'Only the script confirmation should be needed.'
        Assert-True ($arguments -contains '-lock-timeout=5m') 'State locking must remain enabled.'
        if ($project -eq 'core') {
            Assert-True ($arguments -contains '-var=subscription_id=b8d7fc1c-6003-4425-baf0-15d8db0e1714') 'Core destroy must pin the subscription input.'
        }
        if ($project -eq $global:MongoBenchDestroyTest.DestroyFailure) { $global:LASTEXITCODE = 1; return }
        if ($project -ne $global:MongoBenchDestroyTest.StuckState) { $global:MongoBenchDestroyTest.States[$project] = $false }
        return 'Destroyed mock resources'
    }
    throw "Unexpected Terraform command: $arguments"
}

function Run-Scenario {
    param([string] $Name, [scriptblock] $Configure, [scriptblock] $Verify, [string] $ExpectedError = '')
    $global:MongoBenchDestroyTest.Events = [Collections.Generic.List[string]]::new()
    $global:MongoBenchDestroyTest.Destroyed = [Collections.Generic.List[string]]::new()
    $global:MongoBenchDestroyTest.DeletedGroups = [Collections.Generic.List[string]]::new()
    $global:MongoBenchDestroyTest.TemporaryRoots = [Collections.Generic.HashSet[string]]::new()
    $global:MongoBenchDestroyTest.Confirmation = 'DELETE mongo-bench-dev'
    $global:MongoBenchDestroyTest.Groups = @{ 'rg-mongo-bench-dev' = $true; 'rg-mongo-bench-dev-data' = $true; 'rg-mongo-bench-dev-nodes' = $true }
    $global:MongoBenchDestroyTest.States = @{ 'app' = $true; 'db' = $true; 'core' = $true }
    $global:MongoBenchDestroyTest.DestroyFailure = ''
    $global:MongoBenchDestroyTest.InitFailure = ''
    $global:MongoBenchDestroyTest.DeleteFailure = ''
    $global:MongoBenchDestroyTest.StuckState = ''
    $global:MongoBenchDestroyTest.MissingBlobs = @()
    $global:MongoBenchDestroyTest.Residual = $false
    & $Configure
    $caught = ''
    try { & (Join-Path $fixture 'Invoke-DestroyInfrastructure.ps1') | Out-Null } catch { $caught = $_.Exception.Message }
    if ($ExpectedError) {
        Assert-True ($caught -like "*$ExpectedError*") "$Name expected '$ExpectedError', got '$caught'."
    } else {
        Assert-True ($caught -eq '') "$Name failed: $caught"
    }
    Assert-True ($env:TF_DATA_DIR -eq 'original-test-data') 'TF_DATA_DIR must be restored.'
    Assert-True ($env:ARM_SUBSCRIPTION_ID -eq 'original-test-subscription') 'ARM_SUBSCRIPTION_ID must be restored.'
    Assert-True ([string]::IsNullOrEmpty($env:TF_WORKSPACE)) 'TF_WORKSPACE must be restored.'
    & $Verify
    foreach ($root in $global:MongoBenchDestroyTest.TemporaryRoots) {
        Assert-True ((Test-Path -LiteralPath $root) -eq [bool]$ExpectedError) 'Temporary files must be retained only on failure.'
        # Remove only test-created, verified temporary directories after inspecting them.
        $resolved = [IO.Path]::GetFullPath($root)
        $prefix = Join-Path ([IO.Path]::GetTempPath()) 'mongo-bench-destroy-'
        Assert-True ($resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) 'Unexpected test cleanup path.'
        if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
    }
    Write-Host "PASS: $Name"
}

$originalEnvironment = @{}
foreach ($item in Get-ChildItem Env: | Where-Object { $_.Name -like 'TF_*' -or $_.Name -eq 'ARM_SUBSCRIPTION_ID' }) {
    $originalEnvironment[$item.Name] = $item.Value
    [Environment]::SetEnvironmentVariable($item.Name, $null, 'Process')
}
try {
    $env:TF_DATA_DIR = 'original-test-data'
    $env:ARM_SUBSCRIPTION_ID = 'original-test-subscription'
    Run-Scenario 'full teardown order and storage last' {} {
        Assert-True (($global:MongoBenchDestroyTest.Destroyed -join ',') -eq 'app,db,core') 'Wrong destroy order.'
        Assert-True (($global:MongoBenchDestroyTest.DeletedGroups -join ',') -eq 'rg-mongo-bench-dev-data,rg-mongo-bench-dev-nodes,rg-mongo-bench-dev') 'Storage must go last.'
        Assert-True ($global:MongoBenchDestroyTest.Events.IndexOf('confirm') -lt $global:MongoBenchDestroyTest.Events.IndexOf('app init')) 'Confirmation must precede initialization.'
        Assert-True ($global:MongoBenchDestroyTest.Events.IndexOf('core init') -lt $global:MongoBenchDestroyTest.Events.IndexOf('app destroy')) 'All backends must be checked before destruction.'
    }
    foreach ($answer in @('', 'yes', 'delete mongo-bench-dev')) {
        Run-Scenario "cancel with '$answer'" { $global:MongoBenchDestroyTest.Confirmation = $answer } {
            Assert-True ($global:MongoBenchDestroyTest.Destroyed.Count -eq 0 -and $global:MongoBenchDestroyTest.DeletedGroups.Count -eq 0) 'Cancellation must not delete anything.'
            Assert-True ($global:MongoBenchDestroyTest.Events.Count -eq 1) 'Cancellation must precede all infrastructure operations.'
        }
    }
    Run-Scenario 'database failure preserves core and storage' { $global:MongoBenchDestroyTest.DestroyFailure = 'db' } {
        Assert-True (($global:MongoBenchDestroyTest.Destroyed -join ',') -eq 'app,db') 'Core destroy must not start after DB failure.'
        Assert-True ($global:MongoBenchDestroyTest.DeletedGroups.Count -eq 0) 'No group deletion is allowed after Terraform failure.'
    } 'Terraform failed'
    Run-Scenario 'backend initialization failure prevents all deletion' { $global:MongoBenchDestroyTest.InitFailure = 'core' } {
        Assert-True ($global:MongoBenchDestroyTest.Destroyed.Count -eq 0 -and $global:MongoBenchDestroyTest.DeletedGroups.Count -eq 0) 'Backend failures must precede all destruction.'
    } 'Terraform failed'
    Run-Scenario 'missing state storage with remaining resources' { $global:MongoBenchDestroyTest.Groups['rg-mongo-bench-dev'] = $false } {
        Assert-True ($global:MongoBenchDestroyTest.Destroyed.Count -eq 0 -and $global:MongoBenchDestroyTest.DeletedGroups.Count -eq 0) 'Missing state storage must block destruction.'
    } 'state storage resource group is missing'
    Run-Scenario 'nonempty state stops teardown' { $global:MongoBenchDestroyTest.StuckState = 'app' } {
        Assert-True ($global:MongoBenchDestroyTest.Destroyed.Count -eq 1 -and $global:MongoBenchDestroyTest.DeletedGroups.Count -eq 0) 'Nonempty state must stop later stages.'
    } 'still has state entries'
    Run-Scenario 'resume after app and DB already destroyed' {
        $global:MongoBenchDestroyTest.States['app'] = $false
        $global:MongoBenchDestroyTest.States['db'] = $false
    } {
        Assert-True (($global:MongoBenchDestroyTest.Destroyed -join ',') -eq 'core') 'Empty states must be skipped without reading missing upstream outputs.'
    }
    Run-Scenario 'never-applied application' {
        $global:MongoBenchDestroyTest.MissingBlobs = @('mongo-bench/dev/app.tfstate')
        $global:MongoBenchDestroyTest.States['app'] = $false
    } {
        Assert-True (($global:MongoBenchDestroyTest.Destroyed -join ',') -eq 'db,core') 'Missing state must be skipped.'
    }
    Run-Scenario 'untracked resources preserve state storage' { $global:MongoBenchDestroyTest.Residual = $true } {
        Assert-True ($global:MongoBenchDestroyTest.DeletedGroups.Count -eq 0) 'Unexpected Azure resources must block group deletion.'
    } 'Resources remain'
    Run-Scenario 'data group deletion failure preserves storage' { $global:MongoBenchDestroyTest.DeleteFailure = 'rg-mongo-bench-dev-data' } {
        Assert-True (($global:MongoBenchDestroyTest.DeletedGroups -join ',') -eq 'rg-mongo-bench-dev-data') 'Storage deletion must not follow a group deletion failure.'
    } 'Azure CLI failed'
    Run-Scenario 'already destroyed' {
        foreach ($key in @($global:MongoBenchDestroyTest.Groups.Keys)) { $global:MongoBenchDestroyTest.Groups[$key] = $false }
    } {
        Assert-True ($global:MongoBenchDestroyTest.Destroyed.Count -eq 0 -and $global:MongoBenchDestroyTest.DeletedGroups.Count -eq 0) 'An already deleted environment needs no changes.'
    }
    foreach ($project in @('db', 'core')) {
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture "$project/teardown_override.tf.json"))) 'Source override file leaked.'
        Assert-True ([bool](Get-ChildItem (Join-Path $fixture "$project/*.tf") | Select-String 'prevent_destroy = true')) 'Source destroy guards must stay enabled.'
    }
} finally {
    foreach ($item in Get-ChildItem Env: | Where-Object { $_.Name -like 'TF_*' -or $_.Name -eq 'ARM_SUBSCRIPTION_ID' }) {
        [Environment]::SetEnvironmentVariable($item.Name, $null, 'Process')
    }
    foreach ($name in $originalEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name], 'Process') }
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $testPrefix = Join-Path ([IO.Path]::GetTempPath()) 'mongo-bench-destroy-tests-'
    Assert-True ($resolvedTestRoot.StartsWith($testPrefix, [StringComparison]::OrdinalIgnoreCase)) 'Unexpected fixture cleanup path.'
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
}
