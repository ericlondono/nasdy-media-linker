param(
    [switch]$SkipDeploy
)

$ErrorActionPreference = "Stop"

$Version = "v3.6.1.4-mixed-media-routing"
$AppVersion = "v3.6.1.4"
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
Write-Host "Mixed movie / TV routing release"
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
    "app\services\tmdb.py",
    "app\services\multi_import.py",
    "app\services\linker.py",
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

Write-Step "Adding TMDb cross-type lookup helpers"
$TmdbPath = "app\services\tmdb.py"
$Tmdb = Read-TextFile $TmdbPath

if ($Tmdb -notmatch 'def tmdb_search_best_any\(') {
    $Marker = "def tmdb_search(settings"
    $InsertIndex = $Tmdb.IndexOf($Marker)
    if ($InsertIndex -lt 0) {
        Fail "Could not find tmdb_search() in app\services\tmdb.py"
    }

    $TmdbHelpers = @'

def _media_type_label(media_type: str) -> str:
    return "TV show" if media_type == "tv" else "Movie"


def _rank_metadata_candidate(item: dict, preferred_media_type: str = "", query_title: str = "", query_year: str = "") -> float:
    preferred = "tv" if preferred_media_type == "tv" else ("movie" if preferred_media_type == "movie" else "")
    score = float((item or {}).get("match_score") or 0)

    if preferred and (item or {}).get("media_type") == preferred:
        score += 3

    if (item or {}).get("imdb_id"):
        score += 2

    if query_year and str((item or {}).get("year") or "") == str(query_year):
        score += 8

    return score


def _parse_media_identifier(value: str) -> dict:
    text = str(value or "").strip()
    if not text:
        return {}

    imdb = re.search(r"(tt\d{5,12})", text, re.I)
    if imdb:
        return {"kind": "imdb", "id": imdb.group(1).lower()}

    tmdb_url = re.search(r"themoviedb\.org/(movie|tv)/(\d+)", text, re.I)
    if tmdb_url:
        return {
            "kind": "tmdb",
            "media_type": "tv" if tmdb_url.group(1).lower() == "tv" else "movie",
            "id": tmdb_url.group(2),
        }

    typed = re.search(r"\b(movie|tv)[:/#\s-]*(\d{2,10})\b", text, re.I)
    if typed:
        return {
            "kind": "tmdb",
            "media_type": "tv" if typed.group(1).lower() == "tv" else "movie",
            "id": typed.group(2),
        }

    loose_typed = re.search(r"\btmdb[:#\s-]*(movie|tv)?[:/#\s-]*(\d{2,10})\b", text, re.I)
    if loose_typed:
        media_type = loose_typed.group(1) or ""
        return {
            "kind": "tmdb",
            "media_type": "tv" if media_type.lower() == "tv" else ("movie" if media_type.lower() == "movie" else ""),
            "id": loose_typed.group(2),
        }

    if re.fullmatch(r"\d{2,10}", text):
        return {"kind": "tmdb", "media_type": "", "id": text}

    return {}


def _normalize_detail_result(settings, media_type: str, item: dict, query_title: str = "", query_year: str = "") -> dict:
    if not item or not item.get("id"):
        return {}

    fallback = item.get("name") or item.get("title") or query_title or ""
    normalized = _normalize_result(item, "tv" if media_type == "tv" else "movie", fallback, query_title or fallback, query_year or _result_year(item))
    normalized["match_confidence"] = max(int(normalized.get("match_confidence") or 0), 98)
    normalized["confidence_level"] = "high"
    normalized["confidence_label"] = "ID match"
    external = tmdb_external_ids(settings, normalized.get("media_type"), normalized.get("id"))
    normalized["imdb_id"] = (external or {}).get("imdb_id") or ""
    normalized["external_ids"] = external or {}
    normalized["alternatives"] = []
    normalized["route_label"] = f"Resolved as {_media_type_label(normalized.get('media_type'))}"
    return normalized


def tmdb_lookup_identifier(settings, identifier: str, preferred_media_type: str = "", query_title: str = "", query_year: str = ""):
    """
    Resolve IMDb IDs, TMDb URLs, or TMDb numeric IDs into a normalized movie/TV metadata object.

    This is used by the Import Manager when a row starts as the wrong type but the user pastes
    an identifier, or when a mixed collection needs a TV/movie route decision.
    """
    parsed = _parse_media_identifier(identifier)
    if not parsed:
        return None

    preferred = "tv" if preferred_media_type == "tv" else ("movie" if preferred_media_type == "movie" else "")

    try:
        if parsed.get("kind") == "imdb":
            data = _tmdb_get(settings, f"/find/{parsed.get('id')}", {"external_source": "imdb_id"}) or {}
            candidates = []

            for media_type, key in (("movie", "movie_results"), ("tv", "tv_results")):
                for item in data.get(key, []) or []:
                    normalized = _normalize_detail_result(settings, media_type, item, query_title, query_year)
                    if normalized:
                        normalized["imdb_id"] = parsed.get("id")
                        normalized["confidence_label"] = "IMDb ID match"
                        normalized["source_identifier"] = parsed.get("id")
                        candidates.append(normalized)

            if not candidates:
                return None

            candidates.sort(key=lambda item: _rank_metadata_candidate(item, preferred, query_title, query_year), reverse=True)
            return candidates[0]

        if parsed.get("kind") == "tmdb":
            parsed_media_type = parsed.get("media_type") or ""
            id_value = parsed.get("id")
            media_types = []

            if parsed_media_type:
                media_types = [parsed_media_type]
            else:
                if preferred:
                    media_types.append(preferred)
                media_types.extend(mt for mt in ("movie", "tv") if mt not in media_types)

            candidates = []
            for media_type in media_types:
                endpoint = "tv" if media_type == "tv" else "movie"
                try:
                    detail = _tmdb_get(settings, f"/{endpoint}/{id_value}", {}) or {}
                except Exception:
                    continue

                normalized = _normalize_detail_result(settings, media_type, detail, query_title, query_year)
                if normalized:
                    normalized["source_identifier"] = str(id_value)
                    normalized["confidence_label"] = "TMDb ID match"
                    candidates.append(normalized)

            if not candidates:
                return None

            candidates.sort(key=lambda item: _rank_metadata_candidate(item, preferred, query_title, query_year), reverse=True)
            return candidates[0]
    except Exception:
        return None

    return None


def tmdb_search_best_any(settings, title: str, year: str = "", preferred_media_type: str = ""):
    """
    Search both TMDb movie and TV endpoints, then return the best normalized result.

    This lets mixed folders auto-route rows as movies or TV shows instead of assuming
    every row should keep the queue-level media type.
    """
    title = str(title or "").strip()
    if not title:
        return None

    preferred = "tv" if preferred_media_type == "tv" else ("movie" if preferred_media_type == "movie" else "")
    search_order = []
    if preferred:
        search_order.append(preferred)
    search_order.extend(mt for mt in ("movie", "tv") if mt not in search_order)

    candidates = []
    for media_type in search_order:
        for item in tmdb_search_candidates(settings, media_type, title, year, limit=5) or []:
            item = dict(item)
            item["media_type"] = "tv" if item.get("media_type") == "tv" else "movie"
            candidates.append(item)

    if not candidates:
        return None

    candidates.sort(key=lambda item: _rank_metadata_candidate(item, preferred, title, year), reverse=True)
    best = dict(candidates[0])
    external = tmdb_external_ids(settings, best.get("media_type"), best.get("id"))
    best["imdb_id"] = (external or {}).get("imdb_id") or ""
    best["external_ids"] = external or {}
    best["alternatives"] = [
        {
            "id": alt.get("id"),
            "media_type": alt.get("media_type"),
            "title": alt.get("title"),
            "year": alt.get("year"),
            "poster": alt.get("poster"),
            "match_confidence": alt.get("match_confidence"),
            "confidence_level": alt.get("confidence_level"),
            "confidence_label": alt.get("confidence_label"),
        }
        for alt in candidates[1:4]
    ]
    best["route_label"] = f"Auto routed as {_media_type_label(best.get('media_type'))}"
    return best

'@

    $Tmdb = $Tmdb.Substring(0, $InsertIndex) + $TmdbHelpers + $Tmdb.Substring($InsertIndex)
    Write-TextFile -RelativePath $TmdbPath -Content $Tmdb
    Write-Ok "Added TMDb cross-type lookup helpers"
} else {
    Write-Ok "TMDb cross-type lookup helpers already present"
}

Write-Step "Patching multi-import row routing"
$MultiPath = "app\services\multi_import.py"
$Multi = Read-TextFile $MultiPath

if ($Multi -match 'from app\.services\.tmdb import [^\r\n]+') {
    $Multi = [regex]::Replace(
        $Multi,
        'from app\.services\.tmdb import [^\r\n]+',
        'from app.services.tmdb import tmdb_search_with_imdb, tmdb_search_best_any, tmdb_lookup_identifier',
        1
    )
} else {
    Fail "Could not find TMDb import in app\services\multi_import.py"
}

$ApplyStart = $Multi.IndexOf("def _apply_tmdb_match(")
if ($ApplyStart -lt 0) {
    Fail "Could not find _apply_tmdb_match() in app\services\multi_import.py"
}

$NormalizeStart = $Multi.IndexOf("def _normalize_row(", $ApplyStart)
if ($NormalizeStart -lt 0) {
    Fail "Could not find _normalize_row() after _apply_tmdb_match() in app\services\multi_import.py"
}

$BeforeApply = $Multi.Substring(0, $ApplyStart)
$AfterNormalize = $Multi.Substring($NormalizeStart)

$ApplyBlock = @'
def _identifier_input(row: Dict[str, Any]) -> str:
    for key in ("imdb_id", "tmdb_id"):
        value = str((row or {}).get(key) or "").strip()
        if value:
            return value
    return ""


def _row_has_metadata_identifier(row: Dict[str, Any]) -> bool:
    return bool(_identifier_input(row))


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
        if re.search(r"\bS\d{1,2}E\d{1,3}\b|\b\d{1,2}x\d{1,3}\b", text, re.I):
            episode_like += 1
        if detect_season(text):
            season_like += 1

    combined = " ".join(texts)
    if re.search(r"\bS\d{1,2}E\d{1,3}\b|\b\d{1,2}x\d{1,3}\b", combined, re.I):
        return True

    if episode_like >= 2:
        return True

    if videos and season_like >= max(2, min(5, len(videos) // 2)):
        return True

    return False


def _infer_tv_season_from_source(row: Dict[str, Any]) -> str:
    for value in (
        (row or {}).get("season"),
        (row or {}).get("detected"),
        (row or {}).get("source"),
    ):
        detected = detect_season(str(value or ""))
        if detected:
            return _season_number(detected)

    source = Path(str((row or {}).get("source") or ""))
    try:
        videos = find_videos(source) if source.exists() else []
    except Exception:
        videos = []

    for video in videos[:80]:
        detected = detect_season(f"{video.name} {video.parent.name}")
        if detected:
            return _season_number(detected)

    return "01"


def _apply_metadata_to_row(row: Dict[str, Any], metadata: Dict[str, Any], source_label: str = "") -> Dict[str, Any]:
    row = dict(row)
    old_media_type = "tv" if row.get("media_type") == "tv" else "movie"
    new_media_type = "tv" if (metadata or {}).get("media_type") == "tv" else "movie"

    row["media_type"] = new_media_type
    row["media_type_label"] = "TV Show" if new_media_type == "tv" else "Movie"
    row["tmdb_id"] = str((metadata or {}).get("id") or row.get("tmdb_id") or "")
    row["imdb_id"] = (metadata or {}).get("imdb_id") or (row.get("imdb_id") if str(row.get("imdb_id") or "").lower().startswith("tt") else "")
    row["title"] = (metadata or {}).get("title") or row.get("title", "")
    row["year"] = (metadata or {}).get("year") or row.get("year", "")
    row["poster"] = (metadata or {}).get("poster") or row.get("poster", "")
    row["match_score"] = (metadata or {}).get("match_score") or row.get("match_score") or ""
    row["match_confidence"] = (metadata or {}).get("match_confidence") or row.get("match_confidence") or ""
    row["confidence_level"] = (metadata or {}).get("confidence_level") or row.get("confidence_level") or ""
    row["confidence_label"] = (metadata or {}).get("confidence_label") or row.get("confidence_label") or ""
    row["alternatives"] = (metadata or {}).get("alternatives") or row.get("alternatives") or []

    if new_media_type == "tv":
        row["season"] = _infer_tv_season_from_source(row)
    else:
        row["season"] = ""

    route_changed = old_media_type != new_media_type
    label = (metadata or {}).get("route_label") or source_label or ""
    if label:
        row["route_reason"] = label

    confidence = 0
    try:
        confidence = int(row.get("match_confidence") or 0)
    except Exception:
        confidence = 0

    if route_changed:
        row["match_status"] = f"Auto routed as {'TV show' if new_media_type == 'tv' else 'Movie'}"
        row["match_level"] = "good" if confidence >= 85 or row.get("imdb_id") else "warning"
    elif row.get("imdb_id") and confidence >= 85:
        row["match_status"] = "Auto matched"
        row["match_level"] = "good"
    elif row.get("imdb_id"):
        row["match_status"] = "Review match"
        row["match_level"] = "warning"
    elif row.get("tmdb_id"):
        row["match_status"] = "Matched; IMDb unavailable"
        row["match_level"] = "warning"
    else:
        row["match_status"] = "Needs match"
        row["match_level"] = "warning"

    return row


def _route_by_filesystem_signal(row: Dict[str, Any]) -> Dict[str, Any]:
    row = dict(row)
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


def _apply_tmdb_match(settings: Dict[str, Any], row: Dict[str, Any], allow_search: bool = True) -> Dict[str, Any]:
    row = dict(row)

    identifier = _identifier_input(row)
    metadata = None

    if identifier:
        metadata = tmdb_lookup_identifier(
            settings,
            identifier,
            preferred_media_type=row.get("media_type", ""),
            query_title=row.get("title", ""),
            query_year=row.get("year", ""),
        )
    elif allow_search:
        metadata = tmdb_search_best_any(
            settings,
            row.get("title", ""),
            row.get("year", ""),
            preferred_media_type=row.get("media_type", ""),
        )

    if metadata:
        return _apply_metadata_to_row(
            row,
            metadata,
            source_label="ID resolved" if identifier else "Auto routed",
        )

    row = _route_by_filesystem_signal(row)

    if identifier:
        row["match_status"] = row.get("match_status") or "ID lookup unavailable"
        row["match_level"] = row.get("match_level") or "warning"
        row["confidence_level"] = row.get("confidence_level") or "low"
        row["confidence_label"] = row.get("confidence_label") or "Identifier not resolved"
        row["alternatives"] = row.get("alternatives") or []
        return row

    if allow_search:
        row["match_status"] = row.get("match_status") or "Needs match"
        row["match_level"] = row.get("match_level") or "warning"
        row["match_confidence"] = row.get("match_confidence") or ""
        row["confidence_level"] = row.get("confidence_level") or "low"
        row["confidence_label"] = row.get("confidence_label") or "No TMDb match"
        row["alternatives"] = row.get("alternatives") or []

    return row


'@

$Multi = $BeforeApply + $ApplyBlock + $AfterNormalize

$OldPreview = @'
        if auto_match:
            row = _apply_tmdb_match(settings, row)
'@

$NewPreview = @'
        if auto_match or _row_has_metadata_identifier(row) or _source_tv_signal(row):
            row = _apply_tmdb_match(settings, row, allow_search=auto_match)
'@

if ($Multi.Contains($OldPreview)) {
    $Multi = $Multi.Replace($OldPreview, $NewPreview)
    Write-Ok "Preview now resolves pasted IDs and filesystem TV signals"
} elseif ($Multi -match 'allow_search=auto_match') {
    Write-Ok "Preview routing condition already patched"
} else {
    Fail "Could not patch preview_multi_rows() routing condition"
}

$Multi = $Multi.Replace("v3.6.1.3", $AppVersion).Replace("v3.6.1.2", $AppVersion).Replace("v3.6.1.1", $AppVersion).Replace("v3.6.1.0", $AppVersion)

Write-TextFile -RelativePath $MultiPath -Content $Multi

Write-Step "Patching linker TV multi-season planning"
$LinkerPath = "app\services\linker.py"
$Linker = Read-TextFile $LinkerPath

if ($Linker -notmatch 'v3\.6\.1\.4: TV source folders can contain multiple seasons') {
    if ($Linker -match 'from app\.services\.utils import [^\r\n]+') {
        $ImportLine = [regex]::Match($Linker, 'from app\.services\.utils import [^\r\n]+').Value
        if ($ImportLine -notmatch 'detect_season') {
            $NewImportLine = $ImportLine -replace 'detect_episode', 'detect_episode, detect_season'
            $Linker = $Linker.Replace($ImportLine, $NewImportLine)
            Write-Ok "Added detect_season import to linker.py"
        }
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
        # v3.6.1.4: TV source folders can contain multiple seasons.
        # Route each video by the season detected in its own filename/path instead
        # of forcing every episode into the row's single season value.
        display = f"{title} ({year})" if year else title
        show_dir = TV_ROOT / safe_name(display)

        try:
            requested_season = f"{int(str(season or '01')):02d}"
        except Exception:
            requested_season = detect_season(str(season or "")) or "01"

        fallback_by_season = {}
        detected_seasons = set()

        for src in videos:
            src_season = (
                detect_season(src.name)
                or detect_season(str(src.parent))
                or requested_season
                or "01"
            )
            try:
                src_season = f"{int(str(src_season)):02d}"
            except Exception:
                src_season = "01"

            detected_seasons.add(src_season)

            ep = detect_episode(src.name)
            episode_detected = bool(ep)
            if not ep:
                fallback = fallback_by_season.get(src_season, 1)
                ep = f"{fallback:02d}"
                fallback_by_season[src_season] = fallback + 1

            dest_dir = show_dir / f"Season {src_season}"
            new_name = safe_name(f"{display} - S{src_season}E{ep}{src.suffix.lower()}")
            items.append({
                "src": src,
                "dst": dest_dir / new_name,
                "new_name": new_name,
                "season": src_season,
                "episode": ep,
                "episode_detected": episode_detected,
            })

        if len(detected_seasons) == 1:
            only_season = sorted(detected_seasons)[0]
            return show_dir / f"Season {only_season}", items

        return show_dir, items

'@

    $Linker = $BeforeTv + $NewTvBlock + $AfterElse
    Write-TextFile -RelativePath $LinkerPath -Content $Linker
    Write-Ok "Updated TV build plan for multi-season sources"
} else {
    Write-Ok "linker.py already contains v3.6.1.4 TV planning"
}

Write-Step "Patching browser row state updates"
$AppJsPath = "app\static\app.js"
$AppJs = Read-TextFile $AppJsPath

if ($AppJs -notmatch 'v3\.6\.1\.4 mixed media routing') {
    $DatasetMarker = '    tr.dataset.tmdbId = row.tmdb_id || tr.dataset.tmdbId || "";'
    if ($AppJs.Contains($DatasetMarker)) {
        $DatasetPatch = @'
    // v3.6.1.4 mixed media routing: backend preview can change a row from Movie to TV.
    tr.dataset.mediaType = row.media_type || tr.dataset.mediaType || "movie";
    tr.classList.toggle("multi-row-tv", tr.dataset.mediaType === "tv");
    tr.classList.toggle("multi-row-movie", tr.dataset.mediaType !== "tv");

    const titleInput = tr.querySelector(".multi-title");
    if (titleInput && row.title && document.activeElement !== titleInput) {
      titleInput.value = row.title;
    }

    const yearInput = tr.querySelector(".multi-year");
    if (yearInput && row.year && document.activeElement !== yearInput) {
      yearInput.value = row.year;
    }

    const imdbInput = tr.querySelector(".multi-imdb");
    if (imdbInput && row.imdb_id && document.activeElement !== imdbInput) {
      imdbInput.value = row.imdb_id;
    }

    const seasonInput = tr.querySelector(".multi-season");
    if (seasonInput && row.media_type === "tv" && row.season && document.activeElement !== seasonInput) {
      seasonInput.value = row.season;
    }

    tr.dataset.tmdbId = row.tmdb_id || tr.dataset.tmdbId || "";
'@
        $AppJs = $AppJs.Replace($DatasetMarker, $DatasetPatch)
        Write-Ok "Browser table rows now keep backend media_type changes"
    } else {
        Write-Warn "Could not find dataset marker in app.js; media_type sync may already be different."
    }
} else {
    Write-Ok "app.js already has v3.6.1.4 mixed media routing patch"
}

$AppJs = $AppJs.Replace("v3.6.1.3", $AppVersion).Replace("v3.6.1.2", $AppVersion).Replace("v3.6.1.1", $AppVersion).Replace("v3.6.1.0", $AppVersion)
Write-TextFile -RelativePath $AppJsPath -Content $AppJs

Write-Step "Appending mixed routing CSS"
$StylePath = "app\static\style.css"
$Style = Read-TextFile $StylePath

if ($Style -notmatch 'v3\.6\.1\.4 Mixed Media Routing') {
    $StyleAdd = @'

/* v3.6.1.4 Mixed Media Routing */
.multi-import-table tr.multi-row-tv td:first-child {
  box-shadow: inset 3px 0 0 rgba(91, 124, 255, .85);
}

.multi-import-table tr.multi-row-movie td:first-child {
  box-shadow: inset 3px 0 0 rgba(45, 189, 110, .75);
}
/* end v3.6.1.4 Mixed Media Routing */
'@
    $Style = $Style.TrimEnd() + "`r`n" + $StyleAdd.TrimStart("`r", "`n") + "`r`n"
    Write-Ok "Added mixed routing CSS"
} else {
    Write-Ok "Mixed routing CSS already present"
}

$Style = $Style.Replace("v3.6.1.3", $AppVersion).Replace("v3.6.1.2", $AppVersion).Replace("v3.6.1.1", $AppVersion).Replace("v3.6.1.0", $AppVersion)
Write-TextFile -RelativePath $StylePath -Content $Style

Write-Step "Updating DEVELOPMENT.md"
$DevelopmentPath = Join-Path $ProjectRoot "DEVELOPMENT.md"
if (!(Test-Path $DevelopmentPath)) {
    Write-Utf8NoBom -Path $DevelopmentPath -Content "# NASDY Media Linker Development Notes`r`n"
}

$Development = [System.IO.File]::ReadAllText($DevelopmentPath)
if ($Development -notmatch 'v3\.6\.1\.4 Mixed Media Routing') {
    $DevelopmentAdd = @'

## v3.6.1.4 Mixed Media Routing

This release fixes mixed folders that contain both movies and TV shows.

Changes:
- Multi-import rows can now change media type after metadata resolution.
- Pasted IMDb IDs, TMDb URLs, or TMDb numeric IDs are resolved during multi-preview even when automatic search is otherwise off.
- Automatic TMDb matching searches both movie and TV endpoints, then routes the row based on the best metadata match.
- Filesystem episode patterns can route a row to TV even without TMDb.
- TV source folders with multiple seasons now plan each file into its detected season folder instead of forcing everything into Season 01.
- Browser row state now preserves backend media-type changes so final import uses the corrected movie/TV route.

Expected behavior:
- Movie rows import under `/media/movies`.
- TV rows import under `/media/tv`.
- Mixed collections such as Stargate packs can import movies and TV shows from the same source folder.

'@
    $Development = $Development.TrimEnd() + "`r`n" + $DevelopmentAdd.TrimStart("`r", "`n")
    Write-Utf8NoBom -Path $DevelopmentPath -Content $Development
    Write-Ok "Updated DEVELOPMENT.md"
} else {
    Write-Ok "DEVELOPMENT.md already has v3.6.1.4 notes"
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
    & python -m py_compile `
        ".\app\services\tmdb.py" `
        ".\app\services\multi_import.py" `
        ".\app\services\linker.py"
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
Write-Host "  4. Confirm movie rows route to /media/movies"
Write-Host "  5. Confirm TV rows route to /media/tv"
Write-Host "  6. Paste an IMDb ID or TMDb URL into a row and confirm the destination switches correctly"
Write-Host ""
Write-Host "Suggested commit:"
Write-Host '  git add app/config.py app/services/tmdb.py app/services/multi_import.py app/services/linker.py app/static/app.js app/static/style.css DEVELOPMENT.md'
Write-Host '  git commit -m "Route mixed movie and TV imports by metadata"'
Write-Host ""
