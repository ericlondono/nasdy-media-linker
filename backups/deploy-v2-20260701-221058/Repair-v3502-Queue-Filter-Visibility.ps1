#Requires -Version 5.1
param(
  [string]$NasHost = "192.168.0.109",
  [string]$NasUser = "root",
  [string]$RemoteBuildPath = "/mnt/user/appdata/nasdy-media-organizer/build",
  [string]$ImageName = "nasdy-media-linker:latest",
  [string]$ContainerName = "nasdy-media-organizer",
  [string]$HostPort = "8088",
  [switch]$SkipDeploy
)

$ErrorActionPreference = "Stop"

function Write-Step($Message) {
  Write-Host ""
  Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Good($Message) {
  Write-Host $Message -ForegroundColor Green
}

function Write-Warn($Message) {
  Write-Host $Message -ForegroundColor Yellow
}

function Require-Command($Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required command '$Name' was not found."
  }
}

function Write-Utf8NoBom($Path, $Content) {
  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Invoke-Native($Description, [scriptblock]$Command) {
  Write-Step $Description
  & $Command
  if ($LASTEXITCODE -ne 0) {
    throw "$Description failed with exit code $LASTEXITCODE."
  }
}

$ProjectRoot = (Get-Location).Path
$ConfigPath = Join-Path $ProjectRoot "app\config.py"
$AppJsPath = Join-Path $ProjectRoot "app\static\app.js"
$StylePath = Join-Path $ProjectRoot "app\static\style.css"

if (-not (Test-Path $ConfigPath)) {
  throw "Run this from the NASDY Media Linker project folder, e.g. C:\Projects\nasdy-media-linker"
}
if (-not (Test-Path $AppJsPath)) {
  throw "Could not find app\static\app.js"
}
if (-not (Test-Path $StylePath)) {
  throw "Could not find app\static\style.css"
}

$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$BackupDir = Join-Path $ProjectRoot "backup-before-v3502-filter-visibility-$Stamp"

Write-Step "Creating local backup"
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
Copy-Item -Path (Join-Path $ProjectRoot "app") -Destination (Join-Path $BackupDir "app") -Recurse -Force
if (Test-Path (Join-Path $ProjectRoot "Dockerfile")) { Copy-Item (Join-Path $ProjectRoot "Dockerfile") $BackupDir -Force }
if (Test-Path (Join-Path $ProjectRoot "requirements.txt")) { Copy-Item (Join-Path $ProjectRoot "requirements.txt") $BackupDir -Force }
Write-Good "Backup created: $BackupDir"

Write-Step "Applying v3.5.0.2 queue filter visibility fix"

# Bug-fix version bump so the browser gets a new CSS/JS cache key.
$config = [System.IO.File]::ReadAllText($ConfigPath)
$config = [regex]::Replace($config, 'APP_VERSION\s*=\s*"[^"]+"', 'APP_VERSION = "v3.5.0.2"')
Write-Utf8NoBom $ConfigPath $config

# Root cause: older card layout CSS has display:block !important on .folder.torrent-card.
# A normal inline card.style.display = "none" can lose against that rule, so hidden
# cards can remain visible under the wrong queue tab. Force the JS hide operation too.
$appJs = [System.IO.File]::ReadAllText($AppJsPath)
if ($appJs -notmatch 'card\.style\.setProperty\("display",\s*"none",\s*"important"\)') {
  $pattern = '(?m)^\s*card\.hidden\s*=\s*!show;\s*\r?\n\s*card\.style\.display\s*=\s*show\s*\?\s*""\s*:\s*"none";\s*\r?\n\s*card\.classList\.toggle\("hidden",\s*!show\);'
  if ($appJs -notmatch $pattern) {
    throw "Could not find the queue visibility block in app\static\app.js. No files were deployed."
  }
  $replacement = @'
    card.hidden = !show;
    if (show) {
      card.style.removeProperty("display");
    } else {
      card.style.setProperty("display", "none", "important");
    }
    card.classList.toggle("hidden", !show);
'@
  $regex = [regex]::new($pattern)
  $appJs = $regex.Replace($appJs, $replacement.TrimEnd(), 1)
  Write-Good "Updated app.js to hide filtered cards with !important."
} else {
  Write-Warn "app.js already contains the forced queue hide fix; leaving it in place."
}
Write-Utf8NoBom $AppJsPath $appJs

$CssFix = @'

/* v3.5.0.2 queue filter visibility fix */
#queueList .folder.torrent-card.hidden,
#queueList .torrent-card.folder.hidden,
#queueList .folder.torrent-card[hidden],
#queueList .torrent-card.folder[hidden],
.folder-list .folder.torrent-card.hidden,
.folder-list .torrent-card.folder.hidden,
.folder-list .folder.torrent-card[hidden],
.folder-list .torrent-card.folder[hidden] {
  display: none !important;
}
/* end v3.5.0.2 queue filter visibility fix */
'@

$style = [System.IO.File]::ReadAllText($StylePath)
$style = [regex]::Replace(
  $style,
  "(?s)\r?\n?/\* v3\.5\.0\.2 queue filter visibility fix \*/.*?/\* end v3\.5\.0\.2 queue filter visibility fix \*/",
  ""
)
Write-Utf8NoBom $StylePath ($style.TrimEnd() + "`r`n" + $CssFix.TrimEnd() + "`r`n")
Write-Good "Local JS/CSS/version updated for v3.5.0.2."

# Make sure the project still has build files. These are only created if missing.
$DockerfilePath = Join-Path $ProjectRoot "Dockerfile"
$RequirementsPath = Join-Path $ProjectRoot "requirements.txt"

if (-not (Test-Path $DockerfilePath)) {
  $Dockerfile = @'
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8088"]
'@
  Write-Utf8NoBom $DockerfilePath $Dockerfile
}

if (-not (Test-Path $RequirementsPath)) {
  $Requirements = @'
fastapi
uvicorn[standard]
jinja2
python-multipart
requests
'@
  Write-Utf8NoBom $RequirementsPath $Requirements
}

if ($SkipDeploy) {
  Write-Warn "SkipDeploy was used. Local files are patched, but the NAS container was not rebuilt."
  return
}

Require-Command ssh
Require-Command scp
Require-Command tar

$Remote = "$NasUser@$NasHost"
$ArchiveName = "nasdy-v3502-filter-visibility-$Stamp.tgz"
$LocalArchive = Join-Path $env:TEMP $ArchiveName
$RemoteArchive = "/tmp/$ArchiveName"
$LocalDeployScript = Join-Path $env:TEMP "nasdy-v3502-deploy-$Stamp.sh"
$RemoteDeployScript = "/tmp/nasdy-v3502-deploy-$Stamp.sh"

Write-Step "Creating deployment archive"
if (Test-Path $LocalArchive) { Remove-Item $LocalArchive -Force }
& tar -czf $LocalArchive -C $ProjectRoot app Dockerfile requirements.txt
if ($LASTEXITCODE -ne 0) {
  throw "Could not create deployment archive."
}
Write-Good "Created $LocalArchive"

$RemoteScript = @'
#!/bin/sh
set -eu

BUILD_PATH="__REMOTE_BUILD_PATH__"
ARCHIVE="__REMOTE_ARCHIVE__"
IMAGE_NAME="__IMAGE_NAME__"
CONTAINER_NAME="__CONTAINER_NAME__"
REQUESTED_HOST_PORT="__HOST_PORT__"
APP_PORT="8088"
DATA_PATH="/mnt/user/appdata/nasdy-media-organizer/data"

printf '\nDeploying NASDY Media Linker v3.5.0.2 queue-filter visibility fix...\n'
printf 'Build path: %s\n' "$BUILD_PATH"
printf 'Container:  %s\n' "$CONTAINER_NAME"
printf 'Image:      %s\n' "$IMAGE_NAME"

mkdir -p "$BUILD_PATH"
rm -rf "$BUILD_PATH/app"
tar -xzf "$ARCHIVE" -C "$BUILD_PATH"
cd "$BUILD_PATH"

docker build -t "$IMAGE_NAME" .

# Preserve the current working external web port when possible.
CURRENT_HOST_PORT=""
if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  CURRENT_HOST_PORT=$(docker inspect -f '{{with index .NetworkSettings.Ports "8088/tcp"}}{{(index . 0).HostPort}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)
fi
if [ -z "$CURRENT_HOST_PORT" ]; then
  CURRENT_HOST_PORT="$REQUESTED_HOST_PORT"
fi

printf '\nRestarting container with mapping host %s -> container %s...\n' "$CURRENT_HOST_PORT" "$APP_PORT"

docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
mkdir -p "$DATA_PATH"

docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  -p "${CURRENT_HOST_PORT}:${APP_PORT}" \
  -e DOWNLOADS_ROOT=/downloads \
  -e MOVIES_ROOT=/media/movies \
  -e TV_ROOT=/media/tv \
  -e DATA_ROOT=/data \
  -e HOST_DOWNLOADS_ROOT=/mnt/user/NASDY/downloads \
  -e HOST_MEDIA_ROOT=/mnt/user/NASDY/media \
  -e HOST_MNT_ROOT=/host_mnt \
  -v /mnt/user/NASDY/downloads:/downloads \
  -v /mnt/user/NASDY/media:/media \
  -v "$DATA_PATH":/data \
  -v /mnt:/host_mnt \
  "$IMAGE_NAME" \
  uvicorn app.main:app --host 0.0.0.0 --port "$APP_PORT"

sleep 3

echo ""
echo "Container status:"
docker ps --filter "name=$CONTAINER_NAME"

echo ""
echo "Recent logs:"
docker logs --tail=30 "$CONTAINER_NAME" || true

echo ""
echo "Health check from NAS:"
if command -v curl >/dev/null 2>&1; then
  curl -fsS "http://127.0.0.1:${CURRENT_HOST_PORT}/health" || true
elif command -v wget >/dev/null 2>&1; then
  wget -qO- "http://127.0.0.1:${CURRENT_HOST_PORT}/health" || true
else
  echo "curl/wget not available on NAS, skipping local health check."
fi

echo ""
echo "Open: http://__NAS_HOST__:${CURRENT_HOST_PORT}"
echo "Also try: http://nasdy:${CURRENT_HOST_PORT}"
'@

$RemoteScript = $RemoteScript.Replace("__REMOTE_BUILD_PATH__", $RemoteBuildPath)
$RemoteScript = $RemoteScript.Replace("__REMOTE_ARCHIVE__", $RemoteArchive)
$RemoteScript = $RemoteScript.Replace("__IMAGE_NAME__", $ImageName)
$RemoteScript = $RemoteScript.Replace("__CONTAINER_NAME__", $ContainerName)
$RemoteScript = $RemoteScript.Replace("__HOST_PORT__", $HostPort)
$RemoteScript = $RemoteScript.Replace("__NAS_HOST__", $NasHost)
Write-Utf8NoBom $LocalDeployScript $RemoteScript

Invoke-Native "Copying deployment archive to NAS" {
  & scp $LocalArchive "${Remote}:$RemoteArchive"
}

Invoke-Native "Copying deployment script to NAS" {
  & scp $LocalDeployScript "${Remote}:$RemoteDeployScript"
}

Invoke-Native "Building and restarting on NAS" {
  & ssh $Remote "sh '$RemoteDeployScript'"
}

Write-Good "v3.5.0.2 queue filter visibility fix deployed."
Write-Host "Open: http://$NasHost`:$HostPort"
Write-Host "Or:   http://nasdy`:$HostPort"
Write-Warn "Use Ctrl+F5 in the browser so the updated JS/CSS is loaded."
