$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

foreach ($command in @('az', 'docker')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $command"
    }
}
if (-not (Test-Path -LiteralPath (Join-Path $env:MONGO_BENCH_BUILD_CONTEXT 'Dockerfile') -PathType Leaf)) {
    throw 'The application build context must contain a Dockerfile.'
}

& az acr login --name $env:MONGO_BENCH_ACR_NAME
if ($LASTEXITCODE -ne 0) { throw 'ACR sign-in failed. Check az login and the AcrPush role assignment.' }

& docker build --platform linux/amd64 --tag $env:MONGO_BENCH_IMAGE $env:MONGO_BENCH_BUILD_CONTEXT
if ($LASTEXITCODE -ne 0) { throw 'Application image build failed.' }

& docker push $env:MONGO_BENCH_IMAGE
if ($LASTEXITCODE -ne 0) { throw 'Application image push failed.' }
