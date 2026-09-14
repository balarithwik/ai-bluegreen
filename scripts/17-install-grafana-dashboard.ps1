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

function Show-PortForwardDiagnostics {
    Write-Host ""
    Write-Host "------------------------------------------"
    Write-Host " GRAFANA PORT-FORWARD DIAGNOSTICS"
    Write-Host "------------------------------------------"

    if (Test-Path $PortForwardOut) {
        Write-Host "[INFO] stdout:"
        Get-Content $PortForwardOut -Tail 30 -ErrorAction SilentlyContinue | Out-Host
    }

    if (Test-Path $PortForwardErr) {
        Write-Host "[INFO] stderr:"
        Get-Content $PortForwardErr -Tail 30 -ErrorAction SilentlyContinue | Out-Host
    }

    Write-Host "[INFO] Grafana pod status:"
    kubectl get pods -n $Namespace -l "app.kubernetes.io/name=grafana" -o wide | Out-Host
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
Write-Host "[INFO] Waiting for Grafana pod readiness before API validation..."

kubectl wait `
    --for=condition=Ready `
    "pod/$GrafanaPod" `
    -n $Namespace `
    --timeout=120s | Out-Host

if ($LASTEXITCODE -ne 0) {
    kubectl get pod $GrafanaPod -n $Namespace -o wide | Out-Host
    Fail-Step "Grafana pod did not become Ready."
}
Write-Host "[PASS] Grafana pod is Ready."

$ExistingListener = Get-NetTCPConnection `
    -LocalPort $LocalPort `
    -State Listen `
    -ErrorAction SilentlyContinue |
    Select-Object -First 1

if ($ExistingListener) {
    $Owner = Get-Process -Id $ExistingListener.OwningProcess -ErrorAction SilentlyContinue
    $OwnerText = if ($Owner) { "$($Owner.ProcessName) PID $($Owner.Id)" } else { "PID $($ExistingListener.OwningProcess)" }
    Fail-Step "Local port $LocalPort is already in use by $OwnerText. Cleanup must free it before Grafana validation."
}

try {
    $KubectlPath = [string](Get-Command "kubectl.exe" -ErrorAction Stop).Source
}
catch {
    try {
        $KubectlPath = [string](Get-Command "kubectl" -ErrorAction Stop).Source
    }
    catch {
        Fail-Step "kubectl could not be resolved for Grafana port-forward."
    }
}

$KubeConfigPath = $env:KUBECONFIG
if ([string]::IsNullOrWhiteSpace($KubeConfigPath) -or -not (Test-Path $KubeConfigPath)) {
    if (Test-Path "C:\Users\Bala\.kube\config") {
        $KubeConfigPath = "C:\Users\Bala\.kube\config"
    }
}

if ([string]::IsNullOrWhiteSpace($KubeConfigPath) -or -not (Test-Path $KubeConfigPath)) {
    Fail-Step "Unable to resolve a valid kubeconfig for Grafana validation."
}

$KubeConfigPath = (Resolve-Path $KubeConfigPath).Path

Remove-Item $PortForwardOut -Force -ErrorAction SilentlyContinue
Remove-Item $PortForwardErr -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "[INFO] Starting temporary direct Grafana pod port-forward..."
Write-Host "[INFO] Pod mapping: localhost:$LocalPort -> $GrafanaPod:3000"

$Pf = $null

try {
    $Pf = Start-Process `
        -FilePath $KubectlPath `
        -ArgumentList @(
            "--kubeconfig", $KubeConfigPath,
            "port-forward",
            "pod/$GrafanaPod",
            "${LocalPort}:3000",
            "-n", $Namespace,
            "--address", "127.0.0.1"
        ) `
        -RedirectStandardOutput $PortForwardOut `
        -RedirectStandardError $PortForwardErr `
        -WindowStyle Hidden `
        -PassThru

    $Ready = $false

    for ($i = 0; $i -lt 45; $i++) {
        Start-Sleep -Seconds 1

        if ($Pf.HasExited) {
            Show-PortForwardDiagnostics
            Fail-Step "Grafana port-forward exited early with code $($Pf.ExitCode)."
        }

        try {
            $Health = Invoke-RestMethod `
                -Uri "http://127.0.0.1:$LocalPort/api/health" `
                -Method Get `
                -TimeoutSec 3

            if ($Health.database -eq "ok") {
                $Ready = $true
                break
            }
        }
        catch {}
    }

    if (-not $Ready) {
        Show-PortForwardDiagnostics
        Fail-Step "Grafana API did not become reachable on localhost:$LocalPort within 45 seconds."
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

    for ($i = 0; $i -lt 90; $i++) {
        Start-Sleep -Seconds 1

        try {
            $Search = Invoke-RestMethod `
                -Uri "http://127.0.0.1:$LocalPort/api/search?query=AI%20Blue-Green%20Deployment%20Intelligence%20Center" `
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
        Show-PortForwardDiagnostics
        Fail-Step "Grafana sidecar did not load the dashboard within 90 seconds."
    }

    Write-Host "[PASS] Dashboard is loaded in Grafana."
    Write-Host "[INFO] Dashboard UID: $($FoundDashboard.uid)"
}
finally {
    if ($Pf -and -not $Pf.HasExited) {
        Stop-Process -Id $Pf.Id -Force -ErrorAction SilentlyContinue
        Write-Host "[PASS] Temporary Grafana validation port-forward stopped."
    }

    Remove-Item $TempManifest -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "------------------------------------------"
Write-Host " DASHBOARD PANELS"
Write-Host "------------------------------------------"
Write-Host "Deployment & Traffic : Active environment/build, traffic split, routing history"
Write-Host "AI Intelligence      : Risk, confidence, decisions, LLM version, AI reason"
Write-Host "JMeter Validation    : Request counts, errors, latency, P95, throughput"
Write-Host "Kubernetes Health    : Pod readiness, restarts, CPU and memory"
Write-Host ""
Write-Host "=========================================="
Write-Host "GRAFANA DASHBOARD INSTALL RESULT: PASS"
Write-Host "Dashboard : AI Blue-Green Deployment Intelligence Center"
Write-Host "UID       : ai-bluegreen-intelligence"
Write-Host "Open via  : scripts\20-open-monitoring-dashboard.ps1"
Write-Host "URL       : http://localhost:$LocalPort/d/ai-bluegreen-intelligence"
Write-Host "=========================================="
Write-Host ""

exit 0
