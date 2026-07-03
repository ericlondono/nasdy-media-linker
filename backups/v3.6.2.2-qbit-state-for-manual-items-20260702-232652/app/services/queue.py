from pathlib import Path
from datetime import datetime

from app.config import DOWNLOADS_ROOT, IGNORE_NAMES
from app.services.utils import find_videos, guess_type, strip_release_words, detect_year, detect_season, looks_like_multi_movie_folder
from app.services.storage import load_import_db
from app.services.qbittorrent import qbit_completed_items, normalize_source_path, imported_from_db
from app.services.advisor import summarize_queue_item


ADVISOR_SORT_ORDER = {
    "recommended": 0,
    "attention": 1,
    "duplicate": 2,
    "imported": 3,
}


def _apply_advisor(items):
    enriched = []
    for item in items:
        try:
            item.update(summarize_queue_item(item))
        except Exception as error:
            item["advisor_level"] = "attention"
            item["advisor_label"] = "Needs Attention"
            item["advisor_reason"] = f"Advisor unavailable: {error}"
            item["advisor_recommendation"] = "Open the item to review the preview."
        enriched.append(item)

    return sorted(
        enriched,
        key=lambda x: (
            ADVISOR_SORT_ORDER.get(x.get("advisor_level", "recommended"), 9),
            str(x.get("title") or x.get("name") or "").lower(),
        ),
    )


def folder_items():
    folders = []
    db = load_import_db()

    if not DOWNLOADS_ROOT.exists():
        return folders

    for p in sorted(DOWNLOADS_ROOT.iterdir(), key=lambda x: x.stat().st_mtime if x.exists() else 0, reverse=True):
        if not p.is_dir() or p.name.lower() in IGNORE_NAMES:
            continue

        videos = find_videos(p)
        if not videos:
            continue

        media_type = "movie" if looks_like_multi_movie_folder(p) else guess_type(p.name, len(videos))
        stat = p.stat()
        key = str(p)
        title = strip_release_words(p.name)
        year = detect_year(p.name)
        season = detect_season(p.name)

        imported = imported_from_db(db, {
            key,
            normalize_source_path(key),
            p.name,
        })

        folders.append({
            "name": p.name,
            "path": str(p),
            "video_count": len(videos),
            "type": media_type,
            "icon": "TV" if media_type == "tv" else "Movie",
            "type_label": "TV Show" if media_type == "tv" else ("Movie Collection" if looks_like_multi_movie_folder(p) else "Movie"),
            "title": title,
            "year": year,
            "season": season,
            "modified": datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M"),
            "source_kind": "folder",
            "source_key": key,
            "imported": imported,
            "hash": "",
            "state": "",
            "ratio": "",
        })

    return folders


def queue_items(settings):
    if settings.get("qbittorrent_enabled"):
        try:
            items = qbit_completed_items(settings)
            return _apply_advisor(items), "qBittorrent", None
        except Exception as e:
            return _apply_advisor(folder_items()), "Folders", f"qBittorrent error: {e}"

    return _apply_advisor(folder_items()), "Folders", None
# v3.6.2.1 Manual Downloads Scan
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
    v3.6.2.1 behavior:
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

# end v3.6.2.1 Manual Downloads Scan
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
