$ErrorActionPreference = "Stop"

Write-Host "=========================================="
Write-Host " AI BLUE-GREEN LAB - PROMOTE GREEN"
Write-Host "=========================================="
Write-Host ""

$ExpectedContext = "kind-ai-bluegreen"
$Namespace = "ai-bluegreen"
$RolloutName = "ai-bluegreen-rollout"
$ActiveService = "ai-bluegreen-active"
$PreviewService = "ai-bluegreen-preview"

$ExpectedBlueVersion = "v1-healthy"
$ExpectedGreenVersion = "v2-healthy"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

$DecisionFile = Join-Path $ProjectRoot "results\ai-analysis\decision.json"
$PromotionDir = Join-Path $ProjectRoot "results\promotion"
$PromotionStateFile = Join-Path $PromotionDir "promotion-state.json"

function Fail-Step {
    param([string]$Message)

    Write-Host ""
    Write-Host "[FAIL] $Message"
    exit 1
}

function Get-ServiceHash {
    param([string]$ServiceName)

    $Raw = kubectl get svc $ServiceName -n $Namespace -o json

    if ($LASTEXITCODE -ne 0) {
        Fail-Step "Unable to retrieve service '$ServiceName'."
    }

    $Object = ($Raw | Out-String) | ConvertFrom-Json
    return $Object.spec.selector.'rollouts-pod-template-hash'
}

function Get-Rollout {
    $Raw = kubectl get rollout $RolloutName -n $Namespace -o json

    if ($LASTEXITCODE -ne 0) {
        Fail-Step "Unable to retrieve Rollout '$RolloutName'."
    }

    return (($Raw | Out-String) | ConvertFrom-Json)
}

$CurrentContext = (kubectl config current-context).Trim()

if ($LASTEXITCODE -ne 0 -or $CurrentContext -ne $ExpectedContext) {
    Fail-Step "Expected Kubernetes context '$ExpectedContext', but found '$CurrentContext'."
}

Write-Host "[PASS] Kubernetes context is $CurrentContext."

if (-not (Test-Path $DecisionFile)) {
    Fail-Step "AI decision file not found: $DecisionFile"
}

$Decision = Get-Content $DecisionFile -Raw | ConvertFrom-Json

Write-Host ""
Write-Host "[INFO] Validating AI deployment decision..."
Write-Host "[INFO] AI Model         : $($Decision.model)"
Write-Host "[INFO] Final Risk Score : $($Decision.finalRiskScore)/100"
Write-Host "[INFO] Final Decision   : $($Decision.finalDecision)"

if ($Decision.finalDecision -ne "PROMOTE") {
    Fail-Step "AI decision is '$($Decision.finalDecision)'. Green promotion is blocked."
}

Write-Host "[PASS] AI gate authorizes GREEN promotion."

Write-Host ""
Write-Host "[INFO] Validating current Blue-Green routing before cutover..."

$BlueHash = Get-ServiceHash -ServiceName $ActiveService
$GreenHash = Get-ServiceHash -ServiceName $PreviewService

if ([string]::IsNullOrWhiteSpace($BlueHash) -or [string]::IsNullOrWhiteSpace($GreenHash)) {
    Fail-Step "Unable to resolve Active/Preview ReplicaSet hashes."
}

if ($BlueHash -eq $GreenHash) {
    Fail-Step "Active and Preview already point to the same ReplicaSet. No isolated Green candidate is available."
}

try {
    $BlueHealth = Invoke-RestMethod `
        -Uri "http://localhost:8081/health" `
        -Method Get `
        -TimeoutSec 10
}
catch {
    Fail-Step "Unable to reach BLUE Active endpoint before promotion. $($_.Exception.Message)"
}

try {
    $GreenHealth = Invoke-RestMethod `
        -Uri "http://localhost:8082/health" `
        -Method Get `
        -TimeoutSec 10
}
catch {
    Fail-Step "Unable to reach GREEN Preview endpoint before promotion. $($_.Exception.Message)"
}

if ($BlueHealth.version -ne $ExpectedBlueVersion) {
    Fail-Step "Expected Active version '$ExpectedBlueVersion', found '$($BlueHealth.version)'."
}

if ($GreenHealth.version -ne $ExpectedGreenVersion) {
    Fail-Step "Expected Preview version '$ExpectedGreenVersion', found '$($GreenHealth.version)'."
}

Write-Host "[PASS] Active remains BLUE : $($BlueHealth.version) -> $BlueHash"
Write-Host "[PASS] Preview is GREEN    : $($GreenHealth.version) -> $GreenHash"

$RolloutBefore = Get-Rollout
$PauseReasons = @(
    $RolloutBefore.status.pauseConditions |
    ForEach-Object { $_.reason }
)

if ($PauseReasons -notcontains "BlueGreenPause") {
    Fail-Step "Rollout is not paused at the expected BlueGreenPause gate."
}

Write-Host "[PASS] Rollout is paused at BlueGreenPause."

$GreenRsRaw = kubectl get rs -n $Namespace -l "rollouts-pod-template-hash=$GreenHash" -o json
if ($LASTEXITCODE -ne 0) {
    Fail-Step "Unable to retrieve GREEN ReplicaSet."
}

$GreenRsObj = ($GreenRsRaw | Out-String) | ConvertFrom-Json
if ($GreenRsObj.items.Count -lt 1) {
    Fail-Step "GREEN ReplicaSet was not found."
}

$GreenRevision = $GreenRsObj.items[0].metadata.annotations.'rollout.argoproj.io/revision'

$BlueRsRaw = kubectl get rs -n $Namespace -l "rollouts-pod-template-hash=$BlueHash" -o json
if ($LASTEXITCODE -ne 0) {
    Fail-Step "Unable to retrieve BLUE ReplicaSet."
}

$BlueRsObj = ($BlueRsRaw | Out-String) | ConvertFrom-Json
if ($BlueRsObj.items.Count -lt 1) {
    Fail-Step "BLUE ReplicaSet was not found."
}

$BlueRevision = $BlueRsObj.items[0].metadata.annotations.'rollout.argoproj.io/revision'

if (Test-Path $PromotionDir) {
    Remove-Item $PromotionDir -Recurse -Force
}

New-Item -ItemType Directory -Path $PromotionDir -Force | Out-Null

$PromotionState = [ordered]@{
    rollout = $RolloutName
    namespace = $Namespace
    blueVersion = $ExpectedBlueVersion
    greenVersion = $ExpectedGreenVersion
    blueHash = $BlueHash
    greenHash = $GreenHash
    blueRevision = $BlueRevision
    greenRevision = $GreenRevision
    aiModel = $Decision.model
    aiFinalRiskScore = $Decision.finalRiskScore
    aiFinalDecision = $Decision.finalDecision
    promotedAt = (Get-Date).ToString("o")
}

$PromotionState |
    ConvertTo-Json -Depth 5 |
    Set-Content -Path $PromotionStateFile -Encoding UTF8

Write-Host "[PASS] Pre-promotion state saved for rollback."
Write-Host "[INFO] BLUE revision : $BlueRevision"
Write-Host "[INFO] GREEN revision: $GreenRevision"

Write-Host ""
Write-Host "------------------------------------------"
Write-Host " PROMOTING GREEN TO PRODUCTION"
Write-Host "------------------------------------------"
Write-Host "Before: localhost:8081 -> $ExpectedBlueVersion"
Write-Host "After : localhost:8081 -> $ExpectedGreenVersion"
Write-Host ""

kubectl argo rollouts promote $RolloutName -n $Namespace | Out-Host

if ($LASTEXITCODE -ne 0) {
    Fail-Step "Argo Rollouts promotion command failed."
}

Write-Host "[PASS] Promotion command accepted."

Write-Host ""
Write-Host "[INFO] Waiting for Active Service to switch to GREEN..."

$Deadline = (Get-Date).AddSeconds(120)
$CutoverComplete = $false

while ((Get-Date) -lt $Deadline) {
    Start-Sleep -Seconds 2

    $ActiveHashNow = Get-ServiceHash -ServiceName $ActiveService

    try {
        $ActiveHealthNow = Invoke-RestMethod `
            -Uri "http://localhost:8081/health" `
            -Method Get `
            -TimeoutSec 3
    }
    catch {
        $ActiveHealthNow = $null
    }

    if (
        $ActiveHashNow -eq $GreenHash -and
        $ActiveHealthNow -and
        $ActiveHealthNow.status -eq "UP" -and
        $ActiveHealthNow.version -eq $ExpectedGreenVersion
    ) {
        $CutoverComplete = $true
        break
    }

    Write-Host "[INFO] Waiting for cutover... activeHash=$ActiveHashNow"
}

if (-not $CutoverComplete) {
    Fail-Step "Active Service did not switch to GREEN within 120 seconds."
}

Write-Host "[PASS] Active Service now routes 100% traffic to GREEN."

Write-Host ""
Write-Host "[INFO] Waiting for Rollout to become Healthy..."

kubectl argo rollouts status `
    $RolloutName `
    -n $Namespace `
    --timeout 120s | Out-Host

if ($LASTEXITCODE -ne 0) {
    Fail-Step "Rollout did not become Healthy after promotion."
}

Write-Host "[PASS] Rollout is Healthy after promotion."

$ActiveHashAfter = Get-ServiceHash -ServiceName $ActiveService
$PreviewHashAfter = Get-ServiceHash -ServiceName $PreviewService

if ($ActiveHashAfter -ne $GreenHash) {
    Fail-Step "Active Service does not point to promoted GREEN hash."
}

if ($PreviewHashAfter -ne $GreenHash) {
    Fail-Step "Preview Service does not point to promoted GREEN hash."
}

Write-Host "[PASS] Active and Preview now point to GREEN hash: $GreenHash"

try {
    $FinalActiveHealth = Invoke-RestMethod `
        -Uri "http://localhost:8081/health" `
        -Method Get `
        -TimeoutSec 10
}
catch {
    Fail-Step "Promoted GREEN endpoint is not reachable on port 8081."
}

if (
    $FinalActiveHealth.status -ne "UP" -or
    $FinalActiveHealth.version -ne $ExpectedGreenVersion
) {
    Fail-Step "Unexpected post-promotion Active response."
}

Write-Host "[PASS] Production endpoint is healthy: $($FinalActiveHealth.version)"

Write-Host ""
Write-Host "------------------------------------------"
Write-Host " Post-promotion routing"
Write-Host "------------------------------------------"
kubectl get svc `
    $ActiveService `
    $PreviewService `
    -n $Namespace `
    -o custom-columns='NAME:.metadata.name,HASH:.spec.selector.rollouts-pod-template-hash' | Out-Host

Write-Host ""
Write-Host "------------------------------------------"
Write-Host " Rollout status"
Write-Host "------------------------------------------"
kubectl argo rollouts get rollout $RolloutName -n $Namespace | Out-Host

Write-Host ""
Write-Host "------------------------------------------"
Write-Host " ReplicaSets retained for rollback window"
Write-Host "------------------------------------------"
kubectl get rs -n $Namespace -l app=ai-bluegreen-demo | Out-Host

Write-Host ""
Write-Host "------------------------------------------"
Write-Host " Application pods"
Write-Host "------------------------------------------"
kubectl get pods -n $Namespace -l app=ai-bluegreen-demo -o wide | Out-Host

Write-Host ""
Write-Host "[INFO] Rollback state saved at:"
Write-Host "       $PromotionStateFile"

Write-Host ""
Write-Host "=========================================="
Write-Host "GREEN PROMOTION RESULT: PASS"
Write-Host "Production endpoint : http://localhost:8081"
Write-Host "Production version  : $($FinalActiveHealth.version)"
Write-Host "Previous BLUE       : revision $BlueRevision / hash $BlueHash"
Write-Host "Promoted GREEN      : revision $GreenRevision / hash $GreenHash"
Write-Host "=========================================="

exit 0
