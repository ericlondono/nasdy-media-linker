$ErrorActionPreference = "Stop"

$Version = "v3.6.1.0-rc2-split-deploy"
$ProjectRoot = "C:\Projects\nasdy-media-linker"
$NasTarget = "root@NASDY"
$RemotePath = "/mnt/user/appdata/nasdy-media-organizer"
$ImageName = "nasdy-media-linker:latest"
$ContainerName = "nasdy-media-organizer"
$Port = "8088"

function Write-Step($Message) {
    Write-Host ""
    Write-Host "==> $Message"
}

function Write-Ok($Message) {
    Write-Host "[OK] $Message"
}

function Fail($Message) {
    Write-Host "[ERROR] $Message" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "NASDY Media Linker $Version"
Write-Host "Split Deploy RC2"
Write-Host ""

Write-Step "Checking project folder"
if (!(Test-Path $ProjectRoot)) {
    Fail "Project folder not found: $ProjectRoot"
}

Set-Location $ProjectRoot

if (!(Test-Path ".\app")) {
    Fail "This does not look like the project root. Missing .\app"
}

Write-Ok "Project detected: $ProjectRoot"

Write-Step "Creating local backup"
$BackupRoot = Join-Path $ProjectRoot "backups"
if (!(Test-Path $BackupRoot)) {
    New-Item -ItemType Directory -Path $BackupRoot | Out-Null
}

$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$BackupPath = Join-Path $BackupRoot "$Version-$Stamp"

$excludeDirs = @(
    ".git",
    "backups",
    "__pycache__",
    ".pytest_cache",
    ".mypy_cache",
    ".ruff_cache",
    ".venv",
    "venv",
    "node_modules"
)

New-Item -ItemType Directory -Path $BackupPath | Out-Null

Get-ChildItem -Force $ProjectRoot | Where-Object {
    $excludeDirs -notcontains $_.Name
} | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination $BackupPath -Recurse -Force
}

Write-Ok "Backup created: $BackupPath"

Write-Step "Writing .dockerignore"
@'
.git
backups
__pycache__
*.pyc
.pytest_cache
.mypy_cache
.ruff_cache
.venv
venv
node_modules
dist
build
logs
*.log
.DS_Store
Thumbs.db
'@ | Set-Content -Path ".\.dockerignore" -Encoding UTF8

Write-Ok "Wrote .dockerignore"

Write-Step "Writing NAS-side .deploy.sh"
@'
#!/usr/bin/env bash
set -euo pipefail

REMOTE_PATH="/mnt/user/appdata/nasdy-media-organizer"
IMAGE_NAME="nasdy-media-linker:latest"
CONTAINER_NAME="nasdy-media-organizer"
PORT="8088"

echo ""
echo "NASDY Media Linker NAS deploy"
echo "Remote path: ${REMOTE_PATH}"
echo "Image:       ${IMAGE_NAME}"
echo "Container:   ${CONTAINER_NAME}"
echo "Port:        ${PORT}"
echo "Mount:       /mnt:/host_mnt"
echo ""

cd "${REMOTE_PATH}"

echo "==> Cleaning remote Python cache files"
find . -type d -name "__pycache__" -prune -exec rm -rf {} + 2>/dev/null || true
find . -type f -name "*.pyc" -delete 2>/dev/null || true
echo "[OK] Remote Python cache files cleaned"

echo ""
echo "==> Verifying required NAS paths"
for required_path in \
  "/mnt/user/NASDY/downloads" \
  "/mnt/user/NASDY/media" \
  "/mnt/user/appdata/nasdy-media-organizer/data" \
  "/mnt"
do
  if [ ! -e "${required_path}" ]; then
    echo "[ERROR] Required path missing: ${required_path}"
    exit 20
  fi
done
echo "[OK] Required NAS paths exist"

echo ""
echo "==> Building Docker image on NAS"
docker build -t "${IMAGE_NAME}" .
echo "[OK] Docker image built: ${IMAGE_NAME}"

echo ""
echo "==> Restarting container"
docker stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true
docker rm "${CONTAINER_NAME}" >/dev/null 2>&1 || true

docker run -d \
  --name "${CONTAINER_NAME}" \
  --restart unless-stopped \
  -p "${PORT}:8088" \
  -v /mnt/user/NASDY/downloads:/downloads \
  -v /mnt/user/NASDY/media:/media \
  -v /mnt/user/appdata/nasdy-media-organizer/data:/app/data \
  -v /mnt:/host_mnt \
  "${IMAGE_NAME}"

echo "[OK] Container restarted"

echo ""
echo "==> Verifying /host_mnt inside container"
if docker exec "${CONTAINER_NAME}" test -d /host_mnt; then
  echo "[OK] /host_mnt exists inside container"
else
  echo "[ERROR] /host_mnt is missing inside container"
  docker logs "${CONTAINER_NAME}" --tail=120 || true
  exit 25
fi

echo ""
echo "==> Verifying /health"
for i in {1..30}; do
  if curl -fsS "http://127.0.0.1:${PORT}/health" >/tmp/nasdy-health.txt 2>/tmp/nasdy-health-error.txt; then
    echo "[OK] Health check passed"
    cat /tmp/nasdy-health.txt || true
    echo ""
    echo "==> Deployment complete"
    docker ps --filter "name=${CONTAINER_NAME}" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    echo ""
    echo "Summary:"
    echo "  Image:     ${IMAGE_NAME}"
    echo "  Container: ${CONTAINER_NAME}"
    echo "  Port:      ${PORT}"
    echo "  Mount:     /mnt:/host_mnt"
    echo "  Health:    OK"
    exit 0
  fi
  sleep 1
done

echo "[ERROR] Health check failed"
echo ""
echo "Curl error:"
cat /tmp/nasdy-health-error.txt || true
echo ""
echo "Container logs:"
docker logs "${CONTAINER_NAME}" --tail=120 || true
exit 30
'@ | Set-Content -Path ".\.deploy.sh" -Encoding UTF8

Write-Ok "Wrote .deploy.sh"

Write-Step "Writing permanent Deploy.ps1"
@'
$ErrorActionPreference = "Stop"

$ProjectRoot = "C:\Projects\nasdy-media-linker"
$NasTarget = "root@NASDY"
$RemotePath = "/mnt/user/appdata/nasdy-media-organizer"
$RemoteTar = "/tmp/nasdy-media-linker-deploy.tar"
$ContainerName = "nasdy-media-organizer"
$Port = "8088"

function Write-Step($Message) {
    Write-Host ""
    Write-Host "==> $Message"
}

function Write-Ok($Message) {
    Write-Host "[OK] $Message"
}

function Fail($Message) {
    Write-Host "[ERROR] $Message" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "NASDY Media Linker Deploy v2"
Write-Host "Local:     $ProjectRoot"
Write-Host "NAS:       $NasTarget"
Write-Host "Remote:    $RemotePath"
Write-Host "Container: $ContainerName"
Write-Host "Port:      $Port"
Write-Host "Mount:     /mnt:/host_mnt"
Write-Host ""

Write-Step "Checking local project"
if (!(Test-Path $ProjectRoot)) {
    Fail "Project folder not found: $ProjectRoot"
}

Set-Location $ProjectRoot

if (!(Test-Path ".\app")) {
    Fail "This does not look like the project root. Missing .\app"
}

if (!(Test-Path ".\.deploy.sh")) {
    Fail "Missing .deploy.sh. Run the v3.6.1.0 RC2 upgrade script first."
}

Write-Ok "Project detected"

Write-Step "Creating local deployment backup"
$BackupRoot = Join-Path $ProjectRoot "backups"
if (!(Test-Path $BackupRoot)) {
    New-Item -ItemType Directory -Path $BackupRoot | Out-Null
}

$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$BackupPath = Join-Path $BackupRoot "deploy-v2-$Stamp"
New-Item -ItemType Directory -Path $BackupPath | Out-Null

$excludeDirs = @(
    ".git",
    "backups",
    "__pycache__",
    ".pytest_cache",
    ".mypy_cache",
    ".ruff_cache",
    ".venv",
    "venv",
    "node_modules"
)

Get-ChildItem -Force $ProjectRoot | Where-Object {
    $excludeDirs -notcontains $_.Name
} | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination $BackupPath -Recurse -Force
}

Write-Ok "Backup created: $BackupPath"

Write-Step "Cleaning local Python cache files"
Get-ChildItem -Path $ProjectRoot -Directory -Recurse -Force -Filter "__pycache__" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $ProjectRoot -File -Recurse -Force -Filter "*.pyc" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
Write-Ok "Python cache files cleaned"

Write-Step "Packaging source files"
$TempTar = Join-Path $env:TEMP "nasdy-media-linker-deploy.tar"

if (Test-Path $TempTar) {
    Remove-Item $TempTar -Force
}

$tarArgs = @(
    "--exclude=.git",
    "--exclude=backups",
    "--exclude=__pycache__",
    "--exclude=*.pyc",
    "--exclude=.pytest_cache",
    "--exclude=.mypy_cache",
    "--exclude=.ruff_cache",
    "--exclude=.venv",
    "--exclude=venv",
    "--exclude=node_modules",
    "--exclude=*.log",
    "-cf",
    $TempTar,
    "."
)

& tar @tarArgs

if ($LASTEXITCODE -ne 0) {
    Fail "tar packaging failed."
}

Write-Ok "Package created: $TempTar"

Write-Step "Preparing remote folder"
ssh $NasTarget "mkdir -p '$RemotePath'"

if ($LASTEXITCODE -ne 0) {
    Fail "Unable to prepare remote folder over SSH."
}

Write-Step "Copying package to NAS"
scp $TempTar "${NasTarget}:${RemoteTar}"

if ($LASTEXITCODE -ne 0) {
    Fail "scp failed while copying package to NAS."
}

Write-Step "Extracting package and running NAS deployment"
$remoteCommand = "set -e; mkdir -p '$RemotePath'; tar -xf '$RemoteTar' -C '$RemotePath'; chmod +x '$RemotePath/.deploy.sh'; bash '$RemotePath/.deploy.sh'"

ssh $NasTarget $remoteCommand

if ($LASTEXITCODE -ne 0) {
    Fail "NAS deployment failed."
}

Write-Step "Cleaning local package"
Remove-Item $TempTar -Force -ErrorAction SilentlyContinue
Write-Ok "Removed local package"

Write-Host ""
Write-Host "[OK] Deploy v2 complete"
Write-Host "Container: $ContainerName"
Write-Host "Port:      $Port"
Write-Host "Mount:     /mnt:/host_mnt"
Write-Host ""
'@ | Set-Content -Path ".\Deploy.ps1" -Encoding UTF8

Write-Ok "Wrote Deploy.ps1"

Write-Step "Updating DEVELOPMENT.md with split deployment details"
if (!(Test-Path ".\DEVELOPMENT.md")) {
@'
# NASDY Media Linker Development Notes
'@ | Set-Content -Path ".\DEVELOPMENT.md" -Encoding UTF8
}

$devAddendum = @'

## Deploy v2 Architecture

Deployment is split into two files:

```text
Deploy.ps1   - Windows/PowerShell orchestrator
.deploy.sh   - NAS/Linux Docker deployment script
```

This prevents PowerShell from trying to interpret Bash/Linux commands like `seq`, `docker`, or `curl`.

Standard deployment command:

```powershell
cd C:\Projects\nasdy-media-linker
powershell -ExecutionPolicy Bypass -File .\Deploy.ps1
```

Deploy v2 must always:
- Build Docker image on NAS over SSH.
- Restart container `nasdy-media-organizer`.
- Use image `nasdy-media-linker:latest`.
- Expose port `8088`.
- Mount `/mnt:/host_mnt`.
- Verify `/host_mnt` exists inside the container.
- Verify `http://127.0.0.1:8088/health`.

'@

$existingDev = Get-Content ".\DEVELOPMENT.md" -Raw
if ($existingDev -notmatch "Deploy v2 Architecture") {
    Add-Content -Path ".\DEVELOPMENT.md" -Value $devAddendum -Encoding UTF8
    Write-Ok "Updated DEVELOPMENT.md"
} else {
    Write-Ok "DEVELOPMENT.md already contains Deploy v2 notes"
}

Write-Step "Cleaning local Python cache files"
Get-ChildItem -Path $ProjectRoot -Directory -Recurse -Force -Filter "__pycache__" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $ProjectRoot -File -Recurse -Force -Filter "*.pyc" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
Write-Ok "Python cache files cleaned"

Write-Step "Running Deploy.ps1 RC2"
powershell -ExecutionPolicy Bypass -File ".\Deploy.ps1"

if ($LASTEXITCODE -ne 0) {
    Fail "Deploy.ps1 failed."
}

Write-Host ""
Write-Host "NASDY Media Linker $Version complete"
Write-Host ""
Write-Host "Changed files:"
Write-Host "  .dockerignore"
Write-Host "  .deploy.sh"
Write-Host "  Deploy.ps1"
Write-Host "  DEVELOPMENT.md"
Write-Host ""
Write-Host "Next deploy command:"
Write-Host "  powershell -ExecutionPolicy Bypass -File .\Deploy.ps1"
Write-Host ""
Write-Host "Next feature step:"
Write-Host "  v3.6.1.0 smart Import Manager status cards"
Write-Host ""
