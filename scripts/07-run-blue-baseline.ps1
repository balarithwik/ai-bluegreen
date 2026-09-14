param(
    [int]$Threads = 10,
    [int]$RampSeconds = 10,
    [int]$DurationSeconds = 60,
    [int]$PacingMs = 1000
)

$ErrorActionPreference = "Stop"

Write-Host "=========================================="
Write-Host " AI BLUE-GREEN LAB - BLUE BASELINE TEST"
Write-Host "=========================================="
Write-Host ""

$TargetHost = "localhost"
$TargetPort = 8081
$ExpectedVersion = "v1-healthy"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$JmeterDir = Join-Path $ProjectRoot "jmeter"
$TestPlan = Join-Path $JmeterDir "bluegreen-validation.jmx"

$ResultsRoot = Join-Path $ProjectRoot "results"
$ResultDir = Join-Path $ResultsRoot "blue-baseline"
$JtlFile = Join-Path $ResultDir "blue-baseline.jtl"
$JmeterLog = Join-Path $ResultDir "jmeter.log"
$HtmlReport = Join-Path $ResultDir "html-report"
$SummaryJson = Join-Path $ResultDir "summary.json"

function Fail-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "[FAIL] $Message"
    exit 1
}

if (-not (Test-Path $TestPlan)) {
    Fail-Step "JMeter test plan not found: $TestPlan"
}

if (-not (Get-Command jmeter -ErrorAction SilentlyContinue)) {
    Fail-Step "JMeter is not available in PATH."
}

Write-Host "[INFO] Target          : http://${TargetHost}:${TargetPort}"
Write-Host "[INFO] Expected version: $ExpectedVersion"
Write-Host "[INFO] Threads         : $Threads"
Write-Host "[INFO] Ramp            : $RampSeconds seconds"
Write-Host "[INFO] Duration        : $DurationSeconds seconds"
Write-Host "[INFO] Pacing          : $PacingMs ms"
Write-Host ""

Write-Host "[INFO] Validating BLUE endpoint..."

try {
    $Health = Invoke-RestMethod `
        -Uri "http://${TargetHost}:${TargetPort}/health" `
        -Method Get `
        -TimeoutSec 10
}
catch {
    Fail-Step "Unable to reach BLUE endpoint. $($_.Exception.Message)"
}

if ($Health.status -ne "UP" -or $Health.version -ne $ExpectedVersion) {
    Fail-Step "Unexpected BLUE health response. Status='$($Health.status)', Version='$($Health.version)'."
}

Write-Host "[PASS] BLUE endpoint is healthy: $($Health.version)"

if (Test-Path $ResultDir) {
    Write-Host "[INFO] Removing previous Blue baseline results..."
    Remove-Item $ResultDir -Recurse -Force
}

New-Item -ItemType Directory -Path $ResultDir -Force | Out-Null

Write-Host ""
Write-Host "[INFO] Starting JMeter Blue baseline traffic..."

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
    Fail-Step "JMeter Blue baseline execution failed. Check: $JmeterLog"
}

if (-not (Test-Path $JtlFile)) {
    Fail-Step "JMeter result file was not created: $JtlFile"
}

Write-Host "[PASS] JMeter Blue baseline execution completed."

Write-Host ""
Write-Host "[INFO] Calculating baseline summary..."

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
    environment = "BLUE"
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

Write-Host ""
Write-Host "------------------------------------------"
Write-Host " BLUE BASELINE SUMMARY"
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

Write-Host "[INFO] Results:"
Write-Host "       JTL         : $JtlFile"
Write-Host "       HTML report : $HtmlReport"
Write-Host "       Summary     : $SummaryJson"

Write-Host ""
Write-Host "=========================================="
Write-Host "BLUE BASELINE TEST RESULT: PASS"
Write-Host "=========================================="

exit 0
