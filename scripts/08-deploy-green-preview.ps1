$ErrorActionPreference = "Stop"

Write-Host "=========================================="
Write-Host " AI BLUE-GREEN LAB - DEPLOY GREEN PREVIEW"
Write-Host "=========================================="
Write-Host ""

$ExpectedContext = "kind-ai-bluegreen"
$Namespace = "ai-bluegreen"
$RolloutName = "ai-bluegreen-rollout"
$ActiveService = "ai-bluegreen-active"
$PreviewService = "ai-bluegreen-preview"

$BlueVersion = "v1-healthy"
$GreenVersion = "v2-healthy"

$BlueReleaseId = if (-not [string]::IsNullOrWhiteSpace($env:BLUE_RELEASE_ID)) {
    $env:BLUE_RELEASE_ID
}
else {
    "v1"
}

$GreenReleaseId = if (-not [string]::IsNullOrWhiteSpace($env:GREEN_RELEASE_ID)) {
    $env:GREEN_RELEASE_ID
}
else {
    "v2"
}

$GreenImage = "ai-bluegreen-demo:$GreenReleaseId"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$GreenRolloutFile = Join-Path $ProjectRoot "k8s\rollout-green.yaml"

function Fail-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "[FAIL] $Message"
    exit 1
}

function Get-ServiceHash {
    param([string]$ServiceName)

    $ServiceRaw = kubectl get svc $ServiceName -n $Namespace -o json
    if ($LASTEXITCODE -ne 0) {
        Fail-Step "Unable to retrieve service '$ServiceName'."
    }

    $Service = ($ServiceRaw | Out-String) | ConvertFrom-Json
    return $Service.spec.selector.'rollouts-pod-template-hash'
}

function Get-RolloutObject {
    $RolloutRaw = kubectl get rollout $RolloutName -n $Namespace -o json
    if ($LASTEXITCODE -ne 0) {
        Fail-Step "Unable to retrieve Rollout '$RolloutName'."
    }

    return (($RolloutRaw | Out-String) | ConvertFrom-Json)
}

Write-Host "[INFO] Project root   : $ProjectRoot"
Write-Host "[INFO] Rollout        : $RolloutName"
Write-Host "[INFO] Current BLUE   : $BlueVersion"
Write-Host "[INFO] Blue release   : $BlueReleaseId"
Write-Host "[INFO] Candidate GREEN: $GreenVersion"
Write-Host "[INFO] Green release  : $GreenReleaseId"
Write-Host "[INFO] Green image    : $GreenImage"
Write-Host ""

$CurrentContext = (kubectl config current-context).Trim()

if ($LASTEXITCODE -ne 0 -or $CurrentContext -ne $ExpectedContext) {
    Fail-Step "Expected Kubernetes context '$ExpectedContext', but found '$CurrentContext'."
}

Write-Host "[PASS] Kubernetes context is $CurrentContext."

if (-not (Test-Path $GreenRolloutFile)) {
    Fail-Step "Green Rollout manifest not found: $GreenRolloutFile"
}

Write-Host ""
Write-Host "[INFO] Validating current BLUE Active endpoint..."

try {
    $BeforeActive = Invoke-RestMethod `
        -Uri "http://localhost:8081/health" `
        -Method Get `
        -TimeoutSec 10
}
catch {
    Fail-Step "Unable to reach Active endpoint before Green deployment. $($_.Exception.Message)"
}

if ($BeforeActive.status -ne "UP" -or $BeforeActive.version -ne $BlueVersion) {
    Fail-Step "Expected Active version '$BlueVersion' before Green deployment, but found '$($BeforeActive.version)'."
}

Write-Host "[PASS] Active Service is currently serving BLUE: $($BeforeActive.version)"

$BlueHashBefore = Get-ServiceHash -ServiceName $ActiveService
Write-Host "[INFO] BLUE Active hash before update: $BlueHashBefore"

Write-Host ""
Write-Host "[INFO] Rendering GREEN candidate with release image: $GreenImage"

$RenderedGreenRollout = Join-Path $env:TEMP "ai-bluegreen-rollout-green-$PID.yaml"
$GreenRolloutYaml = Get-Content $GreenRolloutFile -Raw

if ($GreenRolloutYaml -notmatch 'image:\s*ai-bluegreen-demo:[^\s]+') {
    Fail-Step "Unable to locate application image in GREEN Rollout manifest."
}

$GreenRolloutYaml = $GreenRolloutYaml -replace `
    'image:\s*ai-bluegreen-demo:[^\s]+', `
    "image: $GreenImage"

$GreenRolloutYaml | Set-Content $RenderedGreenRollout -Encoding UTF8

Write-Host "[INFO] Applying GREEN candidate Rollout..."
kubectl apply -f $RenderedGreenRollout | Out-Host
$GreenApplyRc = $LASTEXITCODE

Remove-Item $RenderedGreenRollout -Force -ErrorAction SilentlyContinue

if ($GreenApplyRc -ne 0) {
    Fail-Step "Unable to apply Green Rollout manifest."
}

Write-Host "[PASS] Green Rollout manifest applied with release '$GreenReleaseId'."

Write-Host ""
Write-Host "[INFO] Waiting for GREEN preview to become available and rollout to pause..."
$Deadline = (Get-Date).AddSeconds(180)
$GreenReady = $false
$PausedForBlueGreen = $false

while ((Get-Date) -lt $Deadline) {
    Start-Sleep -Seconds 2

    $Rollout = Get-RolloutObject
    $Phase = $Rollout.status.phase
    $PauseReasons = @(
        $Rollout.status.pauseConditions |
        ForEach-Object { $_.reason }
    )

    if ($PauseReasons -contains "BlueGreenPause") {
        $PausedForBlueGreen = $true
    }

    try {
        $PreviewHealth = Invoke-RestMethod `
            -Uri "http://localhost:8082/health" `
            -Method Get `
            -TimeoutSec 3

        if ($PreviewHealth.status -eq "UP" -and $PreviewHealth.version -eq $GreenVersion) {
            $GreenReady = $true
        }
    }
    catch {
        $GreenReady = $false
    }

    if ($GreenReady -and $PausedForBlueGreen) {
        break
    }

    Write-Host "[INFO] Waiting... phase=$Phase, greenReady=$GreenReady, blueGreenPause=$PausedForBlueGreen"
}

if (-not $GreenReady) {
    Fail-Step "GREEN preview did not become healthy within 180 seconds."
}

if (-not $PausedForBlueGreen) {
    Fail-Step "Rollout did not enter the expected BlueGreenPause state."
}

Write-Host "[PASS] GREEN preview is healthy: $GreenVersion"
Write-Host "[PASS] Rollout is paused before production promotion."

$ActiveHash = Get-ServiceHash -ServiceName $ActiveService
$PreviewHash = Get-ServiceHash -ServiceName $PreviewService

if ([string]::IsNullOrWhiteSpace($ActiveHash) -or [string]::IsNullOrWhiteSpace($PreviewHash)) {
    Fail-Step "Unable to resolve Active/Preview service hashes."
}

if ($ActiveHash -eq $PreviewHash) {
    Fail-Step "Active and Preview services point to the same ReplicaSet. Green isolation was not established."
}

if ($ActiveHash -ne $BlueHashBefore) {
    Fail-Step "Active Service changed away from the original BLUE ReplicaSet before promotion."
}

Write-Host "[PASS] Active and Preview services point to different ReplicaSets."
Write-Host "[PASS] Active Service remains on original BLUE hash: $ActiveHash"
Write-Host "[PASS] Preview Service points to GREEN hash      : $PreviewHash"

Write-Host ""
Write-Host "[INFO] Waiting for GREEN preview pods to be Ready..."
kubectl wait `
    --for=condition=Ready `
    pod `
    -l "rollouts-pod-template-hash=$PreviewHash" `
    -n $Namespace `
    --timeout=120s | Out-Host

if ($LASTEXITCODE -ne 0) {
    Fail-Step "GREEN preview pods did not become Ready."
}

Write-Host "[PASS] GREEN preview pods are Ready."

Write-Host ""
Write-Host "[INFO] Re-validating BLUE Active endpoint after Green deployment..."

try {
    $ActiveHealth = Invoke-RestMethod `
        -Uri "http://localhost:8081/health" `
        -Method Get `
        -TimeoutSec 10
}
catch {
    Fail-Step "Unable to reach BLUE Active endpoint after Green deployment. $($_.Exception.Message)"
}

if ($ActiveHealth.status -ne "UP" -or $ActiveHealth.version -ne $BlueVersion) {
    Fail-Step "Production Active endpoint changed unexpectedly. Expected '$BlueVersion', found '$($ActiveHealth.version)'."
}

Write-Host "[PASS] BLUE remains live on port 8081: $($ActiveHealth.version)"

Write-Host ""
Write-Host "[INFO] Validating GREEN Preview endpoint..."

try {
    $PreviewHealth = Invoke-RestMethod `
        -Uri "http://localhost:8082/health" `
        -Method Get `
        -TimeoutSec 10
}
catch {
    Fail-Step "Unable to reach GREEN Preview endpoint. $($_.Exception.Message)"
}

if ($PreviewHealth.status -ne "UP" -or $PreviewHealth.version -ne $GreenVersion) {
    Fail-Step "Unexpected GREEN response. Expected '$GreenVersion', found '$($PreviewHealth.version)'."
}

Write-Host "[PASS] GREEN is isolated on port 8082: $($PreviewHealth.version)"

$FinalRollout = Get-RolloutObject
$FinalPauseReasons = @(
    $FinalRollout.status.pauseConditions |
    ForEach-Object { $_.reason }
)

Write-Host ""
Write-Host "------------------------------------------"
Write-Host " Rollout state"
Write-Host "------------------------------------------"
Write-Host "Phase         : $($FinalRollout.status.phase)"
Write-Host "Pause reason  : $($FinalPauseReasons -join ', ')"
Write-Host "Stable RS     : $($FinalRollout.status.stableRS)"
Write-Host "Current hash  : $($FinalRollout.status.currentPodHash)"

Write-Host ""
kubectl argo rollouts get rollout $RolloutName -n $Namespace | Out-Host

Write-Host ""
Write-Host "------------------------------------------"
Write-Host " Service routing"
Write-Host "------------------------------------------"
Write-Host "ACTIVE  -> $BlueVersion  -> hash $ActiveHash -> http://localhost:8081"
Write-Host "PREVIEW -> $GreenVersion -> hash $PreviewHash -> http://localhost:8082"

Write-Host ""
kubectl get svc `
    $ActiveService `
    $PreviewService `
    -n $Namespace `
    -o custom-columns='NAME:.metadata.name,HASH:.spec.selector.rollouts-pod-template-hash' | Out-Host

Write-Host ""
Write-Host "------------------------------------------"
Write-Host " Application pods"
Write-Host "------------------------------------------"
kubectl get pods -n $Namespace -l app=ai-bluegreen-demo -o wide | Out-Host

Write-Host ""
Write-Host "=========================================="
Write-Host "GREEN PREVIEW DEPLOYMENT RESULT: PASS"
Write-Host "Blue release  : $BlueReleaseId"
Write-Host "Green release : $GreenReleaseId"
Write-Host "Production    : $BlueVersion on http://localhost:8081"
Write-Host "Preview       : $GreenVersion on http://localhost:8082"
Write-Host "Promotion     : PAUSED - awaiting validation"
Write-Host "=========================================="

exit 0
