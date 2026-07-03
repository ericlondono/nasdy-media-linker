# NASDY Media Linker - Deploy v3
# One-command deployment with SSH-key support, local backup, source packaging,
# NAS-side Docker build/restart, /host_mnt verification, and /health verification.

[CmdletBinding()]
param(
    [string]$HostName = "NASDY",
    [string]$User = "root",
    [string]$SshKeyPath = (Join-Path $env:USERPROFILE ".ssh\nasdy_ed25519"),
    [switch]$NoKey,
    [string]$RemoteAppPath = "/mnt/user/appdata/nasdy-media-organizer",
    [string]$ImageName = "nasdy-media-linker:latest",
    [string]$ContainerName = "nasdy-media-organizer",
    [int]$Port = 8088,
    [switch]$SkipBackup
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$ProjectRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = (Get-Location).Path
}

$SshKeyPath = [Environment]::ExpandEnvironmentVariables($SshKeyPath)
$Remote = "$User@$HostName"
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) "nasdy-media-linker-deploy-$Stamp"
$PackagePath = Join-Path $WorkDir "source.tar.gz"
$BackupDir = Join-Path $ProjectRoot "backups"
$BackupPath = Join-Path $BackupDir "deploy-v3-local-backup-$Stamp.tar.gz"
$script:UseKey = $false

function Write-Info {
    param([string]$Message)
    Write-Host "[NASDY Deploy] $Message" -ForegroundColor Cyan
}

function Write-Good {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Assert-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found in PATH."
    }
}

function Invoke-NativeChecked {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$FriendlyName
    )

    & $FilePath @Arguments
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        throw "$FriendlyName failed with exit code $code."
    }
}

function ConvertTo-ShSingleQuoted {
    param([string]$Value)
    $sq = [string][char]39
    $dq = [string][char]34
    $escaped = $Value.Replace($sq, $sq + $dq + $sq + $dq + $sq)
    return $sq + $escaped + $sq
}

function Get-TarArgs {
    param([string]$OutputPath)

    return @(
        "-czf", $OutputPath,
        "--exclude=.git",
        "--exclude=.env",
        "--exclude=.ssh",
        "--exclude=data",
        "--exclude=nasdy_ed25519",
        "--exclude=nasdy_ed25519.pub",
        "--exclude=backups",
        "--exclude=__pycache__",
        "--exclude=*.pyc",
        "--exclude=*.pyo",
        "--exclude=.pytest_cache",
        "--exclude=.mypy_cache",
        "--exclude=.ruff_cache",
        "--exclude=.venv",
        "--exclude=venv",
        "--exclude=node_modules",
        "--exclude=logs",
        "--exclude=*.log",
        "--exclude=*.zip",
        "--exclude=*.tar",
        "--exclude=*.tar.gz",
        "--exclude=*.tmp",
        "--exclude=tmp",
        "."
    )
}

function New-TarArchiveFromProject {
    param([string]$OutputPath)

    Push-Location $ProjectRoot
    try {
        $tarArgs = Get-TarArgs -OutputPath $OutputPath
        Invoke-NativeChecked -FilePath "tar.exe" -Arguments $tarArgs -FriendlyName "tar source archive"
    }
    finally {
        Pop-Location
    }
}

function Remove-PythonCaches {
    Write-Info "Cleaning Python cache files."

    $cacheDirs = Get-ChildItem -Path $ProjectRoot -Recurse -Force -Directory -Filter "__pycache__" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notlike "*$([System.IO.Path]::DirectorySeparatorChar)backups$([System.IO.Path]::DirectorySeparatorChar)*" }

    foreach ($dir in $cacheDirs) {
        Remove-Item -Path $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }

    $compiledFiles = Get-ChildItem -Path $ProjectRoot -Recurse -Force -File -Include "*.pyc", "*.pyo" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notlike "*$([System.IO.Path]::DirectorySeparatorChar)backups$([System.IO.Path]::DirectorySeparatorChar)*" }

    foreach ($file in $compiledFiles) {
        Remove-Item -Path $file.FullName -Force -ErrorAction SilentlyContinue
    }
}

function ConvertTo-FoldedBase64 {
    param(
        [string]$Text,
        [int]$LineLength = 76
    )

    $builder = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $Text.Length; $i += $LineLength) {
        $remaining = $Text.Length - $i
        $take = [Math]::Min($LineLength, $remaining)
        [void]$builder.Append($Text.Substring($i, $take))
        [void]$builder.Append("`n")
    }
    return $builder.ToString().TrimEnd()
}

function Test-SshKeyWorks {
    if ($NoKey) {
        return $false
    }

    if (-not (Test-Path $SshKeyPath)) {
        return $false
    }

    Write-Info "Testing SSH key: $SshKeyPath"
    $output = & ssh -i $SshKeyPath -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 $Remote "echo SSH_KEY_OK" 2>$null
    $code = $LASTEXITCODE
    if ($code -eq 0 -and (($output -join "`n") -match "SSH_KEY_OK")) {
        return $true
    }

    return $false
}

function Get-SshArgs {
    $sshArgs = @(
        "-o", "ServerAliveInterval=30",
        "-o", "ServerAliveCountMax=4"
    )

    if ($script:UseKey) {
        $sshArgs += @("-i", $SshKeyPath, "-o", "IdentitiesOnly=yes")
    }

    return $sshArgs
}

if (-not (Test-Path $ProjectRoot)) {
    throw "Project root does not exist: $ProjectRoot"
}

if (-not (Test-Path (Join-Path $ProjectRoot ".deploy.sh"))) {
    throw ".deploy.sh was not found in $ProjectRoot. Run the Deploy v3 upgrade script first."
}

Assert-Command "ssh"
Assert-Command "tar.exe"

$deployStart = Get-Date
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

try {
    Write-Info "Project root: $ProjectRoot"
    Write-Info "Remote target: ${Remote}:$RemoteAppPath"

    if (Test-SshKeyWorks) {
        $script:UseKey = $true
        Write-Good "Using SSH key authentication."
    } else {
        Write-Warning "SSH key was not available or did not pass key-only testing. Falling back to password SSH for this deploy."
        Write-Warning "Run .\Setup-NASDY-SSHKey.ps1 to enable zero-prompt deploys."
    }

    Remove-PythonCaches

    if (-not $SkipBackup) {
        New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
        Write-Info "Creating local source backup: $BackupPath"
        New-TarArchiveFromProject -OutputPath $BackupPath
        Write-Good "Backup complete."
    }

    Write-Info "Packaging deploy source only."
    New-TarArchiveFromProject -OutputPath $PackagePath
    $packageBytes = [System.IO.File]::ReadAllBytes($PackagePath)
    $packageBase64 = ConvertTo-FoldedBase64 ([Convert]::ToBase64String($packageBytes))
    $packageSizeMb = [Math]::Round(($packageBytes.Length / 1MB), 2)
    Write-Good "Package ready: $packageSizeMb MB"

    $remoteScriptTemplate = @'
set -eu

REMOTE_APP_PATH=__REMOTE_APP_PATH__
IMAGE_NAME=__IMAGE_NAME__
CONTAINER_NAME=__CONTAINER_NAME__
PORT=__PORT__
STAMP=__STAMP__
APP_DATA_HOST="/mnt/user/appdata/nasdy-media-organizer/data"

STAGE_DIR="/tmp/nasdy-media-linker-deploy-$STAMP"
PAYLOAD_B64="/tmp/nasdy-media-linker-$STAMP.tar.gz.b64"
PAYLOAD_TGZ="/tmp/nasdy-media-linker-$STAMP.tar.gz"

printf '%s\n' "Receiving NASDY Media Linker source package..."
cat > "$PAYLOAD_B64" <<'__NASDY_PAYLOAD__'
__PACKAGE_BASE64__
__NASDY_PAYLOAD__

if base64 -d "$PAYLOAD_B64" > "$PAYLOAD_TGZ" 2>/dev/null; then
  :
else
  base64 --decode "$PAYLOAD_B64" > "$PAYLOAD_TGZ"
fi

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR" "$REMOTE_APP_PATH" "$APP_DATA_HOST"
tar -xzf "$PAYLOAD_TGZ" -C "$STAGE_DIR"
rm -rf "$STAGE_DIR/.env" "$STAGE_DIR/.ssh" "$STAGE_DIR/data" "$STAGE_DIR/logs" "$STAGE_DIR/backups"

printf '%s\n' "Syncing source to $REMOTE_APP_PATH..."
for item in "$REMOTE_APP_PATH"/* "$REMOTE_APP_PATH"/.[!.]* "$REMOTE_APP_PATH"/..?*; do
  [ -e "$item" ] || continue
  base=$(basename "$item")
  case "$base" in
    data|.env|backups|logs)
      continue
      ;;
  esac
  rm -rf "$item"
done

tar -C "$STAGE_DIR" -cf - . | tar -C "$REMOTE_APP_PATH" -xf -
cd "$REMOTE_APP_PATH"
chmod +x .deploy.sh

NASDY_IMAGE_NAME="$IMAGE_NAME" \
NASDY_CONTAINER_NAME="$CONTAINER_NAME" \
NASDY_PORT="$PORT" \
NASDY_REMOTE_APP_PATH="$REMOTE_APP_PATH" \
./.deploy.sh

rm -f "$PAYLOAD_B64" "$PAYLOAD_TGZ"
rm -rf "$STAGE_DIR"
'@

    $remoteScript = $remoteScriptTemplate
    $remoteScript = $remoteScript.Replace("__REMOTE_APP_PATH__", (ConvertTo-ShSingleQuoted $RemoteAppPath))
    $remoteScript = $remoteScript.Replace("__IMAGE_NAME__", (ConvertTo-ShSingleQuoted $ImageName))
    $remoteScript = $remoteScript.Replace("__CONTAINER_NAME__", (ConvertTo-ShSingleQuoted $ContainerName))
    $remoteScript = $remoteScript.Replace("__PORT__", (ConvertTo-ShSingleQuoted ([string]$Port)))
    $remoteScript = $remoteScript.Replace("__STAMP__", (ConvertTo-ShSingleQuoted $Stamp))
    $remoteScript = $remoteScript.Replace("__PACKAGE_BASE64__", $packageBase64)

    $sshArgs = Get-SshArgs
    Write-Info "Opening deployment SSH session to $Remote."
    ($remoteScript + "`n") | & ssh @sshArgs $Remote "sh -s"
    $remoteCode = $LASTEXITCODE
    if ($remoteCode -ne 0) {
        throw "Remote deployment failed with exit code $remoteCode."
    }

    $deployEnd = Get-Date
    $deploySeconds = [Math]::Round(($deployEnd - $deployStart).TotalSeconds, 1)
    Write-Good "Deploy completed in $deploySeconds seconds."
}
finally {
    if (Test-Path $WorkDir) {
        Remove-Item -Path $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
