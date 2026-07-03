param(
    [switch]$SkipDeploy
)

$ErrorActionPreference = "Stop"

$Version = "v3.6.1.6-movie-pack-routing-fix"
$AppVersion = "v3.6.1.6"
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
Write-Host "Movie-pack routing fix"
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
    "app\services\multi_import.py",
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

Write-Step "Patching multi_import movie-vs-TV fallback routing"
$MultiPath = "app\services\multi_import.py"
$Multi = Read-TextFile $MultiPath

if ($Multi -notmatch 'def _source_movie_signal\(') {
    $InsertAfter = "def _infer_tv_season_from_source(row: Dict[str, Any]) -> str:"
    $InsertIndex = $Multi.IndexOf($InsertAfter)
    if ($InsertIndex -lt 0) {
        Fail "Could not find _infer_tv_season_from_source() in multi_import.py"
    }

    $MovieSignalHelper = @'

def _filename_movie_title_year(value: Any) -> Dict[str, str]:
    text = str(value or "")
    stem = Path(text).stem if text else ""
    stem = re.sub(r"[._]+", " ", stem)
    year_match = re.search(r"\b(19\d{2}|20\d{2})\b", stem)
    year = year_match.group(1) if year_match else ""

    if year_match:
        title_part = stem[:year_match.start()]
    else:
        title_part = stem

    title_part = re.sub(r"\b(?:1080p|720p|2160p|4k|uhd|bluray|blu ray|web dl|webdl|webrip|hdtv|remux|hevc|x265|x264|h264|h265|avc|hdr|dd5 1|dts|truehd|atmos)\b.*$", "", title_part, flags=re.I)
    title_part = re.sub(r"[-_]+", " ", title_part)
    title_part = re.sub(r"\s+", " ", title_part).strip(" -_.")
    title = title_part or stem

    return {"title": title, "year": year}


def _source_movie_signal(row: Dict[str, Any]) -> bool:
    """
    Detect movie-pack rows inside a TV-heavy mixed folder.

    Example:
    Stargate - The Movies/
      Stargate (1994).mkv
      Stargate Continuum (2008).mkv
      Stargate The Ark of Truth (2008).mkv

    These have years and no SxxEyy episode pattern, so they should route as movies,
    not as S01E01/S01E02 TV episodes.
    """
    source = Path(str((row or {}).get("source") or ""))

    try:
        videos = find_videos(source) if source.exists() else []
    except Exception:
        videos = []

    if not videos:
        return False

    texts = [
        str((row or {}).get("detected") or ""),
        str((row or {}).get("title") or ""),
        source.name,
        str(source),
    ]

    path_text = " ".join(texts).lower()
    path_movie_word = bool(re.search(r"\b(movie|movies|film|films|trilogy|duology)\b", path_text, re.I))

    episode_like = 0
    year_like = 0
    direct_like = 0
    distinct_titles = set()

    for video in videos[:100]:
        try:
            rel = video.relative_to(source)
            if len(rel.parts) == 1:
                direct_like += 1
        except Exception:
            pass

        text = f"{video.name} {video.parent.name}"
        if re.search(r"\bS\d{1,2}E\d{1,3}\b|\b\d{1,2}x\d{1,3}\b", text, re.I):
            episode_like += 1
            continue

        parsed = _filename_movie_title_year(video.name)
        if parsed.get("year"):
            year_like += 1
        if parsed.get("title"):
            distinct_titles.add(parsed.get("title", "").lower())

    # A real TV folder should not be forced to movie if most files have episode patterns.
    if episode_like >= max(1, len(videos) // 3):
        return False

    # Strong signal: a direct folder of multiple year-bearing movie files.
    if len(videos) >= 2 and year_like >= 2 and direct_like >= 2:
        return True

    # Strong signal: path says movies/films and files do not look episodic.
    if path_movie_word and episode_like == 0:
        return True

    # Single movie folder/file inside a mixed pack.
    if len(videos) == 1 and year_like == 1 and episode_like == 0:
        return True

    # Multiple distinct non-episode titles with years are likely a movie pack.
    if year_like >= 2 and len(distinct_titles) >= 2 and episode_like == 0:
        return True

    return False


'@

    $Multi = $Multi.Substring(0, $InsertIndex) + $MovieSignalHelper + $Multi.Substring($InsertIndex)
    Write-Ok "Inserted _source_movie_signal() helper"
} else {
    Write-Ok "_source_movie_signal() helper already present"
}

$OldRouteBlock = @'
    if _source_tv_signal(row):
        row["media_type"] = "tv"
        row["media_type_label"] = "TV Show"
        row["season"] = _infer_tv_season_from_source(row)
        row["match_status"] = row.get("match_status") or "Routed by episode pattern"
        row["match_level"] = row.get("match_level") or "warning"
        row["route_reason"] = "Episode pattern detected"
    else:
        row["media_type"] = "movie" if row.get("media_type") == "movie" else row.get("media_type", "movie")
        if row.get("media_type") != "tv":
            row["media_type_label"] = "Movie"
            row["season"] = ""
    return row
'@

$NewRouteBlock = @'
    if _source_tv_signal(row):
        row["media_type"] = "tv"
        row["media_type_label"] = "TV Show"
        row["season"] = _infer_tv_season_from_source(row)
        row["match_status"] = row.get("match_status") or "Routed by episode pattern"
        row["match_level"] = row.get("match_level") or "warning"
        row["route_reason"] = "Episode pattern detected"
    elif _source_movie_signal(row):
        row["media_type"] = "movie"
        row["media_type_label"] = "Movie"
        row["season"] = ""
        row["match_status"] = row.get("match_status") or "Routed by movie filename pattern"
        row["match_level"] = row.get("match_level") or "warning"
        row["route_reason"] = "Movie filename pattern detected"
    else:
        row["media_type"] = "movie" if row.get("media_type") == "movie" else row.get("media_type", "movie")
        if row.get("media_type") != "tv":
            row["media_type_label"] = "Movie"
            row["season"] = ""
    return row
'@

if ($Multi.Contains($OldRouteBlock)) {
    $Multi = $Multi.Replace($OldRouteBlock, $NewRouteBlock)
    Write-Ok "Updated filesystem routing fallback"
} elseif ($Multi -match 'elif _source_movie_signal\(row\)') {
    Write-Ok "Filesystem routing fallback already includes movie signal"
} else {
    Fail "Could not safely patch _route_by_filesystem_signal()"
}

$OldPreviewCondition = 'if auto_match or _row_has_metadata_identifier(row) or _source_tv_signal(row):'
$NewPreviewCondition = 'if auto_match or _row_has_metadata_identifier(row) or _source_tv_signal(row) or _source_movie_signal(row):'

if ($Multi.Contains($OldPreviewCondition)) {
    $Multi = $Multi.Replace($OldPreviewCondition, $NewPreviewCondition)
    Write-Ok "Preview now reroutes movie filename signals"
} elseif ($Multi.Contains($NewPreviewCondition)) {
    Write-Ok "Preview condition already includes movie signals"
} else {
    Write-Warn "Could not find exact preview routing condition. Continuing because auto_match previews still route rows."
}

$Multi = $Multi.Replace("v3.6.1.5", $AppVersion).Replace("v3.6.1.4", $AppVersion).Replace("v3.6.1.3", $AppVersion).Replace("v3.6.1.2", $AppVersion).Replace("v3.6.1.1", $AppVersion).Replace("v3.6.1.0", $AppVersion)
Write-TextFile -RelativePath $MultiPath -Content $Multi

Write-Step "Patching linker movie-pack planning"
$LinkerPath = "app\services\linker.py"
$Linker = Read-TextFile $LinkerPath

# Ensure required utility imports are present.
if ($Linker -match 'from app\.services\.utils import [^\r\n]+') {
    $ImportLine = [regex]::Match($Linker, 'from app\.services\.utils import [^\r\n]+').Value
    $UpdatedImportLine = $ImportLine
    foreach ($Name in @("strip_release_words", "detect_year", "looks_like_multi_movie_folder")) {
        if ($UpdatedImportLine -notmatch "(^|,\s*)$Name(\s*,|$)") {
            $UpdatedImportLine = $UpdatedImportLine + ", $Name"
        }
    }
    if ($UpdatedImportLine -ne $ImportLine) {
        $Linker = $Linker.Replace($ImportLine, $UpdatedImportLine)
        Write-Ok "Added movie planning utility imports"
    }
} else {
    Fail "Could not find app.services.utils import line in linker.py"
}

if ($Linker -notmatch 'def _looks_like_direct_movie_file_collection\(') {
    $BuildIndex = $Linker.IndexOf("def build_plan(")
    if ($BuildIndex -lt 0) {
        Fail "Could not find build_plan() in linker.py"
    }

    $MovieHelpers = @'

def _movie_title_year_from_filename(src, fallback_title="", fallback_year=""):
    stem = str(getattr(src, "stem", "") or "")
    cleaned = re.sub(r"[._]+", " ", stem)
    cleaned = re.sub(r"\s+", " ", cleaned).strip()

    year = detect_year(cleaned) or fallback_year or ""
    year_match = re.search(r"\b(19\d{2}|20\d{2})\b", cleaned)

    if year_match:
        title_text = cleaned[:year_match.start()]
    else:
        title_text = cleaned

    title_text = re.split(
        r"\b(?:480p|576p|720p|1080p|2160p|4320p|4k|8k|uhd|bluray|blu[- ]?ray|bdrip|brrip|web[- ]?dl|webdl|webrip|hdtv|remux|hevc|x265|x264|h264|h265|avc|hdr|dd5\.?1|dts|truehd|atmos)\b",
        title_text,
        maxsplit=1,
        flags=re.I,
    )[0]

    title_text = re.sub(r"[-_]+", " ", title_text)
    title_text = re.sub(r"\s+", " ", title_text).strip(" -_.")
    title = strip_release_words(title_text) or title_text or fallback_title or stem

    return title.strip(), str(year or "").strip()


def _is_direct_child(source_path, src):
    try:
        return len(src.relative_to(source_path).parts) == 1
    except Exception:
        return False


def _looks_like_direct_movie_file_collection(source_path, videos):
    if not videos or len(videos) < 2:
        return False

    direct_videos = [src for src in videos if _is_direct_child(source_path, src)]
    if len(direct_videos) < 2:
        return False

    episode_like = 0
    year_like = 0
    distinct_titles = set()

    for src in direct_videos:
        if detect_episode(src.name):
            episode_like += 1
            continue

        title, year = _movie_title_year_from_filename(src)
        if year:
            year_like += 1
        if title:
            distinct_titles.add(title.lower())

    if episode_like >= max(1, len(direct_videos) // 3):
        return False

    path_text = f"{source_path.name} {source_path}".lower()
    path_movie_word = bool(re.search(r"\b(movie|movies|film|films|trilogy|duology)\b", path_text, re.I))

    if year_like >= 2 and len(distinct_titles) >= 2:
        return True

    if path_movie_word and episode_like == 0:
        return True

    return False


def build_direct_movie_file_collection_plan(source_path, videos, fallback_title="", fallback_year=""):
    items = []
    direct_videos = sorted(
        [src for src in videos if _is_direct_child(source_path, src)],
        key=lambda p: str(p).lower(),
    )

    for src in direct_videos:
        movie_title, movie_year = _movie_title_year_from_filename(src, fallback_title, fallback_year)
        display = f"{movie_title} ({movie_year})" if movie_year else movie_title
        dest_dir = MOVIES_ROOT / safe_name(display)
        new_name = safe_name(f"{display}{src.suffix.lower()}")
        items.append({
            "src": src,
            "dst": dest_dir / new_name,
            "new_name": new_name,
            "movie_title": movie_title,
            "movie_year": movie_year,
            "movie_detected_from": "filename",
        })

    return MOVIES_ROOT, items


'@

    $Linker = $Linker.Substring(0, $BuildIndex) + $MovieHelpers + $Linker.Substring($BuildIndex)
    Write-Ok "Inserted direct movie file collection helpers"
} else {
    Write-Ok "Direct movie file collection helpers already present"
}

$MovieBranchMarker = @'
        # v3.6.0: a torrent/download can be a movie pack with one folder per movie.
        # In that case, create one movie folder per child release instead of naming
        # everything "Parent Title - Part 1/2/3".
        if looks_like_multi_movie_folder(source_path):
            return build_movie_collection_plan(source_path, videos, title, year)
'@

$MovieBranchReplacement = @'
        # v3.6.1.6: a TV-heavy pack can include a direct folder of movie files.
        # In that case, create one movie folder per movie filename instead of
        # forcing them into Season 01 TV episodes or a single "Part 1/2/3" movie.
        if _looks_like_direct_movie_file_collection(source_path, videos):
            return build_direct_movie_file_collection_plan(source_path, videos, title, year)

        # v3.6.0: a torrent/download can be a movie pack with one folder per movie.
        # In that case, create one movie folder per child release instead of naming
        # everything "Parent Title - Part 1/2/3".
        if looks_like_multi_movie_folder(source_path):
            return build_movie_collection_plan(source_path, videos, title, year)
'@

if ($Linker.Contains($MovieBranchMarker)) {
    $Linker = $Linker.Replace($MovieBranchMarker, $MovieBranchReplacement)
    Write-Ok "Patched movie branch for direct movie file collections"
} elseif ($Linker -match '_looks_like_direct_movie_file_collection\(source_path, videos\)') {
    Write-Ok "Movie branch already handles direct movie file collections"
} else {
    # Fallback insert after display line in the movie branch.
    $DisplayLine = '        display = f"{title} ({year})" if year else title'
    $InsertBlock = @'
        display = f"{title} ({year})" if year else title

        if _looks_like_direct_movie_file_collection(source_path, videos):
            return build_direct_movie_file_collection_plan(source_path, videos, title, year)
'@
    if ($Linker.Contains($DisplayLine)) {
        $Linker = $Linker.Replace($DisplayLine, $InsertBlock)
        Write-Ok "Inserted direct movie collection branch after movie display line"
    } else {
        Fail "Could not find a safe movie branch insertion point in linker.py"
    }
}

$Linker = $Linker.Replace("v3.6.1.5", $AppVersion).Replace("v3.6.1.4", $AppVersion).Replace("v3.6.1.3", $AppVersion).Replace("v3.6.1.2", $AppVersion).Replace("v3.6.1.1", $AppVersion).Replace("v3.6.1.0", $AppVersion)
Write-TextFile -RelativePath $LinkerPath -Content $Linker

Write-Step "Updating DEVELOPMENT.md"
$DevelopmentPath = Join-Path $ProjectRoot "DEVELOPMENT.md"
if (!(Test-Path $DevelopmentPath)) {
    Write-Utf8NoBom -Path $DevelopmentPath -Content "# NASDY Media Linker Development Notes`r`n"
}

$Development = [System.IO.File]::ReadAllText($DevelopmentPath)
if ($Development -notmatch 'v3\.6\.1\.6 Movie Pack Routing Fix') {
    $DevelopmentAdd = @'

## v3.6.1.6 Movie Pack Routing Fix

Fix after mixed media routing.

Problem:
- A mixed pack can contain a folder such as `Stargate - The Movies`.
- Because the selected queue item is TV-heavy, rows with no TMDb match and no TV episode pattern could remain marked as TV.
- `build_plan(media_type="tv")` then named movie files as `Season 01 / S01E01`, `S01E02`, etc.

Changes:
- Adds movie filename signal detection in `multi_import.py`.
- If a row has no SxxEyy/1x01 TV pattern but has movie-like filename/year signals, it routes as Movie.
- Adds direct movie-file collection planning in `linker.py`.
- A folder containing direct movie files such as `Stargate (1994).mkv`, `Stargate Continuum (2008).mkv`, and `Stargate The Ark of Truth (2008).mkv` now plans each file under `/media/movies/<Movie Title (Year)>/`.
- TV episode folders still route as TV because SxxEyy patterns win first.

Expected Stargate result:
- Stargate movie files route to `/media/movies`.
- Stargate Atlantis / SG-1 / Universe episode files route to `/media/tv`.

'@
    $Development = $Development.TrimEnd() + "`r`n" + $DevelopmentAdd.TrimStart("`r", "`n")
    Write-Utf8NoBom -Path $DevelopmentPath -Content $Development
    Write-Ok "Updated DEVELOPMENT.md"
} else {
    Write-Ok "DEVELOPMENT.md already has v3.6.1.6 notes"
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
    & python -m py_compile ".\app\services\multi_import.py" ".\app\services\linker.py"
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
Write-Host "  4. Confirm Stargate movie files route to /media/movies"
Write-Host "  5. Confirm Atlantis/SG-1/Universe episode files still route to /media/tv"
Write-Host ""
Write-Host "Expected examples:"
Write-Host "  /media/movies/Stargate (1994)/Stargate (1994).mkv"
Write-Host "  /media/movies/Stargate Continuum (2008)/Stargate Continuum (2008).mkv"
Write-Host "  /media/movies/Stargate The Ark of Truth (2008)/Stargate The Ark of Truth (2008).mkv"
Write-Host ""
Write-Host "Suggested commit:"
Write-Host '  git add app/config.py app/services/multi_import.py app/services/linker.py DEVELOPMENT.md'
Write-Host '  git commit -m "Fix movie pack routing inside mixed imports"'
Write-Host ""
