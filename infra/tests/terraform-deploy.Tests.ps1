#Requires -Version 7.2
# Standalone tests: pwsh -NoProfile -File infra/tests/terraform-deploy.Tests.ps1
# Terraform is mocked; no cloud access is performed.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "mongo-bench-deploy-tests-$([guid]::NewGuid())"
$fixture = Join-Path $testRoot 'infra with spaces'
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$deploymentScript = Join-Path $fixture 'Invoke-TerraformDeploy.ps1'
Copy-Item -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'Invoke-TerraformDeploy.ps1') -Destination $deploymentScript
foreach ($project in @('core', 'db', 'app')) {
    $directory = Join-Path $fixture $project
    New-Item -ItemType Directory -Path $directory | Out-Null
    Set-Content -LiteralPath (Join-Path $directory 'backend.tf') -Value '# mock backend'
}

$global:MongoBenchDeployTest = @{}
function terraform {
    $arguments = @($args)
    $global:LASTEXITCODE = 0
    Assert-True ($arguments[0] -like '-chdir=*') 'Terraform must select the project with -chdir.'
    $directory = $arguments[0].Substring('-chdir='.Length)
    $operation = $arguments[1]
    $global:MongoBenchDeployTest.Calls.Add(@{ Directory = $directory; Operation = $operation; Arguments = $arguments })
    Assert-True ($env:TF_DATA_DIR -eq (Join-Path $directory '.terraform')) 'Each project must have its own data directory.'
    Assert-True ($env:TF_WORKSPACE -eq 'default') 'Deployment must use the default workspace.'
    Assert-True ((Get-Location).Path -eq $testRoot) 'The caller location must not change.'
    switch ($operation) {
        'init' {
            Assert-True ($arguments -contains '-reconfigure') 'Init must use the configured backend rather than a cached backend.'
            Assert-True ($arguments -contains '-lockfile=readonly') 'Init must respect committed provider locks.'
        }
        'validate' {}
        'plan' {
            Assert-True ($arguments -contains '-out=dev.tfplan') 'Plan must save an environment-specific plan.'
            Set-Content -LiteralPath (Join-Path $directory 'dev.tfplan') -Value 'mock saved plan'
        }
        'apply' {
            Assert-True ($arguments[-1] -eq 'dev.tfplan') 'Apply must use the saved plan.'
            Assert-True ($arguments -notcontains '-auto-approve') 'Saved-plan apply needs no auto-approve flag.'
            Assert-True (Test-Path -LiteralPath (Join-Path $directory 'dev.tfplan') -PathType Leaf) 'Apply must have a saved plan.'
        }
        default { throw "Unexpected Terraform command: $arguments" }
    }
    if ($operation -ne 'validate') {
        Assert-True ($arguments -contains '-input=false') 'Terraform must not prompt for missing inputs.'
    }
    if ($operation -in @('plan', 'apply')) {
        Assert-True ($arguments -contains '-lock-timeout=5m') 'State locking must remain enabled.'
    }
    if ($operation -eq $global:MongoBenchDeployTest.Failure) { $global:LASTEXITCODE = 1 }
}

function Run-Scenario {
    param([string] $ScenarioName, [scriptblock] $Run, [scriptblock] $Verify, [string] $ExpectedError = '', [string] $Failure = '')
    $global:MongoBenchDeployTest.Calls = [Collections.Generic.List[hashtable]]::new()
    $global:MongoBenchDeployTest.Failure = $Failure
    $caught = ''
    try { & $Run | Out-Null } catch { $caught = $_.Exception.Message }
    if ($ExpectedError) {
        Assert-True ($caught -like "*$ExpectedError*") "$ScenarioName expected '$ExpectedError', got '$caught'."
    } else {
        Assert-True ($caught -eq '') "$ScenarioName failed: $caught"
    }
    Assert-True ($env:TF_DATA_DIR -eq 'original-deploy-data') 'TF_DATA_DIR must be restored.'
    Assert-True ($env:TF_WORKSPACE -eq 'original-workspace') 'TF_WORKSPACE must be restored.'
    Assert-True ((Get-Location).Path -eq $testRoot) 'The caller location must be restored.'
    & $Verify
    Write-Host "PASS: $ScenarioName"
}

$originalEnvironment = @{}
foreach ($item in Get-ChildItem Env: | Where-Object { $_.Name -like 'TF_*' }) {
    $originalEnvironment[$item.Name] = $item.Value
    Remove-Item -LiteralPath "Env:$($item.Name)"
}
Push-Location $testRoot
try {
    $env:TF_DATA_DIR = 'original-deploy-data'
    $env:TF_WORKSPACE = 'original-workspace'
    . $deploymentScript
    Assert-True ($global:MongoBenchDeployTest.Count -eq 0) 'Dot-sourcing must only load the function.'

    $projects = @{ 'core-infra' = 'core'; 'core' = 'core'; 'db' = 'db'; 'app' = 'app' }
    foreach ($name in $projects.Keys) {
        Run-Scenario "plan $name from another directory" {
            Invoke-TerraformDeploy -Env dev -Project $name -Plan
        } {
            $calls = $global:MongoBenchDeployTest.Calls
            Assert-True (($calls.Operation -join ',') -eq 'init,validate,plan') 'Plan must initialize, validate, and plan only.'
            Assert-True (@($calls | Where-Object Directory -ne (Join-Path $fixture $projects[$name])).Count -eq 0) 'Only the selected project may run.'
        }
    }
    Run-Scenario 'direct script invocation' {
        & $deploymentScript -Env dev -Project app -Plan
    } {
        Assert-True (($global:MongoBenchDeployTest.Calls.Operation -join ',') -eq 'init,validate,plan') 'Direct invocation must run the same commands.'
    }
    foreach ($name in @('core', 'db', 'app')) {
        Run-Scenario "apply $name saved plan" {
            Invoke-TerraformDeploy -Env dev -Project $name -Apply
        } {
            $calls = $global:MongoBenchDeployTest.Calls
            Assert-True (($calls.Operation -join ',') -eq 'init,validate,apply') 'Apply must not generate a new plan.'
            Assert-True (@($calls | Where-Object Directory -ne (Join-Path $fixture $projects[$name])).Count -eq 0) 'Apply must stay in the selected project.'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture "$($projects[$name])/dev.tfplan"))) 'Successfully applied plans must be removed.'
        }
    }
    Run-Scenario 'apply requires a plan for its own project' {
        Set-Content -LiteralPath (Join-Path $fixture 'db/dev.tfplan') -Value 'another project plan'
        Invoke-TerraformDeploy -Env dev -Project app -Apply
    } {
        Assert-True ($global:MongoBenchDeployTest.Calls.Count -eq 0) 'Missing plans must fail before Terraform runs.'
    } 'Saved plan not found'

    $invalidCalls = @(
        @{ Arguments = @{ Project = 'app'; Plan = $true }; Error = '-Env parameter is required' },
        @{ Arguments = @{ Env = 'dev'; Plan = $true }; Error = '-Project parameter is required' },
        @{ Arguments = @{ Env = 'dev'; Project = 'app' }; Error = 'exactly one' },
        @{ Arguments = @{ Env = 'dev'; Project = 'app'; Plan = $true; Apply = $true }; Error = 'exactly one' },
        @{ Arguments = @{ Env = 'prod'; Project = 'app'; Plan = $true }; Error = 'ValidateSet' },
        @{ Arguments = @{ Env = 'dev'; Project = '../db'; Plan = $true }; Error = 'ValidateSet' }
    )
    foreach ($case in $invalidCalls) {
        Run-Scenario "invalid arguments: $($case.Arguments | ConvertTo-Json -Compress)" {
            $parameters = $case.Arguments
            & $deploymentScript @parameters
        } {
            Assert-True ($global:MongoBenchDeployTest.Calls.Count -eq 0) 'Invalid arguments must not invoke Terraform.'
        } $case.Error
    }
    foreach ($operation in @('init', 'validate', 'plan')) {
        Run-Scenario "failed $operation discards stale or partial plan" {
            Set-Content -LiteralPath (Join-Path $fixture 'app/dev.tfplan') -Value 'stale plan'
            Invoke-TerraformDeploy -Env dev -Project app -Plan
        } {
            Assert-True ($global:MongoBenchDeployTest.Calls[-1].Operation -eq $operation) 'No commands may follow a Terraform failure.'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture 'app/dev.tfplan'))) 'Failed planning must leave no applicable plan.'
        } 'Terraform failed' $operation
    }
    Run-Scenario 'failed apply reports failure and preserves plan' {
        Set-Content -LiteralPath (Join-Path $fixture 'app/dev.tfplan') -Value 'saved plan'
        Invoke-TerraformDeploy -Env dev -Project app -Apply
    } {
        Assert-True ($global:MongoBenchDeployTest.Calls[-1].Operation -eq 'apply') 'The apply failure must stop deployment.'
        Assert-True (Test-Path -LiteralPath (Join-Path $fixture 'app/dev.tfplan')) 'A failed apply preserves its plan for inspection.'
    } 'Terraform failed' 'apply'

    foreach ($variable in @('TF_CLI_ARGS', 'TF_CLI_ARGS_plan', 'TF_CLI_ARGS_init')) {
        [Environment]::SetEnvironmentVariable($variable, '-destroy', 'Process')
        try {
            Run-Scenario "reject $variable overrides" {
                Invoke-TerraformDeploy -Env dev -Project app -Plan
            } {
                Assert-True ($global:MongoBenchDeployTest.Calls.Count -eq 0) 'Injected CLI arguments must fail before Terraform runs.'
            } 'Unset TF_CLI_ARGS'
        } finally {
            Remove-Item -LiteralPath "Env:$variable"
        }
    }
    Run-Scenario 'unset environment variables stay unset' {
        Remove-Item Env:TF_DATA_DIR, Env:TF_WORKSPACE
        Invoke-TerraformDeploy -Env DEV -Project APP -Plan
        Assert-True (-not (Test-Path Env:TF_DATA_DIR)) 'An originally absent TF_DATA_DIR must stay absent.'
        Assert-True (-not (Test-Path Env:TF_WORKSPACE)) 'An originally absent TF_WORKSPACE must stay absent.'
        $env:TF_DATA_DIR = 'original-deploy-data'
        $env:TF_WORKSPACE = 'original-workspace'
    } {}
} finally {
    Pop-Location
    foreach ($item in Get-ChildItem Env: | Where-Object { $_.Name -like 'TF_*' }) {
        Remove-Item -LiteralPath "Env:$($item.Name)"
    }
    foreach ($name in $originalEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name], 'Process') }
    Remove-Item Function:terraform, Function:Invoke-TerraformDeploy
    Remove-Variable MongoBenchDeployTest -Scope Global
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $testPrefix = Join-Path ([IO.Path]::GetTempPath()) 'mongo-bench-deploy-tests-'
    Assert-True ($resolvedTestRoot.StartsWith($testPrefix, [StringComparison]::OrdinalIgnoreCase)) 'Unexpected fixture cleanup path.'
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
}
