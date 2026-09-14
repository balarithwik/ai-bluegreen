param(
    [string]$BuildNumber = $env:BUILD_NUMBER
)

$ErrorActionPreference = "Stop"

Write-Host "=========================================="
Write-Host " AI BLUE-GREEN - PACKAGE JMETER EVIDENCE"
Write-Host "=========================================="
Write-Host ""

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

if ([string]::IsNullOrWhiteSpace($BuildNumber)) {
    $BuildNumber = "local-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
}

$ReportDir = Join-Path $ProjectRoot "runtime\reports"
$StageDir = Join-Path $ReportDir "jmeter-evidence"
$SafeBuild = $BuildNumber -replace '[^A-Za-z0-9_.-]', '-'
$ZipFile = Join-Path $ReportDir "ai-bluegreen-jmeter-results-build-$SafeBuild.zip"

if (Test-Path $StageDir) { Remove-Item $StageDir -Recurse -Force }
if (Test-Path $ZipFile) { Remove-Item $ZipFile -Force }
New-Item -ItemType Directory -Path $StageDir -Force | Out-Null

$Phases = @(
    @{ Name = "blue-baseline";  Source = Join-Path $ProjectRoot "results\blue-baseline" },
    @{ Name = "green-preview";  Source = Join-Path $ProjectRoot "results\green-validation" },
    @{ Name = "post-promotion"; Source = Join-Path $ProjectRoot "results\post-promotion" }
)

$Copied = 0
foreach ($Phase in $Phases) {
    $Source = $Phase.Source
    $Destination = Join-Path $StageDir $Phase.Name

    if (-not (Test-Path $Source)) {
        Write-Host "[WARN] JMeter phase directory not found: $Source"
        continue
    }

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null

    foreach ($FileName in @("*.jtl", "jmeter.log", "summary.json", "comparison.json")) {
        Get-ChildItem -Path $Source -Filter $FileName -File -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item $_.FullName $Destination -Force
            $Copied++
        }
    }

    $HtmlSource = Join-Path $Source "html-report"
    if (Test-Path $HtmlSource) {
        Copy-Item -Path $HtmlSource -Destination (Join-Path $Destination "html-report") -Recurse -Force
        $Copied++
    }

    Write-Host "[PASS] Staged JMeter evidence: $($Phase.Name)"
}

if ($Copied -eq 0) {
    Write-Host "[FAIL] No JMeter evidence was found to package."
    exit 1
}

Compress-Archive -Path (Join-Path $StageDir "*") -DestinationPath $ZipFile -CompressionLevel Optimal -Force

if (-not (Test-Path $ZipFile)) {
    Write-Host "[FAIL] JMeter evidence ZIP was not created."
    exit 1
}

$SizeMb = [math]::Round((Get-Item $ZipFile).Length / 1MB, 2)
Remove-Item $StageDir -Recurse -Force

Write-Host ""
Write-Host "[PASS] Complete JMeter evidence package created."
Write-Host "       File : $ZipFile"
Write-Host "       Size : $SizeMb MB"
Write-Host ""
Write-Host "JMETER PACKAGE RESULT: PASS"
exit 0
