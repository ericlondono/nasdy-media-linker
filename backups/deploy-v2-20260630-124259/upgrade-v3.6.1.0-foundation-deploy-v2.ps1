# upgrade-v3.6.1.0-foundation-deploy-v2.ps1
# NASDY Media Linker v3.6.1.0 Foundation + Deploy v2
# Run from: C:\Projects\nasdy-media-linker

$ErrorActionPreference = "Stop"

$ProjectRoot = "C:\Projects\nasdy-media-linker"
$Version = "v3.6.1.0"
$ReleaseName = "foundation-deploy-v2"

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
Write-Host "NASDY Media Linker $Version - Foundation + Deploy v2" -ForegroundColor Green
Write-Host ""

Write-Step "Checking project folder"

if (!(Test-Path $ProjectRoot)) {
    throw "Project folder not found: $ProjectRoot"
}

Set-Location $ProjectRoot

if (!(Test-Path ".\app")) {
    throw "This does not look like the NASDY Media Linker project root. Missing .\app folder."
}

Write-Ok "Project detected: $ProjectRoot"

Write-Step "Creating local backup"

$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$BackupRoot = Join-Path $ProjectRoot "backups"
$BackupPath = Join-Path $BackupRoot "$Version-$ReleaseName-$Timestamp"

if (!(Test-Path $BackupRoot)) {
    New-Item -ItemType Directory -Path $BackupRoot | Out-Null
}

New-Item -ItemType Directory -Path $BackupPath | Out-Null

$BackupItems = @(
    "Deploy.ps1",
    ".dockerignore",
    "DEVELOPMENT.md"
)

foreach ($Item in $BackupItems) {
    $Source = Join-Path $ProjectRoot $Item
    if (Test-Path $Source) {
        $Dest = Join-Path $BackupPath $Item
        $DestParent = Split-Path $Dest -Parent
        if (!(Test-Path $DestParent)) {
            New-Item -ItemType Directory -Path $DestParent -Force | Out-Null
        }
        Copy-Item $Source $Dest -Recurse -Force
    }
}

Write-Ok "Backup created: $BackupPath"

Write-Step "Writing .dockerignore"

$DockerIgnore = @'
.git
.gitignore
backups
__pycache__
*.pyc
.pytest_cache
.mypy_cache
.ruff_cache
.venv
venv
env
node_modules
dist
build
logs
*.log
.DS_Store
Thumbs.db
*.tmp
*.bak
'@

Set-Content -Path ".\.dockerignore" -Value $DockerIgnore -Encoding UTF8
Write-Ok "Wrote .dockerignore"

Write-Step "Writing permanent Deploy.ps1"

$DeployScript = @'
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
'@

Set-Content -Path ".\Deploy.ps1" -Value $DeployScript -Encoding UTF8
Write-Ok "Wrote Deploy.ps1"

Write-Step "Updating DEVELOPMENT.md with expanded project notes"

$DevelopmentMd = @'
# NASDY Media Linker Development Notes

## Core Workflow Rules

- Eric does not manually edit code files.
- All code changes should be delivered as runnable PowerShell upgrade scripts or generated full replacement files.
- Upgrade scripts should create backups before changing files.
- Docker Desktop is not used locally.
- Docker images are built directly on the unRAID NAS over SSH.
- Deployment uses `root@NASDY`.
- Future deploys should use one command: `.\Deploy.ps1`.

## Local Project Path

```text
C:\Projects\nasdy-media-linker
```

## NAS Paths

```text
Remote app path:
/mnt/user/appdata/nasdy-media-organizer

Downloads:
/mnt/user/NASDY/downloads

Media:
/mnt/user/NASDY/media

App data:
/mnt/user/appdata/nasdy-media-organizer/data

Required host mount:
/mnt:/host_mnt
```

## Docker

```text
Container:
nasdy-media-organizer

Image:
nasdy-media-linker:latest

Port:
8088
```

## Required Docker Run Mounts

```bash
-v /mnt/user/NASDY/downloads:/downloads
-v /mnt/user/NASDY/media:/media
-v /mnt/user/appdata/nasdy-media-organizer/data:/app/data
-v /mnt:/host_mnt
```

## Deployment Flow

Normal deployment command:

```powershell
.\Deploy.ps1
```

The deploy script should:

1. Back up the local project.
2. Clean local `__pycache__` and `.pyc` files.
3. Package source files only.
4. Exclude `.git`, `backups`, cache folders, logs, and generated files.
5. Send the package to NASDY over SSH.
6. Extract to `/mnt/user/appdata/nasdy-media-organizer`.
7. Build Docker image on the NAS.
8. Restart the `nasdy-media-organizer` container.
9. Always include `/mnt:/host_mnt`.
10. Verify `/host_mnt` exists inside the container.
11. Verify `/health`.
12. Print a success summary.

## Release Process

1. Create a new Git branch.
2. Create an upgrade script for the version.
3. Backup project automatically.
4. Apply file changes automatically.
5. Clean Python cache files.
6. Build Docker image on NAS over SSH.
7. Restart container.
8. Verify `/health`.
9. Confirm UI behavior.
10. Commit and tag the release.

## Current Release Target

```text
v3.6.1.0
```

## v3.6.1.0 Goals

1. Create permanent `Deploy.ps1`.
2. Bake `/mnt:/host_mnt` into every deployment.
3. Rename `Movie Collection Import Manager` to `Import Manager`.
4. Add smart import status cards.

## Smart Status Goals

Statuses should become decision cards:

```text
🟢 Ready
Auto matched
New movie
Destination available
```

```text
🟡 Needs Review
Multiple TMDb matches found
```

```text
🔴 Duplicate
Already exists in library
```

```text
🔵 Upgrade
Existing quality is lower than incoming quality
```

```text
⚫ Blocked
Missing data or destination unavailable
```

## UI Naming

Use:

```text
Import Manager
```

Do not use:

```text
Movie Collection Import Manager
```

## Coding Preferences

- Prefer full replacement files or automated patch scripts.
- Avoid manual instructions like “open this file and change this line.”
- Keep UI clean, readable, compact, and dark-theme friendly.
- Avoid breaking working import behavior while polishing UI.
- Preserve multi-movie collection behavior.
- Preserve individual editable movie rows.
- Preserve TMDb / IMDb auto matching.
- Preserve hard-link engine behavior.

## Architecture Overview

NASDY Media Linker is a local utility app for reviewing completed downloads, correcting movie/show metadata, and creating hard links into the media library.

High-level flow:

```text
qBittorrent downloads
        ↓
NASDY Media Linker queue
        ↓
Import Manager review
        ↓
TMDb / IMDb match
        ↓
Hard link into media library
        ↓
Jellyfin scans final library path
```

## Known Good Behavior as of v3.6.0.1

- Multi-movie collections are detected.
- Each movie gets its own editable row.
- TMDb automatically finds IMDb IDs.
- The UI is clean and readable.
- The hard-link engine works.
- `/mnt:/host_mnt` is required for host path resolution.

## Future Chat Startup

At the start of a new ChatGPT conversation, upload this file first.

Then say:

```text
Please use DEVELOPMENT.md as the source of truth for our NASDY Media Linker workflow.
```

## Reminder

For longer coding/debugging sessions:

- Start a new Git branch.
- Start a new ChatGPT conversation when the current one gets too long.
'@

Set-Content -Path ".\DEVELOPMENT.md" -Value $DevelopmentMd -Encoding UTF8
Write-Ok "Updated DEVELOPMENT.md"

Write-Step "Cleaning local Python cache files"

Get-ChildItem -Path $ProjectRoot -Recurse -Directory -Filter "__pycache__" -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

Get-ChildItem -Path $ProjectRoot -Recurse -File -Filter "*.pyc" -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

Write-Ok "Python cache files cleaned"

Write-Step "Deploying foundation update with new Deploy.ps1"

powershell -ExecutionPolicy Bypass -File ".\Deploy.ps1"

if ($LASTEXITCODE -ne 0) {
    throw "Deploy.ps1 failed."
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "NASDY Media Linker $Version foundation update complete" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "[OK] Permanent Deploy.ps1 created"
Write-Host "[OK] .dockerignore created"
Write-Host "[OK] DEVELOPMENT.md expanded"
Write-Host "[OK] /mnt:/host_mnt baked into deployment"
Write-Host "[OK] Container deployed and health checked"
Write-Host ""
Write-Host "Next normal deployment command:"
Write-Host "powershell -ExecutionPolicy Bypass -File .\Deploy.ps1"
Write-Host ""
Write-Host "Next feature step:"
Write-Host "v3.6.1.0 UI polish + Smart Status cards"
Write-Host ""
