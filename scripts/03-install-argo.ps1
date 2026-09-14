$ErrorActionPreference = "Stop"

Write-Host "=========================================="
Write-Host " AI BLUE-GREEN LAB - INSTALL ARGO ROLLOUTS"
Write-Host "=========================================="
Write-Host ""

$ArgoVersion = "v1.10.0"
$Namespace = "argo-rollouts"
$ExpectedContext = "kind-ai-bluegreen"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$ToolsDir = Join-Path $ProjectRoot "tools"
$LocalPlugin = Join-Path $ToolsDir "kubectl-argo-rollouts.exe"

$InstallUrl = "https://github.com/argoproj/argo-rollouts/releases/download/$ArgoVersion/install.yaml"
$PluginUrl = "https://github.com/argoproj/argo-rollouts/releases/download/$ArgoVersion/kubectl-argo-rollouts-windows-amd64"

function Fail-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "[FAIL] $Message"
    exit 1
}

Write-Host "[INFO] Argo Rollouts version : $ArgoVersion"
Write-Host "[INFO] Kubernetes namespace   : $Namespace"
Write-Host "[INFO] Expected context       : $ExpectedContext"
Write-Host ""

$CurrentContext = (kubectl config current-context).Trim()
if ($LASTEXITCODE -ne 0 -or $CurrentContext -ne $ExpectedContext) {
    Fail-Step "Expected Kubernetes context '$ExpectedContext', but found '$CurrentContext'."
}
Write-Host "[PASS] Kubernetes context is $CurrentContext."

Write-Host ""
Write-Host "[INFO] Checking namespace '$Namespace'..."

$NamespaceExists = kubectl get namespace $Namespace --ignore-not-found -o name
if ($LASTEXITCODE -ne 0) {
    Fail-Step "Unable to query namespace '$Namespace'."
}

if ([string]::IsNullOrWhiteSpace($NamespaceExists)) {
    Write-Host "[INFO] Creating namespace '$Namespace'..."
    kubectl create namespace $Namespace | Out-Host

    if ($LASTEXITCODE -ne 0) {
        Fail-Step "Unable to create namespace '$Namespace'."
    }

    Write-Host "[PASS] Namespace '$Namespace' created."
}
else {
    Write-Host "[INFO] Namespace '$Namespace' already exists. Reusing it."
}

Write-Host ""
Write-Host "[INFO] Installing Argo Rollouts controller $ArgoVersion..."
Write-Host "[INFO] Using SERVER-SIDE APPLY to avoid large CRD annotation limits."
Write-Host "[INFO] Source: $InstallUrl"

kubectl apply `
    --server-side `
    --force-conflicts `
    -n $Namespace `
    -f $InstallUrl | Out-Host

if ($LASTEXITCODE -ne 0) {
    Fail-Step "Failed to apply the Argo Rollouts installation manifest."
}

Write-Host "[PASS] Argo Rollouts manifest server-side applied."

Write-Host ""
Write-Host "[INFO] Waiting for Argo Rollouts controller deployment..."
kubectl rollout status deployment/argo-rollouts -n $Namespace --timeout=180s | Out-Host

if ($LASTEXITCODE -ne 0) {
    Fail-Step "Argo Rollouts controller did not become Ready within 180 seconds."
}

Write-Host "[PASS] Argo Rollouts controller is Ready."

Write-Host ""
Write-Host "[INFO] Validating Argo Rollouts CRDs..."

$RequiredCrds = @(
    "rollouts.argoproj.io",
    "analysisruns.argoproj.io",
    "analysistemplates.argoproj.io",
    "clusteranalysistemplates.argoproj.io",
    "experiments.argoproj.io"
)

foreach ($Crd in $RequiredCrds) {
    $CrdResult = kubectl get crd $Crd --ignore-not-found -o name

    if ($LASTEXITCODE -ne 0) {
        Fail-Step "Unable to query CRD '$Crd'."
    }

    if ([string]::IsNullOrWhiteSpace($CrdResult)) {
        Fail-Step "Required CRD '$Crd' was not found."
    }

    Write-Host "[PASS] CRD found: $Crd"
}

Write-Host ""
Write-Host "[INFO] Preparing Argo Rollouts Windows CLI..."

if (-not (Test-Path $ToolsDir)) {
    New-Item -ItemType Directory -Path $ToolsDir -Force | Out-Null
}

$SystemPlugin = Get-Command "kubectl-argo-rollouts.exe" -ErrorAction SilentlyContinue

if ($SystemPlugin) {
    Write-Host "[INFO] Existing Argo Rollouts CLI found in PATH:"
    Write-Host "       $($SystemPlugin.Source)"
    $PluginExecutable = $SystemPlugin.Source
}
else {
    if (Test-Path $LocalPlugin) {
        Write-Host "[INFO] Local Argo Rollouts CLI already exists:"
        Write-Host "       $LocalPlugin"
    }
    else {
        Write-Host "[INFO] Downloading Argo Rollouts CLI $ArgoVersion..."
        Write-Host "[INFO] Source: $PluginUrl"

        Invoke-WebRequest `
            -Uri $PluginUrl `
            -OutFile $LocalPlugin `
            -UseBasicParsing

        if (-not (Test-Path $LocalPlugin)) {
            Fail-Step "Argo Rollouts CLI download failed."
        }

        Write-Host "[PASS] Argo Rollouts CLI downloaded."
    }

    $PluginExecutable = $LocalPlugin
}

Write-Host ""
Write-Host "[INFO] Verifying Argo Rollouts CLI..."
& $PluginExecutable version | Out-Host

if ($LASTEXITCODE -ne 0) {
    Fail-Step "Argo Rollouts CLI verification failed."
}

Write-Host "[PASS] Argo Rollouts CLI is available."

Write-Host ""
Write-Host "------------------------------------------"
Write-Host " Argo Rollouts controller status"
Write-Host "------------------------------------------"
kubectl get pods -n $Namespace -o wide | Out-Host

if ($LASTEXITCODE -ne 0) {
    Fail-Step "Unable to retrieve Argo Rollouts pods."
}

Write-Host ""
Write-Host "------------------------------------------"
Write-Host " Installed rollout resources"
Write-Host "------------------------------------------"
kubectl api-resources --api-group=argoproj.io | Out-Host

if ($LASTEXITCODE -ne 0) {
    Fail-Step "Unable to retrieve Argo Rollouts API resources."
}

Write-Host ""
Write-Host "=========================================="
Write-Host "ARGO ROLLOUTS INSTALLATION RESULT: PASS"
Write-Host "Controller version : $ArgoVersion"
Write-Host "Namespace          : $Namespace"
Write-Host "CLI                : $PluginExecutable"
Write-Host "=========================================="

exit 0
