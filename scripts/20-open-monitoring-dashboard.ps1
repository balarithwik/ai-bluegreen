param(
    [string]$TaskName = "AI-BlueGreen-Open-Dashboard",
    [string]$KubeConfigPath = ""
)

$ErrorActionPreference = "Stop"

$ExpectedContext = "kind-ai-bluegreen"
$Namespace = "monitoring"
$GrafanaService = "service/monitoring-grafana"
$GrafanaPort = 3001
$DashboardUid = "ai-bluegreen-intelligence"
$GrafanaUrl = "http://localhost:$GrafanaPort"
$DashboardUrl = "$GrafanaUrl/d/$DashboardUid?orgId=1&refresh=5s"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$RuntimeDir = Join-Path $ProjectRoot "runtime"
$LogDir = Join-Path $RuntimeDir "logs"
$StateFile = Join-Path $RuntimeDir "grafana-port-forward.json"
$OutLog = Join-Path $LogDir "grafana-port-forward.out.log"
$ErrLog = Join-Path $LogDir "grafana-port-forward.err.log"
$LauncherPath = Join-Path $RuntimeDir "grafana-port-forward.cmd"

function Fail-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "[FAIL] $Message"
    exit 1
}

function Warn-Step {
    param([string]$Message)
    Write-Host "[WARN] $Message"
}

New-Item -ItemType Directory -Path $RuntimeDir -Force | Out-Null
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

Write-Host "=========================================="
Write-Host " AI BLUE-GREEN LAB - OPEN MONITORING DASHBOARD"
Write-Host "=========================================="
Write-Host ""
Write-Host "Grafana   : $GrafanaUrl"
Write-Host "Dashboard : $DashboardUrl"
Write-Host ""

$CurrentContext = (kubectl config current-context).Trim()
if ($LASTEXITCODE -ne 0 -or $CurrentContext -ne $ExpectedContext) {
    Fail-Step "Expected Kubernetes context '$ExpectedContext', found '$CurrentContext'."
}
Write-Host "[PASS] Kubernetes context is $CurrentContext."

$GrafanaPod = kubectl get pods `
    -n $Namespace `
    -l "app.kubernetes.io/name=grafana" `
    -o jsonpath='{.items[0].metadata.name}'

if ([string]::IsNullOrWhiteSpace($GrafanaPod)) {
    Fail-Step "Grafana pod was not found."
}

kubectl wait --for=condition=Ready "pod/$GrafanaPod" -n $Namespace --timeout=120s | Out-Host
if ($LASTEXITCODE -ne 0) {
    Fail-Step "Grafana pod '$GrafanaPod' did not become Ready."
}

Write-Host "[PASS] Grafana pod is Ready: $GrafanaPod"

$Listener = Get-NetTCPConnection `
    -LocalPort $GrafanaPort `
    -State Listen `
    -ErrorAction SilentlyContinue |
    Select-Object -First 1

if ($Listener) {
    try {
        $Health = Invoke-RestMethod `
            -Uri "$GrafanaUrl/api/health" `
            -Method Get `
            -TimeoutSec 5

        if ($Health.database -eq "ok") {
            Write-Host "[PASS] Existing Grafana port-forward is healthy on port $GrafanaPort."
        }
        else {
            Fail-Step "Port $GrafanaPort is already in use by a non-healthy Grafana endpoint."
        }
    }
    catch {
        Fail-Step "Port $GrafanaPort is already in use but Grafana is not reachable."
    }
}
else {
    try {
        $KubectlPath = [string](Get-Command "kubectl.exe" -ErrorAction Stop).Source
    }
    catch {
        Fail-Step "kubectl.exe could not be resolved."
    }

    if ([string]::IsNullOrWhiteSpace($KubeConfigPath)) {
        if (-not [string]::IsNullOrWhiteSpace($env:KUBECONFIG) -and (Test-Path $env:KUBECONFIG)) {
            $KubeConfigPath = $env:KUBECONFIG
        }
        elseif (Test-Path "C:\Users\Bala\.kube\config") {
            $KubeConfigPath = "C:\Users\Bala\.kube\config"
        }
        else {
            $Candidate = Join-Path $env:USERPROFILE ".kube\config"
            if (Test-Path $Candidate) {
                $KubeConfigPath = $Candidate
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($KubeConfigPath) -or -not (Test-Path $KubeConfigPath)) {
        Fail-Step "Unable to resolve a valid kubeconfig file for the detached Grafana port-forward."
    }

    $KubeConfigPath = (Resolve-Path $KubeConfigPath).Path

    Remove-Item $OutLog -Force -ErrorAction SilentlyContinue
    Remove-Item $ErrLog -Force -ErrorAction SilentlyContinue

    $LauncherContent = @"
@echo off
"$KubectlPath" --kubeconfig "$KubeConfigPath" port-forward -n "$Namespace" "pod/$GrafanaPod" "${GrafanaPort}:3000" --address 127.0.0.1 1>>"$OutLog" 2>>"$ErrLog"
"@

    Set-Content `
        -Path $LauncherPath `
        -Value $LauncherContent `
        -Encoding ASCII

    $CommandLine = 'cmd.exe /d /s /c ""{0}""' -f $LauncherPath

    try {
        $CreateResult = Invoke-CimMethod `
            -ClassName Win32_Process `
            -MethodName Create `
            -Arguments @{ CommandLine = $CommandLine } `
            -ErrorAction Stop
    }
    catch {
        Fail-Step "Unable to create detached Grafana port-forward process: $($_.Exception.Message)"
    }

    if ([int]$CreateResult.ReturnValue -ne 0) {
        Fail-Step "Win32_Process.Create failed with return value $($CreateResult.ReturnValue)."
    }

    $LauncherPid = [int]$CreateResult.ProcessId
    Write-Host "[INFO] Detached Grafana launcher created (PID $LauncherPid)."

    $PortForwardPid = $null

    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1

        $Listener = Get-NetTCPConnection `
            -LocalPort $GrafanaPort `
            -State Listen `
            -ErrorAction SilentlyContinue |
            Select-Object -First 1

        if ($Listener) {
            $PortForwardPid = [int]$Listener.OwningProcess
            break
        }

        $LauncherProcess = Get-Process -Id $LauncherPid -ErrorAction SilentlyContinue
        if (-not $LauncherProcess) {
            $ErrorTail = ""
            if (Test-Path $ErrLog) {
                $ErrorTail = (Get-Content $ErrLog -Tail 20 -ErrorAction SilentlyContinue) -join " "
            }
            Fail-Step "Detached Grafana launcher exited before port $GrafanaPort became ready. $ErrorTail"
        }
    }

    if ($null -eq $PortForwardPid) {
        $ErrorTail = ""
        if (Test-Path $ErrLog) {
            $ErrorTail = (Get-Content $ErrLog -Tail 30 -ErrorAction SilentlyContinue) -join " "
        }
        Fail-Step "Grafana pod port-forward did not listen on port $GrafanaPort within 30 seconds. $ErrorTail"
    }

    [ordered]@{
        active = $true
        pid = $PortForwardPid
        launcher_pid = $LauncherPid
        local_port = $GrafanaPort
        pod = $GrafanaPod
        kubeconfig = $KubeConfigPath
        started_at = (Get-Date).ToString("o")
    } | ConvertTo-Json -Depth 5 |
        Set-Content -Path $StateFile -Encoding UTF8

    Write-Host "[PASS] Grafana port-forward started PID $PortForwardPid."
}

$Ready = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    try {
        $Health = Invoke-RestMethod `
            -Uri "$GrafanaUrl/api/health" `
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
    Fail-Step "Grafana did not become reachable."
}
Write-Host "[PASS] Grafana reachable."

try {
    $DashboardResponse = Invoke-WebRequest `
        -Uri $DashboardUrl `
        -UseBasicParsing `
        -TimeoutSec 10

    $FinalUri = [string]$DashboardResponse.BaseResponse.ResponseUri.AbsoluteUri

    if ($FinalUri -match "/login") {
        Fail-Step "Grafana redirected to /login. Anonymous Viewer access is not active."
    }

    Write-Host "[PASS] Dashboard available."
    Write-Host "[PASS] Anonymous Viewer access verified."
}
catch {
    Fail-Step "Dashboard is not anonymously reachable at $DashboardUrl."
}

Write-Host ""
Write-Host "------------------------------------------"
Write-Host " OPEN DASHBOARD"
Write-Host "------------------------------------------"

$Identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
Write-Host "Execution Account : $Identity"

if ($Identity -ieq "NT AUTHORITY\SYSTEM") {
    try {
        $Task = Get-ScheduledTask `
            -TaskName $TaskName `
            -ErrorAction SilentlyContinue

        if ($null -ne $Task) {
            Start-ScheduledTask -TaskName $TaskName
            Write-Host "[PASS] Dashboard open request sent to the interactive desktop."
            Write-Host "[PASS] The default browser should open the dashboard in a new tab/window."
        }
        else {
            Warn-Step "Interactive dashboard opener '$TaskName' is not registered."
            Warn-Step "Run scripts\19-register-dashboard-opener.ps1 once from your normal Windows session."
            Write-Host $DashboardUrl
        }
    }
    catch {
        Warn-Step "Unable to trigger dashboard opener: $($_.Exception.Message)"
        Write-Host $DashboardUrl
    }
}
else {
    try {
        Start-Process $DashboardUrl
        Write-Host "[PASS] Dashboard open request sent to the current interactive session."
    }
    catch {
        Warn-Step "Unable to open the browser automatically: $($_.Exception.Message)"
        Write-Host $DashboardUrl
    }
}

Write-Host ""
Write-Host "=========================================="
Write-Host "MONITORING DASHBOARD RESULT: PASS"
Write-Host "URL: $DashboardUrl"
Write-Host "=========================================="

exit 0
