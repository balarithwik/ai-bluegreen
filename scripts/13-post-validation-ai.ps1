$ErrorActionPreference = "Stop"

Write-Host "=========================================="
Write-Host " AI BLUE-GREEN LAB - POST-VALIDATION AI"
Write-Host "=========================================="
Write-Host ""

$ExpectedContext = "kind-ai-bluegreen"
$Namespace = "ai-bluegreen"
$MonitoringNamespace = "monitoring"
$PrometheusService = "monitoring-kube-prometheus-prometheus"
$PrometheusLocalPort = 19090
$PrometheusUrl = "http://localhost:$PrometheusLocalPort"
$OllamaModel = "qwen3:4b-instruct"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

$PromotionStateFile = Join-Path $ProjectRoot "results\promotion\promotion-state.json"
$ResultDir = Join-Path $ProjectRoot "results\post-promotion"
$ComparisonFile = Join-Path $ResultDir "comparison.json"
$TelemetryFile = Join-Path $ResultDir "telemetry.json"
$DecisionFile = Join-Path $ResultDir "decision.json"
$FinalStateFile = Join-Path $ResultDir "final-state.json"
$PortForwardOut = Join-Path $ResultDir "prometheus-portforward.out.log"
$PortForwardErr = Join-Path $ResultDir "prometheus-portforward.err.log"

$AiDir = Join-Path $ProjectRoot "ai-engine"
$Collector = Join-Path $AiDir "collect_metrics.py"
$RiskEngine = Join-Path $AiDir "ai_risk_engine.py"

function Fail-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "[FAIL] $Message"
    exit 1
}

$CurrentContext = (kubectl config current-context).Trim()
if ($LASTEXITCODE -ne 0 -or $CurrentContext -ne $ExpectedContext) {
    Fail-Step "Expected Kubernetes context '$ExpectedContext', found '$CurrentContext'."
}
Write-Host "[PASS] Kubernetes context is $CurrentContext."

foreach ($Required in @($PromotionStateFile,$ComparisonFile,$Collector,$RiskEngine)) {
    if (-not (Test-Path $Required)) {
        Fail-Step "Required file not found: $Required"
    }
}

$Promotion = Get-Content $PromotionStateFile -Raw | ConvertFrom-Json
$Comparison = Get-Content $ComparisonFile -Raw | ConvertFrom-Json

Write-Host "[INFO] Post-validation JMeter evidence loaded."
Write-Host "[INFO] Production acceptance : $($Comparison.productionAcceptance)"
Write-Host "[INFO] AI receives comparison + runtime telemetry only."
Write-Host "[INFO] Demo scenario metadata is NOT provided to the AI engine."

$PortForwardProcess = $null

try {
    Write-Host ""
    Write-Host "[INFO] Starting temporary Prometheus port-forward..."

    $Existing = Get-NetTCPConnection -LocalPort $PrometheusLocalPort -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1

    if (-not $Existing) {
        $PortForwardProcess = Start-Process `
            -FilePath "kubectl" `
            -ArgumentList @(
                "port-forward",
                "svc/$PrometheusService",
                "${PrometheusLocalPort}:9090",
                "-n",
                $MonitoringNamespace
            ) `
            -RedirectStandardOutput $PortForwardOut `
            -RedirectStandardError $PortForwardErr `
            -WindowStyle Hidden `
            -PassThru
    }

    $Ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        try {
            $Response = Invoke-WebRequest -Uri "$PrometheusUrl/-/ready" -UseBasicParsing -TimeoutSec 2
            if ($Response.StatusCode -eq 200) {
                $Ready = $true
                break
            }
        }
        catch {}
    }

    if (-not $Ready) {
        Fail-Step "Prometheus did not become reachable."
    }

    Write-Host "[PASS] Prometheus is reachable."

    Write-Host ""
    Write-Host "[INFO] Collecting fresh production runtime telemetry..."

    & python `
        $Collector `
        --prometheus-url $PrometheusUrl `
        --namespace $Namespace `
        --blue-hash $Promotion.blueHash `
        --green-hash $Promotion.greenHash `
        --expected-replicas 2 `
        --output $TelemetryFile | Out-Host

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $TelemetryFile)) {
        Fail-Step "Prometheus telemetry collection failed."
    }

    Write-Host "[PASS] Runtime telemetry collected."

    Write-Host ""
    Write-Host "[INFO] Running independent post-validation AI analysis..."

    & python `
        $RiskEngine `
        --comparison $ComparisonFile `
        --telemetry $TelemetryFile `
        --output $DecisionFile `
        --model $OllamaModel | Out-Host

    $AiExitCode = $LASTEXITCODE

    if (-not (Test-Path $DecisionFile)) {
        Fail-Step "Post-validation AI decision file was not generated."
    }

    $Decision = Get-Content $DecisionFile -Raw | ConvertFrom-Json

    $FinalAction = "ROLLBACK_REQUIRED"
    if ($Decision.finalDecision -eq "PROMOTE") {
        $FinalAction = "KEEP_GREEN"
    }

    $FinalState = [ordered]@{
        finalAction = $FinalAction
        productionVersion = "v2-healthy"
        productionAcceptance = $Comparison.productionAcceptance
        technicalGate = $Comparison.technicalGate
        aiModel = $Decision.model
        aiFinalRiskScore = $Decision.finalRiskScore
        aiFinalDecision = $Decision.finalDecision
        aiConfidence = $Decision.aiConfidence
        aiExitCode = $AiExitCode
        scenarioKnowledgeProvidedToAI = $false
        generatedAt = (Get-Date).ToString("o")
    }

    $FinalState | ConvertTo-Json -Depth 6 | Set-Content $FinalStateFile -Encoding UTF8

    Write-Host ""
    Write-Host "------------------------------------------"
    Write-Host " POST-VALIDATION AI DECISION"
    Write-Host "------------------------------------------"
    Write-Host "Model                 : $($Decision.model)"
    Write-Host "Production Acceptance : $($Comparison.productionAcceptance)"
    Write-Host "AI Risk Score         : $($Decision.finalRiskScore)/100"
    Write-Host "AI Decision           : $($Decision.finalDecision)"
    Write-Host "Final Action          : $FinalAction"
    Write-Host ""

    if ($FinalAction -eq "KEEP_GREEN") {
        Write-Host "=========================================="
        Write-Host "POST-VALIDATION RESULT: KEEP_GREEN"
        Write-Host "Production remains on GREEN."
        Write-Host "=========================================="
        exit 0
    }

    Write-Host "=========================================="
    Write-Host "POST-VALIDATION RESULT: ROLLBACK_REQUIRED"
    Write-Host "AI/policy evidence does not authorize retaining GREEN."
    Write-Host "=========================================="
    exit 4
}
finally {
    if ($PortForwardProcess -and -not $PortForwardProcess.HasExited) {
        Stop-Process -Id $PortForwardProcess.Id -Force -ErrorAction SilentlyContinue
        Write-Host "[PASS] Temporary Prometheus port-forward stopped."
    }
}
