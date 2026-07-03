from pathlib import Path
from datetime import datetime

from app.config import DOWNLOADS_ROOT, IGNORE_NAMES
from app.services.utils import find_videos, guess_type, strip_release_words, detect_year, detect_season
from app.services.storage import load_import_db, read_history
from app.services.qbittorrent import qbit_completed_items, normalize_source_path, imported_from_db, imported_from_history, history_import_keys


def folder_items():
    folders = []
    db = load_import_db()
    history_keys = history_import_keys()

    if not DOWNLOADS_ROOT.exists():
        return folders

    for p in sorted(DOWNLOADS_ROOT.iterdir(), key=lambda x: x.stat().st_mtime if x.exists() else 0, reverse=True):
        if not p.is_dir() or p.name.lower() in IGNORE_NAMES:
            continue

        videos = find_videos(p)
        if not videos:
            continue

        media_type = guess_type(p.name, len(videos))
        stat = p.stat()
        key = str(p)
        title = strip_release_words(p.name)
        year = detect_year(p.name)
        season = detect_season(p.name)

        imported = imported_from_db(db, {
            key,
            normalize_source_path(key),
            p.name,
        }) or imported_from_history(
            name=p.name,
            title=title,
            year=year,
            source_path=key,
            history_keys=history_keys,
            media_type=media_type,
            season=season,
        )

        folders.append({
            "name": p.name,
            "path": str(p),
            "video_count": len(videos),
            "type": media_type,
            "icon": "📺" if media_type == "tv" else "🎬",
            "type_label": "TV Show" if media_type == "tv" else "Movie",
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
            return items, "qBittorrent", None
        except Exception as e:
            return folder_items(), "Folders", f"qBittorrent error: {e}"

    return folder_items(), "Folders", None
