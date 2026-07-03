param([switch]$SkipDeploy)

$ErrorActionPreference = "Stop"
$Version = "v3.6.2.2-qbit-state-for-manual-items"
$AppVersion = "v3.6.2.2"
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
Write-Host "Use qBittorrent state for manual-scan matched completed items"
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

Step "Patching queue.py qBittorrent state annotation"
$queue = ReadRel "app\services\queue.py"

foreach ($needle in @("def manual_scan_items(", "def _qbit_download_candidate_paths(", "def _qbit_active_download_paths(")) {
  if ($queue -notmatch [regex]::Escape($needle)) {
    Fail "$needle was not found. Run v3.6.2.1 first."
  }
}

if ($queue -notmatch 'v3\.6\.2\.2 qBittorrent State Annotation') {
$patch = @'

# v3.6.2.2 qBittorrent State Annotation
# Manual Scan can still be the row source for a completed qBittorrent torrent if the
# completed-torrent list does not include the item. In that case, show qBittorrent's
# current state/ratio/category/hash instead of "manual scan".

def _qbit_state_display(torrent):
    state = str((torrent or {}).get("state", "") or "").strip()
    if state:
        return state

    try:
        progress = float((torrent or {}).get("progress", 0) or 0)
    except Exception:
        progress = 0

    return "completed" if progress >= 1 else "downloading"


def _qbit_torrent_records(settings):
    try:
        from app.services.qbittorrent import qbit_torrents
    except Exception as error:
        return [], f"qBittorrent state annotation unavailable: {error}"

    try:
        torrents = qbit_torrents(settings)
    except Exception as error:
        return [], f"qBittorrent state annotation failed: {error}"

    records = []

    for torrent in torrents or []:
        try:
            progress = float((torrent or {}).get("progress", 0) or 0)
        except Exception:
            progress = 0

        state = str((torrent or {}).get("state", "") or "").lower()

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

        paths = _qbit_download_candidate_paths(settings, torrent)

        records.append({
            "torrent": torrent,
            "paths": paths,
            "progress": progress,
            "state": state,
            "active": bool(progress < 1 or active_state),
        })

    return records, None


def _qbit_match_record_for_path(path, records, require_complete=False):
    best = None
    best_score = -1

    for record in records or []:
        if require_complete and record.get("active"):
            continue

        paths = record.get("paths") or set()
        if not paths:
            continue

        if not _manual_scan_overlaps(path, paths):
            continue

        # Prefer exact/longer path matches when multiple torrents overlap.
        candidate_norms = {k.replace("\\", "/").rstrip("/") for k in _manual_scan_keyset(path)}
        record_norms = set()
        for p in paths:
            record_norms.update(k.replace("\\", "/").rstrip("/") for k in _manual_scan_keyset(p))

        score = 0
        for c in candidate_norms:
            for r in record_norms:
                if c == r:
                    score = max(score, 100000 + len(c))
                elif c.startswith(r + "/") or r.startswith(c + "/"):
                    score = max(score, min(len(c), len(r)))

        if score > best_score:
            best_score = score
            best = record

    return best


def _annotate_manual_items_with_qbit_state(manual_items, records):
    annotated = []
    matched_count = 0

    for item in manual_items or []:
        new_item = dict(item or {})
        source_path = new_item.get("path") or new_item.get("source_key") or new_item.get("name") or ""

        record = _qbit_match_record_for_path(source_path, records, require_complete=True)

        if record:
            torrent = record.get("torrent") or {}
            matched_count += 1

            new_item["state"] = _qbit_state_display(torrent)
            new_item["hash"] = torrent.get("hash") or new_item.get("hash") or ""
            new_item["ratio"] = torrent.get("ratio", new_item.get("ratio", ""))
            new_item["tracker"] = torrent.get("tracker") or new_item.get("tracker") or ""
            new_item["category"] = torrent.get("category") or new_item.get("category") or ""
            new_item["tags"] = torrent.get("tags") or new_item.get("tags") or ""
            new_item["qbit_matched"] = True
            new_item["qbit_progress"] = record.get("progress")
            new_item["source_kind"] = "manual_scan_qbit_match"
            new_item["source_note"] = "Manual Scan path matched completed qBittorrent torrent"

        annotated.append(new_item)

    return annotated, matched_count


def queue_items(settings):
    """
    v3.6.2.2 behavior:
    - Active qBittorrent downloads are still hidden from Manual Scan.
    - Completed qBittorrent downloads show qBittorrent state even if the row came
      through Manual Scan instead of qbit_completed_items().
    """
    settings = settings or {}

    if settings.get("qbittorrent_enabled"):
        try:
            qbit_items = qbit_completed_items(settings)

            qbit_completed_paths = {
                item.get("path") or item.get("source_key") or ""
                for item in qbit_items or []
                if item.get("path") or item.get("source_key")
            }

            records, record_error = _qbit_torrent_records(settings)

            active_paths = set()
            active_count = 0
            for record in records or []:
                if record.get("active") and record.get("paths"):
                    active_count += 1
                    active_paths.update(record.get("paths") or set())

            # Exclude completed qbit rows already represented by qbit_completed_items,
            # and exclude incomplete downloads so they do not appear early.
            exclude_paths = set(qbit_completed_paths) | set(active_paths)

            manual_items = manual_scan_items(settings, exclude_paths=exclude_paths)
            manual_items, matched_manual_count = _annotate_manual_items_with_qbit_state(manual_items, records)

            merged = _queue_merge_manual(qbit_items, manual_items)

            detail_bits = []
            if manual_items:
                detail_bits.append(f"{len(manual_items)} manual")
            if matched_manual_count:
                detail_bits.append(f"{matched_manual_count} qBT state matched")
            if active_count:
                detail_bits.append(f"{active_count} active hidden")

            source_label = "qBittorrent + Manual Scan"
            if detail_bits:
                source_label += " (" + ", ".join(detail_bits) + ")"

            return merged, source_label, record_error

        except Exception as e:
            manual_items = manual_scan_items(settings, exclude_paths=set())
            return manual_items, "Manual Scan", f"qBittorrent error: {e}"

    return manual_scan_items(settings, exclude_paths=set()), "Manual Scan", None

# end v3.6.2.2 qBittorrent State Annotation
'@
$queue = $queue.TrimEnd() + "`r`n" + $patch.TrimStart("`r","`n") + "`r`n"
Ok "Added qBittorrent state annotation and overriding queue_items()"
} else {
  Ok "qBittorrent state annotation already present"
}

$queue = $queue.Replace("v3.6.2.1",$AppVersion).Replace("v3.6.2.0",$AppVersion).Replace("v3.6.1.8",$AppVersion).Replace("v3.6.1.7",$AppVersion).Replace("v3.6.1.6",$AppVersion).Replace("v3.6.1.5",$AppVersion).Replace("v3.6.1.4",$AppVersion).Replace("v3.6.1.3",$AppVersion).Replace("v3.6.1.2",$AppVersion).Replace("v3.6.1.1",$AppVersion).Replace("v3.6.1.0",$AppVersion)
WriteRel "app\services\queue.py" $queue

Step "Updating DEVELOPMENT.md"
$devPath = Join-Path $ProjectRoot "DEVELOPMENT.md"
if (!(Test-Path $devPath)) { Write-Utf8NoBom $devPath "# NASDY Media Linker Development Notes`r`n" }
$dev = [System.IO.File]::ReadAllText($devPath)
if ($dev -notmatch 'v3\.6\.2\.2 qBittorrent State Annotation') {
$add = @'

## v3.6.2.2 qBittorrent State Annotation

Fix after v3.6.2.1.

Problem:
- Active qBittorrent downloads were correctly hidden from Manual Scan.
- After completion, some items could still appear through Manual Scan rather than `qbit_completed_items()`.
- Those rows showed `state = manual scan` even though qBittorrent still knew about the torrent.

Behavior:
- If Manual Scan finds a file/folder that matches a completed qBittorrent torrent, the row now adopts qBittorrent metadata:
  - `state`
  - `hash`
  - `ratio`
  - `tracker`
  - `category`
  - `tags`
- Active/incomplete qBittorrent downloads are still hidden.
- Manual files with no qBittorrent match still show as manual.

Expected state examples:
- `uploading`
- `stalledUP`
- `queuedUP`
- `completed`
- `manual scan` only when no qBittorrent torrent matches.

'@
  $dev = $dev.TrimEnd() + "`r`n" + $add.TrimStart("`r","`n")
  Write-Utf8NoBom $devPath $dev
  Ok "Updated DEVELOPMENT.md"
} else {
  Ok "DEVELOPMENT.md already has v3.6.2.2 notes"
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
Write-Host "  2. Let a qBittorrent download complete"
Write-Host "  3. Confirm it does not show early while incomplete"
Write-Host "  4. Confirm after completion its tile state says uploading/stalledUP/etc., not manual scan"
Write-Host "  5. Confirm a manually copied non-qBT file still says manual scan"
Write-Host ""
Write-Host "Suggested commit:"
Write-Host '  git add app/config.py app/services/queue.py DEVELOPMENT.md'
Write-Host '  git commit -m "Show qBittorrent state on manual-scan matches"'
Write-Host ""
