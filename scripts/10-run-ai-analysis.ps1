$ErrorActionPreference = "Stop"

Write-Host "=========================================="
Write-Host " AI BLUE-GREEN LAB - AI RISK ANALYSIS"
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
$AiDir = Join-Path $ProjectRoot "ai-engine"
$ResultsDir = Join-Path $ProjectRoot "results\ai-analysis"

$Collector = Join-Path $AiDir "collect_metrics.py"
$RiskEngine = Join-Path $AiDir "ai_risk_engine.py"
$ComparisonFile = Join-Path $ProjectRoot "results\green-validation\comparison.json"
$TelemetryFile = Join-Path $ResultsDir "telemetry.json"
$DecisionFile = Join-Path $ResultsDir "decision.json"
$PortForwardOut = Join-Path $ResultsDir "prometheus-portforward.out.log"
$PortForwardErr = Join-Path $ResultsDir "prometheus-portforward.err.log"

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

$CurrentContext = (kubectl config current-context).Trim()

if ($LASTEXITCODE -ne 0 -or $CurrentContext -ne $ExpectedContext) {
    Fail-Step "Expected Kubernetes context '$ExpectedContext', but found '$CurrentContext'."
}

Write-Host "[PASS] Kubernetes context is $CurrentContext."

foreach ($RequiredFile in @($Collector, $RiskEngine, $ComparisonFile)) {
    if (-not (Test-Path $RequiredFile)) {
        Fail-Step "Required file not found: $RequiredFile"
    }
}

Write-Host "[PASS] AI analysis input files found."

$Comparison = Get-Content $ComparisonFile -Raw | ConvertFrom-Json

if ($Comparison.technicalGate -ne "PASS") {
    Fail-Step "Green technical gate is '$($Comparison.technicalGate)'. AI cannot override a failed technical gate."
}

Write-Host "[PASS] Green technical gate is PASS."

if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Fail-Step "Python is not available in PATH."
}

if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
    Fail-Step "Ollama is not available in PATH."
}

Write-Host ""
Write-Host "[INFO] Checking Ollama service..."

try {
    $OllamaVersion = Invoke-RestMethod `
        -Uri "http://localhost:11434/api/version" `
        -Method Get `
        -TimeoutSec 5

    Write-Host "[PASS] Ollama service is running."
}
catch {
    Fail-Step "Ollama service is not reachable on localhost:11434."
}

Write-Host "[INFO] Required AI model: $OllamaModel"

$OllamaList = ollama list | Out-String

if ($LASTEXITCODE -ne 0) {
    Fail-Step "Unable to query installed Ollama models."
}

if ($OllamaList -notmatch [regex]::Escape($OllamaModel)) {
    Fail-Step "Required model '$OllamaModel' was not found. Run: ollama pull $OllamaModel"
}

Write-Host "[PASS] $OllamaModel is available."

$BlueHash = Get-ServiceHash -ServiceName "ai-bluegreen-active"
$GreenHash = Get-ServiceHash -ServiceName "ai-bluegreen-preview"

if ([string]::IsNullOrWhiteSpace($BlueHash) -or [string]::IsNullOrWhiteSpace($GreenHash)) {
    Fail-Step "Unable to resolve Blue/Green ReplicaSet hashes."
}

if ($BlueHash -eq $GreenHash) {
    Fail-Step "Active and Preview point to the same ReplicaSet. Green must remain isolated before AI analysis."
}

Write-Host ""
Write-Host "[INFO] BLUE hash : $BlueHash"
Write-Host "[INFO] GREEN hash: $GreenHash"

if (Test-Path $ResultsDir) {
    Remove-Item $ResultsDir -Recurse -Force
}

New-Item -ItemType Directory -Path $ResultsDir -Force | Out-Null

$PortForwardProcess = $null

try {
    Write-Host ""
    Write-Host "[INFO] Starting temporary Prometheus port-forward on localhost:$PrometheusLocalPort..."

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

    $PrometheusReady = $false

    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1

        if ($PortForwardProcess.HasExited) {
            break
        }

        try {
            $ReadyResponse = Invoke-WebRequest `
                -Uri "$PrometheusUrl/-/ready" `
                -UseBasicParsing `
                -TimeoutSec 2

            if ($ReadyResponse.StatusCode -eq 200) {
                $PrometheusReady = $true
                break
            }
        }
        catch {
        }
    }

    if (-not $PrometheusReady) {
        if (Test-Path $PortForwardErr) {
            Write-Host ""
            Write-Host "[INFO] Port-forward error log:"
            Get-Content $PortForwardErr | Out-Host
        }

        Fail-Step "Prometheus port-forward did not become ready."
    }

    Write-Host "[PASS] Prometheus is reachable at $PrometheusUrl."

    Write-Host ""
    Write-Host "[INFO] Collecting Blue/Green runtime telemetry..."

    & python `
        $Collector `
        --prometheus-url $PrometheusUrl `
        --namespace $Namespace `
        --blue-hash $BlueHash `
        --green-hash $GreenHash `
        --expected-replicas 2 `
        --output $TelemetryFile | Out-Host

    if ($LASTEXITCODE -ne 0) {
        Fail-Step "Prometheus telemetry collection failed."
    }

    if (-not (Test-Path $TelemetryFile)) {
        Fail-Step "Telemetry output was not created."
    }

    Write-Host "[PASS] Runtime telemetry collected."

    Write-Host ""
    Write-Host "[INFO] Running deterministic + $OllamaModel contextual risk analysis..."

    & python `
        $RiskEngine `
        --comparison $ComparisonFile `
        --telemetry $TelemetryFile `
        --output $DecisionFile `
        --model $OllamaModel | Out-Host

    $AiExitCode = $LASTEXITCODE

    if (-not (Test-Path $DecisionFile)) {
        Fail-Step "AI decision output was not created."
    }

    $Decision = Get-Content $DecisionFile -Raw | ConvertFrom-Json

    Write-Host ""
    Write-Host "------------------------------------------"
    Write-Host " AI DECISION SUMMARY"
    Write-Host "------------------------------------------"
    Write-Host "Model           : $($Decision.model)"
    Write-Host "Base Risk Score : $($Decision.baseRiskScore)/100"
    Write-Host "AI Adjustment   : $($Decision.aiRiskAdjustment)"
    Write-Host "AI Hint         : $($Decision.aiDecisionHint) (advisory only)"
    Write-Host "AI Confidence   : $($Decision.aiConfidence)%"
    Write-Host "Final Risk Score: $($Decision.finalRiskScore)/100"
    Write-Host "Final Decision  : $($Decision.finalDecision)"
    Write-Host ""
    Write-Host "[INFO] Decision file: $DecisionFile"

    Write-Host ""
    Write-Host "=========================================="

    switch ($Decision.finalDecision) {
        "PROMOTE" {
            Write-Host "AI RISK ANALYSIS RESULT: PROMOTE"
            Write-Host "Green is eligible for production promotion."
            Write-Host "=========================================="
            exit 0
        }

        "PAUSE" {
            Write-Host "AI RISK ANALYSIS RESULT: PAUSE"
            Write-Host "Green requires review before promotion."
            Write-Host "=========================================="
            exit 3
        }

        "ABORT" {
            Write-Host "AI RISK ANALYSIS RESULT: ABORT"
            Write-Host "Green must not be promoted."
            Write-Host "=========================================="
            exit 4
        }

        default {
            Fail-Step "Unexpected AI decision '$($Decision.finalDecision)'."
        }
    }
}
finally {
    if ($PortForwardProcess -and -not $PortForwardProcess.HasExited) {
        Write-Host ""
        Write-Host "[INFO] Stopping temporary Prometheus port-forward..."

        Stop-Process `
            -Id $PortForwardProcess.Id `
            -Force `
            -ErrorAction SilentlyContinue

        Write-Host "[PASS] Prometheus port-forward stopped."
    }
}
