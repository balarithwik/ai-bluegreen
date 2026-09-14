param(
    [string]$TaskName = "AI-BlueGreen-Open-Dashboard"
)

$ErrorActionPreference = "Stop"

$DashboardUrl = "http://localhost:3001/d/ai-bluegreen-intelligence?orgId=1&refresh=5s"
$InteractiveUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

Write-Host "=========================================="
Write-Host " AI BLUE-GREEN LAB - REGISTER DASHBOARD OPENER"
Write-Host "=========================================="
Write-Host ""

if ($InteractiveUser -ieq "NT AUTHORITY\SYSTEM") {
    Write-Host "[FAIL] Run this script once from your normal logged-in Windows PowerShell session, not from Jenkins/SYSTEM."
    exit 1
}

Write-Host "Task Name : $TaskName"
Write-Host "User      : $InteractiveUser"
Write-Host "Dashboard : $DashboardUrl"
Write-Host ""

# Delegate the URL to the logged-in user's default browser.
# If Chrome/Edge is already running this normally opens a new tab.
$ActionArguments = "/c start `"`" `"$DashboardUrl`""

$Action = New-ScheduledTaskAction `
    -Execute "$env:SystemRoot\System32\cmd.exe" `
    -Argument $ActionArguments

$Principal = New-ScheduledTaskPrincipal `
    -UserId $InteractiveUser `
    -LogonType Interactive `
    -RunLevel Limited

$Settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 2)

try {
    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $Action `
        -Principal $Principal `
        -Settings $Settings `
        -Force | Out-Null
}
catch {
    Write-Host "[FAIL] Unable to register scheduled task: $($_.Exception.Message)"
    Write-Host "If Windows blocks task creation, reopen PowerShell as Administrator and run this script once."
    exit 1
}

$Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop

Write-Host "[PASS] Interactive dashboard opener registered."
Write-Host "       State : $($Task.State)"
Write-Host ""
Write-Host "Jenkins LocalSystem can now trigger '$TaskName'."
Write-Host ""

exit 0
