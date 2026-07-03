param([switch]$SkipDeploy)

$ErrorActionPreference = "Stop"
$Version = "v3.6.2.1-hide-active-qbit-downloads"
$AppVersion = "v3.6.2.1"
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
Write-Host "Hide active qBittorrent downloads from Manual Scan"
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

Step "Patching queue.py active-download suppression"
$queue = ReadRel "app\services\queue.py"

if ($queue -notmatch 'def manual_scan_items\(') {
  Fail "manual_scan_items() was not found. Run v3.6.2.0 Manual Downloads Scan first."
}
if ($queue -notmatch 'def _manual_scan_overlaps\(') {
  Fail "_manual_scan_overlaps() was not found. Run v3.6.2.0 Manual Downloads Scan first."
}

if ($queue -notmatch 'v3\.6\.2\.1 Active qBittorrent Guard') {
$patch = @'

# v3.6.2.1 Active qBittorrent Guard
# Manual Scan should not expose files that qBittorrent is still downloading.
# Rule:
# - If qBittorrent knows the torrent and progress < 1, hide the manual item.
# - If qBittorrent knows the torrent and progress >= 1, qBittorrent Completed shows it.
# - If no qBittorrent torrent matches the path, Manual Scan can show it.

def _qbit_download_candidate_paths(settings, torrent):
    from pathlib import Path

    try:
        from app.config import DOWNLOADS_ROOT
        from app.services.qbittorrent import normalize_source_path
    except Exception:
        DOWNLOADS_ROOT = Path("/downloads")

        def normalize_source_path(value):
            return str(value or "").replace("\\", "/").rstrip("/")

    paths = set()

    def add_path(value):
        text = normalize_source_path(str(value or "")).rstrip("/")
        if not text:
            return

        # Never exclude the entire downloads root; that would hide every manual item.
        try:
            if text == str(DOWNLOADS_ROOT).rstrip("/"):
                return
        except Exception:
            pass

        paths.add(text)

    save_path = normalize_source_path((torrent or {}).get("save_path") or "")
    content_path = normalize_source_path((torrent or {}).get("content_path") or "")
    name = (torrent or {}).get("name") or ""

    add_path(content_path)

    if save_path and name:
        add_path(str(Path(save_path) / name))

    # For active downloads, qBittorrent may have the real file list even before complete.
    # Use it to hide single bare files and nested folders accurately.
    try:
        from app.services.qbittorrent import qbit_torrent_files
        files = qbit_torrent_files(settings, (torrent or {}).get("hash", ""))
    except Exception:
        files = []

    if save_path and files:
        roots = set()

        for file_info in files:
            file_name = str((file_info or {}).get("name") or "").strip()
            if not file_name:
                continue

            file_path = Path(file_name)
            add_path(str(Path(save_path) / file_path))

            # Also add the top folder for folder torrents.
            if len(file_path.parts) > 1:
                roots.add(file_path.parts[0])

        for root in roots:
            add_path(str(Path(save_path) / root))

    return paths


def _qbit_active_download_paths(settings):
    try:
        from app.services.qbittorrent import qbit_torrents
    except Exception as error:
        return set(), 0, f"qBittorrent active-download guard unavailable: {error}"

    active_paths = set()
    active_count = 0

    try:
        torrents = qbit_torrents(settings)
    except Exception as error:
        return set(), 0, f"qBittorrent active-download guard failed: {error}"

    for torrent in torrents or []:
        try:
            progress = float((torrent or {}).get("progress", 0) or 0)
        except Exception:
            progress = 0

        state = str((torrent or {}).get("state", "") or "").lower()

        # qBittorrent states vary, but progress < 1 is the reliable signal.
        # The state list is an extra safety net for metadata/checking/allocation states.
        active_state = state in {
            "downloading",
            "stalleddl",
            "queueddl",
            "forceddl",
            "metadl",
            "checkingdl",
            "allocating",
            "pauseddl",
            "missingfiles",
            "error",
        }

        if progress >= 1 and not active_state:
            continue

        candidates = _qbit_download_candidate_paths(settings, torrent)
        if candidates:
            active_count += 1
            active_paths.update(candidates)

    return active_paths, active_count, None


def queue_items(settings):
    """
    v3.6.2.1 behavior:
    - qBittorrent completed items still show normally.
    - Manual Scan still shows manually copied files/folders.
    - Manual Scan excludes paths that belong to incomplete qBittorrent torrents.
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

            active_paths, active_count, active_error = _qbit_active_download_paths(settings)
            exclude_paths = set(qbit_paths) | set(active_paths)

            manual_items = manual_scan_items(settings, exclude_paths=exclude_paths)
            merged = _queue_merge_manual(qbit_items, manual_items)

            source_bits = ["qBittorrent + Manual Scan"]
            if manual_items:
                source_bits.append(f"{len(manual_items)} manual")
            if active_count:
                source_bits.append(f"{active_count} active hidden")

            source_label = " (" + ", ".join(source_bits[1:]) + ")" if len(source_bits) > 1 else ""
            warning = active_error

            return merged, source_bits[0] + source_label, warning

        except Exception as e:
            manual_items = manual_scan_items(settings, exclude_paths=set())
            return manual_items, "Manual Scan", f"qBittorrent error: {e}"

    return manual_scan_items(settings, exclude_paths=set()), "Manual Scan", None

# end v3.6.2.1 Active qBittorrent Guard
'@
$queue = $queue.TrimEnd() + "`r`n" + $patch.TrimStart("`r","`n") + "`r`n"
Ok "Added active qBittorrent guard and overriding queue_items()"
} else {
  Ok "Active qBittorrent guard already present"
}

$queue = $queue.Replace("v3.6.2.0",$AppVersion).Replace("v3.6.1.8",$AppVersion).Replace("v3.6.1.7",$AppVersion).Replace("v3.6.1.6",$AppVersion).Replace("v3.6.1.5",$AppVersion).Replace("v3.6.1.4",$AppVersion).Replace("v3.6.1.3",$AppVersion).Replace("v3.6.1.2",$AppVersion).Replace("v3.6.1.1",$AppVersion).Replace("v3.6.1.0",$AppVersion)
WriteRel "app\services\queue.py" $queue

Step "Updating DEVELOPMENT.md"
$devPath = Join-Path $ProjectRoot "DEVELOPMENT.md"
if (!(Test-Path $devPath)) { Write-Utf8NoBom $devPath "# NASDY Media Linker Development Notes`r`n" }
$dev = [System.IO.File]::ReadAllText($devPath)
if ($dev -notmatch 'v3\.6\.2\.1 Active qBittorrent Guard') {
$add = @'

## v3.6.2.1 Active qBittorrent Guard

Fix after Manual Downloads Scan.

Problem:
- Manual Scan made manually copied files/folders visible, but it also saw files that qBittorrent was still actively downloading.
- Those incomplete files should not be importable yet.

Behavior:
- If qBittorrent knows about a torrent and `progress < 1`, Manual Scan hides the matching file/folder.
- If qBittorrent knows about a torrent and it is complete, qBittorrent Completed shows it normally.
- If no qBittorrent torrent matches the file/folder, Manual Scan shows it.

Queue source examples:
- `qBittorrent + Manual Scan (2 manual, 1 active hidden)`
- `qBittorrent`
- `Manual Scan`

Design note:
- Manual Scan should make NASDY Media Linker flexible, not unsafe.
- Incomplete qBittorrent downloads remain hidden until qBittorrent reports them complete.

'@
  $dev = $dev.TrimEnd() + "`r`n" + $add.TrimStart("`r","`n")
  Write-Utf8NoBom $devPath $dev
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
Write-Host "  2. Start a qBittorrent download into /downloads"
Write-Host "  3. Confirm the partially downloaded file/folder does NOT appear from Manual Scan"
Write-Host "  4. Let the torrent complete"
Write-Host "  5. Confirm it appears as an importable completed item"
Write-Host "  6. Manually copy a separate MKV into /downloads"
Write-Host "  7. Confirm the manual item still appears"
Write-Host ""
Write-Host "Suggested commit:"
Write-Host '  git add app/config.py app/services/queue.py DEVELOPMENT.md'
Write-Host '  git commit -m "Hide active qBittorrent downloads from manual scan"'
Write-Host ""
