$ErrorActionPreference = "Stop"

Write-Host "=========================================="
Write-Host " AI BLUE-GREEN LAB - ENABLE GRAFANA ANONYMOUS VIEWER"
Write-Host "=========================================="
Write-Host ""

$ExpectedContext = "kind-ai-bluegreen"
$Namespace = "monitoring"
$ReleaseName = "monitoring"
$Chart = "prometheus-community/kube-prometheus-stack"
$ChartVersion = "88.2.0"
$GrafanaDeployment = "monitoring-grafana"
$GrafanaService = "monitoring-grafana"
$LocalPort = 3001
$DashboardUid = "ai-bluegreen-intelligence"
$DashboardUrl = "http://localhost:$LocalPort/d/${DashboardUid}?orgId=1&refresh=5s"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$ValuesFile = Join-Path $ProjectRoot "k8s\grafana-anonymous-values.yaml"

function Fail-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "[FAIL] $Message"
    exit 1
}

function Test-GrafanaHealth {
    try {
        $Health = Invoke-RestMethod `
            -Uri "http://localhost:$LocalPort/api/health" `
            -Method Get `
            -TimeoutSec 3

        return ($Health.database -eq "ok")
    }
    catch {
        return $false
    }
}

$CurrentContext = (kubectl config current-context).Trim()
if ($LASTEXITCODE -ne 0 -or $CurrentContext -ne $ExpectedContext) {
    Fail-Step "Expected Kubernetes context '$ExpectedContext', found '$CurrentContext'."
}
Write-Host "[PASS] Kubernetes context is $CurrentContext."

if (-not (Test-Path $ValuesFile)) {
    Fail-Step "Grafana anonymous values file not found: $ValuesFile"
}
Write-Host "[PASS] Anonymous-access values file exists."

$Release = helm list -n $Namespace -o json | ConvertFrom-Json |
    Where-Object { $_.name -eq $ReleaseName }

if ($null -eq $Release) {
    Fail-Step "Monitoring Helm release '$ReleaseName' does not exist."
}
Write-Host "[PASS] Monitoring Helm release exists."

Write-Host ""
Write-Host "[INFO] Enabling Grafana anonymous Viewer access..."

helm upgrade `
    $ReleaseName `
    $Chart `
    --namespace $Namespace `
    --version $ChartVersion `
    --reuse-values `
    --values $ValuesFile `
    --wait `
    --timeout 10m | Out-Host

if ($LASTEXITCODE -ne 0) {
    Fail-Step "Unable to update Grafana anonymous access configuration."
}

Write-Host "[PASS] Monitoring release updated."

kubectl rollout status deployment/$GrafanaDeployment `
    -n $Namespace `
    --timeout=180s | Out-Host

if ($LASTEXITCODE -ne 0) {
    Fail-Step "Grafana deployment did not become Ready."
}
Write-Host "[PASS] Grafana deployment is Ready."

$ExistingListener = Get-NetTCPConnection `
    -LocalPort $LocalPort `
    -State Listen `
    -ErrorAction SilentlyContinue |
    Select-Object -First 1

if ($ExistingListener) {
    Write-Host "[INFO] Existing listener found on localhost:$LocalPort (PID $($ExistingListener.OwningProcess))."

    if (Test-GrafanaHealth) {
        Write-Host "[PASS] Existing Grafana port-forward is healthy."
    }
    else {
        Write-Host "[WARN] Existing listener is stale/unhealthy. Stopping PID $($ExistingListener.OwningProcess)..."

        Stop-Process `
            -Id ([int]$ExistingListener.OwningProcess) `
            -Force `
            -ErrorAction SilentlyContinue

        Start-Sleep -Seconds 2

        $StillListening = Get-NetTCPConnection `
            -LocalPort $LocalPort `
            -State Listen `
            -ErrorAction SilentlyContinue |
            Select-Object -First 1

        if ($StillListening) {
            Fail-Step "Port $LocalPort is still occupied by PID $($StillListening.OwningProcess)."
        }

        Write-Host "[PASS] Stale Grafana port-forward removed."
        $ExistingListener = $null
    }
}

$Pf = $null
$StartedTemporaryPf = $false

try {
    if (-not $ExistingListener) {
        Write-Host "[INFO] Starting fresh Grafana port-forward..."

        $Pf = Start-Process `
            -FilePath "kubectl" `
            -ArgumentList @(
                "port-forward",
                "svc/$GrafanaService",
                "${LocalPort}:80",
                "-n",
                $Namespace
            ) `
            -WindowStyle Hidden `
            -PassThru

        $StartedTemporaryPf = $true
    }

    $Ready = $false

    for ($i = 0; $i -lt 45; $i++) {
        Start-Sleep -Seconds 1

        if (Test-GrafanaHealth) {
            $Ready = $true
            break
        }

        if ($StartedTemporaryPf -and $Pf.HasExited) {
            break
        }
    }

    if (-not $Ready) {
        Fail-Step "Grafana did not become reachable on localhost:$LocalPort."
    }

    Write-Host "[PASS] Grafana is reachable."

    $DashboardResponse = Invoke-WebRequest `
        -Uri $DashboardUrl `
        -UseBasicParsing `
        -TimeoutSec 10

    if ($DashboardResponse.StatusCode -lt 200 -or $DashboardResponse.StatusCode -ge 400) {
        Fail-Step "Dashboard returned HTTP $($DashboardResponse.StatusCode)."
    }

    $FinalUri = [string]$DashboardResponse.BaseResponse.ResponseUri.AbsoluteUri

    if ($FinalUri -match "/login") {
        Fail-Step "Grafana still redirects the dashboard to /login."
    }

    Write-Host "[PASS] Dashboard is reachable without authentication."
    Write-Host "[PASS] Anonymous Viewer access verified."
}
finally {
    if ($StartedTemporaryPf -and $Pf -and -not $Pf.HasExited) {
        Stop-Process -Id $Pf.Id -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "=========================================="
Write-Host "GRAFANA ANONYMOUS ACCESS RESULT: PASS"
Write-Host "Role      : Viewer"
Write-Host "Login     : Not required"
Write-Host "Dashboard : $DashboardUrl"
Write-Host "=========================================="

exit 0
