$ErrorActionPreference = "Stop"

Write-Host "=========================================="
Write-Host " AI BLUE-GREEN LAB - INSTALL PUSHGATEWAY"
Write-Host "=========================================="
Write-Host ""

$ExpectedContext = "kind-ai-bluegreen"
$Namespace = "monitoring"
$ReleaseName = "ai-bluegreen-pushgateway"
$Chart = "prometheus-community/prometheus-pushgateway"
$ChartVersion = "3.8.0"
$ServiceName = "ai-bluegreen-pushgateway"
$LocalPort = 19091

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$ValuesFile = Join-Path $ProjectRoot "k8s\pushgateway-values.yaml"

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

if (-not (Test-Path $ValuesFile)) {
    Fail-Step "Pushgateway values file not found: $ValuesFile"
}

$MonitoringNamespace = kubectl get namespace $Namespace --ignore-not-found -o name
if ([string]::IsNullOrWhiteSpace($MonitoringNamespace)) {
    Fail-Step "Monitoring namespace '$Namespace' does not exist. Run monitoring installation first."
}
Write-Host "[PASS] Monitoring namespace exists."

$PrometheusCRD = kubectl get crd servicemonitors.monitoring.coreos.com --ignore-not-found -o name
if ([string]::IsNullOrWhiteSpace($PrometheusCRD)) {
    Fail-Step "ServiceMonitor CRD is missing. kube-prometheus-stack must be installed first."
}
Write-Host "[PASS] ServiceMonitor CRD is available."

Write-Host ""
Write-Host "[INFO] Ensuring prometheus-community Helm repository is available..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update | Out-Host
if ($LASTEXITCODE -ne 0) {
    Fail-Step "Unable to add/update prometheus-community Helm repository."
}

helm repo update | Out-Host
if ($LASTEXITCODE -ne 0) {
    Fail-Step "Helm repository update failed."
}
Write-Host "[PASS] Helm repository is ready."

Write-Host ""
Write-Host "[INFO] Installing/upgrading Prometheus Pushgateway chart $ChartVersion..."

helm upgrade --install `
    $ReleaseName `
    $Chart `
    --version $ChartVersion `
    --namespace $Namespace `
    --values $ValuesFile `
    --wait `
    --timeout 5m | Out-Host

if ($LASTEXITCODE -ne 0) {
    Fail-Step "Pushgateway Helm installation failed."
}

Write-Host "[PASS] Pushgateway Helm release is deployed."

kubectl rollout status deployment/$ServiceName -n $Namespace --timeout=120s | Out-Host
if ($LASTEXITCODE -ne 0) {
    Fail-Step "Pushgateway deployment did not become Ready."
}
Write-Host "[PASS] Pushgateway deployment is Ready."

$Service = kubectl get svc $ServiceName -n $Namespace --ignore-not-found -o name
if ([string]::IsNullOrWhiteSpace($Service)) {
    Fail-Step "Pushgateway Service '$ServiceName' was not created."
}
Write-Host "[PASS] Pushgateway Service exists."

$ServiceMonitor = kubectl get servicemonitor $ServiceName -n $Namespace --ignore-not-found -o name
if ([string]::IsNullOrWhiteSpace($ServiceMonitor)) {
    Fail-Step "Pushgateway ServiceMonitor '$ServiceName' was not created."
}
Write-Host "[PASS] Pushgateway ServiceMonitor exists."

$SmRelease = kubectl get servicemonitor $ServiceName -n $Namespace -o jsonpath='{.metadata.labels.release}'
if ($SmRelease -ne "monitoring") {
    Fail-Step "ServiceMonitor release label is '$SmRelease'; expected 'monitoring'."
}
Write-Host "[PASS] ServiceMonitor has release=monitoring."

Write-Host ""
Write-Host "[INFO] Running Pushgateway connectivity smoke test..."

$PortForwardOut = Join-Path $env:TEMP "ai-bluegreen-pushgateway-pf.out.log"
$PortForwardErr = Join-Path $env:TEMP "ai-bluegreen-pushgateway-pf.err.log"
$Pf = $null

try {
    $Pf = Start-Process `
        -FilePath "kubectl" `
        -ArgumentList @(
            "port-forward",
            "svc/$ServiceName",
            "${LocalPort}:9091",
            "-n",
            $Namespace
        ) `
        -RedirectStandardOutput $PortForwardOut `
        -RedirectStandardError $PortForwardErr `
        -WindowStyle Hidden `
        -PassThru

    $Ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        if ($Pf.HasExited) { break }

        try {
            $Response = Invoke-WebRequest `
                -Uri "http://localhost:$LocalPort/-/ready" `
                -UseBasicParsing `
                -TimeoutSec 2

            if ($Response.StatusCode -eq 200) {
                $Ready = $true
                break
            }
        }
        catch {}
    }

    if (-not $Ready) {
        Fail-Step "Pushgateway port-forward did not become Ready."
    }

    # Pushgateway expects Prometheus exposition text with LF line endings.
    # Avoid a Windows here-string here because CRLF can be parsed as "gauge\r".
    $SmokeMetric = "# TYPE ai_bluegreen_pushgateway_smoke gauge`n" +
                   "ai_bluegreen_pushgateway_smoke 1`n"

    Invoke-WebRequest `
        -Uri "http://localhost:$LocalPort/metrics/job/ai_bluegreen_smoke" `
        -Method Put `
        -Body $SmokeMetric `
        -ContentType "text/plain; version=0.0.4" `
        -UseBasicParsing `
        -TimeoutSec 10 | Out-Null

    Write-Host "[PASS] Test metric was pushed successfully."

    $Metrics = Invoke-WebRequest `
        -Uri "http://localhost:$LocalPort/metrics" `
        -UseBasicParsing `
        -TimeoutSec 10

    if ($Metrics.Content -notmatch "ai_bluegreen_pushgateway_smoke") {
        Fail-Step "Smoke metric was not found in Pushgateway."
    }

    Write-Host "[PASS] Pushgateway exposes the test metric."
}
finally {
    if ($Pf -and -not $Pf.HasExited) {
        Stop-Process -Id $Pf.Id -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "------------------------------------------"
Write-Host " PUSHGATEWAY RESOURCES"
Write-Host "------------------------------------------"
kubectl get deployment,svc,servicemonitor -n $Namespace | Select-String "ai-bluegreen-pushgateway" | Out-Host

Write-Host ""
Write-Host "=========================================="
Write-Host "PUSHGATEWAY INSTALLATION RESULT: PASS"
Write-Host "Service        : $ServiceName"
Write-Host "Namespace      : $Namespace"
Write-Host "Chart Version  : $ChartVersion"
Write-Host "Scrape Interval: 5s"
Write-Host "=========================================="

exit 0
