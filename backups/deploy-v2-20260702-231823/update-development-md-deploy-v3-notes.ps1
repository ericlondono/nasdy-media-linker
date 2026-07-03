$ErrorActionPreference = "Stop"

$ProjectRoot = "C:\Projects\nasdy-media-linker"
$DevelopmentPath = Join-Path $ProjectRoot "DEVELOPMENT.md"

Write-Host ""
Write-Host "Updating DEVELOPMENT.md with Deploy v3 / SSH key notes"
Write-Host ""

if (!(Test-Path $ProjectRoot)) {
    throw "Project folder not found: $ProjectRoot"
}

Set-Location $ProjectRoot

if (!(Test-Path $DevelopmentPath)) {
    throw "DEVELOPMENT.md not found at: $DevelopmentPath"
}

$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$BackupDir = Join-Path $ProjectRoot "backups\development-md-$Stamp"
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
Copy-Item $DevelopmentPath (Join-Path $BackupDir "DEVELOPMENT.md") -Force

Write-Host "[OK] Backup created: $BackupDir"

$Existing = Get-Content $DevelopmentPath -Raw

$Addendum = @'

## Future Infrastructure Goals

### Deploy v3 (Planned)

The current `Deploy.ps1` works correctly, but it still requires multiple SSH/SCP operations. When using password authentication, that can cause several password prompts.

The long-term deployment goal is:

- One deployment command:

```powershell
.\Deploy.ps1
```

- Zero manual file copying.
- One SSH session when practical.
- Zero password prompts using SSH key authentication.
- Automatic project backup.
- Automatic source sync.
- Exclude `__pycache__`, `.pyc`, backups, logs, `.git`, and other generated files.
- Build the Docker image directly on the NAS.
- Restart the `nasdy-media-organizer` container.
- Always mount:

```text
/mnt:/host_mnt
```

- Verify `/host_mnt` exists inside the running container.
- Verify the `/health` endpoint.
- Display a clean deployment summary including:
  - Build time
  - Deploy time
  - Health status
  - Container status
  - Image name
  - Container name
  - Active port
  - Required mounts

### SSH Authentication Goal

Future deployments should use SSH key authentication instead of repeated password prompts.

Desired workflow:

1. Configure an SSH key pair on the Windows development workstation.
2. Install the public key on the NAS under:

```text
/root/.ssh/authorized_keys
```

3. Update `Deploy.ps1` to use the key for SSH/SCP commands:

```powershell
ssh -i "$env:USERPROFILE\.ssh\nasdy_ed25519" root@NASDY
scp -i "$env:USERPROFILE\.ssh\nasdy_ed25519"
```

After setup, deployments should require zero password prompts.

The planned Windows setup command is expected to be similar to:

```powershell
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\nasdy_ed25519"
type "$env:USERPROFILE\.ssh\nasdy_ed25519.pub" | ssh root@NASDY "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"
ssh -i "$env:USERPROFILE\.ssh\nasdy_ed25519" root@NASDY "echo SSH key works"
```

Important:
- Do not remove password-based SSH until key-based SSH has been tested.
- Do not hard-code private key contents into any project file.
- Never commit private key files to Git.
- `Deploy.ps1` should reference the private key path only.

## Design Philosophy

The goal of NASDY Media Linker is to automate repetitive work while keeping the user in control of decisions.

Automation should eliminate unnecessary clicks and typing, but should never silently make destructive decisions.

Examples:

- Automatically detect Movie vs TV.
- Automatically detect IMDb/TMDb IDs.
- Automatically detect upgrades.
- Automatically detect duplicates.
- Allow the user to override any automatic decision.
- Prefer review over guessing when confidence is low.
- Keep imports non-destructive unless the user explicitly chooses otherwise.
- Make deployment boring, repeatable, and easy to verify.

'@

if ($Existing -match "## Future Infrastructure Goals") {
    Write-Host "[OK] DEVELOPMENT.md already contains Future Infrastructure Goals. No duplicate section added."
} else {
    Add-Content -Path $DevelopmentPath -Value $Addendum -Encoding UTF8
    Write-Host "[OK] Added Deploy v3 / SSH key notes and Design Philosophy"
}

Write-Host ""
Write-Host "Preview:"
Write-Host "--------"
Get-Content $DevelopmentPath | Select-Object -Last 80

Write-Host ""
Write-Host "[OK] DEVELOPMENT.md update complete"
Write-Host ""
Write-Host "Suggested commit:"
Write-Host 'git add DEVELOPMENT.md'
Write-Host 'git commit -m "Document Deploy v3 SSH key goal"'
Write-Host ""
