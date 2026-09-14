$ErrorActionPreference = "Stop"

Write-Host "=========================================="
Write-Host " AI BLUE-GREEN LAB - INSTALL GRAFANA DASHBOARD"
Write-Host "=========================================="
Write-Host ""

$ExpectedContext = "kind-ai-bluegreen"
$Namespace = "monitoring"
$GrafanaService = "monitoring-grafana"
$GrafanaSecret = "monitoring-grafana"
$DashboardConfigMap = "ai-bluegreen-intelligence-dashboard"
$LocalPort = 3001

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$DashboardFile = Join-Path $ProjectRoot "grafana\ai-bluegreen-intelligence.json"
$TempManifest = Join-Path $env:TEMP "ai-bluegreen-dashboard-configmap.yaml"
$PortForwardOut = Join-Path $env:TEMP "ai-bluegreen-grafana-pf.out.log"
$PortForwardErr = Join-Path $env:TEMP "ai-bluegreen-grafana-pf.err.log"

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

if (-not (Test-Path $DashboardFile)) {
    Fail-Step "Dashboard JSON not found: $DashboardFile"
}
Write-Host "[PASS] Dashboard JSON exists."

$Grafana = kubectl get svc $GrafanaService -n $Namespace --ignore-not-found -o name
if ([string]::IsNullOrWhiteSpace($Grafana)) {
    Fail-Step "Grafana Service '$GrafanaService' was not found."
}
Write-Host "[PASS] Grafana Service exists."

Write-Host ""
Write-Host "[INFO] Creating/updating Grafana dashboard ConfigMap..."

kubectl create configmap $DashboardConfigMap `
    -n $Namespace `
    --from-file=ai-bluegreen-intelligence.json="$DashboardFile" `
    --dry-run=client `
    -o yaml | Set-Content -Path $TempManifest -Encoding UTF8

if ($LASTEXITCODE -ne 0) {
    Fail-Step "Unable to generate dashboard ConfigMap."
}

kubectl apply -f $TempManifest | Out-Host
if ($LASTEXITCODE -ne 0) {
    Fail-Step "Unable to apply dashboard ConfigMap."
}

kubectl label configmap $DashboardConfigMap `
    -n $Namespace `
    grafana_dashboard=1 `
    --overwrite | Out-Host

if ($LASTEXITCODE -ne 0) {
    Fail-Step "Unable to label dashboard ConfigMap."
}

Write-Host "[PASS] Dashboard ConfigMap is installed with grafana_dashboard=1."

$GrafanaPod = kubectl get pods `
    -n $Namespace `
    -l "app.kubernetes.io/name=grafana" `
    -o jsonpath='{.items[0].metadata.name}'

if ([string]::IsNullOrWhiteSpace($GrafanaPod)) {
    Fail-Step "Grafana pod was not found."
}

Write-Host "[PASS] Grafana pod: $GrafanaPod"

Write-Host ""
Write-Host "[INFO] Starting temporary Grafana port-forward for validation..."

$Pf = $null

try {
    $Pf = Start-Process `
        -FilePath "kubectl" `
        -ArgumentList @(
            "port-forward",
            "svc/$GrafanaService",
            "${LocalPort}:80",
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
            $Health = Invoke-RestMethod `
                -Uri "http://localhost:$LocalPort/api/health" `
                -Method Get `
                -TimeoutSec 2

            if ($Health.database -eq "ok") {
                $Ready = $true
                break
            }
        }
        catch {}
    }

    if (-not $Ready) {
        Fail-Step "Grafana did not become reachable."
    }

    Write-Host "[PASS] Grafana API is healthy."

    $UserB64 = kubectl get secret $GrafanaSecret -n $Namespace -o jsonpath='{.data.admin-user}'
    $PassB64 = kubectl get secret $GrafanaSecret -n $Namespace -o jsonpath='{.data.admin-password}'

    if ([string]::IsNullOrWhiteSpace($UserB64) -or [string]::IsNullOrWhiteSpace($PassB64)) {
        Fail-Step "Unable to retrieve Grafana admin credentials."
    }

    $AdminUser = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($UserB64))
    $AdminPassword = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($PassB64))
    $TokenBytes = [Text.Encoding]::ASCII.GetBytes("${AdminUser}:${AdminPassword}")
    $BasicToken = [Convert]::ToBase64String($TokenBytes)
    $Headers = @{ Authorization = "Basic $BasicToken" }

    Write-Host "[INFO] Waiting for Grafana sidecar to load the dashboard..."

    $Found = $false
    $FoundDashboard = $null

    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 1

        try {
            $Search = Invoke-RestMethod `
                -Uri "http://localhost:$LocalPort/api/search?query=AI%20Blue-Green%20Deployment%20Intelligence%20Center" `
                -Headers $Headers `
                -Method Get `
                -TimeoutSec 3

            if ($Search.Count -gt 0) {
                $Found = $true
                $FoundDashboard = $Search[0]
                break
            }
        }
        catch {}
    }

    if (-not $Found) {
        Fail-Step "Grafana sidecar did not load the dashboard within 60 seconds."
    }

    Write-Host "[PASS] Dashboard is loaded in Grafana."
    Write-Host "[INFO] Dashboard UID: $($FoundDashboard.uid)"
}
finally {
    if ($Pf -and -not $Pf.HasExited) {
        Stop-Process -Id $Pf.Id -Force -ErrorAction SilentlyContinue
    }

    Remove-Item $TempManifest -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "------------------------------------------"
Write-Host " DASHBOARD PANELS"
Write-Host "------------------------------------------"
Write-Host "Deployment & Traffic : Active env/version, traffic split, routing history"
Write-Host "AI Intelligence      : Risk, confidence, decisions, regression factors"
Write-Host "JMeter Validation    : Request counts, errors, latency, P95, throughput"
Write-Host "Kubernetes Health    : Pod readiness, restarts, CPU and memory"
Write-Host ""
Write-Host "=========================================="
Write-Host "GRAFANA DASHBOARD INSTALL RESULT: PASS"
Write-Host "Dashboard : AI Blue-Green Deployment Intelligence Center"
Write-Host "UID       : ai-bluegreen-intelligence"
Write-Host "Open via  : kubectl port-forward svc/$GrafanaService ${LocalPort}:80 -n $Namespace"
Write-Host "URL       : http://localhost:$LocalPort/d/ai-bluegreen-intelligence"
Write-Host "=========================================="

exit 0
