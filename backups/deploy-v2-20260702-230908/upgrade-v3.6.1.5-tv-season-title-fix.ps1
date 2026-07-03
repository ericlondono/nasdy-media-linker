param(
    [switch]$SkipDeploy
)

$ErrorActionPreference = "Stop"

$Version = "v3.6.1.5-tv-season-title-fix"
$AppVersion = "v3.6.1.5"
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
Write-Host "TV season and episode-title naming fix"
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

Write-Step "Patching linker TV season detection and output naming"
$LinkerPath = "app\services\linker.py"
$Linker = Read-TextFile $LinkerPath

if ($Linker -notmatch '(?m)^import re\b') {
    $Linker = "import re`r`n" + $Linker
    Write-Ok "Added import re"
}

if ($Linker -notmatch 'def _normalize_tv_season\(') {
    $BuildIndexForHelpers = $Linker.IndexOf("def build_plan(")
    if ($BuildIndexForHelpers -lt 0) {
        Fail "Could not find build_plan() in app\services\linker.py"
    }

    $Helpers = @'

def _normalize_tv_season(value, default="01"):
    """
    Normalize season values from detect_season(), folder names, or filenames.

    Important: older code tried int("S02"), which failed and fell back to 01.
    This helper turns S02, S02E04, Season 2, and 2 into "02".
    """
    text = str(value or "").strip()
    if not text:
        return default

    patterns = [
        r"\bS0*(\d{1,2})E\d{1,3}\b",
        r"\bS0*(\d{1,2})\b",
        r"\bSeason[ ._-]*0*(\d{1,2})\b",
        r"^\s*0*(\d{1,2})\s*$",
    ]

    for pattern in patterns:
        match = re.search(pattern, text, re.I)
        if match:
            try:
                return f"{int(match.group(1)):02d}"
            except Exception:
                return default

    return default


def _detect_tv_season_for_file(src, fallback="01"):
    fallback = _normalize_tv_season(fallback, "01")

    # Prefer the strongest signal first: SxxEyy in the actual filename.
    for raw in (
        getattr(src, "name", ""),
        getattr(src, "stem", ""),
        getattr(getattr(src, "parent", None), "name", ""),
        str(getattr(src, "parent", "")),
    ):
        direct = _normalize_tv_season(raw, "")
        if direct:
            return direct

        try:
            detected = detect_season(str(raw or ""))
            normalized = _normalize_tv_season(detected, "")
            if normalized:
                return normalized
        except Exception:
            pass

    return fallback


def _episode_title_from_filename(src):
    stem = str(getattr(src, "stem", "") or "")
    match = re.search(r"\b(?:S\d{1,2}E\d{1,3}|\d{1,2}x\d{1,3})[ ._-]+(.+)$", stem, re.I)
    if not match:
        return ""

    title = match.group(1)

    # Strip common release/quality tail tokens while keeping the episode title.
    title = re.split(
        r"[ ._-]+(?:"
        r"480p|576p|720p|1080p|2160p|4320p|4k|8k|uhd|"
        r"bluray|blu[- ._]?ray|bdrip|brrip|web[- ._]?dl|webdl|webrip|hdtv|remux|"
        r"hdrip|dvdrip|x264|x265|h264|h265|hevc|avc|av1|"
        r"hdr10\+?|hdr|dolby[ ._-]?vision|truehd|atmos|dts[- ._]?hd|dts|"
        r"ddp?5?\.?1?|dd5\.1|aac|ac3|eac3"
        r")\b",
        title,
        maxsplit=1,
        flags=re.I,
    )[0]

    title = re.sub(r"[._]+", " ", title)
    title = re.sub(r"\s+", " ", title).strip(" -_.")
    title = re.sub(r"\s*-\s*$", "", title).strip()

    if not title:
        return ""

    if re.fullmatch(r"episode\s*\d+", title, re.I):
        return ""

    # Avoid huge filenames if a release tail slips through.
    if len(title) > 80:
        title = title[:80].rstrip(" -_.")

    return title


'@

    $Linker = $Linker.Substring(0, $BuildIndexForHelpers) + $Helpers + $Linker.Substring($BuildIndexForHelpers)
    Write-Ok "Inserted TV season/title helper functions"
} else {
    Write-Ok "TV season/title helpers already present"
}

$BuildIndex = $Linker.IndexOf("def build_plan(")
if ($BuildIndex -lt 0) {
    Fail "Could not find build_plan() in app\services\linker.py"
}

$TvIndex = $Linker.IndexOf('    if media_type == "tv":', $BuildIndex)
if ($TvIndex -lt 0) {
    Fail "Could not find TV branch in build_plan()"
}

$ElseIndex = $Linker.IndexOf("    else:", $TvIndex)
if ($ElseIndex -lt 0) {
    Fail "Could not find movie branch after TV branch in build_plan()"
}

$BeforeTv = $Linker.Substring(0, $TvIndex)
$AfterElse = $Linker.Substring($ElseIndex)

$NewTvBlock = @'
    if media_type == "tv":
        # v3.6.1.5: TV source folders can contain multiple seasons and episode titles.
        # Route each video by the season detected in its own filename/path.
        # Preserve the episode title from the source filename when available.
        display = f"{title} ({year})" if year else title
        show_dir = TV_ROOT / safe_name(display)

        requested_season = _normalize_tv_season(season or "01", "01")
        fallback_by_season = {}
        detected_seasons = set()

        for src in videos:
            src_season = _detect_tv_season_for_file(src, requested_season)
            detected_seasons.add(src_season)

            ep = detect_episode(src.name)
            episode_detected = bool(ep)
            if not ep:
                fallback = fallback_by_season.get(src_season, 1)
                ep = f"{fallback:02d}"
                fallback_by_season[src_season] = fallback + 1

            episode_title = _episode_title_from_filename(src)
            dest_dir = show_dir / f"Season {src_season}"

            base_name = f"{display} - S{src_season}E{ep}"
            if episode_title:
                base_name = f"{base_name} - {episode_title}"

            new_name = safe_name(f"{base_name}{src.suffix.lower()}")
            items.append({
                "src": src,
                "dst": dest_dir / new_name,
                "new_name": new_name,
                "season": src_season,
                "episode": ep,
                "episode_title": episode_title,
                "episode_detected": episode_detected,
            })

        if len(detected_seasons) == 1:
            only_season = sorted(detected_seasons)[0]
            return show_dir / f"Season {only_season}", items

        return show_dir, items

'@

$Linker = $BeforeTv + $NewTvBlock + $AfterElse
$Linker = $Linker.Replace("v3.6.1.4", $AppVersion).Replace("v3.6.1.3", $AppVersion).Replace("v3.6.1.2", $AppVersion).Replace("v3.6.1.1", $AppVersion).Replace("v3.6.1.0", $AppVersion)

Write-TextFile -RelativePath $LinkerPath -Content $Linker
Write-Ok "Updated TV build_plan branch"

Write-Step "Updating DEVELOPMENT.md"
$DevelopmentPath = Join-Path $ProjectRoot "DEVELOPMENT.md"
if (!(Test-Path $DevelopmentPath)) {
    Write-Utf8NoBom -Path $DevelopmentPath -Content "# NASDY Media Linker Development Notes`r`n"
}

$Development = [System.IO.File]::ReadAllText($DevelopmentPath)
if ($Development -notmatch 'v3\.6\.1\.5 TV Season and Episode Title Fix') {
    $DevelopmentAdd = @'

## v3.6.1.5 TV Season and Episode Title Fix

Fix after mixed media routing.

Problem:
- TV shows routed correctly to `/media/tv`, but some S02 files were still renamed into `Season 01` / `S01Exx`.
- The cause was season normalization: values like `S02` could fail numeric conversion and fall back to `01`.
- Episode titles such as `Duet` were also dropped from the output filename.

Changes:
- Adds robust TV season normalization for `S02E04`, `S02`, `Season 2`, and `2`.
- Detects each TV file's season from the filename before using the row fallback season.
- Preserves episode titles from source filenames when available.
- Example output:
  `/media/tv/Stargate Atlantis (2004)/Season 02/Stargate Atlantis (2004) - S02E04 - Duet.mkv`

'@
    $Development = $Development.TrimEnd() + "`r`n" + $DevelopmentAdd.TrimStart("`r", "`n")
    Write-Utf8NoBom -Path $DevelopmentPath -Content $Development
    Write-Ok "Updated DEVELOPMENT.md"
} else {
    Write-Ok "DEVELOPMENT.md already has v3.6.1.5 notes"
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
Write-Host "  4. Confirm Atlantis S02 files preview under Season 02"
Write-Host "  5. Confirm output filenames preserve episode titles when available"
Write-Host ""
Write-Host "Expected example:"
Write-Host "  /media/tv/Stargate Atlantis (2004)/Season 02/Stargate Atlantis (2004) - S02E04 - Duet.mkv"
Write-Host ""
Write-Host "Suggested commit:"
Write-Host '  git add app/config.py app/services/linker.py DEVELOPMENT.md'
Write-Host '  git commit -m "Fix TV season detection and episode titles"'
Write-Host ""
