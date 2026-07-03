param(
    [switch]$SkipDeploy
)

$ErrorActionPreference = "Stop"

$Version = "v3.6.1.3-emergency-history-recovery"
$AppVersion = "v3.6.1.3"
$ProjectRoot = "C:\Projects\nasdy-media-linker"

function Write-Step($Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok($Message) {
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Warn($Message) {
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Fail($Message) {
    Write-Host "[ERROR] $Message" -ForegroundColor Red
    exit 1
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Content
    )
    $Parent = Split-Path -Parent $Path
    if ($Parent -and !(Test-Path $Parent)) {
        New-Item -ItemType Directory -Force -Path $Parent | Out-Null
    }
    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}

function Read-TextFile {
    param([Parameter(Mandatory=$true)][string]$RelativePath)
    $Path = Join-Path $ProjectRoot $RelativePath
    if (!(Test-Path $Path)) {
        Fail "Missing required file: $RelativePath"
    }
    return [System.IO.File]::ReadAllText($Path)
}

function Write-TextFile {
    param(
        [Parameter(Mandatory=$true)][string]$RelativePath,
        [Parameter(Mandatory=$true)][string]$Content
    )
    $Path = Join-Path $ProjectRoot $RelativePath
    Write-Utf8NoBom -Path $Path -Content $Content
    Write-Ok "Wrote $RelativePath"
}

function Backup-File {
    param(
        [Parameter(Mandatory=$true)][string]$RelativePath,
        [Parameter(Mandatory=$true)][string]$BackupPath
    )
    $SourcePath = Join-Path $ProjectRoot $RelativePath
    if (Test-Path $SourcePath) {
        $DestPath = Join-Path $BackupPath $RelativePath
        New-Item -ItemType Directory -Force -Path (Split-Path $DestPath -Parent) | Out-Null
        Copy-Item $SourcePath $DestPath -Force
    }
}

Write-Host ""
Write-Host "NASDY Media Linker $Version"
Write-Host "Emergency UI recovery"
Write-Host ""

Write-Step "Checking project folder"
if (!(Test-Path $ProjectRoot)) {
    Fail "Project folder not found: $ProjectRoot"
}

Set-Location $ProjectRoot

if (!(Test-Path ".\app")) {
    Fail "This does not look like the project root. Missing .\app"
}
if (!(Test-Path ".\Deploy.ps1")) {
    Fail "Deploy.ps1 is missing."
}
if (!(Test-Path ".\.deploy.sh")) {
    Fail ".deploy.sh is missing."
}

Write-Ok "Project detected: $ProjectRoot"

Write-Step "Creating local backup"
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$BackupRoot = Join-Path $ProjectRoot "backups"
$BackupPath = Join-Path $BackupRoot "$Version-$Stamp"
New-Item -ItemType Directory -Force -Path $BackupPath | Out-Null

$FilesToBackup = @(
    "app\config.py",
    "app\static\app.js",
    "app\static\style.css",
    "DEVELOPMENT.md"
)

foreach ($RelativePath in $FilesToBackup) {
    Backup-File -RelativePath $RelativePath -BackupPath $BackupPath
}

Write-Ok "Backup created: $BackupPath"

Write-Step "Updating app version"
$Config = Read-TextFile "app\config.py"
$ConfigUpdated = [regex]::Replace($Config, 'APP_VERSION\s*=\s*["''][^"''\r\n]+["'']', "APP_VERSION = `"$AppVersion`"")
if ($ConfigUpdated -eq $Config) {
    Write-Warn "APP_VERSION was not found in app\config.py. Leaving config version unchanged."
} else {
    Write-TextFile -RelativePath "app\config.py" -Content $ConfigUpdated
    Write-Ok "Set APP_VERSION to $AppVersion"
}

Write-Step "Removing unsafe Import History collapse JavaScript"
$AppJsPath = "app\static\app.js"
$AppJs = Read-TextFile $AppJsPath

$StartMarker = "function findPanelByHeadingText(headingText)"
$EndMarker = "function schedulePreview()"

$StartIndex = $AppJs.IndexOf($StartMarker)
if ($StartIndex -ge 0) {
    $EndIndex = $AppJs.IndexOf($EndMarker, $StartIndex)
    if ($EndIndex -gt $StartIndex) {
        $Before = $AppJs.Substring(0, $StartIndex)
        $After = $AppJs.Substring($EndIndex)
        $AppJs = $Before + $After
        Write-Ok "Removed Import History collapse/toggle runtime block"
    } else {
        Write-Warn "Found collapse block start but could not find safe end marker. Leaving app.js runtime block unchanged."
    }
} else {
    Write-Ok "No Import History collapse runtime block found"
}

$AppJs = $AppJs.Replace("v3.6.1.2", $AppVersion).Replace("v3.6.1.1", $AppVersion).Replace("v3.6.1.0", $AppVersion)
Write-TextFile -RelativePath $AppJsPath -Content $AppJs

Write-Step "Adding CSS recovery guard"
$StylePath = "app\static\style.css"
$Style = Read-TextFile $StylePath

if ($Style -notmatch 'v3\.6\.1\.3 Emergency Import History Recovery') {
    $StyleAdd = @'

/* v3.6.1.3 Emergency Import History Recovery */

/*
  v3.6.1.2 used a heuristic to find the Import History panel.
  On the live layout it could select a parent container instead of just the
  history card, which hid the main app and left only the floating button.

  Recovery rule: disable the floating history controls and force the app/panels
  back to visible. We will re-add collapsed history later using explicit markup.
*/
.history-rail-toggle,
.history-panel-toggle {
  display: none !important;
}

body.import-history-collapsed,
body.import-history-expanded {
  background: #0f172a !important;
}

.import-history-panel,
body.import-history-collapsed .import-history-panel,
body.import-history-expanded .import-history-panel {
  display: block !important;
  visibility: visible !important;
  opacity: 1 !important;
}

.import-history-layout-parent,
body.import-history-collapsed .import-history-layout-parent,
body.import-history-expanded .import-history-layout-parent {
  visibility: visible !important;
  opacity: 1 !important;
}

body.import-history-collapsed .import-history-layout-parent,
body.import-history-expanded .import-history-layout-parent {
  grid-template-columns: var(--nasdy-recovered-grid-columns, revert) !important;
}

/* Keep the status cards constrained while we restore the layout. */
.smart-status-card {
  max-width: 138px !important;
}

/* end v3.6.1.3 Emergency Import History Recovery */
'@
    $Style = $Style.TrimEnd() + "`r`n" + $StyleAdd.TrimStart("`r", "`n") + "`r`n"
    Write-Ok "Added emergency CSS recovery guard"
} else {
    Write-Ok "Emergency CSS recovery guard already present"
}

$Style = $Style.Replace("v3.6.1.2", $AppVersion).Replace("v3.6.1.1", $AppVersion).Replace("v3.6.1.0", $AppVersion)
Write-TextFile -RelativePath $StylePath -Content $Style

Write-Step "Updating DEVELOPMENT.md"
$DevelopmentPath = Join-Path $ProjectRoot "DEVELOPMENT.md"
if (!(Test-Path $DevelopmentPath)) {
    Write-Utf8NoBom -Path $DevelopmentPath -Content "# NASDY Media Linker Development Notes`r`n"
}

$Development = [System.IO.File]::ReadAllText($DevelopmentPath)
if ($Development -notmatch 'v3\.6\.1\.3 Emergency Import History Recovery') {
    $DevelopmentAdd = @'

## v3.6.1.3 Emergency Import History Recovery

Recovery release after v3.6.1.2.

Problem:
- The Import History collapse script used heading/ancestor detection.
- On the live layout it could hide the wrong parent container.
- The app appeared as a blank page with only the floating Import History button visible.

Fix:
- Removes the unsafe runtime Import History collapse script.
- Hides the floating Import History controls.
- Forces the Import History panel/layout classes visible again.
- Preserves the smart status-card UI and status-width fixes.

Next:
- Rebuild Import History collapse using explicit template markup/classes instead of DOM guessing.

'@
    $Development = $Development.TrimEnd() + "`r`n" + $DevelopmentAdd.TrimStart("`r", "`n")
    Write-Utf8NoBom -Path $DevelopmentPath -Content $Development
    Write-Ok "Updated DEVELOPMENT.md"
} else {
    Write-Ok "DEVELOPMENT.md already has v3.6.1.3 notes"
}

Write-Step "Cleaning local Python cache files"
Get-ChildItem -Path $ProjectRoot -Directory -Recurse -Force -Filter "__pycache__" -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $ProjectRoot -File -Recurse -Force -Filter "*.pyc" -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue
Write-Ok "Python cache files cleaned"

Write-Step "Showing changed files"
git status --short

if ($SkipDeploy) {
    Write-Warn "Skipped deployment because -SkipDeploy was used."
    Write-Host ""
    Write-Host "Run this when ready:"
    Write-Host "  powershell -ExecutionPolicy Bypass -File .\Deploy.ps1"
    exit 0
}

Write-Step "Deploying with permanent Deploy.ps1"
powershell -ExecutionPolicy Bypass -File ".\Deploy.ps1"

if ($LASTEXITCODE -ne 0) {
    Fail "Deploy.ps1 failed."
}

Write-Host ""
Write-Host "NASDY Media Linker $Version complete" -ForegroundColor Green
Write-Host ""
Write-Host "Verify in browser:"
Write-Host "  1. Hard refresh http://NASDY:8088"
Write-Host "  2. Confirm version shows $AppVersion"
Write-Host "  3. Confirm the main app is visible again"
Write-Host "  4. Confirm Import History is visible again for now"
Write-Host "  5. Confirm status cards still use colored dots and stay contained"
Write-Host ""
Write-Host "Suggested commit:"
Write-Host '  git add app/config.py app/static/app.js app/static/style.css DEVELOPMENT.md'
Write-Host '  git commit -m "Recover from unsafe import history collapse"'
Write-Host ""
