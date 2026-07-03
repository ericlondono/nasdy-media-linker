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
