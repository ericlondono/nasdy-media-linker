#Requires -Version 5.1
param(
  [string]$NasHost = "192.168.0.109",
  [string]$NasUser = "root",
  [string]$ImageName = "nasdy-media-linker:latest",
  [string]$ContainerName = "nasdy-media-organizer",
  [string]$HostPort = "8088"
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

function Invoke-Native($Description, [scriptblock]$Command) {
  Write-Step $Description
  & $Command
  if ($LASTEXITCODE -ne 0) {
    throw "$Description failed with exit code $LASTEXITCODE."
  }
}

Require-Command ssh
Require-Command scp

$Remote = "$NasUser@$NasHost"
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$LocalFix = Join-Path $env:TEMP "nasdy-fix-v350-port-$Stamp.sh"
$RemoteFix = "/tmp/nasdy-fix-v350-port-$Stamp.sh"

$RemoteScript = @'
#!/bin/sh
set -eu

IMAGE_NAME="__IMAGE_NAME__"
CONTAINER_NAME="__CONTAINER_NAME__"
HOST_PORT="__HOST_PORT__"
APP_PORT="8088"
DATA_PATH="/mnt/user/appdata/nasdy-media-organizer/data"

printf '\nFixing NASDY v3.5.0 Docker port mapping...\n'
printf 'Container: %s\n' "$CONTAINER_NAME"
printf 'Image:     %s\n' "$IMAGE_NAME"
printf 'Mapping:   host %s -> container %s\n' "$HOST_PORT" "$APP_PORT"

if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
  echo "ERROR: Docker image not found: $IMAGE_NAME"
  echo "Run the v3.5.0 NAS installer again first, then rerun this repair."
  exit 1
fi

# Stop/remove the broken container created by the first v3.5.0 installer.
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

# Make sure another container is not already holding the intended web port.
PORT_OWNER=$(docker ps --format '{{.Names}} {{.Ports}}' | grep -E "0\.0\.0\.0:${HOST_PORT}->|\[::\]:${HOST_PORT}->" || true)
if [ -n "$PORT_OWNER" ]; then
  echo "ERROR: Host port $HOST_PORT is already in use:"
  echo "$PORT_OWNER"
  echo "Stop that container or rerun this script with a different -HostPort."
  exit 1
fi

mkdir -p "$DATA_PATH"

# Force Uvicorn to listen on 8088 and map host 8088 to container 8088.
docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  -p "${HOST_PORT}:${APP_PORT}" \
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
  curl -fsS "http://127.0.0.1:${HOST_PORT}/health" || true
elif command -v wget >/dev/null 2>&1; then
  wget -qO- "http://127.0.0.1:${HOST_PORT}/health" || true
else
  echo "curl/wget not available on NAS, skipping local health check."
fi

echo ""
echo "Open: http://__NAS_HOST__:${HOST_PORT}"
echo "Also try: http://nasdy:${HOST_PORT}"
'@

$RemoteScript = $RemoteScript.Replace("__IMAGE_NAME__", $ImageName)
$RemoteScript = $RemoteScript.Replace("__CONTAINER_NAME__", $ContainerName)
$RemoteScript = $RemoteScript.Replace("__HOST_PORT__", $HostPort)
$RemoteScript = $RemoteScript.Replace("__NAS_HOST__", $NasHost)

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($LocalFix, $RemoteScript, $Utf8NoBom)

Write-Step "Copying repair script to NAS"
& scp $LocalFix "${Remote}:$RemoteFix"
if ($LASTEXITCODE -ne 0) {
  throw "Could not copy repair script to NAS."
}

Invoke-Native "Running repair on NAS" {
  & ssh $Remote "sh '$RemoteFix'"
}

Write-Good "v3.5.0 port mapping repair complete."
Write-Host "Open: http://$NasHost`:$HostPort"
Write-Host "Or:   http://nasdy`:$HostPort"
Write-Warn "Use Ctrl+F5 after it opens so the browser reloads app.js/style.css."
