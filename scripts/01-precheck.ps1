$ErrorActionPreference = "Stop"

Write-Host "=========================================="
Write-Host " AI BLUE-GREEN LAB - PRE-REQUISITE CHECK"
Write-Host "=========================================="
Write-Host ""

$failed = $false

function Test-Command {
    param(
        [Parameter(Mandatory=$true)][string]$Command,
        [Parameter(Mandatory=$true)][string]$DisplayName
    )

    if (Get-Command $Command -ErrorAction SilentlyContinue) {
        Write-Host "[PASS] $DisplayName found."
    }
    else {
        Write-Host "[FAIL] $DisplayName not found in PATH."
        $script:failed = $true
    }
}

function Test-PortAvailable {
    param(
        [Parameter(Mandatory=$true)][int]$Port,
        [Parameter(Mandatory=$true)][string]$Purpose
    )

    $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue

    if ($listener) {
        Write-Host "[FAIL] Port $Port is already in use - reserved for $Purpose."
        $script:failed = $true
    }
    else {
        Write-Host "[PASS] Port $Port is available - $Purpose."
    }
}

Test-Command "docker"  "Docker"
Test-Command "kind"    "kind"
Test-Command "kubectl" "kubectl"
Test-Command "helm"    "Helm"
Test-Command "python"  "Python"
Test-Command "java"    "Java"
Test-Command "jmeter"  "JMeter"
Test-Command "ollama"  "Ollama"

Write-Host ""
Write-Host "------------------------------------------"
Write-Host " Version checks"
Write-Host "------------------------------------------"

if (Get-Command docker -ErrorAction SilentlyContinue)  { docker --version }
if (Get-Command kind -ErrorAction SilentlyContinue)    { kind version }
if (Get-Command kubectl -ErrorAction SilentlyContinue) { kubectl version --client }
if (Get-Command helm -ErrorAction SilentlyContinue)    { helm version --short }
if (Get-Command python -ErrorAction SilentlyContinue)  { python --version }
if (Get-Command java -ErrorAction SilentlyContinue)    { java -version }
if (Get-Command jmeter -ErrorAction SilentlyContinue)  { jmeter -v }
if (Get-Command ollama -ErrorAction SilentlyContinue)  { ollama --version }

Write-Host ""
Write-Host "------------------------------------------"
Write-Host " Docker daemon check"
Write-Host "------------------------------------------"

try {
    docker info *> $null
    Write-Host "[PASS] Docker daemon is running."
}
catch {
    Write-Host "[FAIL] Docker daemon is not running or is not reachable."
    $failed = $true
}

Write-Host ""
Write-Host "------------------------------------------"
Write-Host " Port availability check"
Write-Host "------------------------------------------"

Test-PortAvailable -Port 8081 -Purpose "Blue Active"
Test-PortAvailable -Port 8082 -Purpose "Green Preview"

Write-Host ""
Write-Host "=========================================="

if (-not $failed) {
    Write-Host "PRE-CHECK RESULT: PASS"
    Write-Host "Environment is ready for cluster creation."
    exit 0
}
else {
    Write-Host "PRE-CHECK RESULT: FAIL"
    Write-Host "Fix the failed prerequisite(s) before continuing."
    exit 1
}
