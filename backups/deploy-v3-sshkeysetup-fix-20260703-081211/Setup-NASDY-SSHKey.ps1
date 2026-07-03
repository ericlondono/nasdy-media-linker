# NASDY Media Linker - SSH key setup helper
# Generated for Deploy v3.

[CmdletBinding()]
param(
    [string]$HostName = "NASDY",
    [string]$User = "root",
    [string]$KeyPath = (Join-Path $env:USERPROFILE ".ssh\nasdy_ed25519"),
    [switch]$ForceNewKey,
    [switch]$PromptForPassphrase
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

function Write-Info {
    param([string]$Message)
    Write-Host "[NASDY SSH] $Message" -ForegroundColor Cyan
}

function Write-Good {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Assert-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found in PATH. Install/enable Windows OpenSSH first."
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

Assert-Command "ssh"
Assert-Command "ssh-keygen"

$KeyPath = [Environment]::ExpandEnvironmentVariables($KeyPath)
$KeyDir = Split-Path -Parent $KeyPath
$PublicKeyPath = "$KeyPath.pub"
$Remote = "$User@$HostName"
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"

if (-not (Test-Path $KeyDir)) {
    New-Item -ItemType Directory -Path $KeyDir -Force | Out-Null
    Write-Good "Created SSH directory: $KeyDir"
}

if ((Test-Path $KeyPath) -and $ForceNewKey) {
    $PrivateBackup = "$KeyPath.backup-$Stamp"
    $PublicBackup = "$PublicKeyPath.backup-$Stamp"
    Move-Item -Path $KeyPath -Destination $PrivateBackup -Force
    if (Test-Path $PublicKeyPath) {
        Move-Item -Path $PublicKeyPath -Destination $PublicBackup -Force
    }
    Write-Info "Existing key moved to backup: $PrivateBackup"
}

if (-not (Test-Path $KeyPath)) {
    Write-Info "Creating ed25519 key: $KeyPath"
    $keygenArgs = @(
        "-t", "ed25519",
        "-f", $KeyPath,
        "-C", "nasdy-media-linker-$env:COMPUTERNAME"
    )
    if (-not $PromptForPassphrase) {
        $keygenArgs += @("-N", "")
    }
    Invoke-NativeChecked -FilePath "ssh-keygen" -Arguments $keygenArgs -FriendlyName "ssh-keygen"
} else {
    Write-Good "Using existing private key: $KeyPath"
}

if (-not (Test-Path $PublicKeyPath)) {
    Write-Info "Public key file is missing; recreating it from the private key."
    $derivedPublicKey = & ssh-keygen -y -f $KeyPath
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($derivedPublicKey -join "`n"))) {
        throw "Could not derive public key from $KeyPath."
    }
    [System.IO.File]::WriteAllText($PublicKeyPath, (($derivedPublicKey -join "`n").Trim() + "`n"), [System.Text.Encoding]::ASCII)
}

$PublicKey = (Get-Content -Raw -Encoding ASCII $PublicKeyPath).Trim()
if ([string]::IsNullOrWhiteSpace($PublicKey)) {
    throw "Public key file is empty: $PublicKeyPath"
}

$InstallTemplate = @'
umask 077
mkdir -p "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
cat >> "$HOME/.ssh/authorized_keys" <<'__NASDY_PUBLIC_KEY__'
__PUBLIC_KEY__
__NASDY_PUBLIC_KEY__
awk 'NF && !seen[$0]++' "$HOME/.ssh/authorized_keys" > "$HOME/.ssh/authorized_keys.tmp"
mv "$HOME/.ssh/authorized_keys.tmp" "$HOME/.ssh/authorized_keys"
chmod 700 "$HOME/.ssh"
chmod 600 "$HOME/.ssh/authorized_keys"
printf '%s\n' "authorized_keys installed"
'@

$InstallScript = $InstallTemplate.Replace("__PUBLIC_KEY__", $PublicKey)

Write-Info "Installing public key on $Remote. This uses the existing password path only for setup if the NAS asks for it."
($InstallScript + "`n") | & ssh $Remote "sh -s"
$installCode = $LASTEXITCODE
if ($installCode -ne 0) {
    throw "Public key install failed with exit code $installCode. Password SSH has not been changed."
}

Write-Info "Testing key-only SSH login."
$keyTestOutput = & ssh -i $KeyPath -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 $Remote "echo SSH_KEY_OK"
$keyTestCode = $LASTEXITCODE
if ($keyTestCode -ne 0 -or (($keyTestOutput -join "`n") -notmatch "SSH_KEY_OK")) {
    throw "Key install finished, but key-only login did not pass. Password SSH has not been removed or changed."
}

Write-Good "SSH key works for $Remote"
Write-Host ""
Write-Host "Deploy.ps1 will use this key automatically when it exists and passes BatchMode testing:"
Write-Host "  $KeyPath"
