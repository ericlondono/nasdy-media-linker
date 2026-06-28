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

    if not url:
        raise ValueError("qBittorrent URL is required.")
    if not username:
        raise ValueError("qBittorrent username is required.")

    r = s.post(
        f"{url}/api/v2/auth/login",
        data={"username": username, "password": password},
        timeout=8,
    )

    if r.status_code not in (200, 204):
    raise ValueError(f"qBittorrent login failed. HTTP {r.status_code}: {r.text[:80]}")

# qBittorrent 5.x may return 204 No Content, so verify auth with a real API call.
check = s.get(f"{url}/api/v2/app/version", timeout=8)

if check.status_code != 200:
    raise ValueError(
        f"qBittorrent login could not be verified. "
        f"Login HTTP {r.status_code}, verify HTTP {check.status_code}: {check.text[:80]}"
    )

return s, url

def qbit_torrents(settings):
    session, url = qbit_session(settings)
    r = session.get(f"{url}/api/v2/torrents/info", timeout=10)
    r.raise_for_status()
    return r.json()


def resolve_torrent_source(torrent):
    candidates = []

    content_path = normalize_source_path(torrent.get("content_path") or "")
    save_path = normalize_source_path(torrent.get("save_path") or "")
    name = torrent.get("name") or ""

    if content_path:
        candidates.append(Path(content_path))

    if save_path and name:
        candidates.append(Path(save_path) / name)

    if save_path:
        candidates.append(Path(save_path))

    for candidate in candidates:
        if candidate.is_file():
            candidate = candidate.parent
        if candidate.exists():
            videos = find_videos(candidate)
            if videos:
                return candidate, videos

    return None, []


def qbit_completed_items(settings):
    torrents = qbit_torrents(settings)
    db = load_import_db()
    items = []

    for t in torrents:
        progress = float(t.get("progress", 0))
        if progress < 1:
            continue

        source_path, videos = resolve_torrent_source(t)
        if not source_path or not videos:
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
            "tracker": t.get("tracker", ""),
            "category": t.get("category", ""),
            "tags": t.get("tags", ""),
            "size": int(t.get("size", 0)),
        })

    return sorted(items, key=lambda x: (x["imported"], x["name"].lower()))


def test_qbit(settings):
    torrents = qbit_torrents(settings)
    completed = sum(1 for t in torrents if float(t.get("progress", 0)) >= 1)
    return completed