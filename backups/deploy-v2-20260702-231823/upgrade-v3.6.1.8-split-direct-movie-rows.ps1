param(
    [switch]$SkipDeploy
)

$ErrorActionPreference = "Stop"

$Version = "v3.6.1.8-split-direct-movie-rows"
$AppVersion = "v3.6.1.8"
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
Write-Host "Split direct movie files into individual rows"
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

Write-Step "Patching multi_import.py row splitting"
$MultiPath = "app\services\multi_import.py"
$Multi = Read-TextFile $MultiPath

# Replace the existing movie filename parser with a safer version that removes the year parentheses.
$NewFilenameParser = @'
def _filename_movie_title_year(value: Any) -> Dict[str, str]:
    text = str(value or "")
    stem = Path(text).stem if text else ""
    cleaned = re.sub(r"[._]+", " ", stem)
    cleaned = re.sub(r"\s+", " ", cleaned).strip()

    year_match = re.search(r"[\(\[\{]?\b(19\d{2}|20\d{2})\b[\)\]\}]?", cleaned)
    year = year_match.group(1) if year_match else ""

    if year_match:
        title_part = cleaned[:year_match.start()]
    else:
        title_part = cleaned

    title_part = re.sub(
        r"\b(?:1080p|720p|2160p|4320p|4k|8k|uhd|bluray|blu ray|web dl|webdl|webrip|hdtv|remux|hevc|x265|x264|h264|h265|avc|hdr|dd5 1|dts|truehd|atmos)\b.*$",
        "",
        title_part,
        flags=re.I,
    )
    title_part = re.sub(r"[-_]+", " ", title_part)
    title_part = re.sub(r"\s+", " ", title_part).strip(" -_.()[]{}")
    title = title_case_guess(title_part) if title_part else title_case_guess(stem)

    return {"title": title, "year": year}


'@

if ($Multi -match 'def _filename_movie_title_year\(') {
    $Multi = [regex]::Replace(
        $Multi,
        '(?s)def _filename_movie_title_year\(.*?\n(?=def _source_movie_signal\()',
        $NewFilenameParser,
        1
    )
    Write-Ok "Replaced _filename_movie_title_year() with safer parser"
} else {
    $InsertIndex = $Multi.IndexOf("def _source_movie_signal(")
    if ($InsertIndex -lt 0) {
        Fail "Could not find _source_movie_signal() or _filename_movie_title_year() in multi_import.py. Run v3.6.1.6 first."
    }
    $Multi = $Multi.Substring(0, $InsertIndex) + $NewFilenameParser + $Multi.Substring($InsertIndex)
    Write-Ok "Inserted _filename_movie_title_year() parser"
}

if ($Multi -notmatch 'def _expand_direct_movie_file_rows\(') {
    $SplitHelpers = @'

def _is_direct_child(base: Path, path: Path) -> bool:
    try:
        return len(path.relative_to(base).parts) == 1
    except Exception:
        return False


def _direct_movie_file_candidates(row: Dict[str, Any]) -> List[Path]:
    """
    Return direct child movie files that should become individual editable rows.

    This deliberately excludes TV episode-looking files. It is intended for folders like:
      Stargate - The Movies/
        Stargate (1994).mkv
        Stargate Continuum (2008).mkv
        Stargate The Ark of Truth (2008).mkv
    """
    source = Path(str((row or {}).get("source") or ""))
    if not source.exists() or not source.is_dir():
        return []

    try:
        videos = find_videos(source)
    except Exception:
        return []

    direct_videos = [video for video in videos if _is_direct_child(source, video)]
    if len(direct_videos) < 2:
        return []

    episode_like = 0
    year_like = 0
    distinct_titles = set()

    for video in direct_videos[:100]:
        text = video.name
        if re.search(r"\bS\d{1,2}E\d{1,3}\b|\b\d{1,2}x\d{1,3}\b", text, re.I):
            episode_like += 1
            continue

        parsed = _filename_movie_title_year(video.name)
        if parsed.get("year"):
            year_like += 1
        if parsed.get("title"):
            distinct_titles.add(parsed.get("title", "").lower())

    if episode_like:
        return []

    source_text = f"{source.name} {source}".lower()
    movie_word = bool(re.search(r"\b(movie|movies|film|films|trilogy|duology)\b", source_text, re.I))

    if year_like >= 2 and len(distinct_titles) >= 2:
        return sorted(direct_videos, key=lambda p: str(p).lower())

    if movie_word and year_like >= 1:
        return sorted(direct_videos, key=lambda p: str(p).lower())

    return []


def _expand_direct_movie_file_rows(rows: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """
    Split direct movie-file packs into one Import Manager row per movie file.

    The linker already knows how to route those files to /media/movies, but a single
    grouped row means one IMDb/TMDb field is shared by all movies. Splitting here gives
    each movie its own editable metadata row before preview/import.
    """
    expanded: List[Dict[str, Any]] = []

    for raw in rows or []:
        row = dict(raw or {})

        # Rows created by this splitter are already one file per row.
        if row.get("split_from_movie_pack"):
            expanded.append(row)
            continue

        candidates = _direct_movie_file_candidates(row)
        if len(candidates) < 2:
            expanded.append(row)
            continue

        parent_source = str(row.get("source") or "")
        parent_title = str(row.get("title") or row.get("detected") or Path(parent_source).name)

        for index, video in enumerate(candidates, start=1):
            parsed = _filename_movie_title_year(video.name)
            title = parsed.get("title") or parent_title or video.stem
            year = parsed.get("year") or str(row.get("year") or "")

            child = dict(row)
            child.update({
                "row_id": f"{row.get('row_id') or 'movie-pack'}-file-{index}",
                "enabled": row.get("enabled", True),
                "media_type": "movie",
                "media_type_label": "Movie",
                "source": str(video),
                "source_key": str(video),
                "parent_source": parent_source,
                "detected": video.stem,
                "title": title,
                "year": year,
                "season": "",
                "imdb_id": "",
                "tmdb_id": "",
                "alternatives": [],
                "match_status": "",
                "match_level": "",
                "match_score": "",
                "match_confidence": "",
                "confidence_level": "",
                "confidence_label": "",
                "file_count": 1,
                "split_from_movie_pack": True,
                "route_reason": "Direct movie file split from mixed pack",
            })
            expanded.append(child)

    return expanded


'@

    $InsertPoint = $Multi.IndexOf("def _route_by_filesystem_signal(")
    if ($InsertPoint -lt 0) {
        $InsertPoint = $Multi.IndexOf("def _apply_tmdb_match(")
    }
    if ($InsertPoint -lt 0) {
        Fail "Could not find a safe insertion point for direct movie row splitting helpers."
    }

    $Multi = $Multi.Substring(0, $InsertPoint) + $SplitHelpers + $Multi.Substring($InsertPoint)
    Write-Ok "Inserted direct movie row splitting helpers"
} else {
    Write-Ok "Direct movie row splitting helpers already present"
}

if ($Multi -notmatch 'rows = _expand_direct_movie_file_rows\(rows\)') {
    $PreviewMarker = 'def preview_multi_rows(rows: List[Dict[str, Any]], settings: Optional[Dict[str, Any]] = None, auto_match: bool = False, mode: str = "custom") -> Dict[str, Any]:'
    $PreviewIndex = $Multi.IndexOf($PreviewMarker)
    if ($PreviewIndex -lt 0) {
        Fail "Could not find preview_multi_rows() signature."
    }

    $SettingsLine = '    settings = settings or {}'
    $SettingsIndex = $Multi.IndexOf($SettingsLine, $PreviewIndex)
    if ($SettingsIndex -lt 0) {
        Fail "Could not find settings initialization inside preview_multi_rows()."
    }

    $InsertAfter = $SettingsIndex + $SettingsLine.Length
    $PatchLine = "`r`n    rows = _expand_direct_movie_file_rows(rows)"
    $Multi = $Multi.Substring(0, $InsertAfter) + $PatchLine + $Multi.Substring($InsertAfter)
    Write-Ok "preview_multi_rows() now splits direct movie files before rendering"
} else {
    Write-Ok "preview_multi_rows() already splits direct movie files"
}

$Multi = $Multi.Replace("v3.6.1.7", $AppVersion).Replace("v3.6.1.6", $AppVersion).Replace("v3.6.1.5", $AppVersion).Replace("v3.6.1.4", $AppVersion).Replace("v3.6.1.3", $AppVersion).Replace("v3.6.1.2", $AppVersion).Replace("v3.6.1.1", $AppVersion).Replace("v3.6.1.0", $AppVersion)
Write-TextFile -RelativePath $MultiPath -Content $Multi

Write-Step "Patching linker.py for file-source movie rows"
$LinkerPath = "app\services\linker.py"
$Linker = Read-TextFile $LinkerPath

# Replace the linker movie filename parser too, so direct movie planning no longer creates double parentheses.
$NewLinkerParser = @'
def _movie_title_year_from_filename(src, fallback_title="", fallback_year=""):
    stem = str(getattr(src, "stem", "") or "")
    cleaned = re.sub(r"[._]+", " ", stem)
    cleaned = re.sub(r"\s+", " ", cleaned).strip()

    year_match = re.search(r"[\(\[\{]?\b(19\d{2}|20\d{2})\b[\)\]\}]?", cleaned)
    year = year_match.group(1) if year_match else (detect_year(cleaned) or fallback_year or "")

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
    title_text = re.sub(r"\s+", " ", title_text).strip(" -_.()[]{}")
    title = strip_release_words(title_text) or title_text or fallback_title or stem

    return title.strip(), str(year or "").strip()


'@

if ($Linker -match 'def _movie_title_year_from_filename\(') {
    $Linker = [regex]::Replace(
        $Linker,
        '(?s)def _movie_title_year_from_filename\(.*?\n(?=def _is_direct_child\()',
        $NewLinkerParser,
        1
    )
    Write-Ok "Replaced _movie_title_year_from_filename() with safer parser"
} else {
    Write-Warn "_movie_title_year_from_filename() not found in linker.py. Skipping parser replacement."
}

# Let build_plan handle a single file source, since split movie rows point directly at one video file.
if ($Linker -notmatch 'v3\.6\.1\.8: split movie rows can pass a single file path') {
    $OldVideosLine = '    videos = find_videos(source_path)'
    $NewVideosBlock = @'
    # v3.6.1.8: split movie rows can pass a single file path as the source.
    if source_path.is_file():
        videos = [source_path]
    else:
        videos = find_videos(source_path)
'@

    $BuildIndex = $Linker.IndexOf("def build_plan(")
    if ($BuildIndex -lt 0) {
        Fail "Could not find build_plan() in linker.py"
    }

    $VideosIndex = $Linker.IndexOf($OldVideosLine, $BuildIndex)
    if ($VideosIndex -lt 0) {
        if ($Linker -match 'if source_path\.is_file\(\):\s*\n\s*videos = \[source_path\]') {
            Write-Ok "build_plan() already handles file sources"
        } else {
            Fail "Could not find videos = find_videos(source_path) inside build_plan()."
        }
    } else {
        $Linker = $Linker.Substring(0, $VideosIndex) + $NewVideosBlock.TrimEnd() + $Linker.Substring($VideosIndex + $OldVideosLine.Length)
        Write-Ok "build_plan() now handles file sources"
    }
} else {
    Write-Ok "build_plan() already includes v3.6.1.8 file-source support"
}

$Linker = $Linker.Replace("v3.6.1.7", $AppVersion).Replace("v3.6.1.6", $AppVersion).Replace("v3.6.1.5", $AppVersion).Replace("v3.6.1.4", $AppVersion).Replace("v3.6.1.3", $AppVersion).Replace("v3.6.1.2", $AppVersion).Replace("v3.6.1.1", $AppVersion).Replace("v3.6.1.0", $AppVersion)
Write-TextFile -RelativePath $LinkerPath -Content $Linker

Write-Step "Updating DEVELOPMENT.md"
$DevelopmentPath = Join-Path $ProjectRoot "DEVELOPMENT.md"
if (!(Test-Path $DevelopmentPath)) {
    Write-Utf8NoBom -Path $DevelopmentPath -Content "# NASDY Media Linker Development Notes`r`n"
}

$Development = [System.IO.File]::ReadAllText($DevelopmentPath)
if ($Development -notmatch 'v3\.6\.1\.8 Split Direct Movie Rows') {
    $DevelopmentAdd = @'

## v3.6.1.8 Split Direct Movie Rows

Fix after movie-pack routing.

Problem:
- `Stargate - The Movies` was routing to `/media/movies`, but it still appeared as one grouped Import Manager row.
- One grouped row means one IMDb/TMDb field would apply to all three movies.
- The preview could route the files correctly, but the metadata editor could not assign a different ID per movie.

Changes:
- Direct folders of movie files are now split into one Import Manager row per file.
- Each split movie row points directly at its own video file source.
- `build_plan()` now supports a single video file as the source.
- Filename parsing removes year parentheses correctly, preventing destinations like `Stargate ((1994))`.
- TV episode folders are not split because SxxEyy / 1x01 patterns exclude them from movie splitting.

Expected result:
- `Stargate (1994)` gets its own row and IMDb/TMDb field.
- `Stargate Continuum (2008)` gets its own row and IMDb/TMDb field.
- `Stargate The Ark of Truth (2008)` gets its own row and IMDb/TMDb field.
- TV shows such as Atlantis, SG-1, Universe, and Origins remain grouped by show/season rows.

'@
    $Development = $Development.TrimEnd() + "`r`n" + $DevelopmentAdd.TrimStart("`r", "`n")
    Write-Utf8NoBom -Path $DevelopmentPath -Content $Development
    Write-Ok "Updated DEVELOPMENT.md"
} else {
    Write-Ok "DEVELOPMENT.md already has v3.6.1.8 notes"
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
Write-Host "  4. Confirm the three Stargate movie files are three separate rows"
Write-Host "  5. Confirm each movie row has its own IMDb/TMDb field"
Write-Host "  6. Confirm movie destinations do not contain double parentheses"
Write-Host ""
Write-Host "Expected movie rows:"
Write-Host "  Stargate (1994)"
Write-Host "  Stargate Continuum (2008)"
Write-Host "  Stargate The Ark of Truth (2008)"
Write-Host ""
Write-Host "Expected movie destinations:"
Write-Host "  /media/movies/Stargate (1994)/Stargate (1994).mkv"
Write-Host "  /media/movies/Stargate Continuum (2008)/Stargate Continuum (2008).mkv"
Write-Host "  /media/movies/Stargate The Ark of Truth (2008)/Stargate The Ark of Truth (2008).mkv"
Write-Host ""
Write-Host "Suggested commit:"
Write-Host '  git add app/config.py app/services/multi_import.py app/services/linker.py DEVELOPMENT.md'
Write-Host '  git commit -m "Split direct movie files into editable import rows"'
Write-Host ""
