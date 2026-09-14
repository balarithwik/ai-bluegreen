$ErrorActionPreference = "Stop"

Write-Host "=========================================="
Write-Host " AI BLUE-GREEN LAB - DEPLOY BLUE BASELINE"
Write-Host "=========================================="
Write-Host ""

$ExpectedContext = "kind-ai-bluegreen"
$Namespace = "ai-bluegreen"
$RolloutName = "ai-bluegreen-rollout"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$K8sDir = Join-Path $ProjectRoot "k8s"

$NamespaceFile = Join-Path $K8sDir "namespace.yaml"
$ActiveServiceFile = Join-Path $K8sDir "active-service.yaml"
$PreviewServiceFile = Join-Path $K8sDir "preview-service.yaml"
$ServiceMonitorFile = Join-Path $K8sDir "servicemonitor.yaml"
$RolloutFile = Join-Path $K8sDir "rollout.yaml"

$BlueReleaseId = if (-not [string]::IsNullOrWhiteSpace($env:BLUE_RELEASE_ID)) {
    $env:BLUE_RELEASE_ID
}
else {
    "v1"
}

$BlueImage = "ai-bluegreen-demo:$BlueReleaseId"

function Fail-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "[FAIL] $Message"
    exit 1
}

Write-Host "[INFO] Project root : $ProjectRoot"
Write-Host "[INFO] Namespace    : $Namespace"
Write-Host "[INFO] Rollout      : $RolloutName"
Write-Host "[INFO] Blue release : $BlueReleaseId"
Write-Host "[INFO] Blue image   : $BlueImage"
Write-Host ""

$CurrentContext = (kubectl config current-context).Trim()

if ($LASTEXITCODE -ne 0 -or $CurrentContext -ne $ExpectedContext) {
    Fail-Step "Expected Kubernetes context '$ExpectedContext', but found '$CurrentContext'."
}

Write-Host "[PASS] Kubernetes context is $CurrentContext."

$RequiredFiles = @(
    $NamespaceFile,
    $ActiveServiceFile,
    $PreviewServiceFile,
    $ServiceMonitorFile,
    $RolloutFile
)

foreach ($File in $RequiredFiles) {
    if (-not (Test-Path $File)) {
        Fail-Step "Required Kubernetes file not found: $File"
    }
}

Write-Host "[PASS] Required Kubernetes manifests found."

Write-Host ""
Write-Host "[INFO] Applying Blue-Green namespace..."
kubectl apply -f $NamespaceFile | Out-Host
if ($LASTEXITCODE -ne 0) {
    Fail-Step "Unable to apply namespace manifest."
}

Write-Host ""
Write-Host "[INFO] Applying Active and Preview services..."
kubectl apply -f $ActiveServiceFile | Out-Host
if ($LASTEXITCODE -ne 0) {
    Fail-Step "Unable to apply Active Service."
}

kubectl apply -f $PreviewServiceFile | Out-Host
if ($LASTEXITCODE -ne 0) {
    Fail-Step "Unable to apply Preview Service."
}

Write-Host "[PASS] Blue-Green services applied."

Write-Host ""
Write-Host "[INFO] Applying ServiceMonitor..."
kubectl apply -f $ServiceMonitorFile | Out-Host
if ($LASTEXITCODE -ne 0) {
    Fail-Step "Unable to apply ServiceMonitor."
}

Write-Host "[PASS] ServiceMonitor applied."

Write-Host ""
Write-Host "[INFO] Rendering initial BLUE Rollout with release image: $BlueImage"

$RenderedBlueRollout = Join-Path $env:TEMP "ai-bluegreen-rollout-blue-$PID.yaml"
$BlueRolloutYaml = Get-Content $RolloutFile -Raw

if ($BlueRolloutYaml -notmatch 'image:\s*ai-bluegreen-demo:[^\s]+') {
    Fail-Step "Unable to locate application image in BLUE Rollout manifest."
}

$BlueRolloutYaml = $BlueRolloutYaml -replace `
    'image:\s*ai-bluegreen-demo:[^\s]+', `
    "image: $BlueImage"

$BlueRolloutYaml | Set-Content $RenderedBlueRollout -Encoding UTF8

Write-Host "[INFO] Applying initial BLUE Rollout..."
kubectl apply -f $RenderedBlueRollout | Out-Host
$BlueApplyRc = $LASTEXITCODE

Remove-Item $RenderedBlueRollout -Force -ErrorAction SilentlyContinue

if ($BlueApplyRc -ne 0) {
    Fail-Step "Unable to apply Argo Rollout."
}

Write-Host "[PASS] Initial Rollout manifest applied with release '$BlueReleaseId'."

Write-Host ""
Write-Host "[INFO] Waiting for Argo Rollout to become healthy..."
kubectl argo rollouts status `
    --timeout 180s `
    $RolloutName `
    -n $Namespace | Out-Host

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "[INFO] Current rollout details:"
    kubectl argo rollouts get rollout $RolloutName -n $Namespace | Out-Host
    Fail-Step "Initial BLUE Rollout did not become healthy."
}

Write-Host "[PASS] Initial BLUE Rollout is healthy."

Write-Host ""
Write-Host "[INFO] Waiting for application pods..."
kubectl wait `
    --for=condition=Ready `
    pod `
    -l app=ai-bluegreen-demo `
    -n $Namespace `
    --timeout=180s | Out-Host

if ($LASTEXITCODE -ne 0) {
    Fail-Step "Application pods did not become Ready."
}

Write-Host "[PASS] Application pods are Ready."

Write-Host ""
Write-Host "[INFO] Validating Active endpoint: http://localhost:8081/health"

try {
    $ActiveHealth = Invoke-RestMethod `
        -Uri "http://localhost:8081/health" `
        -Method Get `
        -TimeoutSec 10
}
catch {
    Fail-Step "Unable to reach Blue Active endpoint on localhost:8081. $($_.Exception.Message)"
}

if ($ActiveHealth.status -ne "UP" -or $ActiveHealth.version -ne "v1-healthy") {
    Fail-Step "Unexpected Active response. Status='$($ActiveHealth.status)', Version='$($ActiveHealth.version)'."
}

Write-Host "[PASS] Active Service is serving BLUE version: $($ActiveHealth.version)"

Write-Host ""
Write-Host "[INFO] Validating Preview endpoint: http://localhost:8082/health"

try {
    $PreviewHealth = Invoke-RestMethod `
        -Uri "http://localhost:8082/health" `
        -Method Get `
        -TimeoutSec 10
}
catch {
    Fail-Step "Unable to reach Preview endpoint on localhost:8082. $($_.Exception.Message)"
}

if ($PreviewHealth.status -ne "UP" -or $PreviewHealth.version -ne "v1-healthy") {
    Fail-Step "Unexpected Preview response. Status='$($PreviewHealth.status)', Version='$($PreviewHealth.version)'."
}

Write-Host "[PASS] Preview Service currently points to initial BLUE version: $($PreviewHealth.version)"

Write-Host ""
Write-Host "------------------------------------------"
Write-Host " Rollout status"
Write-Host "------------------------------------------"
kubectl argo rollouts get rollout $RolloutName -n $Namespace | Out-Host

Write-Host ""
Write-Host "------------------------------------------"
Write-Host " Application pods"
Write-Host "------------------------------------------"
kubectl get pods -n $Namespace -l app=ai-bluegreen-demo -o wide | Out-Host

Write-Host ""
Write-Host "------------------------------------------"
Write-Host " Blue-Green services"
Write-Host "------------------------------------------"
kubectl get svc `
    ai-bluegreen-active `
    ai-bluegreen-preview `
    -n $Namespace `
    -o wide | Out-Host

Write-Host ""
Write-Host "------------------------------------------"
Write-Host " Service selectors managed by Argo"
Write-Host "------------------------------------------"
kubectl get svc `
    ai-bluegreen-active `
    ai-bluegreen-preview `
    -n $Namespace `
    -o custom-columns='NAME:.metadata.name,HASH:.spec.selector.rollouts-pod-template-hash' | Out-Host

Write-Host ""
Write-Host "=========================================="
Write-Host "BLUE BASELINE DEPLOYMENT RESULT: PASS"
Write-Host "Active endpoint  : http://localhost:8081"
Write-Host "Preview endpoint : http://localhost:8082"
Write-Host "Blue release ID  : $BlueReleaseId"
Write-Host "Blue image       : $BlueImage"
Write-Host "Active version   : $($ActiveHealth.version)"
Write-Host "Preview version  : $($PreviewHealth.version)"
Write-Host "=========================================="

exit 0
