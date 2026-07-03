param(
    [string]$NasHost = "NASDY",
    [string]$NasUser = "root",
    [string]$RemoteProjectPath = "/mnt/user/appdata/nasdy-media-organizer",
    [string]$ContainerName = "nasdy-media-organizer",
    [string]$ImageName = "nasdy-media-linker:latest",
    [int]$Port = 8088,
    [switch]$NoCache
)

$ErrorActionPreference = "Stop"

function Write-Step($Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Good($Message) {
    Write-Host "✅ $Message" -ForegroundColor Green
}

function Write-Warn($Message) {
    Write-Host "⚠️  $Message" -ForegroundColor Yellow
}

function Fail($Message) {
    Write-Host "❌ $Message" -ForegroundColor Red
    exit 1
}

$ProjectRoot = (Get-Location).Path

Write-Step "Checking project folder"

if (!(Test-Path "$ProjectRoot\app")) {
    Fail "This does not look like the NASDY Media Linker project folder. Missing .\app"
}
if (!(Test-Path "$ProjectRoot\Dockerfile")) {
    Fail "Missing Dockerfile. Run this from C:\Projects\nasdy-media-linker"
}
if (!(Test-Path "$ProjectRoot\requirements.txt")) {
    Fail "Missing requirements.txt. Run this from C:\Projects\nasdy-media-linker"
}
if (!(Test-Path "$ProjectRoot\app\config.py")) {
    Fail "Missing app\config.py"
}

$VersionLine = Select-String -Path "$ProjectRoot\app\config.py" -Pattern 'APP_VERSION\s*=' | Select-Object -First 1
$LocalVersion = "unknown"
if ($VersionLine) {
    $LocalVersion = (($VersionLine.Line -replace '.*APP_VERSION\s*=\s*"', '') -replace '".*', '')
}

Write-Good "Local project detected: $ProjectRoot"
Write-Good "Local app version: $LocalVersion"

Write-Step "Creating local backup"

$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$BackupRoot = Join-Path $ProjectRoot "backups"
$BackupPath = Join-Path $BackupRoot "deploy-before-$LocalVersion-$Stamp"
New-Item -ItemType Directory -Force -Path $BackupPath | Out-Null

Copy-Item "$ProjectRoot\app" "$BackupPath\app" -Recurse -Force
Copy-Item "$ProjectRoot\Dockerfile" "$BackupPath\Dockerfile" -Force
Copy-Item "$ProjectRoot\requirements.txt" "$BackupPath\requirements.txt" -Force

Write-Good "Backup created: $BackupPath"

Write-Step "Checking SSH connection to $NasUser@$NasHost"

ssh "$NasUser@$NasHost" "echo SSH_OK" | Out-Null
if ($LASTEXITCODE -ne 0) {
    Fail "SSH connection failed."
}
Write-Good "SSH connection OK"

Write-Step "Preparing remote project folder"

ssh "$NasUser@$NasHost" "mkdir -p '$RemoteProjectPath' '$RemoteProjectPath/backups'"
if ($LASTEXITCODE -ne 0) {
    Fail "Could not create remote project folder."
}

Write-Step "Creating remote backup"

$RemoteBackupPath = "$RemoteProjectPath/backups/deploy-before-$LocalVersion-$Stamp"
ssh "$NasUser@$NasHost" "mkdir -p '$RemoteBackupPath'; if [ -d '$RemoteProjectPath/app' ]; then cp -a '$RemoteProjectPath/app' '$RemoteBackupPath/app'; fi; if [ -f '$RemoteProjectPath/Dockerfile' ]; then cp -a '$RemoteProjectPath/Dockerfile' '$RemoteBackupPath/Dockerfile'; fi; if [ -f '$RemoteProjectPath/requirements.txt' ]; then cp -a '$RemoteProjectPath/requirements.txt' '$RemoteBackupPath/requirements.txt'; fi"
if ($LASTEXITCODE -ne 0) {
    Fail "Remote backup failed."
}
Write-Good "Remote backup created: $RemoteBackupPath"

Write-Step "Syncing local files to NAS"

scp -r "$ProjectRoot\app" "$ProjectRoot\Dockerfile" "$ProjectRoot\requirements.txt" "${NasUser}@${NasHost}:$RemoteProjectPath/"
if ($LASTEXITCODE -ne 0) {
    Fail "SCP sync failed."
}
Write-Good "Files synced to NAS"

Write-Step "Verifying remote version"

$RemoteVersion = ssh "$NasUser@$NasHost" "grep 'APP_VERSION' '$RemoteProjectPath/app/config.py' | sed 's/.*APP_VERSION *= *\"//' | sed 's/\".*//'"
$RemoteVersion = ($RemoteVersion | Select-Object -First 1).Trim()

if (!$RemoteVersion) {
    Fail "Could not read remote APP_VERSION after sync."
}

Write-Good "Remote app version: $RemoteVersion"

if ($RemoteVersion -ne $LocalVersion) {
    Write-Warn "Remote version does not match local version. Local=$LocalVersion Remote=$RemoteVersion"
}

Write-Step "Building Docker image on NAS"

$BuildFlag = ""
if ($NoCache) {
    $BuildFlag = "--no-cache"
}

ssh "$NasUser@$NasHost" "cd '$RemoteProjectPath' && docker build $BuildFlag -t '$ImageName' ."
if ($LASTEXITCODE -ne 0) {
    Fail "Docker build failed."
}
Write-Good "Docker image built: $ImageName"

Write-Step "Restarting container"

$RunCommand = @"
docker stop '$ContainerName' || true
docker rm '$ContainerName' || true
docker run -d \
  --name '$ContainerName' \
  --restart unless-stopped \
  -p ${Port}:${Port} \
  -v /mnt/user/NASDY/downloads:/downloads \
  -v /mnt/user/NASDY/media:/media \
  -v /mnt/user/appdata/nasdy-media-organizer/data:/app/data \
  '$ImageName'
"@

ssh "$NasUser@$NasHost" $RunCommand
if ($LASTEXITCODE -ne 0) {
    Fail "Container restart failed."
}
Write-Good "Container restarted"

Write-Step "Waiting for app to come online"

$Healthy = $false
for ($i = 1; $i -le 20; $i++) {
    Start-Sleep -Seconds 2
    try {
        $Health = Invoke-RestMethod -Uri "http://$NasHost`:$Port/health" -TimeoutSec 4
        if ($Health.ok -eq $true) {
            $Healthy = $true
            $RunningVersion = $Health.version
            break
        }
    } catch {
        Write-Host "Waiting... attempt $i/20"
    }
}

if (!$Healthy) {
    Write-Warn "The container started, but /health did not respond yet."
    Write-Host ""
    Write-Host "Recent logs:" -ForegroundColor Yellow
    ssh "$NasUser@$NasHost" "docker logs '$ContainerName' --tail=80"
    exit 1
}

Write-Good "App is online"
Write-Good "Running version: $RunningVersion"

if ($RunningVersion -ne $LocalVersion) {
    Write-Warn "Running version does not match local version. Local=$LocalVersion Running=$RunningVersion"
} else {
    Write-Good "Version verified"
}

Write-Step "Recent container logs"
ssh "$NasUser@$NasHost" "docker logs '$ContainerName' --tail=40"

Write-Host ""
Write-Host "🎉 Deployment successful." -ForegroundColor Green
Write-Host "Open: http://$NasHost`:$Port" -ForegroundColor Green
