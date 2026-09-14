param(
    [string]$ClusterName = "ai-bluegreen"
)

$ErrorActionPreference = "Stop"

Write-Host "=========================================="
Write-Host " AI BLUE-GREEN LAB - FULL CLEANUP"
Write-Host "=========================================="
Write-Host ""
Write-Host "Cluster : $ClusterName"
Write-Host ""
Write-Host "Cleanup policy:"
Write-Host "  Runtime condition   : DELETE / STOP"
Write-Host "  Monitoring sessions : STOP"
Write-Host "  Kind cluster        : DELETE"
Write-Host "  Results             : DELETE"
Write-Host "  JMeter outputs      : DELETE"
Write-Host "  AI outputs          : DELETE"
Write-Host "  Runtime state       : DELETE"
Write-Host "  Logs                : DELETE"
Write-Host "  Generated reports   : DELETE"
Write-Host "  Docker images       : PRESERVE"
Write-Host "  Ollama models       : PRESERVE"
Write-Host ""

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "============================================================"
    Write-Host " $Title"
    Write-Host "============================================================"
}

function Stop-SavedProcessesFromState {
    param([string]$StateFile)

    if (-not (Test-Path $StateFile)) {
        return
    }

    try {
        $State = Get-Content $StateFile -Raw | ConvertFrom-Json

        foreach ($Entry in @($State.processes)) {
            if ($null -eq $Entry.localKubectlProcessId) {
                continue
            }

            $PidValue = [int]$Entry.localKubectlProcessId
            $Proc = Get-Process -Id $PidValue -ErrorAction SilentlyContinue

            if ($Proc) {
                Stop-Process -Id $PidValue -Force -ErrorAction SilentlyContinue
                Write-Host "[PASS] Stopped runtime-condition process PID $PidValue."
            }
        }
    }
    catch {
        Write-Host "[WARN] Unable to parse process-state file: $StateFile"
    }
}

function Stop-KubectlListener {
    param(
        [int]$Port,
        [string]$Name
    )

    $Listeners = @(
        Get-NetTCPConnection `
            -LocalPort $Port `
            -State Listen `
            -ErrorAction SilentlyContinue
    )

    if ($Listeners.Count -eq 0) {
        Write-Host "[INFO] $Name port $Port is already free."
        return
    }

    foreach ($Listener in $Listeners) {
        $PidValue = [int]$Listener.OwningProcess
        $Proc = Get-Process -Id $PidValue -ErrorAction SilentlyContinue

        if (-not $Proc) {
            continue
        }

        if ($Proc.ProcessName -match '^kubectl$') {
            Stop-Process -Id $PidValue -Force -ErrorAction SilentlyContinue
            Write-Host "[PASS] Stopped $Name kubectl process PID $PidValue."
        }
        else {
            Write-Host "[WARN] Port $Port belongs to $($Proc.ProcessName) PID $PidValue. Left untouched."
        }
    }
}

function Remove-GeneratedPath {
    param(
        [string]$Path,
        [string]$Label
    )

    if (Test-Path $Path) {
        Remove-Item $Path -Recurse -Force -ErrorAction Stop
        Write-Host "[PASS] Removed $Label."
    }
    else {
        Write-Host "[INFO] $Label is already absent."
    }
}

Write-Section "STOP CONTROLLED RUNTIME CONDITION"

Stop-SavedProcessesFromState `
    -StateFile (Join-Path $ProjectRoot "results\scenario-control\post-validation-condition.json")

Stop-SavedProcessesFromState `
    -StateFile (Join-Path $ProjectRoot "results\rollback-test\cpu-stress-state.json")

Write-Host "[PASS] Runtime-condition cleanup completed."

Write-Section "STOP MONITORING CONNECTIONS"

Stop-KubectlListener -Port 13001  -Name "Grafana"
Stop-KubectlListener -Port 19090 -Name "Prometheus"
Stop-KubectlListener -Port 19091 -Name "Pushgateway"

Write-Host "[PASS] Monitoring cleanup completed."

Write-Section "DELETE KIND CLUSTER"

$KindCommand = Get-Command kind -ErrorAction SilentlyContinue

if ($KindCommand) {
    $ClusterOutput = cmd /c "kind get clusters 2>nul"

    $Clusters = @(
        $ClusterOutput |
        ForEach-Object { $_.ToString().Trim() } |
        Where-Object { $_ }
    )

    if ($Clusters -contains $ClusterName) {
        Write-Host "[INFO] Deleting kind cluster '$ClusterName'..."
        & kind delete cluster --name $ClusterName | Out-Host

        if ($LASTEXITCODE -ne 0) {
            throw "kind delete cluster failed with exit code $LASTEXITCODE."
        }

        Write-Host "[PASS] Kind cluster '$ClusterName' deleted."
    }
    else {
        Write-Host "[PASS] Kind cluster '$ClusterName' is already absent."
    }
}
else {
    Write-Host "[WARN] kind executable is not available. Cluster deletion could not be checked."
}

Write-Section "DELETE GENERATED EXECUTION EVIDENCE"

Remove-GeneratedPath `
    -Path (Join-Path $ProjectRoot "results") `
    -Label "results directory (JMeter, AI, telemetry, promotion/rollback evidence)"

Remove-GeneratedPath `
    -Path (Join-Path $ProjectRoot "runtime") `
    -Label "runtime directory (pipeline state and generated reports)"

Remove-GeneratedPath `
    -Path (Join-Path $ProjectRoot "logs") `
    -Label "logs directory"

New-Item -ItemType Directory -Path (Join-Path $ProjectRoot "results") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $ProjectRoot "runtime") -Force | Out-Null

Write-Host "[PASS] Fresh results and runtime directories created."

Write-Section "VERIFY CLEAN STATE"

$ClusterStillExists = $false

if ($KindCommand) {
    $VerifyOutput = cmd /c "kind get clusters 2>nul"

    $VerifyClusters = @(
        $VerifyOutput |
        ForEach-Object { $_.ToString().Trim() } |
        Where-Object { $_ }
    )

    $ClusterStillExists = $VerifyClusters -contains $ClusterName
}

if ($ClusterStillExists) {
    throw "Cluster '$ClusterName' still exists after cleanup."
}

Write-Host "[PASS] Kind cluster is absent."

foreach ($Port in @(13001, 19090, 19091)) {
    $Listener = Get-NetTCPConnection `
        -LocalPort $Port `
        -State Listen `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $Listener) {
        Write-Host "[PASS] Local port $Port is free."
    }
    else {
        $Owner = Get-Process -Id $Listener.OwningProcess -ErrorAction SilentlyContinue

        if ($Owner) {
            Write-Host "[WARN] Port $Port remains in use by $($Owner.ProcessName) PID $($Owner.Id)."
        }
        else {
            Write-Host "[WARN] Port $Port remains in use."
        }
    }
}

Write-Host ""
Write-Host "[INFO] Verifying Grafana port 13001 can actually be bound by Windows..."

$BindTest = $null
try {
    $BindTest = [System.Net.Sockets.TcpListener]::new(
        [System.Net.IPAddress]::Loopback,
        13001
    )
    $BindTest.Start()
    Write-Host "[PASS] Grafana port 13001 is bindable."
}
catch {
    throw "Grafana port 13001 is not bindable: $($_.Exception.Message)"
}
finally {
    if ($null -ne $BindTest) {
        try { $BindTest.Stop() } catch {}
    }
}

$ResultItems = @(Get-ChildItem -Path (Join-Path $ProjectRoot "results") -Force -ErrorAction SilentlyContinue)
$RuntimeItems = @(Get-ChildItem -Path (Join-Path $ProjectRoot "runtime") -Force -ErrorAction SilentlyContinue)

if ($ResultItems.Count -ne 0) {
    throw "results directory is not empty after cleanup."
}

if ($RuntimeItems.Count -ne 0) {
    throw "runtime directory is not empty after cleanup."
}

Write-Host "[PASS] results directory is clean."
Write-Host "[PASS] runtime directory is clean."

Write-Host ""
Write-Host "=========================================="
Write-Host "FULL CLEANUP RESULT: PASS"
Write-Host "=========================================="
Write-Host "Cluster            : DELETED"
Write-Host "Monitoring sessions: STOPPED"
Write-Host "JMeter results     : DELETED"
Write-Host "AI results         : DELETED"
Write-Host "Logs               : DELETED"
Write-Host "Generated reports  : DELETED"
Write-Host "Docker images      : PRESERVED"
Write-Host "Ollama models      : PRESERVED"
Write-Host ""
Write-Host "Environment is ready for the next fresh Jenkins execution."
Write-Host ""

exit 0
