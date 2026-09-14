$ErrorActionPreference = "Stop"

Write-Host "=========================================="
Write-Host " AI BLUE-GREEN LAB - INSTALL MONITORING"
Write-Host "=========================================="
Write-Host ""

$ExpectedContext = "kind-ai-bluegreen"
$Namespace = "monitoring"
$ReleaseName = "monitoring"
$RepoName = "prometheus-community"
$RepoUrl = "https://prometheus-community.github.io/helm-charts"
$ChartName = "prometheus-community/kube-prometheus-stack"
$ChartVersion = "88.2.0"

function Fail-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "[FAIL] $Message"
    exit 1
}

Write-Host "[INFO] Expected context : $ExpectedContext"
Write-Host "[INFO] Namespace        : $Namespace"
Write-Host "[INFO] Helm release     : $ReleaseName"
Write-Host "[INFO] Chart            : $ChartName"
Write-Host "[INFO] Chart version    : $ChartVersion"
Write-Host ""

$CurrentContext = (kubectl config current-context).Trim()

if ($LASTEXITCODE -ne 0 -or $CurrentContext -ne $ExpectedContext) {
    Fail-Step "Expected Kubernetes context '$ExpectedContext', but found '$CurrentContext'."
}

Write-Host "[PASS] Kubernetes context is $CurrentContext."

Write-Host ""
Write-Host "[INFO] Checking Helm repository '$RepoName'..."

$RepoList = helm repo list 2>$null | Out-String

if ($RepoList -notmatch [regex]::Escape($RepoName)) {
    Write-Host "[INFO] Adding Helm repository '$RepoName'..."

    helm repo add $RepoName $RepoUrl | Out-Host

    if ($LASTEXITCODE -ne 0) {
        Fail-Step "Unable to add Helm repository '$RepoName'."
    }

    Write-Host "[PASS] Helm repository added."
}
else {
    Write-Host "[INFO] Helm repository '$RepoName' already exists."
}

Write-Host ""
Write-Host "[INFO] Updating Helm repositories..."

helm repo update | Out-Host

if ($LASTEXITCODE -ne 0) {
    Fail-Step "Helm repository update failed."
}

Write-Host "[PASS] Helm repositories updated."

Write-Host ""
Write-Host "[INFO] Installing/upgrading kube-prometheus-stack..."
Write-Host "[INFO] This may take a few minutes on the first run."

helm upgrade --install $ReleaseName $ChartName `
    --namespace $Namespace `
    --create-namespace `
    --version $ChartVersion `
    --wait `
    --timeout 10m | Out-Host

if ($LASTEXITCODE -ne 0) {
    Fail-Step "kube-prometheus-stack installation failed."
}

Write-Host "[PASS] Helm release '$ReleaseName' installed/upgraded."

Write-Host ""
Write-Host "[INFO] Validating Helm release..."

$ReleaseStatus = helm status $ReleaseName -n $Namespace -o json | ConvertFrom-Json

if ($LASTEXITCODE -ne 0) {
    Fail-Step "Unable to retrieve Helm release status."
}

if ($ReleaseStatus.info.status -ne "deployed") {
    Fail-Step "Helm release status is '$($ReleaseStatus.info.status)' instead of 'deployed'."
}

Write-Host "[PASS] Helm release status is deployed."

Write-Host ""
Write-Host "[INFO] Waiting for monitoring deployments..."

$Deployments = @(
    kubectl get deployments -n $Namespace -o name |
    ForEach-Object { $_.ToString().Trim() } |
    Where-Object { $_ -ne "" }
)

if ($LASTEXITCODE -ne 0) {
    Fail-Step "Unable to retrieve monitoring deployments."
}

foreach ($Deployment in $Deployments) {
    Write-Host "[INFO] Waiting for $Deployment ..."
    kubectl rollout status $Deployment -n $Namespace --timeout=300s | Out-Host

    if ($LASTEXITCODE -ne 0) {
        Fail-Step "Deployment '$Deployment' did not become Ready."
    }
}

Write-Host "[PASS] Monitoring deployments are Ready."

Write-Host ""
Write-Host "[INFO] Validating Prometheus and Grafana services..."

$GrafanaService = kubectl get svc -n $Namespace -l "app.kubernetes.io/name=grafana" -o name
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($GrafanaService)) {
    Fail-Step "Grafana service was not found."
}

Write-Host "[PASS] Grafana service found: $GrafanaService"

$PrometheusService = kubectl get svc -n $Namespace -l "app=kube-prometheus-stack-prometheus" -o name
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($PrometheusService)) {
    # Fallback for chart label variations.
    $PrometheusService = kubectl get svc -n $Namespace -o name |
        Where-Object { $_ -match "prometheus$|prometheus-" } |
        Select-Object -First 1
}

if ([string]::IsNullOrWhiteSpace($PrometheusService)) {
    Fail-Step "Prometheus service was not found."
}

Write-Host "[PASS] Prometheus service found: $PrometheusService"

Write-Host ""
Write-Host "------------------------------------------"
Write-Host " Monitoring pods"
Write-Host "------------------------------------------"
kubectl get pods -n $Namespace -o wide | Out-Host

if ($LASTEXITCODE -ne 0) {
    Fail-Step "Unable to retrieve monitoring pods."
}

Write-Host ""
Write-Host "------------------------------------------"
Write-Host " Monitoring services"
Write-Host "------------------------------------------"
kubectl get svc -n $Namespace | Out-Host

if ($LASTEXITCODE -ne 0) {
    Fail-Step "Unable to retrieve monitoring services."
}

Write-Host ""
Write-Host "=========================================="
Write-Host "MONITORING INSTALLATION RESULT: PASS"
Write-Host "Release       : $ReleaseName"
Write-Host "Namespace     : $Namespace"
Write-Host "Chart version : $ChartVersion"
Write-Host "=========================================="

exit 0
