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