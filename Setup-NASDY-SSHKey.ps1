param(
    [string]$NasHost = "NASDY",
    [string]$NasUser = "root",
    [string]$KeyPath = "$env:USERPROFILE\.ssh\nasdy_ed25519",
    [switch]$ForceNewKey
)

$ErrorActionPreference = "Stop"

function Write-Step($Message) { Write-Host "[NASDY SSH] $Message" -ForegroundColor Cyan }
function Write-Ok($Message) { Write-Host "[OK] $Message" -ForegroundColor Green }
function Write-Warn($Message) { Write-Host "[WARN] $Message" -ForegroundColor Yellow }

function Invoke-Native {
    param(
        [Parameter(Mandatory=$true)][string]$FriendlyName,
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$true)][string[]]$Arguments
    )
    & $FilePath @Arguments
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        throw "$FriendlyName failed with exit code $code."
    }
}

function Test-KeyOnlySsh {
    param(
        [Parameter(Mandatory=$true)][string]$Target,
        [Parameter(Mandatory=$true)][string]$Key
    )

    $args = @(
        "-i", $Key,
        "-o", "BatchMode=yes",
        "-o", "IdentitiesOnly=yes",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "ConnectTimeout=8",
        $Target,
        "echo SSH_KEY_WORKS"
    )

    $output = & ssh @args 2>&1
    $code = $LASTEXITCODE
    return ($code -eq 0 -and (($output -join "`n") -match "SSH_KEY_WORKS"))
}

$sshKeygen = Get-Command ssh-keygen -ErrorAction SilentlyContinue
if (-not $sshKeygen) { throw "ssh-keygen was not found. Install Windows OpenSSH Client first." }

$ssh = Get-Command ssh -ErrorAction SilentlyContinue
if (-not $ssh) { throw "ssh was not found. Install Windows OpenSSH Client first." }

$keyDir = Split-Path -Parent $KeyPath
if (-not (Test-Path $keyDir)) {
    New-Item -ItemType Directory -Force -Path $keyDir | Out-Null
}

$pubPath = "$KeyPath.pub"
if ($ForceNewKey -and (Test-Path $KeyPath)) {
    $oldDir = Join-Path $keyDir ("nasdy-old-key-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
    New-Item -ItemType Directory -Force -Path $oldDir | Out-Null
    Move-Item $KeyPath (Join-Path $oldDir (Split-Path -Leaf $KeyPath)) -Force
    if (Test-Path $pubPath) { Move-Item $pubPath (Join-Path $oldDir (Split-Path -Leaf $pubPath)) -Force }
    Write-Warn "Existing key moved to: $oldDir"
}

if (-not (Test-Path $KeyPath) -or -not (Test-Path $pubPath)) {
    Write-Step "Creating ed25519 key: $KeyPath"
    $comment = "nasdy-media-linker-$env:COMPUTERNAME"
    Invoke-Native -FriendlyName "ssh-keygen" -FilePath "ssh-keygen" -Arguments @(
        "-t", "ed25519",
        "-f", $KeyPath,
        "-C", $comment,
        "-N", "`"`""
    )
} else {
    Write-Ok "SSH key already exists: $KeyPath"
}

if (-not (Test-Path $pubPath)) {
    throw "Public key file was not created: $pubPath"
}

$target = "$NasUser@$NasHost"

if (Test-KeyOnlySsh -Target $target -Key $KeyPath) {
    Write-Ok "SSH key authentication already works for $target"
    exit 0
}

$publicKey = (Get-Content -Raw -Path $pubPath).Trim()
if ([string]::IsNullOrWhiteSpace($publicKey)) {
    throw "Public key is empty: $pubPath"
}

# Avoid brittle shell quoting by uploading a tiny temp pubkey file first, then installing it on the NAS.
$tempName = "nasdy_deploy_key_$([Guid]::NewGuid().ToString('N')).pub"
$remoteTemp = "/tmp/$tempName"

Write-Step "Uploading public key to $target. This may ask for the NASDY root password once."
& scp -o StrictHostKeyChecking=accept-new $pubPath "${target}:$remoteTemp"
$scpCode = $LASTEXITCODE
if ($scpCode -ne 0) {
    throw "Public key upload failed with exit code $scpCode. Password SSH has not been changed."
}

$remoteCommand = "mkdir -p /root/.ssh; chmod 700 /root/.ssh; touch /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys; grep -qxF -f '$remoteTemp' /root/.ssh/authorized_keys || cat '$remoteTemp' >> /root/.ssh/authorized_keys; rm -f '$remoteTemp'; echo authorized_keys installed"

Write-Step "Installing public key in /root/.ssh/authorized_keys"
& ssh -o StrictHostKeyChecking=accept-new $target $remoteCommand
$installCode = $LASTEXITCODE
if ($installCode -ne 0) {
    throw "Public key install failed with exit code $installCode. Password SSH has not been changed."
}

Start-Sleep -Seconds 1

if (-not (Test-KeyOnlySsh -Target $target -Key $KeyPath)) {
    throw "Key was installed, but key-only SSH test failed. Password SSH has not been changed."
}

Write-Ok "SSH key authentication works for $target"
Write-Host ""
Write-Host "Next deploy command:" -ForegroundColor Cyan
Write-Host "  cd C:\Projects\nasdy-media-linker"
Write-Host "  powershell -ExecutionPolicy Bypass -File .\Deploy.ps1"
