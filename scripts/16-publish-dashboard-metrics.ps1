$ErrorActionPreference = "Stop"

Write-Host "=========================================="
Write-Host " AI BLUE-GREEN LAB - PUBLISH DASHBOARD METRICS"
Write-Host "=========================================="
Write-Host ""

$ExpectedContext = "kind-ai-bluegreen"
$MonitoringNamespace = "monitoring"
$PushgatewayService = "ai-bluegreen-pushgateway"
$PrometheusService = "monitoring-kube-prometheus-prometheus"
$PushgatewayPort = 19091
$PrometheusPort = 19090
$JobName = "ai_bluegreen_intelligence"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

$Publisher = Join-Path $ProjectRoot "ai-engine\publish_observability_metrics.py"
$ResultDir = Join-Path $ProjectRoot "results\observability"
$MetricsFile = Join-Path $ResultDir "published-metrics.prom"

function Fail-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "[FAIL] $Message"
    exit 1
}

function Wait-HttpReady {
    param(
        [string]$Url,
        [int]$Seconds = 30
    )

    for ($i = 0; $i -lt $Seconds; $i++) {
        Start-Sleep -Seconds 1
        try {
            $Response = Invoke-WebRequest `
                -Uri $Url `
                -UseBasicParsing `
                -TimeoutSec 2

            if ($Response.StatusCode -eq 200) {
                return $true
            }
        }
        catch {}
    }

    return $false
}

$CurrentContext = (kubectl config current-context).Trim()
if ($LASTEXITCODE -ne 0 -or $CurrentContext -ne $ExpectedContext) {
    Fail-Step "Expected Kubernetes context '$ExpectedContext', found '$CurrentContext'."
}
Write-Host "[PASS] Kubernetes context is $CurrentContext."

if (-not (Test-Path $Publisher)) {
    Fail-Step "Metric publisher not found: $Publisher"
}

$Pushgateway = kubectl get svc $PushgatewayService `
    -n $MonitoringNamespace `
    --ignore-not-found `
    -o name

if ([string]::IsNullOrWhiteSpace($Pushgateway)) {
    Fail-Step "Pushgateway Service '$PushgatewayService' was not found."
}
Write-Host "[PASS] Pushgateway Service exists."

New-Item -ItemType Directory -Path $ResultDir -Force | Out-Null

$PushOut = Join-Path $ResultDir "pushgateway-portforward.out.log"
$PushErr = Join-Path $ResultDir "pushgateway-portforward.err.log"
$PromOut = Join-Path $ResultDir "prometheus-portforward.out.log"
$PromErr = Join-Path $ResultDir "prometheus-portforward.err.log"

$PushProcess = $null
$PromProcess = $null

try {
    Write-Host ""
    Write-Host "[INFO] Starting Pushgateway port-forward..."

    $PushProcess = Start-Process `
        -FilePath "kubectl" `
        -ArgumentList @(
            "port-forward",
            "svc/$PushgatewayService",
            "${PushgatewayPort}:9091",
            "-n",
            $MonitoringNamespace
        ) `
        -RedirectStandardOutput $PushOut `
        -RedirectStandardError $PushErr `
        -WindowStyle Hidden `
        -PassThru

    if (-not (Wait-HttpReady -Url "http://localhost:$PushgatewayPort/-/ready")) {
        Fail-Step "Pushgateway port-forward did not become Ready."
    }
    Write-Host "[PASS] Pushgateway is reachable."

    Write-Host ""
    Write-Host "[INFO] Publishing JMeter + AI + deployment metrics..."

    & python `
        $Publisher `
        --project-root $ProjectRoot `
        --pushgateway-url "http://localhost:$PushgatewayPort" `
        --job $JobName `
        --output $MetricsFile | Out-Host

    if ($LASTEXITCODE -ne 0) {
        Fail-Step "Metric publisher failed."
    }

    Write-Host "[PASS] Metrics were pushed to Pushgateway."

    $PushMetrics = Invoke-WebRequest `
        -Uri "http://localhost:$PushgatewayPort/metrics" `
        -UseBasicParsing `
        -TimeoutSec 10

    # Core metrics must exist after every dashboard publication.
    # AI metrics are required only after at least one real AI decision file exists.
    $RequiredMetrics = @(
        "jmeter_total_requests",
        "jmeter_successful_requests",
        "jmeter_failed_requests",
        "ai_bluegreen_traffic_percent",
        "ai_bluegreen_environment_state",
        "ai_bluegreen_release_info"
    )

    $PreAiDecision = Join-Path $ProjectRoot "results\ai-analysis\decision.json"
    $PostAiDecision = Join-Path $ProjectRoot "results\post-promotion\decision.json"

    if ((Test-Path $PreAiDecision) -or (Test-Path $PostAiDecision)) {
        $RequiredMetrics += "ai_bluegreen_final_risk_score"
        $RequiredMetrics += "ai_bluegreen_llm_info"
        $RequiredMetrics += "ai_bluegreen_ai_reason_info"
    }
    else {
        Write-Host "[INFO] No AI decision exists yet. AI risk metrics are intentionally not expected."
    }

    foreach ($RequiredMetric in $RequiredMetrics) {
        if ($PushMetrics.Content -notmatch $RequiredMetric) {
            Fail-Step "Required metric '$RequiredMetric' is missing from Pushgateway."
        }
    }

    Write-Host "[PASS] Required dashboard metrics exist in Pushgateway."

    Write-Host ""
    Write-Host "[INFO] Starting Prometheus port-forward to verify scraping..."

    $PromProcess = Start-Process `
        -FilePath "kubectl" `
        -ArgumentList @(
            "port-forward",
            "svc/$PrometheusService",
            "${PrometheusPort}:9090",
            "-n",
            $MonitoringNamespace
        ) `
        -RedirectStandardOutput $PromOut `
        -RedirectStandardError $PromErr `
        -WindowStyle Hidden `
        -PassThru

    if (-not (Wait-HttpReady -Url "http://localhost:$PrometheusPort/-/ready")) {
        Fail-Step "Prometheus port-forward did not become Ready."
    }
    Write-Host "[PASS] Prometheus is reachable."

    Write-Host "[INFO] Waiting for the 5-second ServiceMonitor scrape..."
    Start-Sleep -Seconds 8

    $Query = [uri]::EscapeDataString('jmeter_total_requests{job="ai_bluegreen_intelligence"}')
    $PrometheusResponse = Invoke-RestMethod `
        -Uri "http://localhost:$PrometheusPort/api/v1/query?query=$Query" `
        -Method Get `
        -TimeoutSec 10

    if (
        $PrometheusResponse.status -ne "success" -or
        $PrometheusResponse.data.result.Count -eq 0
    ) {
        Fail-Step "Prometheus has not scraped jmeter_total_requests from Pushgateway."
    }

    Write-Host "[PASS] Prometheus is scraping the JMeter metrics."

    Write-Host ""
    Write-Host "------------------------------------------"
    Write-Host " PROMETHEUS REQUEST COUNT SNAPSHOT"
    Write-Host "------------------------------------------"

    foreach ($Result in $PrometheusResponse.data.result) {
        $Phase = $Result.metric.test_phase
        $Value = $Result.value[1]
        Write-Host ("{0,-20}: {1}" -f $Phase, $Value)
    }

    Write-Host ""
    Write-Host "=========================================="
    Write-Host "OBSERVABILITY METRIC PUBLISH RESULT: PASS"
    Write-Host "JMeter request metrics : READY"
    Write-Host "AI intelligence metrics: READY"
    Write-Host "Deployment state metrics: READY"
    Write-Host "Prometheus scrape       : VERIFIED"
    Write-Host "=========================================="
}
finally {
    if ($PushProcess -and -not $PushProcess.HasExited) {
        Stop-Process -Id $PushProcess.Id -Force -ErrorAction SilentlyContinue
    }

    if ($PromProcess -and -not $PromProcess.HasExited) {
        Stop-Process -Id $PromProcess.Id -Force -ErrorAction SilentlyContinue
    }
}

exit 0
