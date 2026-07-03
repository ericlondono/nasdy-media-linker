param(
    [switch]$SkipDeploy,
    [string]$ProjectRoot = "C:\Projects\nasdy-media-linker"
)

$ErrorActionPreference = "Stop"
$Version = "v3.6.2.1-legacy-tv-season-parser-fix"
$AppVersion = "v3.6.2.1"

function Step($Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Ok($Message) {
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Warn($Message) {
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
    Ok "Wrote $RelativePath"
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

function Replace-RegexOnceLiteral {
    param(
        [Parameter(Mandatory=$true)][string]$Text,
        [Parameter(Mandatory=$true)][string]$Pattern,
        [Parameter(Mandatory=$true)][string]$Replacement,
        [Parameter(Mandatory=$true)][string]$Description
    )
    $Regex = [System.Text.RegularExpressions.Regex]::new($Pattern)
    if (!$Regex.IsMatch($Text)) {
        Fail "Could not find patch target: $Description"
    }
    $LiteralReplacement = $Replacement
    $Evaluator = { param($Match) $LiteralReplacement }.GetNewClosure()
    return $Regex.Replace($Text, [System.Text.RegularExpressions.MatchEvaluator]$Evaluator, 1)
}

Write-Host ""
Write-Host "NASDY Media Linker $Version"
Write-Host "Legacy TV season parser and complete-series title cleanup"
Write-Host ""

Step "Checking project folder"
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

Ok "Project detected: $ProjectRoot"

Step "Creating local backup"
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$BackupRoot = Join-Path $ProjectRoot "backups"
$BackupPath = Join-Path $BackupRoot "$Version-$Stamp"
New-Item -ItemType Directory -Force -Path $BackupPath | Out-Null

$FilesToBackup = @(
    "app\config.py",
    "app\services\utils.py",
    "app\services\linker.py",
    "app\services\multi_import.py",
    "app\static\app.js",
    "static\app.js",
    "DEVELOPMENT.md"
)

foreach ($RelativePath in $FilesToBackup) {
    Backup-File -RelativePath $RelativePath -BackupPath $BackupPath
}

Ok "Backup created: $BackupPath"

Step "Updating app version"
$Config = Read-TextFile "app\config.py"
$ConfigUpdated = [regex]::Replace($Config, 'APP_VERSION\s*=\s*["''][^"''\r\n]+["'']', "APP_VERSION = `"$AppVersion`"")
if ($ConfigUpdated -eq $Config) {
    Warn "APP_VERSION was not found in app\config.py. Leaving config version unchanged."
} else {
    Write-TextFile -RelativePath "app\config.py" -Content $ConfigUpdated
    Ok "Set APP_VERSION to $AppVersion"
}

Step "Patching utility season/episode detection"
$UtilsPath = "app\services\utils.py"
$Utils = Read-TextFile $UtilsPath

$UtilsSeasonEpisode = @'
def detect_season(text: str) -> str:
    text = str(text)

    m = re.search(r"\bS0*(\d{1,2})\s*E\s*\d{1,3}\b", text, re.I)
    if m:
        return f"{int(m.group(1)):02d}"

    m = re.search(r"\bS0*(\d{1,2})\b", text, re.I)
    if m:
        return f"{int(m.group(1)):02d}"

    m = re.search(r"\b(?:Season|Series)[ ._-]*0*(\d{1,2})\b", text, re.I)
    if m:
        return f"{int(m.group(1)):02d}"

    # Legacy TV scene naming: 5x01, 05x01, or 5 x 01.
    m = re.search(r"\b0*(\d{1,2})\s*x\s*\d{1,3}\b", text, re.I)
    if m:
        return f"{int(m.group(1)):02d}"

    return "01"


def detect_episode(filename: str) -> str:
    filename = str(filename)
    m = re.search(r"\bS\d{1,2}\s*E\s*(\d{1,3})\b", filename, re.I)
    if m:
        return f"{int(m.group(1)):02d}"
    m = re.search(r"\b\d{1,2}\s*x\s*(\d{1,3})\b", filename, re.I)
    if m:
        return f"{int(m.group(1)):02d}"
    return ""


'@

$Utils = Replace-RegexOnceLiteral `
    -Text $Utils `
    -Pattern '(?s)def detect_season\(.*?\r?\n(?=def strip_release_words\()' `
    -Replacement $UtilsSeasonEpisode `
    -Description "utils.py detect_season/detect_episode block"

$UtilsLooksLikeTv = @'
def looks_like_tv_name(name: str) -> bool:
    return bool(re.search(r"\bS\d{1,2}\b|\bS\d{1,2}\s*E\s*\d{1,3}\b|\bSeason[ ._-]*\d{1,2}\b|\b\d{1,2}\s*x\s*\d{1,3}\b", str(name), re.I))


'@

$Utils = Replace-RegexOnceLiteral `
    -Text $Utils `
    -Pattern '(?s)def looks_like_tv_name\(.*?\r?\n(?=def looks_like_multi_movie_folder\()' `
    -Replacement $UtilsLooksLikeTv `
    -Description "utils.py looks_like_tv_name block"

Write-TextFile -RelativePath $UtilsPath -Content $Utils

Step "Patching linker.py TV destination planner"
$LinkerPath = "app\services\linker.py"
$Linker = Read-TextFile $LinkerPath

$LinkerTvHelpers = @'
def _normalize_tv_season(value, default="01"):
    """
    Normalize season values from folder names, filenames, or row inputs.

    Supports modern SxxEyy/Sxx forms and legacy scene forms such as 5x01,
    05x01, and 5 x 01. The legacy form was the cause of Reno 911! episodes
    being planned into Season 01 even when filenames clearly said 5x01.
    """
    text = str(value or "").strip()
    if not text:
        return default

    patterns = [
        r"\bS0*(\d{1,2})\s*E\s*\d{1,3}\b",
        r"\bS0*(\d{1,2})\b",
        r"\b(?:Season|Series)[ ._-]*0*(\d{1,2})\b",
        r"\b0*(\d{1,2})\s*x\s*\d{1,3}\b",
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

    # Prefer the strongest signal first: a season/episode pattern in the file itself.
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


def _clean_tv_show_title(value):
    """Remove pack/season/release descriptors from TV show titles."""
    text = str(value or "").strip()
    if not text:
        return ""

    text = strip_release_words(text)
    text = re.sub(r"\b(?:Season|Series)[ ._-]*0*\d{1,2}\b.*$", " ", text, flags=re.I)
    text = re.sub(r"\bS0*\d{1,2}\b.*$", " ", text, flags=re.I)
    text = re.sub(r"\b0*\d{1,2}\s*x\s*\d{1,3}\b.*$", " ", text, flags=re.I)
    text = re.sub(
        r"\b(?:Complete(?:[ ._-]*(?:Series|Season|Collection))?|All[ ._-]*Seasons?|Full[ ._-]*Series|Collection|Box[ ._-]*Set|Pack)\b.*$",
        " ",
        text,
        flags=re.I,
    )
    text = re.sub(r"\b(?:DVD|DVDRip|BluRay|WEB[- ._]?DL|WEBRip|HDTV|x264|x265|XviD)\b.*$", " ", text, flags=re.I)
    text = re.sub(r"[._]+", " ", text)
    text = re.sub(r"\s+", " ", text).strip(" -_.()[]{}")
    return text


def _tv_title_key(value):
    return re.sub(r"[^a-z0-9]+", "", str(value or "").lower())


def _tv_title_looks_polluted(value):
    return bool(re.search(
        r"\b(?:complete|all[ ._-]*seasons?|full[ ._-]*series|collection|box[ ._-]*set|pack|season[ ._-]*\d+|series[ ._-]*\d+|S\d{1,2}|dvd|dvdrip|xvid|webrip|web[- ._]?dl|hdtv|bluray)\b",
        str(value or ""),
        re.I,
    ))


def _episode_show_title_from_filename(src):
    stem = str(getattr(src, "stem", "") or "")
    if not stem:
        return ""

    match = re.search(
        r"^(?P<title>.+?)(?:\s*[-._]+\s*|\s+)(?:S0*\d{1,2}\s*E\s*\d{1,3}|0*\d{1,2}\s*x\s*\d{1,3})\b",
        stem,
        re.I,
    )
    if not match:
        return ""

    return _clean_tv_show_title(match.group("title"))


def _best_tv_show_title(title, source_path, videos):
    """
    Choose a clean TV show title for destination planning.

    This prevents pack folders such as "Reno 911! Complete" from becoming the
    show folder, while still preserving useful punctuation from filenames such
    as "Reno 911! - 5x01 - ..." when the editable row contains "Reno 911".
    """
    explicit_raw = str(title or "").strip()
    explicit = _clean_tv_show_title(explicit_raw)

    candidates = []
    for src in list(videos or [])[:20]:
        candidate = _episode_show_title_from_filename(src)
        if candidate:
            candidates.append(candidate)

    for raw in (
        getattr(source_path, "name", ""),
        getattr(getattr(source_path, "parent", None), "name", ""),
    ):
        candidate = _clean_tv_show_title(raw)
        if candidate and candidate.lower() not in {"downloads", "download", "tv", "television", "media"}:
            candidates.append(candidate)

    cleaned_candidates = []
    seen = set()
    for candidate in candidates:
        candidate = _clean_tv_show_title(candidate)
        key = _tv_title_key(candidate)
        if not candidate or not key or key in seen:
            continue
        seen.add(key)
        cleaned_candidates.append(candidate)

    if explicit:
        explicit_key = _tv_title_key(explicit)
        if not _tv_title_looks_polluted(explicit_raw):
            for candidate in cleaned_candidates:
                if _tv_title_key(candidate) == explicit_key and len(candidate) > len(explicit):
                    return candidate
            return explicit
        return explicit

    if cleaned_candidates:
        return cleaned_candidates[0]

    return explicit_raw


def _episode_title_from_filename(src):
    stem = str(getattr(src, "stem", "") or "")
    match = re.search(
        r"\b(?:S\d{1,2}\s*E\s*\d{1,3}|\d{1,2}\s*x\s*\d{1,3})\b[ ._-]*(?:-\s*)?(.+)$",
        stem,
        re.I,
    )
    if not match:
        return ""

    title = match.group(1)

    # Strip common release/quality tail tokens while keeping the episode title.
    title = re.split(
        r"[ ._-]+(?:"
        r"480p|576p|720p|1080p|2160p|4320p|4k|8k|uhd|"
        r"bluray|blu[- ._]?ray|bdrip|brrip|web[- ._]?dl|webdl|webrip|hdtv|remux|"
        r"hdrip|dvdrip|x264|x265|h264|h265|hevc|avc|av1|xvid|"
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

$Linker = Replace-RegexOnceLiteral `
    -Text $Linker `
    -Pattern '(?s)def _normalize_tv_season\(.*?\r?\n(?=def _movie_title_year_from_filename\()' `
    -Replacement $LinkerTvHelpers `
    -Description "linker.py TV helper block"

$OldDisplayPattern = '        display = f"\{title\} \(\{year\}\)" if year else title\r?\n        show_dir = TV_ROOT / safe_name\(display\)'
$NewDisplayBlock = @'
        tv_title = _best_tv_show_title(title, source_path, videos) or title
        display = f"{tv_title} ({year})" if year else tv_title
        show_dir = TV_ROOT / safe_name(display)
'@
$Linker = Replace-RegexOnceLiteral `
    -Text $Linker `
    -Pattern $OldDisplayPattern `
    -Replacement $NewDisplayBlock.TrimEnd() `
    -Description "linker.py TV display/show_dir block"

Write-TextFile -RelativePath $LinkerPath -Content $Linker

Step "Patching multi_import.py Import Manager row planning"
$MultiPath = "app\services\multi_import.py"
$Multi = Read-TextFile $MultiPath

$MultiSeasonHelpers = @'
TV_EPISODE_PATTERN = re.compile(
    r"\bS0*(?P<s_season>\d{1,2})\s*E\s*(?P<s_episode>\d{1,3})\b|\b0*(?P<x_season>\d{1,2})\s*x\s*(?P<x_episode>\d{1,3})\b",
    re.I,
)


def _explicit_season_number(value: Any, default: str = "") -> str:
    """Return a season only when the text contains an explicit season signal."""
    text = str(value or "").strip()
    if not text:
        return default

    patterns = [
        r"\bS0*(\d{1,2})\s*E\s*\d{1,3}\b",
        r"\bS0*(\d{1,2})\b",
        r"\b(?:Season|Series)[ ._\-]*0*(\d{1,2})\b",
        r"\b0*(\d{1,2})\s*x\s*\d{1,3}\b",
    ]

    for pattern in patterns:
        match = re.search(pattern, text, re.I)
        if match:
            try:
                return f"{int(match.group(1)):02d}"
            except Exception:
                return default

    return default


def _season_number(value: Any, default: str = "01") -> str:
    explicit = _explicit_season_number(value, "")
    if explicit:
        return explicit

    text = str(value or "").strip()
    if not text:
        text = default
    try:
        return f"{int(text):02d}"
    except Exception:
        detected = detect_season(text)
        try:
            return f"{int(detected):02d}"
        except Exception:
            return str(default or "01").zfill(2)


def _season_from_folder(name: str) -> Optional[str]:
    return _explicit_season_number(name, "") or None


def _season_from_videos(path: Path) -> Optional[str]:
    try:
        videos = find_videos(path)
    except Exception:
        videos = []

    counts: Dict[str, int] = {}
    for video in videos[:100]:
        season = _explicit_season_number(f"{video.name} {video.parent.name}", "")
        if season:
            counts[season] = counts.get(season, 0) + 1

    if not counts:
        return None
    return sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))[0][0]


def _clean_media_title(value: str) -> str:
    text = strip_release_words(value or "")
    text = re.sub(r"[\(\[\{]?\b(19\d{2}|20\d{2})\b[\)\]\}]?", " ", text)
    text = re.sub(r"\s+", " ", text).strip(" ._-()[]{}")
    return title_case_guess(text) if text else strip_release_words(value or "")


def _clean_tv_show_title(value: Any) -> str:
    text = str(value or "").strip()
    if not text:
        return ""

    text = strip_release_words(text)
    text = re.sub(r"\b(?:Season|Series)[ ._\-]*0*\d{1,2}\b.*$", " ", text, flags=re.I)
    text = re.sub(r"\bS0*\d{1,2}\b.*$", " ", text, flags=re.I)
    text = re.sub(r"\b0*\d{1,2}\s*x\s*\d{1,3}\b.*$", " ", text, flags=re.I)
    text = re.sub(
        r"\b(?:Complete(?:[ ._\-]*(?:Series|Season|Collection))?|All[ ._\-]*Seasons?|Full[ ._\-]*Series|Collection|Box[ ._\-]*Set|Pack)\b.*$",
        " ",
        text,
        flags=re.I,
    )
    text = re.sub(r"\b(?:DVD|DVDRip|BluRay|WEB[- ._]?DL|WEBRip|HDTV|x264|x265|XviD)\b.*$", " ", text, flags=re.I)
    text = re.sub(r"[._]+", " ", text)
    text = re.sub(r"\s+", " ", text).strip(" -_.()[]{}")
    return title_case_guess(text) if text else ""


def _tv_title_key(value: Any) -> str:
    return re.sub(r"[^a-z0-9]+", "", str(value or "").lower())


def _tv_title_looks_polluted(value: Any) -> bool:
    return bool(re.search(
        r"\b(?:complete|all[ ._\-]*seasons?|full[ ._\-]*series|collection|box[ ._\-]*set|pack|season[ ._\-]*\d+|series[ ._\-]*\d+|S\d{1,2}|dvd|dvdrip|xvid|webrip|web[- ._]?dl|hdtv|bluray)\b",
        str(value or ""),
        re.I,
    ))


def _episode_show_title_from_filename(path: Any) -> str:
    stem = Path(str(path or "")).stem
    if not stem:
        return ""

    match = re.search(
        r"^(?P<title>.+?)(?:\s*[-._]+\s*|\s+)(?:S0*\d{1,2}\s*E\s*\d{1,3}|0*\d{1,2}\s*x\s*\d{1,3})\b",
        stem,
        re.I,
    )
    if not match:
        return ""

    return _clean_tv_show_title(match.group("title"))


def _best_tv_show_title(fallback_title: str, source_path: Path, videos: Optional[List[Path]] = None) -> str:
    explicit_raw = str(fallback_title or "").strip()
    explicit = _clean_tv_show_title(explicit_raw)

    candidates: List[str] = []
    for video in list(videos or [])[:30]:
        candidate = _episode_show_title_from_filename(video.name)
        if candidate:
            candidates.append(candidate)

    for raw in (
        getattr(source_path, "name", ""),
        getattr(getattr(source_path, "parent", None), "name", ""),
    ):
        candidate = _clean_tv_show_title(raw)
        if candidate and candidate.lower() not in {"downloads", "download", "tv", "television", "media"}:
            candidates.append(candidate)

    cleaned: List[str] = []
    seen = set()
    for candidate in candidates:
        candidate = _clean_tv_show_title(candidate)
        key = _tv_title_key(candidate)
        if not candidate or not key or key in seen:
            continue
        seen.add(key)
        cleaned.append(candidate)

    if explicit:
        explicit_key = _tv_title_key(explicit)
        if not _tv_title_looks_polluted(explicit_raw):
            for candidate in cleaned:
                if _tv_title_key(candidate) == explicit_key and len(candidate) > len(explicit):
                    return candidate
            return explicit
        return explicit

    if cleaned:
        return cleaned[0]

    return explicit_raw


def _clean_parent_title(value: str) -> str:
    return _clean_tv_show_title(value or "") or strip_release_words(value or "")


'@

$Multi = Replace-RegexOnceLiteral `
    -Text $Multi `
    -Pattern '(?s)def _season_number\(.*?\r?\n(?=def _video_count\()' `
    -Replacement $MultiSeasonHelpers `
    -Description "multi_import.py season/title helper block"

$MultiDetectTvRows = @'
def detect_tv_season_rows(source: str, fallback_title: str = "", fallback_year: str = "") -> List[Dict[str, Any]]:
    source_path = Path(source or "")
    rows = []
    try:
        parent_videos = find_videos(source_path)
    except Exception:
        parent_videos = []

    parent_title = _best_tv_show_title(fallback_title or "", source_path, parent_videos) or _clean_parent_title(source_path.name)
    parent_year = fallback_year or detect_year(source_path.name)

    season_children = []
    for child in _child_dirs_with_videos(source_path):
        season = _season_from_folder(child.name) or _season_from_videos(child)
        if season:
            season_children.append((child, season))

    if len(season_children) < 2:
        return []

    for index, (child, season) in enumerate(season_children, start=1):
        videos = find_videos(child)
        rows.append({
            "row_id": f"tv-{index}",
            "enabled": True,
            "media_type": "tv",
            "source": str(child),
            "source_key": str(child),
            "detected": child.name,
            "title": parent_title,
            "year": parent_year,
            "imdb_id": "",
            "tmdb_id": "",
            "season": season,
            "file_count": len(videos),
        })

    return rows


'@

$Multi = Replace-RegexOnceLiteral `
    -Text $Multi `
    -Pattern '(?s)def detect_tv_season_rows\(.*?\r?\n(?=def detect_multi_import_rows\()' `
    -Replacement $MultiDetectTvRows `
    -Description "multi_import.py detect_tv_season_rows block"

$MultiSourceTvSignal = @'
def _source_tv_signal(row: Dict[str, Any]) -> bool:
    source = Path(str((row or {}).get("source") or ""))
    texts = [
        str((row or {}).get("detected") or ""),
        str((row or {}).get("title") or ""),
        source.name,
        str(source),
    ]

    try:
        videos = find_videos(source) if source.exists() else []
    except Exception:
        videos = []

    episode_like = 0
    season_like = 0
    for video in videos[:80]:
        text = f"{video.name} {video.parent.name}"
        texts.append(text)
        if TV_EPISODE_PATTERN.search(text):
            episode_like += 1
        if _explicit_season_number(text, ""):
            season_like += 1

    combined = " ".join(texts)
    if TV_EPISODE_PATTERN.search(combined):
        return True

    if episode_like >= 2:
        return True

    if videos and season_like >= max(2, min(5, len(videos) // 2)):
        return True

    return False


'@

$Multi = Replace-RegexOnceLiteral `
    -Text $Multi `
    -Pattern '(?s)def _source_tv_signal\(.*?\r?\n(?=def _filename_movie_title_year\()' `
    -Replacement $MultiSourceTvSignal `
    -Description "multi_import.py _source_tv_signal block"

$MultiInferSeason = @'
def _infer_tv_season_from_source(row: Dict[str, Any]) -> str:
    # Do not trust the normalized default row season first. A default "01" can
    # mask a filename like 5x01, so inspect detected/source/video signals first.
    for value in (
        (row or {}).get("detected"),
        (row or {}).get("source"),
    ):
        season = _explicit_season_number(value, "")
        if season:
            return season

    source = Path(str((row or {}).get("source") or ""))
    try:
        videos = find_videos(source) if source.exists() else []
    except Exception:
        videos = []

    counts: Dict[str, int] = {}
    for video in videos[:100]:
        season = _explicit_season_number(f"{video.name} {video.parent.name}", "")
        if season:
            counts[season] = counts.get(season, 0) + 1

    if counts:
        return sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))[0][0]

    season = _explicit_season_number((row or {}).get("season"), "")
    if season:
        return season

    return "01"


'@

$Multi = Replace-RegexOnceLiteral `
    -Text $Multi `
    -Pattern '(?s)def _infer_tv_season_from_source\(.*?\r?\n(?=def _apply_metadata_to_row\()' `
    -Replacement $MultiInferSeason `
    -Description "multi_import.py _infer_tv_season_from_source block"

$MultiNormalizeRow = @'
def _normalize_row(row: Dict[str, Any], index: int) -> Dict[str, Any]:
    media_type = "movie" if row.get("media_type") == "movie" else "tv"
    source = str(row.get("source") or "").strip()
    title = str(row.get("title") or "").strip()
    year = str(row.get("year") or "").strip()
    season = "" if media_type == "movie" else _season_number(row.get("season") or "01")
    imdb_id = str(row.get("imdb_id") or "").strip()

    if media_type == "tv":
        source_path = Path(source or "")
        try:
            videos = find_videos(source_path) if source_path.exists() else []
        except Exception:
            videos = []
        title = _best_tv_show_title(title, source_path, videos) or title

    return {
        "row_id": str(row.get("row_id") or f"row-{index}"),
        "enabled": _as_bool(row.get("enabled"), True),
        "media_type": media_type,
        "source": source,
        "source_key": str(row.get("source_key") or source),
        "detected": str(row.get("detected") or Path(source).name),
        "title": title,
        "year": year,
        "imdb_id": imdb_id,
        "tmdb_id": str(row.get("tmdb_id") or ""),
        "season": season,
        "file_count": int(row.get("file_count") or 0),
        "poster": str(row.get("poster") or ""),
        "match_status": str(row.get("match_status") or ("Manual IMDb" if imdb_id else "Needs match")),
        "match_level": str(row.get("match_level") or ("good" if imdb_id else "warning")),
        "match_score": row.get("match_score") or "",
    }


'@

$Multi = Replace-RegexOnceLiteral `
    -Text $Multi `
    -Pattern '(?s)def _normalize_row\(.*?\r?\n(?=def _legacy_status_from_plan\()' `
    -Replacement $MultiNormalizeRow `
    -Description "multi_import.py _normalize_row block"

$Multi = $Multi.Replace('\bS\d{1,2}E\d{1,3}\b|\b\d{1,2}x\d{1,3}\b', '\bS\d{1,2}\s*E\s*\d{1,3}\b|\b\d{1,2}\s*x\s*\d{1,3}\b')
Write-TextFile -RelativePath $MultiPath -Content $Multi

Step "Updating Import Manager version badge"
$AppJsPath = "app\static\app.js"
$AppJs = Read-TextFile $AppJsPath
$BadgePattern = '<span class="status-chip advisor-chip recommended">v[^<]+</span>'
$BadgeReplacement = '<span class="status-chip advisor-chip recommended">' + $AppVersion + '</span>'
$AppJs2 = [regex]::Replace($AppJs, $BadgePattern, $BadgeReplacement, 1)
if ($AppJs2 -eq $AppJs) {
    Warn "Could not find Import Manager version badge in app\static\app.js."
} else {
    Write-TextFile -RelativePath $AppJsPath -Content $AppJs2
    Ok "Set Import Manager badge to $AppVersion"
}

if (Test-Path (Join-Path $ProjectRoot "static\app.js")) {
    $LegacyAppJsPath = "static\app.js"
    $LegacyAppJs = Read-TextFile $LegacyAppJsPath
    $LegacyAppJs2 = [regex]::Replace($LegacyAppJs, $BadgePattern, $BadgeReplacement, 1)
    if ($LegacyAppJs2 -ne $LegacyAppJs) {
        Write-TextFile -RelativePath $LegacyAppJsPath -Content $LegacyAppJs2
        Ok "Set legacy static badge to $AppVersion"
    }
}

Step "Updating DEVELOPMENT.md"
$DevelopmentPath = Join-Path $ProjectRoot "DEVELOPMENT.md"
if (!(Test-Path $DevelopmentPath)) {
    Write-Utf8NoBom -Path $DevelopmentPath -Content "# NASDY Media Linker Development Notes`r`n"
}
$Development = [System.IO.File]::ReadAllText($DevelopmentPath)
if ($Development -notmatch 'v3\.6\.2\.1 Legacy TV Season Parser Fix') {
    $DevelopmentAdd = @'

## v3.6.2.1 Legacy TV Season Parser Fix

Problem:
- Complete-series TV packs such as `Reno 911! Complete` could pollute the show title with pack descriptors.
- Legacy episode names such as `5x01` exposed the episode number but not the season number to the planner, causing files to fall back to `Season 01` / `S01E01`.
- Some Import Manager TV rows could inherit a default season before checking stronger filename signals.

Change:
- Adds explicit support for legacy TV patterns such as `5x01`, `05x01`, and `5 x 01` in season and episode parsing.
- Cleans TV show titles by removing pack descriptors such as `Complete`, `Collection`, `Pack`, season labels, and release words while preserving punctuation from filenames when useful.
- Prefers filename/folder season evidence before defaulting to Season 01.
- Updates the Import Manager version badge to match the backend app version.

Expected Reno 911 result:
- `Reno 911! Complete` imports under `/media/tv/Reno 911!/`.
- `Reno 911 Season 5` and filenames like `Reno 911! - 5x01 - Title.avi` import under `Season 05` as `S05E01`.
'@
    $Development = $Development.TrimEnd() + "`r`n" + $DevelopmentAdd.TrimStart("`r", "`n")
    Write-Utf8NoBom -Path $DevelopmentPath -Content $Development
    Ok "Updated DEVELOPMENT.md"
} else {
    Ok "DEVELOPMENT.md already has v3.6.2.1 notes"
}

Step "Cleaning local Python cache files"
Get-ChildItem -Path $ProjectRoot -Directory -Recurse -Force -Filter "__pycache__" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $ProjectRoot -File -Recurse -Force -Filter "*.pyc" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
Ok "Python cache files cleaned"

Step "Best-effort Python syntax check"
$PythonCmd = Get-Command python -ErrorAction SilentlyContinue
if ($PythonCmd) {
    & python -m py_compile ".\app\config.py" ".\app\services\utils.py" ".\app\services\linker.py" ".\app\services\multi_import.py"
    if ($LASTEXITCODE -ne 0) {
        Fail "Python syntax check failed. Backup is available at $BackupPath"
    }
    Ok "Python syntax check passed"
} else {
    Warn "Python not found locally; skipping local syntax check."
}

Step "Showing changed files"
$GitCmd = Get-Command git -ErrorAction SilentlyContinue
if ($GitCmd) {
    git status --short
} else {
    Warn "git not found locally; skipping git status."
}

if ($SkipDeploy) {
    Warn "Skipped deployment because -SkipDeploy was used."
    Write-Host "Run later: powershell -ExecutionPolicy Bypass -File .\Deploy.ps1"
    exit 0
}

Step "Deploying with permanent Deploy.ps1"
powershell -ExecutionPolicy Bypass -File ".\Deploy.ps1"
if ($LASTEXITCODE -ne 0) {
    Fail "Deploy.ps1 failed. Backup is available at $BackupPath"
}

Write-Host ""
Write-Host "NASDY Media Linker $Version complete" -ForegroundColor Green
Write-Host ""
Write-Host "Verify:"
Write-Host "  1. Hard refresh http://NASDY:8088"
Write-Host "  2. Open the Reno 911! Complete queue item."
Write-Host "  3. Confirm rows show Reno 911! as the show title."
Write-Host "  4. Confirm 5x01 previews as Season 05 / S05E01, not Season 01 / S01E01."
Write-Host ""
Write-Host "Suggested commit:"
Write-Host '  git add app/config.py app/services/utils.py app/services/linker.py app/services/multi_import.py app/static/app.js DEVELOPMENT.md'
Write-Host '  git commit -m "Fix legacy TV season parser for complete-series packs"'
Write-Host '  git tag v3.6.2.1'
Write-Host ""
