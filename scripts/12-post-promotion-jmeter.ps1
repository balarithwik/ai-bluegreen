param(
    [int]$Threads = 20,
    [int]$RampSeconds = 10,
    [int]$DurationSeconds = 60,
    [int]$PacingMs = 1000,
    [double]$MaxErrorRatePct = 2.0,
    [double]$MaxAverageResponseMs = 125.0,
    [double]$MaxP95ResponseMs = 180.0
)

$ErrorActionPreference = "Stop"

Write-Host "=========================================="
Write-Host " AI BLUE-GREEN LAB - POST-PROMOTION JMETER"
Write-Host "=========================================="
Write-Host ""

$ExpectedContext = "kind-ai-bluegreen"
$Namespace = "ai-bluegreen"
$TargetHost = "localhost"
$TargetPort = 8081
$ExpectedVersion = "v2-healthy"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

$TestPlan = Join-Path $ProjectRoot "jmeter\bluegreen-validation.jmx"
$BlueSummaryFile = Join-Path $ProjectRoot "results\blue-baseline\summary.json"
$PromotionStateFile = Join-Path $ProjectRoot "results\promotion\promotion-state.json"

$ResultDir = Join-Path $ProjectRoot "results\post-promotion"
$JtlFile = Join-Path $ResultDir "post-promotion.jtl"
$JmeterLog = Join-Path $ResultDir "jmeter.log"
$HtmlReport = Join-Path $ResultDir "html-report"
$SummaryFile = Join-Path $ResultDir "summary.json"
$ComparisonFile = Join-Path $ResultDir "comparison.json"

function Fail-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "[FAIL] $Message"
    exit 1
}

function ResultText {
    param([bool]$Passed)
    if ($Passed) { return "PASS" }
    return "FAIL"
}

$CurrentContext = (kubectl config current-context).Trim()
if ($LASTEXITCODE -ne 0 -or $CurrentContext -ne $ExpectedContext) {
    Fail-Step "Expected Kubernetes context '$ExpectedContext', found '$CurrentContext'."
}
Write-Host "[PASS] Kubernetes context is $CurrentContext."

foreach ($Required in @($TestPlan,$BlueSummaryFile,$PromotionStateFile)) {
    if (-not (Test-Path $Required)) {
        Fail-Step "Required file not found: $Required"
    }
}

$Blue = Get-Content $BlueSummaryFile -Raw | ConvertFrom-Json
$Promotion = Get-Content $PromotionStateFile -Raw | ConvertFrom-Json

$ActiveHash = kubectl get svc ai-bluegreen-active -n $Namespace -o jsonpath='{.spec.selector.rollouts-pod-template-hash}'
if ($LASTEXITCODE -ne 0 -or $ActiveHash -ne $Promotion.greenHash) {
    Fail-Step "Active Service is not pointing to the promoted GREEN ReplicaSet."
}

try {
    $Health = Invoke-RestMethod -Uri "http://${TargetHost}:${TargetPort}/health" -Method Get -TimeoutSec 10
}
catch {
    Fail-Step "Promoted production endpoint is unreachable."
}

if ($Health.status -ne "UP" -or $Health.version -ne $ExpectedVersion) {
    Fail-Step "Unexpected production health response. Version='$($Health.version)'."
}

Write-Host "[PASS] Promoted GREEN is healthy before the production load test."

if (Test-Path $ResultDir) {
    Remove-Item $ResultDir -Recurse -Force
}
New-Item -ItemType Directory -Path $ResultDir -Force | Out-Null

Write-Host ""
Write-Host "------------------------------------------"
Write-Host " POST-PROMOTION LOAD PROFILE"
Write-Host "------------------------------------------"
Write-Host "Concurrent Users : $Threads"
Write-Host "Ramp-up          : $RampSeconds seconds"
Write-Host "Duration         : $DurationSeconds seconds"
Write-Host "Pacing           : $PacingMs ms"
Write-Host ""
Write-Host "[INFO] Running production validation traffic against ACTIVE GREEN..."

& jmeter `
    -n `
    -t $TestPlan `
    -l $JtlFile `
    -j $JmeterLog `
    -e `
    -o $HtmlReport `
    "-JTARGET_HOST=$TargetHost" `
    "-JTARGET_PORT=$TargetPort" `
    "-JTHREADS=$Threads" `
    "-JRAMP=$RampSeconds" `
    "-JDURATION=$DurationSeconds" `
    "-JPACING_MS=$PacingMs" `
    "-Jjmeter.save.saveservice.output_format=csv" | Out-Host

if ($LASTEXITCODE -ne 0) {
    Fail-Step "Post-promotion JMeter execution failed."
}

$Samples = @(Import-Csv $JtlFile)
if ($Samples.Count -eq 0) {
    Fail-Step "No post-promotion JMeter samples were generated."
}

$Elapsed = @($Samples | ForEach-Object { [double]$_.elapsed } | Sort-Object)
$Total = $Samples.Count
$Errors = @($Samples | Where-Object { $_.success -eq "false" }).Count
$Successes = $Total - $Errors
$ErrorRate = [math]::Round(($Errors / $Total) * 100, 3)
$Average = [math]::Round((($Elapsed | Measure-Object -Average).Average), 2)
$Min = [math]::Round($Elapsed[0], 2)
$Max = [math]::Round($Elapsed[-1], 2)

$P95Index = [math]::Ceiling($Elapsed.Count * 0.95) - 1
if ($P95Index -lt 0) { $P95Index = 0 }
$P95 = [math]::Round($Elapsed[$P95Index], 2)

$Timestamps = @($Samples | ForEach-Object { [double]$_.timeStamp } | Sort-Object)
$ThroughputRps = 0.0
if ($Timestamps.Count -gt 1) {
    $ElapsedSeconds = ($Timestamps[-1] - $Timestamps[0]) / 1000.0
    if ($ElapsedSeconds -gt 0) {
        $ThroughputRps = [math]::Round($Total / $ElapsedSeconds, 2)
    }
}

$ErrorPass = $ErrorRate -le $MaxErrorRatePct
$AveragePass = $Average -le $MaxAverageResponseMs
$P95Pass = $P95 -le $MaxP95ResponseMs
$AcceptancePass = $ErrorPass -and $AveragePass -and $P95Pass

# Blue comparison is informational because Blue ran at 10 users and this run uses 20.
$AverageRegression = [math]::Round((($Average - [double]$Blue.averageResponseMs) / [double]$Blue.averageResponseMs) * 100, 2)
$P95Regression = [math]::Round((($P95 - [double]$Blue.p95ResponseMs) / [double]$Blue.p95ResponseMs) * 100, 2)
$ErrorDelta = [math]::Round(($ErrorRate - [double]$Blue.errorRatePct), 3)

$Summary = [ordered]@{
    environment = "POST_PROMOTION_GREEN"
    version = $ExpectedVersion
    endpoint = "http://${TargetHost}:${TargetPort}/api/orders"
    concurrentUsers = $Threads
    rampSeconds = $RampSeconds
    durationSeconds = $DurationSeconds
    pacingMs = $PacingMs
    totalRequests = $Total
    successfulRequests = $Successes
    failedRequests = $Errors
    errorRatePct = $ErrorRate
    averageResponseMs = $Average
    p95ResponseMs = $P95
    minResponseMs = $Min
    maxResponseMs = $Max
    throughputRps = $ThroughputRps
    productionAcceptance = $(if ($AcceptancePass) { "PASS" } else { "FAIL" })
    generatedAt = (Get-Date).ToString("o")
}

$Summary | ConvertTo-Json -Depth 5 | Set-Content $SummaryFile -Encoding UTF8

$Comparison = [ordered]@{
    comparisonPurpose = "POST_PROMOTION_20_USER_PRODUCTION_VALIDATION"
    technicalGate = "PASS"
    productionAcceptance = $(if ($AcceptancePass) { "PASS" } else { "FAIL" })
    loadProfile = [ordered]@{
        blueBaselineUsers = 10
        postPromotionUsers = $Threads
        relativeBlueComparisonIsInformational = $true
    }
    blue = [ordered]@{
        version = $Blue.version
        concurrentUsers = 10
        errorRatePct = [double]$Blue.errorRatePct
        averageResponseMs = [double]$Blue.averageResponseMs
        p95ResponseMs = [double]$Blue.p95ResponseMs
    }
    green = [ordered]@{
        version = $ExpectedVersion
        concurrentUsers = $Threads
        errorRatePct = $ErrorRate
        averageResponseMs = $Average
        p95ResponseMs = $P95
        throughputRps = $ThroughputRps
    }
    productionThresholds = [ordered]@{
        errorRateMaxPct = $MaxErrorRatePct
        averageResponseMaxMs = $MaxAverageResponseMs
        p95ResponseMaxMs = $MaxP95ResponseMs
    }
    regressions = [ordered]@{
        errorRateDeltaPoints = $ErrorDelta
        averageResponseRegressionPct = $AverageRegression
        p95RegressionPct = $P95Regression
    }
    checks = [ordered]@{
        errorRate = (ResultText $ErrorPass)
        averageResponse = (ResultText $AveragePass)
        p95Response = (ResultText $P95Pass)
    }
    recommendation = "CONTINUE_TO_POST_VALIDATION_AI"
    generatedAt = (Get-Date).ToString("o")
}

$Comparison | ConvertTo-Json -Depth 6 | Set-Content $ComparisonFile -Encoding UTF8

Write-Host ""
Write-Host "------------------------------------------"
Write-Host " 20-USER PRODUCTION VALIDATION RESULT"
Write-Host "------------------------------------------"
Write-Host ("{0,-20} {1,-14} {2,-14} {3}" -f "Metric","Observed","Acceptance","Result")
Write-Host ("{0,-20} {1,-14} {2,-14} {3}" -f "Requests",$Total,"-","INFO")
Write-Host ("{0,-20} {1,-14} {2,-14} {3}" -f "Throughput","${ThroughputRps}/s","-","INFO")
Write-Host ("{0,-20} {1,-14} {2,-14} {3}" -f "Error Rate","$ErrorRate%","<=$MaxErrorRatePct%","$(ResultText $ErrorPass)")
Write-Host ("{0,-20} {1,-14} {2,-14} {3}" -f "Average","${Average}ms","<=${MaxAverageResponseMs}ms","$(ResultText $AveragePass)")
Write-Host ("{0,-20} {1,-14} {2,-14} {3}" -f "P95","${P95}ms","<=${MaxP95ResponseMs}ms","$(ResultText $P95Pass)")
Write-Host ""
Write-Host "Production Acceptance : $(if ($AcceptancePass) { 'PASS' } else { 'FAIL' })"
Write-Host ""
Write-Host "[INFO] Acceptance result is evidence for the independent AI analysis."
Write-Host "[INFO] Scenario intent is not included in AI input."
Write-Host ""
Write-Host "=========================================="
Write-Host "POST-PROMOTION JMETER RESULT: COMPLETE"
Write-Host "Next: publish dashboard metrics, hold 30 seconds, then run post-validation AI."
Write-Host "=========================================="

exit 0
