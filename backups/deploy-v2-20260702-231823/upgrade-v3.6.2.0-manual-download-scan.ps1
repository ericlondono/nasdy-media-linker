param([switch]$SkipDeploy)

$ErrorActionPreference = "Stop"
$Version = "v3.6.2.0-manual-download-scan"
$AppVersion = "v3.6.2.0"
$ProjectRoot = "C:\Projects\nasdy-media-linker"

function Step($m){ Write-Host ""; Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m){ Write-Host "[OK] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Fail($m){ Write-Host "[ERROR] $m" -ForegroundColor Red; exit 1 }
function Write-Utf8NoBom($Path,$Content){
  $parent = Split-Path -Parent $Path
  if ($parent -and !(Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path,$Content,$enc)
}
function ReadRel($rel){
  $p = Join-Path $ProjectRoot $rel
  if (!(Test-Path $p)) { Fail "Missing required file: $rel" }
  return [System.IO.File]::ReadAllText($p)
}
function WriteRel($rel,$content){
  $p = Join-Path $ProjectRoot $rel
  Write-Utf8NoBom $p $content
  Ok "Wrote $rel"
}
function BackupRel($rel,$backup){
  $src = Join-Path $ProjectRoot $rel
  if (Test-Path $src) {
    $dst = Join-Path $backup $rel
    New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
    Copy-Item $src $dst -Force
  }
}

Write-Host ""
Write-Host "NASDY Media Linker $Version"
Write-Host "Manual downloads scan release"
Write-Host ""

Step "Checking project folder"
if (!(Test-Path $ProjectRoot)) { Fail "Project folder not found: $ProjectRoot" }
Set-Location $ProjectRoot
if (!(Test-Path ".\app")) { Fail "This does not look like the project root. Missing .\app" }
if (!(Test-Path ".\Deploy.ps1")) { Fail "Deploy.ps1 is missing." }
if (!(Test-Path ".\.deploy.sh")) { Fail ".deploy.sh is missing." }
Ok "Project detected: $ProjectRoot"

Step "Creating local backup"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = Join-Path $ProjectRoot "backups\$Version-$stamp"
New-Item -ItemType Directory -Force -Path $backup | Out-Null
BackupRel "app\config.py" $backup
BackupRel "app\services\queue.py" $backup
BackupRel "DEVELOPMENT.md" $backup
Ok "Backup created: $backup"

Step "Updating app version"
$config = ReadRel "app\config.py"
$config2 = [regex]::Replace($config, 'APP_VERSION\s*=\s*["''][^"''\r\n]+["'']', "APP_VERSION = `"$AppVersion`"")
if ($config2 -ne $config) { WriteRel "app\config.py" $config2; Ok "Set APP_VERSION to $AppVersion" } else { Warn "APP_VERSION was not found." }

Step "Patching queue.py with Manual Scan"
$queue = ReadRel "app\services\queue.py"

if ($queue -notmatch 'v3\.6\.2\.0 Manual Downloads Scan') {
$manual = @'

# v3.6.2.0 Manual Downloads Scan
# Adds manually copied files/folders in /downloads to the queue even when qBittorrent is enabled.

def _manual_scan_is_video(path):
    try:
        from app.config import VIDEO_EXTENSIONS
        return path.is_file() and path.suffix.lower() in VIDEO_EXTENSIONS
    except Exception:
        return False


def _manual_scan_normalized(value):
    try:
        from app.services.qbittorrent import normalize_source_path
        return normalize_source_path(str(value or ""))
    except Exception:
        return str(value or "").replace("\\", "/").rstrip("/")


def _manual_scan_keyset(value):
    raw = str(value or "").strip()
    normalized = _manual_scan_normalized(raw)
    keys = {raw, normalized}
    try:
        p = Path(raw)
        keys.add(str(p))
        keys.add(str(p.resolve()))
    except Exception:
        pass
    return {k for k in keys if k}


def _manual_scan_overlaps(candidate, excluded_paths):
    candidate_norms = {k.replace("\\", "/").rstrip("/") for k in _manual_scan_keyset(candidate)}
    for excluded in excluded_paths or set():
        excluded_norms = {k.replace("\\", "/").rstrip("/") for k in _manual_scan_keyset(excluded)}
        for c in candidate_norms:
            for e in excluded_norms:
                if c and e and (c == e or c.startswith(e + "/") or e.startswith(c + "/")):
                    return True
    return False


def _manual_scan_imported(db, history_keys, name, title, year, source_path, media_type, season):
    try:
        imported_db = imported_from_db(db, {source_path, _manual_scan_normalized(source_path), name, title, f"{title} {year}".strip()})
    except Exception:
        imported_db = False
    if imported_db:
        return True

    try:
        return imported_from_history(
            name=name,
            title=title,
            year=year,
            source_path=source_path,
            history_keys=history_keys,
            media_type=media_type,
            season=season,
        )
    except Exception:
        return False


def manual_scan_items(settings=None, exclude_paths=None):
    """
    Scan /downloads directly.

    Supports:
    - /downloads/Movie Folder/movie.mkv
    - /downloads/Movie.mkv
    - /downloads/TV Show/Season 01/S01E01.mkv
    - /downloads/Mixed Collection/...
    """
    from datetime import datetime
    from pathlib import Path

    from app.config import DOWNLOADS_ROOT, IGNORE_NAMES
    from app.services.storage import load_import_db
    from app.services.utils import find_videos, guess_type, strip_release_words, detect_year, detect_season

    items = []
    exclude_paths = set(exclude_paths or [])

    try:
        db = load_import_db()
    except Exception:
        db = {}

    try:
        history_keys = history_import_keys()
    except Exception:
        history_keys = set()

    if not DOWNLOADS_ROOT.exists():
        return items

    for p in sorted(DOWNLOADS_ROOT.iterdir(), key=lambda x: x.stat().st_mtime if x.exists() else 0, reverse=True):
        if p.name.lower() in IGNORE_NAMES:
            continue

        if _manual_scan_overlaps(p, exclude_paths):
            continue

        if p.is_dir():
            try:
                videos = find_videos(p)
            except Exception:
                videos = []
            if not videos:
                continue
            source_path = p
            name = p.name
            video_count = len(videos)
            source_kind = "manual_folder"
            try:
                size = sum(v.stat().st_size for v in videos if v.exists())
            except Exception:
                size = 0
        elif _manual_scan_is_video(p):
            source_path = p
            name = p.name
            video_count = 1
            source_kind = "manual_file"
            try:
                size = p.stat().st_size
            except Exception:
                size = 0
        else:
            continue

        stat = p.stat()
        media_type = guess_type(name, video_count)
        title_source = Path(name).stem if p.is_file() else name
        title = strip_release_words(title_source)
        year = detect_year(name)
        season = detect_season(name)
        key = str(source_path)

        imported = _manual_scan_imported(
            db=db,
            history_keys=history_keys,
            name=name,
            title=title,
            year=year,
            source_path=key,
            media_type=media_type,
            season=season,
        )

        items.append({
            "name": name,
            "path": str(source_path),
            "video_count": video_count,
            "type": media_type,
            "icon": "TV" if media_type == "tv" else "Movie",
            "type_label": "TV Show" if media_type == "tv" else "Movie",
            "title": title,
            "year": year,
            "season": season,
            "modified": datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M"),
            "source_kind": source_kind,
            "source_key": key,
            "imported": imported,
            "hash": "",
            "state": "manual scan",
            "ratio": "",
            "tracker": "",
            "category": "manual",
            "tags": "manual",
            "size": size,
        })

    return sorted(items, key=lambda x: (x.get("imported", False), x.get("name", "").lower()))


def _queue_merge_manual(qbit_items, manual_items):
    merged = []
    seen = set()
    for item in list(qbit_items or []) + list(manual_items or []):
        keys = tuple(sorted(_manual_scan_keyset(item.get("path") or item.get("source_key") or item.get("name"))))
        if keys in seen:
            continue
        seen.add(keys)
        merged.append(item)
    return sorted(merged, key=lambda x: (x.get("imported", False), x.get("name", "").lower()))


def queue_items(settings):
    """
    v3.6.2.0 behavior:
    - qBittorrent enabled: show qBittorrent completed items PLUS manual scan items.
    - qBittorrent error: fall back to Manual Scan.
    - qBittorrent disabled: Manual Scan is the queue source.
    """
    settings = settings or {}

    if settings.get("qbittorrent_enabled"):
        try:
            qbit_items = qbit_completed_items(settings)
            qbit_paths = {
                item.get("path") or item.get("source_key") or ""
                for item in qbit_items or []
                if item.get("path") or item.get("source_key")
            }
            manual_items = manual_scan_items(settings, exclude_paths=qbit_paths)
            merged = _queue_merge_manual(qbit_items, manual_items)
            if manual_items:
                return merged, f"qBittorrent + Manual Scan ({len(manual_items)} manual)", None
            return merged, "qBittorrent", None
        except Exception as e:
            manual_items = manual_scan_items(settings, exclude_paths=set())
            return manual_items, "Manual Scan", f"qBittorrent error: {e}"

    return manual_scan_items(settings, exclude_paths=set()), "Manual Scan", None

# end v3.6.2.0 Manual Downloads Scan
'@
$queue = $queue.TrimEnd() + "`r`n" + $manual.TrimStart("`r","`n") + "`r`n"
Ok "Added Manual Scan queue override"
} else {
  Ok "Manual Scan patch already present"
}

$queue = $queue.Replace("v3.6.1.8",$AppVersion).Replace("v3.6.1.7",$AppVersion).Replace("v3.6.1.6",$AppVersion).Replace("v3.6.1.5",$AppVersion).Replace("v3.6.1.4",$AppVersion).Replace("v3.6.1.3",$AppVersion).Replace("v3.6.1.2",$AppVersion).Replace("v3.6.1.1",$AppVersion).Replace("v3.6.1.0",$AppVersion)
WriteRel "app\services\queue.py" $queue

Step "Updating DEVELOPMENT.md"
$devPath = Join-Path $ProjectRoot "DEVELOPMENT.md"
if (!(Test-Path $devPath)) { Write-Utf8NoBom $devPath "# NASDY Media Linker Development Notes`r`n" }
$dev = [System.IO.File]::ReadAllText($devPath)
if ($dev -notmatch 'v3\.6\.2\.0 Manual Downloads Scan') {
$add = @'

## v3.6.2.0 Manual Downloads Scan

Problem:
- The queue was primarily driven by qBittorrent completed torrents.
- Manually copied files/folders in `/downloads` could be invisible when qBittorrent was enabled.
- Bare files such as `/downloads/Twisters (2024).mkv` were also not guaranteed to become queue items.

Change:
- Adds a manual scan source for the root downloads folder.
- When qBittorrent is enabled, the queue now shows completed qBittorrent items plus manual files/folders not already represented by qBittorrent.
- When qBittorrent errors, the app falls back to Manual Scan.
- When qBittorrent is disabled, Manual Scan is the queue source.

Manual Scan supports:
- `/downloads/Movie Folder/movie.mkv`
- `/downloads/Movie.mkv`
- `/downloads/TV Show/Season 01/S01E01.mkv`
- `/downloads/Mixed Collection/...`

Manual scan items use:
- `source_kind = manual_folder` for folders
- `source_kind = manual_file` for bare video files
- no qBittorrent hash
- no qBittorrent ratio/state dependency

Design note:
- This makes NASDY Media Linker a true downloads import manager instead of only a qBittorrent completed-torrent importer.

'@
  $dev = $dev.TrimEnd() + "`r`n" + $add.TrimStart("`r","`n")
  Write-Utf8NoBom $devPath $dev
  Ok "Updated DEVELOPMENT.md"
} else {
  Ok "DEVELOPMENT.md already has v3.6.2.0 notes"
}

Step "Cleaning local Python cache files"
Get-ChildItem -Path $ProjectRoot -Directory -Recurse -Force -Filter "__pycache__" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $ProjectRoot -File -Recurse -Force -Filter "*.pyc" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
Ok "Python cache files cleaned"

Step "Best-effort Python syntax check"
$PythonCmd = Get-Command python -ErrorAction SilentlyContinue
if ($PythonCmd) {
  & python -m py_compile ".\app\services\queue.py"
  if ($LASTEXITCODE -ne 0) { Fail "Python syntax check failed." }
  Ok "Python syntax check passed"
} else {
  Warn "Python not found locally; skipping local syntax check."
}

Step "Showing changed files"
git status --short

if ($SkipDeploy) {
  Warn "Skipped deployment because -SkipDeploy was used."
  Write-Host "Run later: powershell -ExecutionPolicy Bypass -File .\Deploy.ps1"
  exit 0
}

Step "Deploying with permanent Deploy.ps1"
powershell -ExecutionPolicy Bypass -File ".\Deploy.ps1"
if ($LASTEXITCODE -ne 0) { Fail "Deploy.ps1 failed." }

Write-Host ""
Write-Host "NASDY Media Linker $Version complete" -ForegroundColor Green
Write-Host ""
Write-Host "Verify:"
Write-Host "  1. Hard refresh http://NASDY:8088"
Write-Host "  2. Put a bare MKV directly in /downloads"
Write-Host "  3. Put a manually copied folder with an MKV under /downloads"
Write-Host "  4. Confirm both appear even if qBittorrent did not download them"
Write-Host ""
Write-Host "Suggested commit:"
Write-Host '  git add app/config.py app/services/queue.py DEVELOPMENT.md'
Write-Host '  git commit -m "Add manual downloads scan queue source"'
Write-Host ""
