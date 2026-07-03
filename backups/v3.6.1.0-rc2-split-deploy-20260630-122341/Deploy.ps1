# Deploy.ps1
# NASDY Media Linker permanent deployment script
# Run from: C:\Projects\nasdy-media-linker
#
# This deploys from Windows PowerShell to unRAID over SSH.
# It does NOT use local Docker Desktop.
# It builds and restarts Docker directly on NASDY.

$ErrorActionPreference = "Stop"

$ProjectRoot = "C:\Projects\nasdy-media-linker"
$NasTarget = "root@NASDY"
$RemotePath = "/mnt/user/appdata/nasdy-media-organizer"
$ImageName = "nasdy-media-linker:latest"
$ContainerName = "nasdy-media-organizer"
$Port = "8088"

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "NASDY Media Linker Deploy v2" -ForegroundColor Green
Write-Host "Local:     $ProjectRoot"
Write-Host "NAS:       $NasTarget"
Write-Host "Remote:    $RemotePath"
Write-Host "Image:     $ImageName"
Write-Host "Container: $ContainerName"
Write-Host "Port:      $Port"
Write-Host "Mount:     /mnt:/host_mnt"
Write-Host ""

Write-Step "Checking local project"

if (!(Test-Path $ProjectRoot)) {
    throw "Project folder not found: $ProjectRoot"
}

Set-Location $ProjectRoot

if (!(Test-Path ".\app")) {
    throw "This does not look like the NASDY Media Linker project root. Missing .\app folder."
}

Write-Ok "Project detected"

Write-Step "Creating local deployment backup"

$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$BackupRoot = Join-Path $ProjectRoot "backups"
$BackupPath = Join-Path $BackupRoot "deploy-v2-$Timestamp"

if (!(Test-Path $BackupRoot)) {
    New-Item -ItemType Directory -Path $BackupRoot | Out-Null
}

New-Item -ItemType Directory -Path $BackupPath | Out-Null

$ItemsToBackup = @(
    "app",
    "Dockerfile",
    "requirements.txt",
    ".dockerignore",
    "DEVELOPMENT.md",
    "Deploy.ps1"
)

foreach ($Item in $ItemsToBackup) {
    $Source = Join-Path $ProjectRoot $Item
    if (Test-Path $Source) {
        Copy-Item $Source (Join-Path $BackupPath $Item) -Recurse -Force
    }
}

Write-Ok "Backup created: $BackupPath"

Write-Step "Cleaning local Python cache files"

Get-ChildItem -Path $ProjectRoot -Recurse -Directory -Filter "__pycache__" -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

Get-ChildItem -Path $ProjectRoot -Recurse -File -Filter "*.pyc" -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

Write-Ok "Python cache files cleaned"

Write-Step "Packaging source files"

$TempTar = Join-Path $env:TEMP "nasdy-media-linker-deploy.tar"

if (Test-Path $TempTar) {
    Remove-Item $TempTar -Force
}

$TarArgs = @(
    "--exclude=.git",
    "--exclude=backups",
    "--exclude=__pycache__",
    "--exclude=*.pyc",
    "--exclude=.pytest_cache",
    "--exclude=.mypy_cache",
    "--exclude=.ruff_cache",
    "--exclude=.venv",
    "--exclude=venv",
    "--exclude=env",
    "--exclude=node_modules",
    "--exclude=dist",
    "--exclude=build",
    "--exclude=logs",
    "--exclude=*.log",
    "-cf",
    $TempTar,
    "."
)

& tar @TarArgs

if (!(Test-Path $TempTar)) {
    throw "Failed to create deployment package: $TempTar"
}

Write-Ok "Package created: $TempTar"

Write-Step "Deploying to NAS over SSH"

$RemoteScript = @"
set -e

REMOTE_PATH='$RemotePath'
IMAGE_NAME='$ImageName'
CONTAINER_NAME='$ContainerName'
PORT='$Port'

echo ""
echo "==> Remote deploy started"
echo "Remote path: \$REMOTE_PATH"
echo "Image:       \$IMAGE_NAME"
echo "Container:   \$CONTAINER_NAME"
echo "Port:        \$PORT"
echo "Mount:       /mnt:/host_mnt"

mkdir -p "\$REMOTE_PATH"
cd "\$REMOTE_PATH"

echo ""
echo "==> Extracting source"
tar -xf -

echo ""
echo "==> Cleaning remote Python cache files"
find . -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
find . -type f -name '*.pyc' -delete 2>/dev/null || true

echo ""
echo "==> Verifying required NAS paths"
test -d /mnt || { echo "[ERROR] /mnt does not exist on NAS"; exit 20; }
test -d /mnt/user/NASDY/downloads || { echo "[ERROR] /mnt/user/NASDY/downloads does not exist"; exit 21; }
test -d /mnt/user/NASDY/media || { echo "[ERROR] /mnt/user/NASDY/media does not exist"; exit 22; }
mkdir -p /mnt/user/appdata/nasdy-media-organizer/data

echo ""
echo "==> Building Docker image on NAS"
docker build -t "\$IMAGE_NAME" .

echo ""
echo "==> Restarting container"
docker stop "\$CONTAINER_NAME" 2>/dev/null || true
docker rm "\$CONTAINER_NAME" 2>/dev/null || true

docker run -d \
  --name "\$CONTAINER_NAME" \
  --restart unless-stopped \
  -p "\$PORT:8088" \
  -v /mnt/user/NASDY/downloads:/downloads \
  -v /mnt/user/NASDY/media:/media \
  -v /mnt/user/appdata/nasdy-media-organizer/data:/app/data \
  -v /mnt:/host_mnt \
  "\$IMAGE_NAME"

echo ""
echo "==> Verifying /host_mnt mount inside container"
docker exec "\$CONTAINER_NAME" test -d /host_mnt

echo ""
echo "==> Verifying /health"
for i in \$(seq 1 30); do
  if curl -fsS "http://127.0.0.1:\$PORT/health" >/tmp/nasdy-health.txt 2>/tmp/nasdy-health-error.txt; then
    echo "[OK] Health check passed"
    cat /tmp/nasdy-health.txt || true
    echo ""
    echo "==> Container status"
    docker ps --filter "name=\$CONTAINER_NAME" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    echo ""
    echo "==> Deployment complete"
    echo "Image:     \$IMAGE_NAME"
    echo "Container: \$CONTAINER_NAME"
    echo "Port:      \$PORT"
    echo "Mount:     /mnt:/host_mnt"
    echo "Health:    OK"
    exit 0
  fi
  sleep 1
done

echo "[ERROR] Health check failed"
echo ""
echo "Last curl error:"
cat /tmp/nasdy-health-error.txt || true
echo ""
echo "Recent logs:"
docker logs "\$CONTAINER_NAME" --tail=120 || true
exit 30
"@

Get-Content $TempTar -Encoding Byte -ReadCount 0 | ssh $NasTarget $RemoteScript

if ($LASTEXITCODE -ne 0) {
    throw "Deployment failed."
}

Remove-Item $TempTar -Force

Write-Host ""
Write-Host "[OK] Deploy complete" -ForegroundColor Green
Write-Host "Container: $ContainerName"
Write-Host "Port:      $Port"
Write-Host "Mount:     /mnt:/host_mnt"
Write-Host "Health:    OK"
Write-Host ""
