$ErrorActionPreference = "Stop"

Write-Host "=========================================="
Write-Host " AI BLUE-GREEN LAB - CREATE KIND CLUSTER"
Write-Host "=========================================="
Write-Host ""

$ClusterName = "ai-bluegreen"
$ContextName = "kind-ai-bluegreen"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$KindConfig = Join-Path $ProjectRoot "config\kind-config.yaml"

function Fail-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "[FAIL] $Message"
    exit 1
}

Write-Host "[INFO] Project root : $ProjectRoot"
Write-Host "[INFO] Cluster name : $ClusterName"
Write-Host "[INFO] Config file  : $KindConfig"
Write-Host ""

if (-not (Test-Path $KindConfig)) {
    Fail-Step "kind configuration file not found: $KindConfig"
}

docker info *> $null
if ($LASTEXITCODE -ne 0) {
    Fail-Step "Docker daemon is not reachable."
}
Write-Host "[PASS] Docker daemon is reachable."

Write-Host ""
Write-Host "[INFO] Checking for existing kind clusters..."

$ExistingClustersRaw = cmd /c "kind get clusters 2>nul"
$KindListExitCode = $LASTEXITCODE

if ($KindListExitCode -ne 0) {
    Fail-Step "Unable to query existing kind clusters."
}

$ExistingClusters = @(
    $ExistingClustersRaw |
    ForEach-Object { $_.ToString().Trim() } |
    Where-Object { $_ -and $_ -ne "No kind clusters found." }
)

if ($ExistingClusters -contains $ClusterName) {
    Write-Host "[INFO] Cluster '$ClusterName' already exists. Reusing existing cluster."
}
else {
    Write-Host "[INFO] Cluster '$ClusterName' does not exist."
    Write-Host "[INFO] Creating kind cluster '$ClusterName'..."

    kind create cluster `
        --name $ClusterName `
        --config $KindConfig `
        --wait 5m

    if ($LASTEXITCODE -ne 0) {
        Fail-Step "kind cluster creation failed."
    }

    Write-Host "[PASS] Cluster '$ClusterName' created successfully."
}

Write-Host ""
Write-Host "[INFO] Selecting Kubernetes context '$ContextName'..."
kubectl config use-context $ContextName | Out-Host

if ($LASTEXITCODE -ne 0) {
    Fail-Step "Unable to select Kubernetes context '$ContextName'."
}

$CurrentContext = (kubectl config current-context).Trim()

if ($LASTEXITCODE -ne 0 -or $CurrentContext -ne $ContextName) {
    Fail-Step "Unexpected Kubernetes context. Expected '$ContextName', found '$CurrentContext'."
}

Write-Host "[PASS] Current context is $CurrentContext."

Write-Host ""
Write-Host "[INFO] Waiting for all Kubernetes nodes to become Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=180s | Out-Host

if ($LASTEXITCODE -ne 0) {
    Fail-Step "One or more Kubernetes nodes did not become Ready within 180 seconds."
}

$NodeNames = @(
    kubectl get nodes -o name |
    ForEach-Object { $_.ToString().Trim() } |
    Where-Object { $_ -ne "" }
)

if ($LASTEXITCODE -ne 0) {
    Fail-Step "Unable to retrieve Kubernetes nodes."
}

if ($NodeNames.Count -ne 2) {
    Fail-Step "Expected 2 nodes, but found $($NodeNames.Count)."
}

Write-Host "[PASS] Two Kubernetes nodes detected."

Write-Host ""
Write-Host "------------------------------------------"
Write-Host " Cluster status"
Write-Host "------------------------------------------"
kubectl get nodes -o wide | Out-Host

if ($LASTEXITCODE -ne 0) {
    Fail-Step "Unable to retrieve final node status."
}

Write-Host ""
Write-Host "------------------------------------------"
Write-Host " Reserved host endpoints"
Write-Host "------------------------------------------"
Write-Host "Blue Active   : http://localhost:8081 -> NodePort 30081"
Write-Host "Green Preview : http://localhost:8082 -> NodePort 30082"

Write-Host ""
Write-Host "=========================================="
Write-Host "CLUSTER CREATION RESULT: PASS"
Write-Host "Cluster '$ClusterName' is ready."
Write-Host "=========================================="

exit 0
