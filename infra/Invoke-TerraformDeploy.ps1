#Requires -Version 7.2
<#
.SYNOPSIS
Plans or applies one mongo-bench Terraform project.
.DESCRIPTION
Run this script directly, or dot-source it once to load Invoke-TerraformDeploy.
Only dev is configured. Plan saves dev.tfplan in the selected project; Apply
requires that saved plan and applies it without another approval prompt.
.EXAMPLE
. ./infra/Invoke-TerraformDeploy.ps1
Invoke-TerraformDeploy -Env dev -Project core -Plan
Invoke-TerraformDeploy -Env dev -Project core -Apply
.EXAMPLE
./infra/Invoke-TerraformDeploy.ps1 -Env dev -Project app -Plan
#>
[CmdletBinding()]
param(
    [string] $Env,
    [string] $Project,
    [switch] $Plan,
    [switch] $Apply
)

function Invoke-TerraformDeploy {
    [CmdletBinding()]
    param(
        [ValidateSet('dev')]
        [string] $Env,
        [ValidateSet('core', 'core-infra', 'db', 'app')]
        [string] $Project,
        [switch] $Plan,
        [switch] $Apply
    )

    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest

    if (-not $Env) { throw 'The -Env parameter is required (currently: dev). Only dev infrastructure is configured.' }
    if (-not $Project) { throw 'The -Project parameter is required: core, db, or app (core-infra is an alias for core).' }
    if ([bool]$Plan -eq [bool]$Apply) { throw 'Specify exactly one of -Plan or -Apply.' }

    $projects = @{
        'core'       = 'core'
        'core-infra' = 'core'
        'db'         = 'db'
        'app'        = 'app'
    }
    $directory = Join-Path $PSScriptRoot $projects[$Project]
    $planName = "$($Env.ToLowerInvariant()).tfplan"
    $planPath = Join-Path $directory $planName
    if (-not (Test-Path -LiteralPath (Join-Path $directory 'backend.tf') -PathType Leaf)) {
        throw "Terraform project not found: $directory"
    }
    if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
        throw 'Required command not found: terraform'
    }
    # Keep the selected project's backend and the requested action authoritative.
    if (@(Get-ChildItem Env: | Where-Object Name -Like 'TF_CLI_ARGS*').Count -gt 0) {
        throw 'Unset TF_CLI_ARGS and TF_CLI_ARGS_* before running deployment.'
    }
    if ($Apply -and -not (Test-Path -LiteralPath $planPath -PathType Leaf)) {
        throw "Saved plan not found: $planPath. Run -Env $Env -Project $Project -Plan first."
    }
    if ($Plan -and (Test-Path -LiteralPath $planPath)) {
        # An unsuccessful new plan must never leave an older plan available to apply.
        Remove-Item -LiteralPath $planPath -Force
    }

    function Invoke-ProjectTerraform {
        param([string[]] $Arguments)
        & terraform "-chdir=$directory" @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "Terraform failed (exit code $LASTEXITCODE) in $directory : $($Arguments -join ' ')"
        }
    }

    $originalEnvironment = @{}
    foreach ($name in @('TF_DATA_DIR', 'TF_WORKSPACE')) {
        $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    try {
        # These projects have separate state keys; environments do not use workspaces.
        $env:TF_DATA_DIR = Join-Path $directory '.terraform'
        $env:TF_WORKSPACE = 'default'
        Write-Host "Project: $($projects[$Project]); environment: $Env; workspace: default"
        Invoke-ProjectTerraform @('init', '-reconfigure', '-input=false', '-lockfile=readonly')
        Invoke-ProjectTerraform @('validate')
        if ($Plan) {
            Invoke-ProjectTerraform @('plan', '-input=false', '-lock-timeout=5m', "-out=$planName")
            Write-Host "Saved plan: $planPath"
            Write-Host "To apply: Invoke-TerraformDeploy -Env $Env -Project $Project -Apply"
        } else {
            Invoke-ProjectTerraform @('apply', '-input=false', '-lock-timeout=5m', $planName)
            Remove-Item -LiteralPath $planPath -Force
            Write-Host 'Deployment complete. Applied plan removed; run -Plan before the next deployment.'
        }
    } catch {
        if ($Plan -and (Test-Path -LiteralPath $planPath)) {
            Remove-Item -LiteralPath $planPath -Force
        }
        throw
    } finally {
        foreach ($name in $originalEnvironment.Keys) {
            if ($null -eq $originalEnvironment[$name]) {
                Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
            } else {
                [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name], 'Process')
            }
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-TerraformDeploy @PSBoundParameters
}
