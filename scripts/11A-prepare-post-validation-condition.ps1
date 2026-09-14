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

$PeriodSeconds = 0.10
$BusySeconds = [math]::Round($PeriodSeconds * ($TargetCpuPercent / 100.0), 4)
$PythonCode = (
    "import time; " +
    "end=time.time()+$DurationSeconds; " +
    "period=$PeriodSeconds; " +
    "busy=$BusySeconds; " +
    "exec('while time.time()<end:\n s=time.perf_counter()\n while time.perf_counter()-s<busy: pass\n time.sleep(max(0.0,period-busy))')"
)

$Processes = @()

Write-Host ""
Write-Host "[INFO] Preparing controlled post-validation runtime condition..."
Write-Host "[INFO] Target CPU duty cycle : $TargetCpuPercent%"
Write-Host "[INFO] Duration              : $DurationSeconds seconds"

try {
    $KubectlPath = [string](Get-Command "kubectl.exe" -ErrorAction Stop).Source
}
catch {
    Fail-Step "kubectl.exe could not be resolved for detached runtime-condition launch."
}

foreach ($Pod in $Pods) {
    # Launch kubectl through Win32_Process rather than Start-Process.
    # This prevents Jenkins durable-task process cleanup from terminating the
    # controlled condition when this PowerShell step finishes.
    $CommandLine = (
        "`"$KubectlPath`" exec $Pod -n $Namespace -- python -c `"$PythonCode`""
    )

    try {
        $CreateResult = Invoke-CimMethod `
            -ClassName Win32_Process `
            -MethodName Create `
            -Arguments @{ CommandLine = $CommandLine }
    }
    catch {
        Fail-Step "Unable to launch detached runtime condition on $Pod. $($_.Exception.Message)"
    }

    if ($CreateResult.ReturnValue -ne 0 -or $CreateResult.ProcessId -le 0) {
        Fail-Step "Detached runtime-condition launch failed on $Pod. Win32 return=$($CreateResult.ReturnValue)."
    }

    $DetachedPid = [int]$CreateResult.ProcessId
    Start-Sleep -Seconds 2

    if (-not (Get-Process -Id $DetachedPid -ErrorAction SilentlyContinue)) {
        Fail-Step "Runtime condition on $Pod exited immediately after launch."
    }

    $Processes += [ordered]@{
        pod = $Pod
        localKubectlProcessId = $DetachedPid
        launchMode = "DETACHED_WIN32_PROCESS"
        durationSeconds = $DurationSeconds
        targetCpuPercentOfLimit = $TargetCpuPercent
    }

    Write-Host "[PASS] Detached runtime condition started on $Pod (PID $DetachedPid)."
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
