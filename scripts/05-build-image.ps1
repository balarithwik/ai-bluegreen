$ErrorActionPreference = "Stop"

Write-Host "=========================================="
Write-Host " AI BLUE-GREEN LAB - BUILD APPLICATION"
Write-Host "=========================================="
Write-Host ""

$ExpectedContext = "kind-ai-bluegreen"
$ClusterName = "ai-bluegreen"
$ImageName = "ai-bluegreen-demo"

# Jenkins supplies one unique release pair per build:
#   blue-YYYYMMDD-HHmmss-BUILD_NUMBER
#   green-YYYYMMDD-HHmmss-BUILD_NUMBER
#
# A local fallback keeps the script independently runnable outside Jenkins.
$FallbackBuildId = "$(Get-Date -Format 'yyyyMMdd-HHmmss')-local"

$BlueTag = if (-not [string]::IsNullOrWhiteSpace($env:BLUE_RELEASE_ID)) {
    $env:BLUE_RELEASE_ID
}
else {
    "blue-$FallbackBuildId"
}

$GreenTag = if (-not [string]::IsNullOrWhiteSpace($env:GREEN_RELEASE_ID)) {
    $env:GREEN_RELEASE_ID
}
else {
    "green-$FallbackBuildId"
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$AppDir = Join-Path $ProjectRoot "app"

function Fail-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "[FAIL] $Message"
    exit 1
}

Write-Host "[INFO] Project root : $ProjectRoot"
Write-Host "[INFO] Application  : $AppDir"
Write-Host "[INFO] Blue release : $BlueTag"
Write-Host "[INFO] Green release: $GreenTag"
Write-Host "[INFO] Blue image   : ${ImageName}:${BlueTag}"
Write-Host "[INFO] Green image  : ${ImageName}:${GreenTag}"
Write-Host ""

$CurrentContext = (kubectl config current-context).Trim()

if ($LASTEXITCODE -ne 0 -or $CurrentContext -ne $ExpectedContext) {
    Fail-Step "Expected Kubernetes context '$ExpectedContext', but found '$CurrentContext'."
}

Write-Host "[PASS] Kubernetes context is $CurrentContext."

if (-not (Test-Path (Join-Path $AppDir "Dockerfile"))) {
    Fail-Step "Dockerfile not found under '$AppDir'."
}

if (-not (Test-Path (Join-Path $AppDir "app.py"))) {
    Fail-Step "app.py not found under '$AppDir'."
}

if (-not (Test-Path (Join-Path $AppDir "requirements.txt"))) {
    Fail-Step "requirements.txt not found under '$AppDir'."
}

docker info *> $null
if ($LASTEXITCODE -ne 0) {
    Fail-Step "Docker daemon is not reachable."
}

Write-Host "[PASS] Docker daemon is reachable."

Write-Host ""
Write-Host "[INFO] Building Blue application image..."
docker build `
    -t "${ImageName}:${BlueTag}" `
    $AppDir | Out-Host

if ($LASTEXITCODE -ne 0) {
    Fail-Step "Docker build failed for ${ImageName}:${BlueTag}."
}

Write-Host "[PASS] Built ${ImageName}:${BlueTag}."

Write-Host ""
Write-Host "[INFO] Creating Green image tag from the validated application build..."
docker tag `
    "${ImageName}:${BlueTag}" `
    "${ImageName}:${GreenTag}"

if ($LASTEXITCODE -ne 0) {
    Fail-Step "Unable to create image tag ${ImageName}:${GreenTag}."
}

Write-Host "[PASS] Created ${ImageName}:${GreenTag}."

Write-Host ""
Write-Host "[INFO] Loading Blue image into kind cluster..."
kind load docker-image `
    "${ImageName}:${BlueTag}" `
    --name $ClusterName | Out-Host

if ($LASTEXITCODE -ne 0) {
    Fail-Step "Unable to load ${ImageName}:${BlueTag} into kind."
}

Write-Host "[PASS] Loaded ${ImageName}:${BlueTag}."

Write-Host ""
Write-Host "[INFO] Loading Green image into kind cluster..."
kind load docker-image `
    "${ImageName}:${GreenTag}" `
    --name $ClusterName | Out-Host

if ($LASTEXITCODE -ne 0) {
    Fail-Step "Unable to load ${ImageName}:${GreenTag} into kind."
}

Write-Host "[PASS] Loaded ${ImageName}:${GreenTag}."

Write-Host ""
Write-Host "------------------------------------------"
Write-Host " Local Docker images"
Write-Host "------------------------------------------"
docker images $ImageName | Out-Host

if ($LASTEXITCODE -ne 0) {
    Fail-Step "Unable to list local Docker images."
}

Write-Host ""
Write-Host "[INFO] Verifying images inside kind nodes..."

$KindNodes = @(
    kind get nodes --name $ClusterName |
    ForEach-Object { $_.ToString().Trim() } |
    Where-Object { $_ -ne "" }
)

if ($LASTEXITCODE -ne 0 -or $KindNodes.Count -eq 0) {
    Fail-Step "Unable to retrieve kind nodes."
}

foreach ($Node in $KindNodes) {
    Write-Host ""
    Write-Host "[INFO] Images on node: $Node"

    docker exec $Node crictl images | Select-String $ImageName | Out-Host

    if ($LASTEXITCODE -ne 0) {
        Fail-Step "Unable to verify images on kind node '$Node'."
    }
}

Write-Host ""
Write-Host "=========================================="
Write-Host "APPLICATION BUILD RESULT: PASS"
Write-Host "Blue image  : ${ImageName}:${BlueTag}"
Write-Host "Green image : ${ImageName}:${GreenTag}"
Write-Host "Cluster     : $ClusterName"
Write-Host "=========================================="

exit 0
