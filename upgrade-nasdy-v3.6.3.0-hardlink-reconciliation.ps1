$ErrorActionPreference = "Stop"

$Version = "v3.6.3.0"
$Feature = "hardlink-reconciliation"
$ProjectRoot = (Get-Location).Path

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Value
    )
    $fullPath = Join-Path $ProjectRoot $Path
    $parent = Split-Path $fullPath -Parent
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($fullPath, $Value, $utf8NoBom)
}

function Read-ProjectText {
    param([Parameter(Mandatory=$true)][string]$Path)
    return [System.IO.File]::ReadAllText((Join-Path $ProjectRoot $Path))
}

Write-Host "==> Checking project folder"
if (-not (Test-Path (Join-Path $ProjectRoot "app/config.py"))) {
    throw "This must be run from the NASDY Media Linker project root, usually C:\Projects\nasdy-media-linker"
}
if (-not (Test-Path (Join-Path $ProjectRoot "Deploy.ps1"))) {
    Write-Warning "Deploy.ps1 was not found in this folder. The patch can still apply, but deploy will need the normal project root."
}
Write-Host "[OK] Project detected: $ProjectRoot"

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupRoot = Join-Path $ProjectRoot "backups/$Version-$Feature-$stamp"
New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null

Write-Host "==> Creating backup"
$filesToBackup = @(
    "app/config.py",
    "app/main.py",
    "app/services/queue.py",
    "app/services/hardlink_reconcile.py",
    "app/static/app.js",
    "DEVELOPMENT.md"
)
foreach ($relative in $filesToBackup) {
    $src = Join-Path $ProjectRoot $relative
    if (Test-Path $src) {
        $dst = Join-Path $backupRoot $relative
        $dstParent = Split-Path $dst -Parent
        New-Item -ItemType Directory -Force -Path $dstParent | Out-Null
        Copy-Item -Force $src $dst
    }
}
Write-Host "[OK] Backup created: $backupRoot"

Write-Host "==> Writing hardlink reconciliation service"
$hardlinkService = @'
from pathlib import Path
import os
from typing import Any, Dict, Iterable, List, Optional, Set, Tuple

from app.config import HOST_MNT_ROOT, VIDEO_EXTENSIONS
from app.services.logger import log
from app.services.utils import find_videos, is_skippable_video
from app.services.linker import resolve_real_host_path

Signature = Tuple[int, int, int]


def _is_video_file(path: Path) -> bool:
    try:
        return path.is_file() and path.suffix.lower() in VIDEO_EXTENSIONS and not is_skippable_video(path)
    except Exception:
        return False


def source_videos(source: Any) -> List[Path]:
    path = Path(str(source or ""))
    try:
        if _is_video_file(path):
            return [path]
        if path.exists() and path.is_dir():
            return find_videos(path)
    except Exception:
        return []
    return []


def _stat_signature(path: Path, resolve_source: bool = False) -> Optional[Signature]:
    try:
        real_path = resolve_real_host_path(path) if resolve_source else path
        st = os.stat(real_path)
        return (int(st.st_dev), int(st.st_ino), int(st.st_size))
    except Exception:
        return None


def _source_signature(path: Path) -> Optional[Signature]:
    return _stat_signature(path, resolve_source=True)


def _media_signature(path: Path) -> Optional[Signature]:
    return _stat_signature(path, resolve_source=False)


def _dedupe_paths(paths: Iterable[Path]) -> List[Path]:
    out: List[Path] = []
    seen: Set[str] = set()
    for path in paths:
        try:
            key = str(path.resolve()) if path.exists() else str(path)
        except Exception:
            key = str(path)
        if key in seen:
            continue
        seen.add(key)
        out.append(path)
    return out


def candidate_media_roots() -> List[Path]:
    roots: List[Path] = []

    # Prefer real unRAID disk paths because hard links are created there.
    try:
        roots.append(HOST_MNT_ROOT / "cache" / "NASDY" / "media")
        roots.extend(sorted(HOST_MNT_ROOT.glob("disk*/NASDY/media")))
        roots.append(HOST_MNT_ROOT / "user" / "NASDY" / "media")
    except Exception:
        pass

    # Fallback to the container media mount. This helps in dev/test environments.
    roots.append(Path("/media"))

    return _dedupe_paths([root for root in roots if root.exists() and root.is_dir()])


def _iter_media_videos(root: Path):
    try:
        for path in root.rglob("*"):
            if _is_video_file(path):
                yield path
    except Exception as error:
        log(f"WARN hardlink reconcile scan skipped root={root}: {error}")


def scan_media_for_signatures(wanted: Set[Signature]) -> Dict[Signature, List[Path]]:
    found: Dict[Signature, List[Path]] = {}
    if not wanted:
        return found

    remaining = set(wanted)
    for root in candidate_media_roots():
        for path in _iter_media_videos(root):
            sig = _media_signature(path)
            if sig not in wanted:
                continue
            found.setdefault(sig, []).append(path)
            remaining.discard(sig)
        if not remaining:
            break

    return found


def _pretty_media_path(path: Path) -> str:
    text = str(path)
    replacements = []
    try:
        replacements.extend([
            (str(HOST_MNT_ROOT / "user" / "NASDY" / "media"), "/media"),
            (str(HOST_MNT_ROOT / "cache" / "NASDY" / "media"), "/media"),
        ])
        for disk_root in sorted(HOST_MNT_ROOT.glob("disk*/NASDY/media")):
            replacements.append((str(disk_root), "/media"))
    except Exception:
        pass

    for prefix, replacement in replacements:
        if text == prefix:
            return replacement
        if text.startswith(prefix + "/"):
            return replacement + text[len(prefix):]

    return text


def _destination_summary(paths: List[Path]) -> str:
    if not paths:
        return ""

    parents = []
    seen = set()
    for path in paths:
        parent = _pretty_media_path(path.parent)
        if parent not in seen:
            seen.add(parent)
            parents.append(parent)

    if len(parents) == 1:
        return parents[0]
    if len(parents) <= 4:
        return "; ".join(parents)
    return f"{len(paths)} hard-linked file(s) across {len(parents)} media folders"


def _reconciled_entry(item: Dict[str, Any], linked_paths: List[Path], video_count: int) -> Dict[str, Any]:
    media_type = item.get("type") or item.get("media_type") or "movie"
    title = item.get("title") or item.get("name") or ""
    year = item.get("year") or ""
    season = item.get("season") or ""
    source = item.get("path") or item.get("source") or ""
    source_key = item.get("source_key") or source

    return {
        "time": "Auto-detected on queue refresh",
        "type": media_type,
        "title": title,
        "year": year,
        "imdb_id": item.get("imdb_id", ""),
        "season": season if media_type == "tv" else "",
        "count": int(video_count or 0),
        "destination": _destination_summary(linked_paths),
        "jellyfin": "",
        "status": "success",
        "import_type": "reconciled-hardlink",
        "source": source,
        "source_key": source_key,
        "diagnostics": [],
        "linked_paths": [_pretty_media_path(p) for p in linked_paths[:50]],
    }


def reconcile_queue_items(items: List[Dict[str, Any]]) -> Tuple[List[Dict[str, Any]], Dict[str, Any]]:
    """
    Mark queue items imported when their source video files already have matching
    hard links somewhere under the media library.

    This deliberately uses device/inode identity, not title-only matching. If a new
    torrent is a different file, such as a higher-quality upgrade, it will not be
    marked imported by this reconciler.
    """
    output: List[Dict[str, Any]] = [dict(item or {}) for item in (items or [])]
    item_signatures: Dict[int, List[Signature]] = {}
    item_video_counts: Dict[int, int] = {}
    wanted: Set[Signature] = set()

    for index, item in enumerate(output):
        # Keep manual/user-tracked imported items untouched.
        if item.get("imported"):
            continue

        videos = source_videos(item.get("path") or item.get("source") or "")
        signatures: List[Signature] = []
        for video in videos:
            sig = _source_signature(video)
            if sig:
                signatures.append(sig)
                wanted.add(sig)

        if signatures:
            item_signatures[index] = signatures
            item_video_counts[index] = len(videos)

    media_index = scan_media_for_signatures(wanted)

    fully_linked = 0
    partially_linked = 0

    for index, signatures in item_signatures.items():
        item = output[index]
        linked_paths: List[Path] = []
        missing_count = 0

        for sig in signatures:
            matches = media_index.get(sig) or []
            if matches:
                linked_paths.append(matches[0])
            else:
                missing_count += 1

        if linked_paths and missing_count == 0:
            fully_linked += 1
            entry = _reconciled_entry(item, linked_paths, item_video_counts.get(index, len(signatures)))
            item["imported"] = True
            item["imported_record"] = entry
            item["auto_reconciled"] = True
            item["advisor_level"] = "imported"
            item["advisor_label"] = "Imported"
            item["advisor_reason"] = "Already hard-linked in media library"
            item["advisor_recommendation"] = "No action needed. NML found matching hard links already present in /media."
        elif linked_paths:
            partially_linked += 1
            item["hardlink_reconcile"] = {
                "state": "partial",
                "matched": len(linked_paths),
                "missing": missing_count,
                "linked_paths": [_pretty_media_path(p) for p in linked_paths[:20]],
            }
            if not item.get("advisor_reason"):
                item["advisor_reason"] = f"{len(linked_paths)} already hard-linked, {missing_count} still missing"

    output.sort(key=lambda x: (bool(x.get("imported")), str(x.get("title") or x.get("name") or "").lower()))

    return output, {
        "fully_linked": fully_linked,
        "partially_linked": partially_linked,
        "wanted_signatures": len(wanted),
    }


def reconciled_import_record(
    media_type: str,
    source: str,
    source_key: str = "",
    title: str = "",
    year: str = "",
    season: str = "01",
) -> Optional[Dict[str, Any]]:
    item = {
        "name": Path(str(source or "")).name,
        "path": source,
        "source": source,
        "source_key": source_key or source,
        "type": media_type or "movie",
        "title": title or Path(str(source or "")).stem,
        "year": year or "",
        "season": season or "01",
        "imported": False,
    }
    reconciled, _summary = reconcile_queue_items([item])
    if reconciled and reconciled[0].get("imported") and reconciled[0].get("imported_record"):
        return reconciled[0].get("imported_record")
    return None

'@
Write-Utf8NoBom -Path "app/services/hardlink_reconcile.py" -Value $hardlinkService
Write-Host "[OK] Wrote app/services/hardlink_reconcile.py"

Write-Host "==> Updating app version"
$configPath = "app/config.py"
$config = Read-ProjectText $configPath
$config = [regex]::Replace($config, 'APP_VERSION\s*=\s*"[^"]+"', 'APP_VERSION = "v3.6.3.0"')
Write-Utf8NoBom -Path $configPath -Value $config
Write-Host "[OK] Updated APP_VERSION to v3.6.3.0"

Write-Host "==> Patching preview auto-reconcile"
$mainPath = "app/main.py"
$main = Read-ProjectText $mainPath
if ($main -notmatch 'from app\.services\.hardlink_reconcile import reconciled_import_record') {
    $anchor = 'from app.services.multi_import import build_multi_import_preview, preview_multi_rows, public_multi_import_payload'
    if (-not $main.Contains($anchor)) {
        throw "Could not find main.py import anchor for multi_import. No changes were written to main.py."
    }
    $main = $main.Replace($anchor, "$anchor`nfrom app.services.hardlink_reconcile import reconciled_import_record")
}

if ($main -notmatch 'imported = reconciled_import_record\(') {
    $oldPreview = @'
        imported = find_import_record(db, source_key, source)

        if imported:
'@
    $newPreview = @'
        imported = find_import_record(db, source_key, source)
        if not imported:
            try:
                imported = reconciled_import_record(
                    media_type=media_type,
                    source=source,
                    source_key=source_key,
                    title=title,
                    year=year,
                    season=season,
                )
            except Exception as reconcile_error:
                log(f"WARN hardlink reconcile preview skipped: {reconcile_error}")

        if imported:
'@
    if (-not $main.Contains($oldPreview)) {
        throw "Could not find main.py preview anchor. No changes were written to main.py."
    }
    $main = $main.Replace($oldPreview, $newPreview)
}
Write-Utf8NoBom -Path $mainPath -Value $main
Write-Host "[OK] Patched app/main.py"

Write-Host "==> Patching queue reconciliation"
$queuePath = "app/services/queue.py"
$queue = Read-ProjectText $queuePath
$queue = [regex]::Replace($queue, '(?s)# v3\.6\.3\.0 Hardlink Reconciliation.*?# end v3\.6\.3\.0 Hardlink Reconciliation\s*', '')
$queueBlock = @'
# v3.6.3.0 Hardlink Reconciliation
# Automatically marks queue rows imported when their source files are already
# hard-linked somewhere under the media library. This is inode/device based, so
# true upgrades or replacements stay visible for review.

def _v363_reconcile_queue_items(items):
    try:
        from app.services.hardlink_reconcile import reconcile_queue_items
        return reconcile_queue_items(items or [])
    except Exception as error:
        try:
            from app.services.logger import log
            log(f"WARN hardlink reconcile queue skipped: {error}")
        except Exception:
            pass
        return list(items or []), {"fully_linked": 0, "partially_linked": 0, "error": str(error)}


def _v363_reconcile_detail_bits(summary):
    bits = []
    try:
        full = int((summary or {}).get("fully_linked") or 0)
    except Exception:
        full = 0
    try:
        partial = int((summary or {}).get("partially_linked") or 0)
    except Exception:
        partial = 0

    if full:
        bits.append(f"{full} hardlink reconciled")
    if partial:
        bits.append(f"{partial} partial hardlink match")
    return bits


def queue_items(settings):
    """
    v3.6.3.0 behavior:
    - Keep v3.6.2.2 qBittorrent + Manual Scan behavior.
    - Hide incomplete qBittorrent downloads from Manual Scan.
    - Preserve qBittorrent state annotation for completed manual-scan matches.
    - Also reconcile actual hard links already present in /media so deploys/path-key
      changes do not force the user to mark the same imported media again.
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

            exclude_paths = set(qbit_completed_paths) | set(active_paths)

            manual_items = manual_scan_items(settings, exclude_paths=exclude_paths)
            manual_items, matched_manual_count = _annotate_manual_items_with_qbit_state(manual_items, records)

            merged = _queue_merge_manual(qbit_items, manual_items)
            merged, reconcile_summary = _v363_reconcile_queue_items(merged)

            detail_bits = []
            if manual_items:
                detail_bits.append(f"{len(manual_items)} manual")
            if matched_manual_count:
                detail_bits.append(f"{matched_manual_count} qBT state matched")
            if active_count:
                detail_bits.append(f"{active_count} active hidden")
            detail_bits.extend(_v363_reconcile_detail_bits(reconcile_summary))

            source_label = "qBittorrent + Manual Scan"
            if detail_bits:
                source_label += " (" + ", ".join(detail_bits) + ")"

            return merged, source_label, record_error

        except Exception as e:
            manual_items = manual_scan_items(settings, exclude_paths=set())
            manual_items, reconcile_summary = _v363_reconcile_queue_items(manual_items)
            source_label = "Manual Scan"
            detail_bits = _v363_reconcile_detail_bits(reconcile_summary)
            if detail_bits:
                source_label += " (" + ", ".join(detail_bits) + ")"
            return manual_items, source_label, f"qBittorrent error: {e}"

    manual_items = manual_scan_items(settings, exclude_paths=set())
    manual_items, reconcile_summary = _v363_reconcile_queue_items(manual_items)
    source_label = "Manual Scan"
    detail_bits = _v363_reconcile_detail_bits(reconcile_summary)
    if detail_bits:
        source_label += " (" + ", ".join(detail_bits) + ")"
    return manual_items, source_label, None

# end v3.6.3.0 Hardlink Reconciliation
'@
$queue = $queue.TrimEnd() + "`r`n" + $queueBlock + "`r`n"
Write-Utf8NoBom -Path $queuePath -Value $queue
Write-Host "[OK] Patched app/services/queue.py"

Write-Host "==> Updating imported preview message"
$appJsPath = "app/static/app.js"
$appJs = Read-ProjectText $appJsPath
if ($appJs -notmatch 'isReconciledHardlink') {
    $oldJs = @'
    const importType = data.imported.import_type || "linked";
    const heading = importType === "manual" ? "Manually Marked Imported" : "Previously Hard Linked";
    const verb = importType === "manual" ? "Marked" : "Linked";

    setImportButton("Already Imported", true);
    setManualButtons(true);

    metadata.innerHTML = `
      <div class="advisor-panel imported">
        <div class="advisor-heading-row">
          <h3>${escapeHtml(heading)}</h3>
          <span class="status-chip advisor-chip imported">Imported</span>
        </div>
        <p>This item is already recorded in Media Linker import tracking.</p>
'@
    $newJs = @'
    const importType = data.imported.import_type || "linked";
    const isManualImport = importType === "manual";
    const isReconciledHardlink = importType === "reconciled-hardlink";
    const heading = isManualImport
      ? "Manually Marked Imported"
      : (isReconciledHardlink ? "Already Hard Linked in Library" : "Previously Hard Linked");
    const verb = isManualImport ? "Marked" : (isReconciledHardlink ? "Detected" : "Linked");
    const importedMessage = isReconciledHardlink
      ? "NML found matching hard links already present in the media library, so no new action is needed."
      : "This item is already recorded in Media Linker import tracking.";

    setImportButton("Already Imported", true);
    setManualButtons(true);

    metadata.innerHTML = `
      <div class="advisor-panel imported">
        <div class="advisor-heading-row">
          <h3>${escapeHtml(heading)}</h3>
          <span class="status-chip advisor-chip imported">Imported</span>
        </div>
        <p>${escapeHtml(importedMessage)}</p>
'@
    if ($appJs.Contains($oldJs)) {
        $appJs = $appJs.Replace($oldJs, $newJs)
        Write-Host "[OK] Patched app/static/app.js"
    } else {
        Write-Warning "Could not find the exact imported-message block in app.js. Backend reconciliation still works; preview copy was not changed."
    }
} else {
    Write-Host "[OK] app.js already has reconciled hardlink message support"
}
Write-Utf8NoBom -Path $appJsPath -Value $appJs

Write-Host "==> Updating DEVELOPMENT.md"
$devPath = "DEVELOPMENT.md"
if (Test-Path (Join-Path $ProjectRoot $devPath)) {
    $dev = Read-ProjectText $devPath
    if ($dev -notmatch '### v3\.6\.3\.0 Hardlink Reconciliation') {
        $dev = $dev.Replace('App version:       v3.6.2.2', 'App version:       v3.6.3.0')
        $dev = $dev.Replace('Next app release target:     TBD', 'Next app release target:     v3.6.3.0 Hardlink Reconciliation')
        $dev = $dev.Replace('Current app stable:          v3.6.2.2', "Current app stable:          v3.6.2.2`r`nNext app test candidate:      v3.6.3.0")
        $note = @'
### v3.6.3.0 Hardlink Reconciliation

Problem:

- Queue items could reappear as not imported after deploys or source-key changes.
- Existing protection depended mostly on `imports.json` aliases and history records.
- If tracking aliases were missing or changed, the user had to manually mark already-imported seeding media again.

Changes:

- Added inode/device based hardlink reconciliation.
- NML now scans source video files in `/downloads` and looks for matching hard links under the media library.
- If every source video already has a matching hard link in `/media`, the queue row is automatically marked Imported.
- This comparison uses actual file identity, not title-only matching, so a different release, better resolution, or better audio remains visible for review as a duplicate/upgrade candidate.
- Preview now reports `Already Hard Linked in Library` for auto-reconciled items.

Expected behavior:

- Previously hard-linked torrents remain in the Imported tab after future deploys.
- Manual re-marking should no longer be needed for media that is still truly hard-linked.
- New upgraded files are not hidden unless they are the exact same hard-linked file already present in `/media`.
'@
        if ($dev.Contains("`n## Infrastructure Release Notes")) {
            $dev = $dev.Replace("`n## Infrastructure Release Notes", "`n$note`n`n## Infrastructure Release Notes")
        } else {
            $dev = $dev.TrimEnd() + "`r`n`r`n" + $note + "`r`n"
        }
        Write-Utf8NoBom -Path $devPath -Value $dev
        Write-Host "[OK] Updated DEVELOPMENT.md"
    } else {
        Write-Host "[OK] DEVELOPMENT.md already has v3.6.3.0 notes"
    }
} else {
    Write-Warning "DEVELOPMENT.md not found; skipped documentation update."
}

Write-Host "==> Cleaning Python cache files"
Get-ChildItem -Path $ProjectRoot -Recurse -Directory -Filter "__pycache__" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $ProjectRoot -Recurse -File -Include "*.pyc", "*.pyo" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
Write-Host "[OK] Python cache files cleaned"

Write-Host ""
Write-Host "==============================================="
Write-Host " NASDY Media Linker v3.6.3.0 patch complete"
Write-Host "==============================================="
Write-Host "[OK] Backup created"
Write-Host "[OK] Hardlink reconciliation service added"
Write-Host "[OK] Queue auto-reconciles existing hard links"
Write-Host "[OK] Preview recognizes auto-reconciled items"
Write-Host ""
Write-Host "Next command:"
Write-Host "powershell -ExecutionPolicy Bypass -File .\Deploy.ps1"
