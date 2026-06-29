from pathlib import Path
import requests

from app.config import DOWNLOADS_ROOT, VIDEO_EXTENSIONS
from app.services.storage import load_import_db
from app.services.utils import guess_type, strip_release_words, detect_year, detect_season


def normalize_source_path(raw_path: str) -> str:
    if not raw_path:
        return ""
    p = raw_path.replace("\\", "/")
    p = p.replace("/mnt/user/NASDY/downloads", "/downloads")
    p = p.replace("/mnt/user/downloads", "/downloads")
    return p.rstrip("/")


def normalize_qbit_url(raw_url: str) -> str:
    url = (raw_url or "").strip().rstrip("/")
    if url and not url.startswith(("http://", "https://")):
        url = "http://" + url
    return url


def qbit_session(settings):
    session = requests.Session()
    url = normalize_qbit_url(settings.get("qbittorrent_url", ""))
    username = settings.get("qbittorrent_username", "")
    password = settings.get("qbittorrent_password", "")

    if not url:
        raise ValueError("qBittorrent URL is required.")
    if not username:
        raise ValueError("qBittorrent username is required.")

    login = session.post(
        f"{url}/api/v2/auth/login",
        data={"username": username, "password": password},
        timeout=8,
    )

    if login.status_code not in (200, 204):
        raise ValueError(f"qBittorrent login failed. HTTP {login.status_code}: {login.text[:80]}")

    check = session.get(f"{url}/api/v2/app/version", timeout=8)
    if check.status_code != 200:
        raise ValueError(
            f"qBittorrent login could not be verified. "
            f"Login HTTP {login.status_code}, verify HTTP {check.status_code}: {check.text[:80]}"
        )

    return session, url


def qbit_torrents(settings):
    session, url = qbit_session(settings)
    response = session.get(f"{url}/api/v2/torrents/info", timeout=10)
    response.raise_for_status()
    return response.json()


def qbit_torrent_files(settings, torrent_hash: str):
    if not torrent_hash:
        return []

    session, url = qbit_session(settings)
    response = session.get(
        f"{url}/api/v2/torrents/files",
        params={"hash": torrent_hash},
        timeout=10,
    )
    response.raise_for_status()
    return response.json()


def is_video_name(name: str) -> bool:
    return Path(str(name)).suffix.lower() in VIDEO_EXTENSIONS


def completed_video_files(settings, torrent):
    files = qbit_torrent_files(settings, torrent.get("hash", ""))
    return [
        f for f in files
        if is_video_name(f.get("name", ""))
        and float(f.get("progress", 0)) >= 1
    ]


def find_common_root(paths):
    clean_parts = []
    for p in paths:
        parts = Path(p).parts
        if len(parts) > 1:
            clean_parts.append(parts[:-1])

    if not clean_parts:
        return ""

    common = list(clean_parts[0])
    for parts in clean_parts[1:]:
        i = 0
        while i < min(len(common), len(parts)) and common[i] == parts[i]:
            i += 1
        common = common[:i]

    return str(Path(*common)) if common else ""


def resolve_video_source(settings, torrent, video_files):
    """
    Important: never scan the whole downloads folder.

    We use qBittorrent's file list to determine the real source location.
    Non-video torrents return no video_files and are skipped entirely.
    """
    save_path = normalize_source_path(torrent.get("save_path") or "")
    content_path = normalize_source_path(torrent.get("content_path") or "")
    name = torrent.get("name") or ""

    video_names = [vf.get("name", "") for vf in video_files if vf.get("name")]
    common_root = find_common_root(video_names)

    candidates = []

    if content_path:
        candidates.append(Path(content_path))

    if save_path and common_root:
        candidates.append(Path(save_path) / common_root)

    if save_path and name:
        candidates.append(Path(save_path) / name)

    if save_path and len(video_files) == 1:
        candidates.append(Path(save_path) / video_names[0])

    seen = set()
    for candidate in candidates:
        candidate = Path(candidate)

        if candidate.is_file():
            candidate = candidate.parent

        if str(candidate).rstrip("/") == str(DOWNLOADS_ROOT).rstrip("/"):
            continue

        key = str(candidate)
        if key in seen:
            continue
        seen.add(key)

        if not candidate.exists():
            continue

        matched = []
        for vf in video_files:
            qbit_name = Path(vf.get("name", "")).name
            possible = list(candidate.rglob(qbit_name))
            matched.extend([p for p in possible if p.is_file() and is_video_name(p.name)])

        if matched:
            return candidate, sorted(set(matched), key=lambda p: str(p).lower())

    return None, []


def qbit_completed_items(settings):
    torrents = qbit_torrents(settings)
    db = load_import_db()
    items = []

    for torrent in torrents:
        if float(torrent.get("progress", 0)) < 1:
            continue

        video_files = completed_video_files(settings, torrent)

        # This is the main fix: no completed video files means no queue item.
        if not video_files:
            continue

        source_path, videos = resolve_video_source(settings, torrent, video_files)
        if not source_path or not videos:
            continue

        name = torrent.get("name", source_path.name)
        media_type = guess_type(name, len(videos))
        key = torrent.get("hash") or str(source_path)

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
            "hash": torrent.get("hash", ""),
            "state": torrent.get("state", ""),
            "ratio": round(float(torrent.get("ratio", 0)), 2),
            "tracker": torrent.get("tracker", ""),
            "category": torrent.get("category", ""),
            "tags": torrent.get("tags", ""),
            "size": int(torrent.get("size", 0)),
        })

    return sorted(items, key=lambda x: (x["imported"], x["name"].lower()))


def test_qbit(settings):
    torrents = qbit_torrents(settings)
    completed = sum(1 for t in torrents if float(t.get("progress", 0)) >= 1)
    return completed
