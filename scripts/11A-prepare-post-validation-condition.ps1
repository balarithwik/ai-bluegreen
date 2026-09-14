param(
    [Parameter(Mandatory=$false)]
    [ValidateSet("ALL_STAGES_PROMOTE","ROLLBACK_AT_POST_VALIDATION")]
    [string]$Scenario = $env:DEMO_SCENARIO
)

$ErrorActionPreference = "Stop"

Write-Host "=========================================="
Write-Host " AI BLUE-GREEN LAB - PREPARE POST VALIDATION"
Write-Host "=========================================="
Write-Host ""

$ExpectedContext = "kind-ai-bluegreen"
$Namespace = "ai-bluegreen"
$ActiveService = "ai-bluegreen-active"
$ExpectedVersion = "v2-healthy"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$ScenarioDir = Join-Path $ProjectRoot "scenarios"
$EvidenceDir = Join-Path $ProjectRoot "results\scenario-control"
$EvidenceFile = Join-Path $EvidenceDir "post-validation-condition.json"

function Fail-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "[FAIL] $Message"
    exit 1
}

if ([string]::IsNullOrWhiteSpace($Scenario)) {
    Fail-Step "Scenario was not supplied. Use -Scenario or DEMO_SCENARIO."
}

$ScenarioFile = switch ($Scenario) {
    "ALL_STAGES_PROMOTE" {
        Join-Path $ScenarioDir "all-stages-promote.json"
    }
    "ROLLBACK_AT_POST_VALIDATION" {
        Join-Path $ScenarioDir "rollback-at-post-validation.json"
    }
}

if (-not (Test-Path $ScenarioFile)) {
    Fail-Step "Scenario configuration not found: $ScenarioFile"
}

$ScenarioConfig = Get-Content $ScenarioFile -Raw | ConvertFrom-Json
if ($ScenarioConfig.scenario -ne $Scenario) {
    Fail-Step "Scenario configuration mismatch."
}

$CurrentContext = (kubectl config current-context).Trim()
if ($LASTEXITCODE -ne 0 -or $CurrentContext -ne $ExpectedContext) {
    Fail-Step "Expected context '$ExpectedContext', found '$CurrentContext'."
}
Write-Host "[PASS] Kubernetes context is $CurrentContext."

try {
    $Health = Invoke-RestMethod -Uri "http://localhost:8081/health" -Method Get -TimeoutSec 10
}
catch {
    Fail-Step "Unable to reach Active production endpoint."
}

if ($Health.status -ne "UP" -or $Health.version -ne $ExpectedVersion) {
    Fail-Step "Expected Active production '$ExpectedVersion', found '$($Health.version)'."
}

Write-Host "[PASS] Promoted GREEN is Active and healthy."

$Mode = [string]$ScenarioConfig.postValidationCondition.mode
New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null

if ($Mode -eq "NONE") {
    [ordered]@{
        scenario = $Scenario
        conditionMode = "NONE"
        conditionActivated = $false
        preparedAt = (Get-Date).ToString("o")
    } | ConvertTo-Json -Depth 6 | Set-Content $EvidenceFile -Encoding UTF8

    Write-Host ""
    Write-Host "[PASS] Post-validation environment remains unchanged."
    Write-Host "[INFO] AI receives no scenario metadata; it will evaluate only runtime evidence."
    Write-Host ""
    Write-Host "POST-VALIDATION CONDITION RESULT: READY"
    exit 0
}

if ($Mode -ne "CPU_DUTY_CYCLE") {
    Fail-Step "Unsupported post-validation condition mode '$Mode'."
}

$TargetCpuPercent = [int]$ScenarioConfig.postValidationCondition.targetCpuPercentOfLimit
$DurationSeconds = [int]$ScenarioConfig.postValidationCondition.durationSeconds
$WarmupSeconds = [int]$ScenarioConfig.postValidationCondition.warmupSeconds

if ($TargetCpuPercent -lt 1 -or $TargetCpuPercent -gt 95) {
    Fail-Step "Configured CPU target must be between 1 and 95 percent."
}

$ActiveHash = kubectl get svc $ActiveService -n $Namespace -o jsonpath='{.spec.selector.rollouts-pod-template-hash}'
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($ActiveHash)) {
    Fail-Step "Unable to resolve Active GREEN ReplicaSet hash."
}

$PodText = kubectl get pods -n $Namespace -l "rollouts-pod-template-hash=$ActiveHash" -o name
if ($LASTEXITCODE -ne 0) {
    Fail-Step "Unable to retrieve Active GREEN pods."
}

$Pods = @($PodText | ForEach-Object { ($_ -replace '^pod/','').Trim() } | Where-Object { $_ })
if ($Pods.Count -eq 0) {
    Fail-Step "No Active GREEN pods found."
}

Write-Host "[PASS] Active GREEN pods found: $($Pods.Count)"
$Pods | ForEach-Object { Write-Host "       $_" }

function Convert-CpuQuantityToCores {
    param([string]$Quantity)

    if ([string]::IsNullOrWhiteSpace($Quantity)) {
        return 0.0
    }

    $Text = $Quantity.Trim()

    if ($Text.EndsWith("m")) {
        return ([double]($Text.TrimEnd("m"))) / 1000.0
    }

    if ($Text.EndsWith("u")) {
        return ([double]($Text.TrimEnd("u"))) / 1000000.0
    }

    if ($Text.EndsWith("n")) {
        return ([double]($Text.TrimEnd("n"))) / 1000000000.0
    }

    return [double]$Text
}

$PeriodSeconds = 0.10
$Processes = @()
$FailedPods = @()

$RemoteScript = "/tmp/ai-bluegreen-cpu-duty.py"
$RemoteLog = "/tmp/ai-bluegreen-cpu-duty.log"
$RemotePidFile = "/tmp/ai-bluegreen-cpu-duty.pid"

Write-Host ""
Write-Host "[INFO] Preparing controlled post-validation runtime condition..."
Write-Host "[INFO] Target CPU utilization : $TargetCpuPercent% of each pod CPU limit"
Write-Host "[INFO] Duration               : $DurationSeconds seconds"
Write-Host "[INFO] Launch mode            : REMOTE_BACKGROUND_PROCESS"

foreach ($Pod in $Pods) {
    Write-Host ""
    Write-Host "[INFO] Preparing CPU condition on $Pod..."

    $CpuLimitRaw = kubectl get pod $Pod `
        -n $Namespace `
        -o jsonpath='{.spec.containers[0].resources.limits.cpu}'

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($CpuLimitRaw)) {
        Write-Host "[WARN] Unable to resolve CPU limit for $Pod."
        $FailedPods += $Pod
        continue
    }

    try {
        $CpuLimitCores = Convert-CpuQuantityToCores -Quantity $CpuLimitRaw
    }
    catch {
        Write-Host "[WARN] Unable to parse CPU limit '$CpuLimitRaw' for $Pod."
        $FailedPods += $Pod
        continue
    }

    if ($CpuLimitCores -le 0) {
        Write-Host "[WARN] CPU limit for $Pod is invalid: $CpuLimitRaw"
        $FailedPods += $Pod
        continue
    }

    # Convert "70% of pod CPU limit" into the fraction of one CPU core that
    # a single Python busy-loop must consume.
    # Example: 500m limit * 70% = 350m = 0.35 of one CPU core.
    $TargetCores = $CpuLimitCores * ($TargetCpuPercent / 100.0)
    $BusyFraction = [math]::Round($TargetCores, 4)

    if ($BusyFraction -le 0 -or $BusyFraction -ge 0.95) {
        Write-Host "[WARN] Computed busy fraction $BusyFraction is outside the supported single-worker range for $Pod."
        $FailedPods += $Pod
        continue
    }

    $BusySeconds = [math]::Round($PeriodSeconds * $BusyFraction, 5)

    Write-Host "[INFO] Pod CPU limit        : $CpuLimitRaw ($([math]::Round($CpuLimitCores,3)) cores)"
    Write-Host "[INFO] Target CPU           : $TargetCpuPercent% of limit"
    Write-Host "[INFO] Target process CPU   : $([math]::Round($TargetCores * 1000,0))m"
    Write-Host "[INFO] Busy duty fraction   : $([math]::Round($BusyFraction * 100,2))% of one core"

    $PythonScript = @"
import time

duration = $DurationSeconds
period = $PeriodSeconds
busy = $BusySeconds
end = time.time() + duration

while time.time() < end:
    started = time.perf_counter()

    while time.perf_counter() - started < busy:
        pass

    remaining = period - busy
    if remaining > 0:
        time.sleep(remaining)
"@

    # Write the stress program into the application container first.
    $PythonScript | kubectl exec -i $Pod `
        -n $Namespace `
        -- sh -c "cat > $RemoteScript"

    if ($LASTEXITCODE -ne 0) {
        Write-Host "[WARN] Unable to create remote CPU script on $Pod."
        $FailedPods += $Pod
        continue
    }

    # Start the process INSIDE the pod and immediately return its remote PID.
    # stdout/stderr/stdin are redirected so the process is independent of the
    # Jenkins kubectl client process.
    $LaunchCommand = "python $RemoteScript > $RemoteLog 2>&1 < /dev/null & echo `$! > $RemotePidFile; cat $RemotePidFile"

    $LaunchOutput = kubectl exec $Pod `
        -n $Namespace `
        -- sh -c $LaunchCommand

    if ($LASTEXITCODE -ne 0) {
        Write-Host "[WARN] Remote CPU process launch failed on $Pod."
        $FailedPods += $Pod
        continue
    }

    $RemotePidText = (($LaunchOutput | Out-String).Trim() -split "\r?\n")[-1].Trim()
    $RemotePid = 0

    if (-not [int]::TryParse($RemotePidText, [ref]$RemotePid) -or $RemotePid -le 0) {
        Write-Host "[WARN] Unable to obtain remote PID from $Pod. Output='$RemotePidText'"
        $FailedPods += $Pod
        continue
    }

    Start-Sleep -Seconds 2

    kubectl exec $Pod `
        -n $Namespace `
        -- sh -c "kill -0 $RemotePid 2>/dev/null" | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Write-Host "[WARN] Remote CPU process on $Pod exited immediately."

        $RemoteTail = kubectl exec $Pod `
            -n $Namespace `
            -- sh -c "tail -n 20 $RemoteLog 2>/dev/null || true"

        if ($RemoteTail) {
            Write-Host "[INFO] Remote log tail:"
            $RemoteTail | ForEach-Object { Write-Host "       $_" }
        }

        $FailedPods += $Pod
        continue
    }

    $Processes += [ordered]@{
        pod = $Pod
        remoteProcessId = $RemotePid
        launchMode = "REMOTE_BACKGROUND_PROCESS"
        remoteScript = $RemoteScript
        remoteLog = $RemoteLog
        remotePidFile = $RemotePidFile
        cpuLimit = $CpuLimitRaw
        cpuLimitCores = [math]::Round($CpuLimitCores, 4)
        targetCpuPercentOfLimit = $TargetCpuPercent
        targetCpuCores = [math]::Round($TargetCores, 4)
        durationSeconds = $DurationSeconds
    }

    Write-Host "[PASS] Remote CPU condition started on $Pod (remote PID $RemotePid)."
}

if ($Processes.Count -ne $Pods.Count) {
    Write-Host ""
    Write-Host "[WARN] CPU condition did not start successfully on every Active GREEN pod."
    Write-Host "[INFO] Successful pods : $($Processes.Count)/$($Pods.Count)"

    if ($FailedPods.Count -gt 0) {
        Write-Host "[INFO] Failed pods:"
        $FailedPods | ForEach-Object { Write-Host "       $_" }
    }

    # Stop any condition that did start so Stage 08 never leaves a partial
    # degradation behind when the requested all-pod condition could not be prepared.
    foreach ($Entry in $Processes) {
        kubectl exec $Entry.pod `
            -n $Namespace `
            -- sh -c "kill $($Entry.remoteProcessId) 2>/dev/null || true" | Out-Null
    }

    Fail-Step "Controlled CPU condition requires all Active GREEN pods. Partial launch was rolled back."
}

[ordered]@{
    scenario = $Scenario
    conditionMode = $Mode
    conditionActivated = $true
    activeVersion = $ExpectedVersion
    activeHash = $ActiveHash
    targetCpuPercentOfLimit = $TargetCpuPercent
    durationSeconds = $DurationSeconds
    warmupSeconds = $WarmupSeconds
    startedAt = (Get-Date).ToString("o")
    launchMode = "REMOTE_BACKGROUND_PROCESS"
    processes = $Processes
} | ConvertTo-Json -Depth 8 | Set-Content $EvidenceFile -Encoding UTF8

Write-Host ""
Write-Host "[INFO] Waiting $WarmupSeconds seconds before post-validation traffic..."
Start-Sleep -Seconds $WarmupSeconds

Write-Host ""
Write-Host "[PASS] Post-validation condition is active."
Write-Host "[INFO] Scenario/control metadata is retained only as Jenkins/report evidence."
Write-Host "[INFO] AI input contains only performance and runtime telemetry."
Write-Host ""
Write-Host "POST-VALIDATION CONDITION RESULT: READY"

exit 0
