$ErrorActionPreference = "Stop"

Write-Host "=========================================="
Write-Host " AI BLUE-GREEN LAB - ROLLBACK TO BLUE"
Write-Host "=========================================="
Write-Host ""

$ExpectedContext = "kind-ai-bluegreen"
$Namespace = "ai-bluegreen"
$RolloutName = "ai-bluegreen-rollout"
$ActiveService = "ai-bluegreen-active"
$PreviewService = "ai-bluegreen-preview"

$ExpectedGreenVersion = "v2-healthy"
$ExpectedBlueVersion = "v1-healthy"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

$PromotionStateFile = Join-Path $ProjectRoot "results\promotion\promotion-state.json"
$PostPromotionStateFile = Join-Path $ProjectRoot "results\post-promotion\final-state.json"
$RollbackDir = Join-Path $ProjectRoot "results\rollback"
$RollbackStateFile = Join-Path $RollbackDir "rollback-state.json"

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

if (-not (Test-Path $PromotionStateFile)) {
    Fail-Step "Promotion state file not found: $PromotionStateFile"
}

if (-not (Test-Path $PostPromotionStateFile)) {
    Fail-Step "Post-promotion final-state file not found: $PostPromotionStateFile"
}

$Promotion = Get-Content $PromotionStateFile -Raw | ConvertFrom-Json
$PostState = Get-Content $PostPromotionStateFile -Raw | ConvertFrom-Json

Write-Host ""
Write-Host "[INFO] Validating rollback authorization..."
Write-Host "[INFO] Post-promotion action : $($PostState.finalAction)"
Write-Host "[INFO] Saved BLUE revision   : $($Promotion.blueRevision)"
Write-Host "[INFO] Saved BLUE hash       : $($Promotion.blueHash)"

if ($PostState.finalAction -ne "ROLLBACK_REQUIRED") {
    Fail-Step "Post-promotion state is '$($PostState.finalAction)'. Rollback is not authorized."
}

Write-Host "[PASS] Rollback is authorized by post-promotion validation."

try {
    $CurrentHealth = Invoke-RestMethod `
        -Uri "http://localhost:8081/health" `
        -Method Get `
        -TimeoutSec 10
}
catch {
    Fail-Step "Unable to reach current Active production endpoint."
}

if ($CurrentHealth.version -ne $ExpectedGreenVersion) {
    Fail-Step "Expected current production '$ExpectedGreenVersion', found '$($CurrentHealth.version)'."
}

Write-Host "[PASS] Current production is still GREEN: $($CurrentHealth.version)"

$GreenHashBefore = Get-ServiceHash -ServiceName $ActiveService
Write-Host "[INFO] Current Active GREEN hash: $GreenHashBefore"

Write-Host ""
Write-Host "------------------------------------------"
Write-Host " STARTING CONTROLLED ROLLBACK"
Write-Host "------------------------------------------"
Write-Host "Current production : $ExpectedGreenVersion"
Write-Host "Rollback target    : $ExpectedBlueVersion"
Write-Host "Target revision    : $($Promotion.blueRevision)"
Write-Host ""

kubectl argo rollouts undo `
    $RolloutName `
    -n $Namespace `
    --to-revision $Promotion.blueRevision | Out-Host

if ($LASTEXITCODE -ne 0) {
    Fail-Step "Argo Rollouts undo command failed."
}

Write-Host "[PASS] Undo command accepted."

Write-Host ""
Write-Host "[INFO] Waiting for BLUE rollback candidate to become Preview and pause..."

$Deadline = (Get-Date).AddSeconds(180)
$BluePreviewReady = $false
$BlueGreenPaused = $false
$BluePreviewHash = $null

while ((Get-Date) -lt $Deadline) {
    Start-Sleep -Seconds 2

    $Rollout = Get-Rollout
    $PauseReasons = @(
        $Rollout.status.pauseConditions |
        ForEach-Object { $_.reason }
    )

    if ($PauseReasons -contains "BlueGreenPause") {
        $BlueGreenPaused = $true
    }

    $PreviewHashNow = Get-ServiceHash -ServiceName $PreviewService

    try {
        $PreviewHealth = Invoke-RestMethod `
            -Uri "http://localhost:8082/health" `
            -Method Get `
            -TimeoutSec 3

        if (
            $PreviewHealth.status -eq "UP" -and
            $PreviewHealth.version -eq $ExpectedBlueVersion
        ) {
            $BluePreviewReady = $true
            $BluePreviewHash = $PreviewHashNow
        }
    }
    catch {
        $BluePreviewReady = $false
    }

    if ($BluePreviewReady -and $BlueGreenPaused) {
        break
    }

    Write-Host "[INFO] Waiting... bluePreviewReady=$BluePreviewReady, blueGreenPause=$BlueGreenPaused"
}

if (-not $BluePreviewReady) {
    Fail-Step "BLUE rollback candidate did not become healthy on Preview within 180 seconds."
}

if (-not $BlueGreenPaused) {
    Fail-Step "Rollback candidate did not pause at BlueGreenPause."
}

Write-Host "[PASS] BLUE rollback candidate is healthy on Preview: $ExpectedBlueVersion"
Write-Host "[PASS] Rollout paused before rollback cutover."
Write-Host "[INFO] BLUE rollback candidate hash: $BluePreviewHash"

$ActiveHashBeforeCutover = Get-ServiceHash -ServiceName $ActiveService

if ($ActiveHashBeforeCutover -ne $GreenHashBefore) {
    Fail-Step "Active Service changed before controlled rollback promotion."
}

Write-Host "[PASS] GREEN remains Active until rollback promotion."

Write-Host ""
Write-Host "[INFO] Promoting BLUE rollback candidate to Active..."

kubectl argo rollouts promote $RolloutName -n $Namespace | Out-Host

if ($LASTEXITCODE -ne 0) {
    Fail-Step "Rollback promotion command failed."
}

Write-Host "[PASS] Rollback promotion command accepted."

Write-Host ""
Write-Host "[INFO] Waiting for production Active Service to return to BLUE..."

$Deadline = (Get-Date).AddSeconds(120)
$RollbackComplete = $false

while ((Get-Date) -lt $Deadline) {
    Start-Sleep -Seconds 2

    $ActiveHashNow = Get-ServiceHash -ServiceName $ActiveService

    try {
        $ActiveHealth = Invoke-RestMethod `
            -Uri "http://localhost:8081/health" `
            -Method Get `
            -TimeoutSec 3
    }
    catch {
        $ActiveHealth = $null
    }

    if (
        $ActiveHealth -and
        $ActiveHealth.status -eq "UP" -and
        $ActiveHealth.version -eq $ExpectedBlueVersion -and
        $ActiveHashNow -eq $BluePreviewHash
    ) {
        $RollbackComplete = $true
        break
    }

    Write-Host "[INFO] Waiting for rollback cutover... activeHash=$ActiveHashNow"
}

if (-not $RollbackComplete) {
    Fail-Step "Production did not return to BLUE within 120 seconds."
}

Write-Host "[PASS] Production traffic is restored to BLUE."

Write-Host ""
Write-Host "[INFO] Waiting for Rollout to become Healthy..."

kubectl argo rollouts status `
    $RolloutName `
    -n $Namespace `
    --timeout 120s | Out-Host

if ($LASTEXITCODE -ne 0) {
    Fail-Step "Rollout did not become Healthy after rollback."
}

Write-Host "[PASS] Rollout is Healthy after rollback."

$ActiveHashAfter = Get-ServiceHash -ServiceName $ActiveService
$PreviewHashAfter = Get-ServiceHash -ServiceName $PreviewService

if ($ActiveHashAfter -ne $BluePreviewHash) {
    Fail-Step "Active Service is not pointing to the restored BLUE ReplicaSet."
}

if ($PreviewHashAfter -ne $BluePreviewHash) {
    Fail-Step "Preview Service is not aligned to the restored BLUE ReplicaSet."
}

try {
    $FinalHealth = Invoke-RestMethod `
        -Uri "http://localhost:8081/health" `
        -Method Get `
        -TimeoutSec 10
}
catch {
    Fail-Step "Restored BLUE endpoint is not reachable."
}

if ($FinalHealth.status -ne "UP" -or $FinalHealth.version -ne $ExpectedBlueVersion) {
    Fail-Step "Unexpected health response after rollback."
}

New-Item -ItemType Directory -Path $RollbackDir -Force | Out-Null

$RolloutAfter = Get-Rollout

$RollbackState = [ordered]@{
    rollbackRequired = $true
    rollbackCompleted = $true
    previousProductionVersion = $ExpectedGreenVersion
    restoredProductionVersion = $ExpectedBlueVersion
    previousGreenHash = $GreenHashBefore
    restoredBlueHash = $BluePreviewHash
    requestedBlueRevision = $Promotion.blueRevision
    currentStableRS = $RolloutAfter.status.stableRS
    completedAt = (Get-Date).ToString("o")
}

$RollbackState |
    ConvertTo-Json -Depth 5 |
    Set-Content -Path $RollbackStateFile -Encoding UTF8

Write-Host ""
Write-Host "------------------------------------------"
Write-Host " FINAL SERVICE ROUTING"
Write-Host "------------------------------------------"
kubectl get svc `
    $ActiveService `
    $PreviewService `
    -n $Namespace `
    -o custom-columns='NAME:.metadata.name,HASH:.spec.selector.rollouts-pod-template-hash' | Out-Host

Write-Host ""
Write-Host "------------------------------------------"
Write-Host " FINAL ROLLOUT STATUS"
Write-Host "------------------------------------------"
kubectl argo rollouts get rollout $RolloutName -n $Namespace | Out-Host

Write-Host ""
Write-Host "=========================================="
Write-Host "ROLLBACK RESULT: PASS"
Write-Host "Production endpoint : http://localhost:8081"
Write-Host "Restored version    : $($FinalHealth.version)"
Write-Host "Restored hash       : $BluePreviewHash"
Write-Host "Previous GREEN hash : $GreenHashBefore"
Write-Host "=========================================="

exit 0
