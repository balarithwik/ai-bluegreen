param(
    [int]$Threads = 10,
    [int]$RampSeconds = 10,
    [int]$DurationSeconds = 60,
    [int]$PacingMs = 1000,
    [double]$LatencyTolerancePct = 15.0,
    [double]$ErrorTolerancePoints = 0.5
)

$ErrorActionPreference = "Stop"

Write-Host "=========================================="
Write-Host " AI BLUE-GREEN LAB - GREEN VALIDATION"
Write-Host "=========================================="
Write-Host ""

$TargetHost = "localhost"
$TargetPort = 8082
$ExpectedVersion = "v2-healthy"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$JmeterDir = Join-Path $ProjectRoot "jmeter"
$TestPlan = Join-Path $JmeterDir "bluegreen-validation.jmx"

$ResultsRoot = Join-Path $ProjectRoot "results"
$BlueSummaryFile = Join-Path $ResultsRoot "blue-baseline\summary.json"

$ResultDir = Join-Path $ResultsRoot "green-validation"
$JtlFile = Join-Path $ResultDir "green-validation.jtl"
$JmeterLog = Join-Path $ResultDir "jmeter.log"
$HtmlReport = Join-Path $ResultDir "html-report"
$SummaryJson = Join-Path $ResultDir "summary.json"
$ComparisonJson = Join-Path $ResultDir "comparison.json"

function Fail-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "[FAIL] $Message"
    exit 1
}

function Format-Decision {
    param([bool]$Passed)
    if ($Passed) { return "PASS" }
    return "FAIL"
}

if (-not (Test-Path $TestPlan)) {
    Fail-Step "JMeter test plan not found: $TestPlan"
}

if (-not (Test-Path $BlueSummaryFile)) {
    Fail-Step "Blue baseline summary not found: $BlueSummaryFile"
}

if (-not (Get-Command jmeter -ErrorAction SilentlyContinue)) {
    Fail-Step "JMeter is not available in PATH."
}

$Blue = Get-Content $BlueSummaryFile -Raw | ConvertFrom-Json

Write-Host "[INFO] Target             : http://${TargetHost}:${TargetPort}"
Write-Host "[INFO] Expected version   : $ExpectedVersion"
Write-Host "[INFO] Threads            : $Threads"
Write-Host "[INFO] Ramp               : $RampSeconds seconds"
Write-Host "[INFO] Duration           : $DurationSeconds seconds"
Write-Host "[INFO] Pacing             : $PacingMs ms"
Write-Host "[INFO] Latency tolerance  : +$LatencyTolerancePct % vs Blue"
Write-Host "[INFO] Error tolerance    : +$ErrorTolerancePoints percentage point vs Blue"
Write-Host ""

Write-Host "------------------------------------------"
Write-Host " BLUE REFERENCE"
Write-Host "------------------------------------------"
Write-Host "Error Rate       : $($Blue.errorRatePct) %"
Write-Host "Average Response : $($Blue.averageResponseMs) ms"
Write-Host "P95 Response     : $($Blue.p95ResponseMs) ms"

$AllowedErrorRate = [math]::Round(([double]$Blue.errorRatePct + $ErrorTolerancePoints), 3)
$AllowedAverage = [math]::Round(([double]$Blue.averageResponseMs * (1 + ($LatencyTolerancePct / 100))), 2)
$AllowedP95 = [math]::Round(([double]$Blue.p95ResponseMs * (1 + ($LatencyTolerancePct / 100))), 2)

Write-Host ""
Write-Host "------------------------------------------"
Write-Host " GREEN ACCEPTANCE LIMITS"
Write-Host "------------------------------------------"
Write-Host "Error Rate       : <= $AllowedErrorRate %"
Write-Host "Average Response : <= $AllowedAverage ms"
Write-Host "P95 Response     : <= $AllowedP95 ms"

Write-Host ""
Write-Host "[INFO] Validating GREEN endpoint..."

try {
    $Health = Invoke-RestMethod `
        -Uri "http://${TargetHost}:${TargetPort}/health" `
        -Method Get `
        -TimeoutSec 10
}
catch {
    Fail-Step "Unable to reach GREEN preview endpoint. $($_.Exception.Message)"
}

if ($Health.status -ne "UP" -or $Health.version -ne $ExpectedVersion) {
    Fail-Step "Unexpected GREEN health response. Status='$($Health.status)', Version='$($Health.version)'."
}

Write-Host "[PASS] GREEN endpoint is healthy: $($Health.version)"

if (Test-Path $ResultDir) {
    Write-Host "[INFO] Removing previous Green validation results..."
    Remove-Item $ResultDir -Recurse -Force
}

New-Item -ItemType Directory -Path $ResultDir -Force | Out-Null

Write-Host ""
Write-Host "[INFO] Starting JMeter Green validation traffic..."

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
    Fail-Step "JMeter Green validation execution failed. Check: $JmeterLog"
}

if (-not (Test-Path $JtlFile)) {
    Fail-Step "JMeter result file was not created: $JtlFile"
}

Write-Host "[PASS] JMeter Green validation execution completed."

Write-Host ""
Write-Host "[INFO] Calculating Green summary..."

$Samples = @(Import-Csv $JtlFile)

if ($Samples.Count -eq 0) {
    Fail-Step "No JMeter samples found in $JtlFile"
}

$Elapsed = @(
    $Samples |
    ForEach-Object { [double]$_.elapsed } |
    Sort-Object
)

$Total = $Samples.Count
$Errors = @($Samples | Where-Object { $_.success -eq "false" }).Count
$Successes = $Total - $Errors
$ErrorRatePct = [math]::Round(($Errors / $Total) * 100, 3)
$AverageMs = [math]::Round((($Elapsed | Measure-Object -Average).Average), 2)
$MinMs = [math]::Round($Elapsed[0], 2)
$MaxMs = [math]::Round($Elapsed[-1], 2)

$P95Index = [math]::Ceiling($Elapsed.Count * 0.95) - 1
if ($P95Index -lt 0) {
    $P95Index = 0
}
$P95Ms = [math]::Round($Elapsed[$P95Index], 2)

$Summary = [ordered]@{
    environment = "GREEN"
    version = $ExpectedVersion
    endpoint = "http://${TargetHost}:${TargetPort}/api/orders"
    threads = $Threads
    rampSeconds = $RampSeconds
    durationSeconds = $DurationSeconds
    pacingMs = $PacingMs
    totalRequests = $Total
    successfulRequests = $Successes
    failedRequests = $Errors
    errorRatePct = $ErrorRatePct
    averageResponseMs = $AverageMs
    p95ResponseMs = $P95Ms
    minResponseMs = $MinMs
    maxResponseMs = $MaxMs
    generatedAt = (Get-Date).ToString("o")
}

$Summary | ConvertTo-Json | Set-Content -Path $SummaryJson -Encoding UTF8

$ErrorPass = $ErrorRatePct -le $AllowedErrorRate
$AveragePass = $AverageMs -le $AllowedAverage
$P95Pass = $P95Ms -le $AllowedP95

$OverallPass = $ErrorPass -and $AveragePass -and $P95Pass

$ErrorDelta = [math]::Round(($ErrorRatePct - [double]$Blue.errorRatePct), 3)

if ([double]$Blue.averageResponseMs -gt 0) {
    $AverageRegressionPct = [math]::Round((($AverageMs - [double]$Blue.averageResponseMs) / [double]$Blue.averageResponseMs) * 100, 2)
}
else {
    $AverageRegressionPct = 0
}

if ([double]$Blue.p95ResponseMs -gt 0) {
    $P95RegressionPct = [math]::Round((($P95Ms - [double]$Blue.p95ResponseMs) / [double]$Blue.p95ResponseMs) * 100, 2)
}
else {
    $P95RegressionPct = 0
}

$Comparison = [ordered]@{
    blue = [ordered]@{
        version = $Blue.version
        errorRatePct = [double]$Blue.errorRatePct
        averageResponseMs = [double]$Blue.averageResponseMs
        p95ResponseMs = [double]$Blue.p95ResponseMs
    }
    green = [ordered]@{
        version = $ExpectedVersion
        errorRatePct = $ErrorRatePct
        averageResponseMs = $AverageMs
        p95ResponseMs = $P95Ms
    }
    thresholds = [ordered]@{
        errorRateMaxPct = $AllowedErrorRate
        averageResponseMaxMs = $AllowedAverage
        p95ResponseMaxMs = $AllowedP95
        latencyTolerancePct = $LatencyTolerancePct
        errorTolerancePoints = $ErrorTolerancePoints
    }
    regressions = [ordered]@{
        errorRateDeltaPoints = $ErrorDelta
        averageResponseRegressionPct = $AverageRegressionPct
        p95RegressionPct = $P95RegressionPct
    }
    checks = [ordered]@{
        errorRate = (Format-Decision $ErrorPass)
        averageResponse = (Format-Decision $AveragePass)
        p95Response = (Format-Decision $P95Pass)
    }
    technicalGate = $(if ($OverallPass) { "PASS" } else { "FAIL" })
    recommendation = $(if ($OverallPass) { "CONTINUE_TO_AI_ANALYSIS" } else { "ABORT_GREEN" })
    generatedAt = (Get-Date).ToString("o")
}

$Comparison | ConvertTo-Json -Depth 5 | Set-Content -Path $ComparisonJson -Encoding UTF8

Write-Host ""
Write-Host "------------------------------------------"
Write-Host " GREEN VALIDATION SUMMARY"
Write-Host "------------------------------------------"
Write-Host "Version          : $ExpectedVersion"
Write-Host "Total Requests   : $Total"
Write-Host "Successful       : $Successes"
Write-Host "Failed           : $Errors"
Write-Host "Error Rate       : $ErrorRatePct %"
Write-Host "Average Response : $AverageMs ms"
Write-Host "P95 Response     : $P95Ms ms"
Write-Host "Minimum Response : $MinMs ms"
Write-Host "Maximum Response : $MaxMs ms"

Write-Host ""
Write-Host "------------------------------------------"
Write-Host " BLUE vs GREEN TECHNICAL GATE"
Write-Host "------------------------------------------"
Write-Host ("{0,-20} {1,-12} {2,-12} {3,-12} {4}" -f "Metric","Blue","Green","Limit","Result")
Write-Host ("{0,-20} {1,-12} {2,-12} {3,-12} {4}" -f "Error Rate","$($Blue.errorRatePct)%","$ErrorRatePct%","<=$AllowedErrorRate%","$(Format-Decision $ErrorPass)")
Write-Host ("{0,-20} {1,-12} {2,-12} {3,-12} {4}" -f "Average","$($Blue.averageResponseMs)ms","${AverageMs}ms","<=${AllowedAverage}ms","$(Format-Decision $AveragePass)")
Write-Host ("{0,-20} {1,-12} {2,-12} {3,-12} {4}" -f "P95","$($Blue.p95ResponseMs)ms","${P95Ms}ms","<=${AllowedP95}ms","$(Format-Decision $P95Pass)")

Write-Host ""
Write-Host "Regression:"
Write-Host "  Error delta : $ErrorDelta percentage points"
Write-Host "  Average     : $AverageRegressionPct %"
Write-Host "  P95         : $P95RegressionPct %"

Write-Host ""
Write-Host "[INFO] Results:"
Write-Host "       JTL        : $JtlFile"
Write-Host "       HTML       : $HtmlReport"
Write-Host "       Summary    : $SummaryJson"
Write-Host "       Comparison : $ComparisonJson"

Write-Host ""
Write-Host "=========================================="

if ($OverallPass) {
    Write-Host "GREEN TECHNICAL GATE RESULT: PASS"
    Write-Host "Recommendation: CONTINUE TO AI ANALYSIS"
    Write-Host "=========================================="
    exit 0
}
else {
    Write-Host "GREEN TECHNICAL GATE RESULT: FAIL"
    Write-Host "Recommendation: ABORT GREEN"
    Write-Host "=========================================="
    exit 2
}
