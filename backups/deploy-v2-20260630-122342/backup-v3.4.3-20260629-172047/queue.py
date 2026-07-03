from pathlib import Path
from datetime import datetime
from app.config import DOWNLOADS_ROOT, IGNORE_NAMES
from app.services.utils import find_videos, guess_type, strip_release_words, detect_year, detect_season
from app.services.storage import load_import_db
from app.services.qbittorrent import qbit_completed_items

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
        media_type = guess_type(p.name, len(videos))
        stat = p.stat()
        key = str(p)
        folders.append({
            "name": p.name,
            "path": str(p),
            "video_count": len(videos),
            "type": media_type,
            "icon": "📺" if media_type == "tv" else "🎬",
            "type_label": "TV Show" if media_type == "tv" else "Movie",
            "title": strip_release_words(p.name),
            "year": detect_year(p.name),
            "season": detect_season(p.name),
            "modified": datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M"),
            "source_kind": "folder",
            "source_key": key,
            "imported": key in db,
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
