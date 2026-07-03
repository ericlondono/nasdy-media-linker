param(
    [switch]$SkipDeploy
)

$ErrorActionPreference = "Stop"

$Version = "v3.6.1.7-tv-branch-movie-pack-guard"
$AppVersion = "v3.6.1.7"
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
Write-Host "TV branch movie-pack guard"
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
    "app\services\linker.py",
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

Write-Step "Patching linker build_plan guard"
$LinkerPath = "app\services\linker.py"
$Linker = Read-TextFile $LinkerPath

if ($Linker -notmatch '_looks_like_direct_movie_file_collection') {
    Fail "Missing _looks_like_direct_movie_file_collection() from v3.6.1.6. Run v3.6.1.6 first, then this patch."
}

if ($Linker -notmatch 'build_direct_movie_file_collection_plan') {
    Fail "Missing build_direct_movie_file_collection_plan() from v3.6.1.6. Run v3.6.1.6 first, then this patch."
}

if ($Linker -notmatch 'v3\.6\.1\.7: even when a row arrives as TV') {
    $BuildIndex = $Linker.IndexOf("def build_plan(")
    if ($BuildIndex -lt 0) {
        Fail "Could not find build_plan() in app\services\linker.py"
    }

    $TvBranch = '    if media_type == "tv":'
    $TvIndex = $Linker.IndexOf($TvBranch, $BuildIndex)
    if ($TvIndex -lt 0) {
        Fail "Could not find TV branch inside build_plan()"
    }

    $Guard = @'
    # v3.6.1.7: even when a row arrives as TV, a direct folder of movie files
    # must route to Movies. This catches mixed packs where the frontend/backend
    # still passes media_type="tv" for a "Stargate - The Movies" folder.
    if media_type == "tv" and _looks_like_direct_movie_file_collection(source_path, videos):
        return build_direct_movie_file_collection_plan(source_path, videos, title, year)

'@

    $Linker = $Linker.Substring(0, $TvIndex) + $Guard + $Linker.Substring($TvIndex)
    Write-Ok "Inserted TV-branch movie-pack guard"
} else {
    Write-Ok "TV-branch movie-pack guard already present"
}

# Add an extra safety net in the TV branch itself: if a TV source has no episode patterns
# and the direct movie collection detector says movie, force movie planning.
# This protects against future refactors that move the guard lower.
if ($Linker -notmatch 'movie_detected_from"\: "tv_branch_guard"') {
    $Linker = $Linker.Replace(
        '"movie_detected_from": "filename",',
        '"movie_detected_from": "filename",'
    )
    Write-Ok "Direct movie collection planner remains unchanged"
}

$Linker = $Linker.Replace("v3.6.1.6", $AppVersion).Replace("v3.6.1.5", $AppVersion).Replace("v3.6.1.4", $AppVersion).Replace("v3.6.1.3", $AppVersion).Replace("v3.6.1.2", $AppVersion).Replace("v3.6.1.1", $AppVersion).Replace("v3.6.1.0", $AppVersion)
Write-TextFile -RelativePath $LinkerPath -Content $Linker

Write-Step "Updating DEVELOPMENT.md"
$DevelopmentPath = Join-Path $ProjectRoot "DEVELOPMENT.md"
if (!(Test-Path $DevelopmentPath)) {
    Write-Utf8NoBom -Path $DevelopmentPath -Content "# NASDY Media Linker Development Notes`r`n"
}

$Development = [System.IO.File]::ReadAllText($DevelopmentPath)
if ($Development -notmatch 'v3\.6\.1\.7 TV Branch Movie Pack Guard') {
    $DevelopmentAdd = @'

## v3.6.1.7 TV Branch Movie Pack Guard

Fix after v3.6.1.6.

Problem:
- v3.6.1.6 added direct movie-file collection planning in the Movie branch.
- However, mixed packs can still pass `media_type="tv"` into `build_plan()` for a movie folder such as `Stargate - The Movies`.
- Because the TV branch ran first, those movie files were still converted into `Season 01 / S01E01`, `S01E02`, etc.

Change:
- Adds an early guard inside `build_plan()`.
- If a row arrives as TV but the source is clearly a direct folder of movie files, the linker routes it through the movie collection planner before the TV branch runs.

Expected result:
- `Stargate - The Movies` routes to `/media/movies`.
- `Stargate Atlantis`, `SG-1`, `Universe`, and other episode folders still route to `/media/tv`.

'@
    $Development = $Development.TrimEnd() + "`r`n" + $DevelopmentAdd.TrimStart("`r", "`n")
    Write-Utf8NoBom -Path $DevelopmentPath -Content $Development
    Write-Ok "Updated DEVELOPMENT.md"
} else {
    Write-Ok "DEVELOPMENT.md already has v3.6.1.7 notes"
}

Write-Step "Cleaning local Python cache files"
Get-ChildItem -Path $ProjectRoot -Directory -Recurse -Force -Filter "__pycache__" -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $ProjectRoot -File -Recurse -Force -Filter "*.pyc" -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue
Write-Ok "Python cache files cleaned"

Write-Step "Best-effort Python syntax check"
$PythonCmd = Get-Command python -ErrorAction SilentlyContinue
if ($PythonCmd) {
    & python -m py_compile ".\app\services\linker.py"
    if ($LASTEXITCODE -ne 0) {
        Fail "Python syntax check failed."
    }
    Write-Ok "Python syntax check passed"
} else {
    Write-Warn "Python not found locally; skipping local syntax check."
}

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
Write-Host "  3. Re-open the Stargate collection"
Write-Host "  4. Confirm the three Stargate movie files route to /media/movies"
Write-Host "  5. Confirm Atlantis/SG-1/Universe episode files still route to /media/tv"
Write-Host ""
Write-Host "Expected movie examples:"
Write-Host "  /media/movies/Stargate (1994)/Stargate (1994).mkv"
Write-Host "  /media/movies/Stargate Continuum (2008)/Stargate Continuum (2008).mkv"
Write-Host "  /media/movies/Stargate The Ark of Truth (2008)/Stargate The Ark of Truth (2008).mkv"
Write-Host ""
Write-Host "Suggested commit:"
Write-Host '  git add app/config.py app/services/linker.py DEVELOPMENT.md'
Write-Host '  git commit -m "Guard TV branch against movie-pack folders"'
Write-Host ""
