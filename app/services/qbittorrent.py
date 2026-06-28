from pathlib import Path
import requests
from app.services.utils import find_videos, guess_type, strip_release_words, detect_year, detect_season
from app.services.storage import load_import_db

def normalize_source_path(raw_path: str):
    if not raw_path:
        return ""
    p = raw_path.replace("\\", "/")
    p = p.replace("/mnt/user/NASDY/downloads", "/downloads")
    p = p.replace("/mnt/user/downloads", "/downloads")
    return p

def qbit_session(settings):
    s = requests.Session()
    url = settings.get("qbittorrent_url", "").rstrip("/")
    username = settings.get("qbittorrent_username", "")
    password = settings.get("qbittorrent_password", "")
    if not url or not username:
        raise ValueError("qBittorrent URL and username are required.")
    r = s.post(f"{url}/api/v2/auth/login", data={"username": username, "password": password}, timeout=8)
    if r.status_code != 200 or "Ok." not in r.text:
        raise ValueError(f"qBittorrent login failed. HTTP {r.status_code}: {r.text[:80]}")
    return s, url

def qbit_completed_items(settings):
    session, url = qbit_session(settings)
    r = session.get(f"{url}/api/v2/torrents/info", timeout=10)
    r.raise_for_status()
    torrents = r.json()
    db = load_import_db()
    items = []

    for t in torrents:
        if float(t.get("progress", 0)) < 1:
            continue

        content_path = normalize_source_path(t.get("content_path") or t.get("save_path") or "")
        source_path = Path(content_path)

        if source_path.is_file():
            source_path = source_path.parent

        if not source_path.exists():
            fallback = Path(normalize_source_path((t.get("save_path") or "") + "/" + (t.get("name") or "")))
            if fallback.exists():
                source_path = fallback
            else:
                continue

        videos = find_videos(source_path)
        if not videos:
            continue

        name = t.get("name", source_path.name)
        media_type = guess_type(name, len(videos))
        key = t.get("hash") or str(source_path)

        items.append({
            "name": name,
            "path": str(source_path),
            "video_count": len(videos),
            "type": media_type,
            "icon": "📺" if media_type == "tv" else "🎬",
            "type_label": "TV Show" if media_type == "tv" else "Movie",
            "title": strip_release_words(name),
            "year": detect_year(name),
            "season": detect_season(name),
            "modified": "qBittorrent",
            "source_kind": "torrent",
            "source_key": key,
            "imported": key in db,
            "hash": t.get("hash", ""),
            "state": t.get("state", ""),
            "ratio": round(float(t.get("ratio", 0)), 2),
        })

    return sorted(items, key=lambda x: (x["imported"], x["name"].lower()))

def test_qbit(settings):
    session, url = qbit_session(settings)
    r = session.get(f"{url}/api/v2/torrents/info", timeout=8)
    r.raise_for_status()
    torrents = r.json()
    completed = sum(1 for t in torrents if float(t.get("progress", 0)) >= 1)
    return completed
