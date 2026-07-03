# NASDY Media Linker v3.4.7 stability patch v2
# Run from: C:\Projects\nasdy-media-linker

$ErrorActionPreference = "Stop"

$ProjectRoot = (Get-Location).Path
$AppDir = Join-Path $ProjectRoot "app"
if (!(Test-Path $AppDir)) {
    throw "This must be run from the nasdy-media-linker project folder. Expected app\ under $ProjectRoot"
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = Join-Path $ProjectRoot "backup-before-v347-$stamp"
New-Item -ItemType Directory -Path $backup -Force | Out-Null
Copy-Item -Path (Join-Path $ProjectRoot "app") -Destination $backup -Recurse -Force
Write-Host "Backup created: $backup"

function Write-Utf8NoBom($Path, $Content) {
    $dir = Split-Path $Path -Parent
    if (!(Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

# app/config.py
Write-Utf8NoBom (Join-Path $ProjectRoot "app\config.py") @'
import os
from pathlib import Path

APP_NAME = "NASDY Media Linker"
APP_VERSION = "v3.4.7"

DOWNLOADS_ROOT = Path(os.environ.get("DOWNLOADS_ROOT", "/downloads"))
MOVIES_ROOT = Path(os.environ.get("MOVIES_ROOT", "/media/movies"))
TV_ROOT = Path(os.environ.get("TV_ROOT", "/media/tv"))
DATA_ROOT = Path(os.environ.get("DATA_ROOT", "/data"))

HOST_DOWNLOADS_ROOT = os.environ.get("HOST_DOWNLOADS_ROOT", "/mnt/user/NASDY/downloads")
HOST_MEDIA_ROOT = os.environ.get("HOST_MEDIA_ROOT", "/mnt/user/NASDY/media")
HOST_MNT_ROOT = Path(os.environ.get("HOST_MNT_ROOT", "/host_mnt"))

VIDEO_EXTENSIONS = {".mkv", ".mp4", ".avi", ".mov", ".m4v", ".wmv"}

IGNORE_NAMES = {
    "audiobooks", "books", "print", "movies", "tv shows", "tv", "music",
    "media organizer", "lost+found", "media linker"
}

QUALITY_WORDS = [
    "2160p","1080p","720p","480p","webrip","web-rip","web-dl","webdl","bluray","blu-ray","brrip",
    "hdrip","dvdrip","uhd","truehd","remux","x264","x265","h264","h265","hevc","av1","flac","aac",
    "truehd","atmos","dts","dts-hd","ma","hdr","hdr10","dv","dolby","vision","proper","repack",
    "extended","unrated","directors","director","cut","amzn","amazon","nf","netflix","hulu","max",
    "lama","trolluhd","playweb","ddp","dd5","5.1","7.1","10bit","8bit","yts","rarbg", "eac3", "siqma"
]

DATA_ROOT.mkdir(parents=True, exist_ok=True)

HISTORY_FILE = DATA_ROOT / "history.jsonl"
IMPORT_DB_FILE = DATA_ROOT / "imports.json"
SETTINGS_FILE = DATA_ROOT / "settings.json"
LOG_FILE = DATA_ROOT / "media-linker.log"
'@

# app/services/qbittorrent.py
Write-Utf8NoBom (Join-Path $ProjectRoot "app\services\qbittorrent.py") @'
from pathlib import Path
import requests

from app.config import DOWNLOADS_ROOT, VIDEO_EXTENSIONS
from app.services.storage import load_import_db
from app.services.utils import guess_type, strip_release_words, detect_year, detect_season


def normalize_source_path(raw_path: str) -> str:
    if not raw_path:
        return ""
    p = str(raw_path).replace("\\", "/")
    p = p.replace("/mnt/user/NASDY/downloads", "/downloads")
    p = p.replace("/mnt/user/downloads", "/downloads")
    return p.rstrip("/")


def normalize_qbit_url(raw_url: str) -> str:
    url = (raw_url or "").strip().rstrip("/")
    if url and not url.startswith(("http://", "https://")):
        url = "http://" + url
    return url


def import_db_keys(db):
    keys = set()
    for key, entry in (db or {}).items():
        if key:
            keys.add(str(key))
            keys.add(normalize_source_path(str(key)))
        if isinstance(entry, dict):
            for field in ("source", "source_key", "hash", "destination"):
                value = entry.get(field)
                if value:
                    keys.add(str(value))
                    keys.add(normalize_source_path(str(value)))
    return {k for k in keys if k}


def imported_from_db(db, candidates):
    keys = import_db_keys(db)
    for candidate in candidates:
        if not candidate:
            continue
        c = str(candidate)
        n = normalize_source_path(c)
        if c in keys or n in keys:
            return True
    return False


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

        if not video_files:
            continue

        source_path, videos = resolve_video_source(settings, torrent, video_files)
        if not source_path or not videos:
            continue

        name = torrent.get("name", source_path.name)
        media_type = guess_type(name, len(videos))
        torrent_hash = torrent.get("hash", "")
        key = torrent_hash or str(source_path)
        title = strip_release_words(name)
        year = detect_year(name)
        season = detect_season(name)

        import_candidates = {
            key,
            torrent_hash,
            str(source_path),
            normalize_source_path(str(source_path)),
            normalize_source_path(torrent.get("content_path") or ""),
            normalize_source_path(torrent.get("save_path") or ""),
            name,
        }

        imported = imported_from_db(db, import_candidates)

        items.append({
            "name": name,
            "path": str(source_path),
            "video_count": len(videos),
            "type": media_type,
            "icon": "TV" if media_type == "tv" else "Movie",
            "type_label": "TV Show" if media_type == "tv" else "Movie",
            "title": title,
            "year": year,
            "season": season,
            "modified": "qBittorrent",
            "source_kind": "torrent",
            "source_key": key,
            "imported": imported,
            "hash": torrent_hash,
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
'@

# app/services/queue.py
Write-Utf8NoBom (Join-Path $ProjectRoot "app\services\queue.py") @'
from pathlib import Path
from datetime import datetime

from app.config import DOWNLOADS_ROOT, IGNORE_NAMES
from app.services.utils import find_videos, guess_type, strip_release_words, detect_year, detect_season
from app.services.storage import load_import_db
from app.services.qbittorrent import qbit_completed_items, normalize_source_path, imported_from_db


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
'@

# app/services/linker.py
Write-Utf8NoBom (Join-Path $ProjectRoot "app\services\linker.py") @'
import os
from pathlib import Path
from app.config import MOVIES_ROOT, TV_ROOT, HOST_MNT_ROOT
from app.services.utils import find_videos, detect_episode, safe_name
from app.services.logger import log


def build_plan(media_type: str, source: str, title: str, year: str, season: str):
    source_path = Path(source)
    videos = find_videos(source_path)
    title = title.strip()
    year = year.strip()
    season = season.strip() or "01"

    if not source_path.exists():
        raise ValueError(f"Source folder does not exist: {source_path}")
    if not title:
        raise ValueError("Title is required.")
    if not videos:
        raise ValueError("No video files found.")

    items = []
    if media_type == "tv":
        season = f"{int(season):02d}"
        display = f"{title} ({year})" if year else title
        dest_dir = TV_ROOT / safe_name(display) / f"Season {season}"
        fallback = 1
        for src in videos:
            ep = detect_episode(src.name)
            if not ep:
                ep = f"{fallback:02d}"
                fallback += 1
            new_name = safe_name(f"{display} - S{season}E{ep}{src.suffix.lower()}")
            items.append({"src": src, "dst": dest_dir / new_name, "new_name": new_name, "episode": ep})
    else:
        display = f"{title} ({year})" if year else title
        dest_dir = MOVIES_ROOT / safe_name(display)
        if len(videos) == 1:
            src = videos[0]
            new_name = safe_name(f"{display}{src.suffix.lower()}")
            items.append({"src": src, "dst": dest_dir / new_name, "new_name": new_name})
        else:
            for idx, src in enumerate(videos, start=1):
                new_name = safe_name(f"{display} - Part {idx}{src.suffix.lower()}")
                items.append({"src": src, "dst": dest_dir / new_name, "new_name": new_name})
    return dest_dir, items


def container_to_host_user_path(container_path: Path) -> Path:
    p = Path(container_path)
    s = str(p)
    if s.startswith("/downloads"):
        rel = s.removeprefix("/downloads").lstrip("/")
        return HOST_MNT_ROOT / "user" / "NASDY" / "downloads" / rel
    if s.startswith("/media"):
        rel = s.removeprefix("/media").lstrip("/")
        return HOST_MNT_ROOT / "user" / "NASDY" / "media" / rel
    return p


def resolve_real_host_path(container_path: Path) -> Path:
    user_path = container_to_host_user_path(container_path)
    s = str(user_path)
    marker = "/host_mnt/user/"
    if s.startswith(marker):
        rel = s.removeprefix(marker)
    else:
        return user_path

    candidates = []
    for root in [HOST_MNT_ROOT / "cache"] + sorted(HOST_MNT_ROOT.glob("disk*")):
        candidates.append(root / rel)

    for c in candidates:
        if c.exists():
            return c

    return user_path


def matching_dest_on_source_disk(src_real: Path, dst_container: Path) -> Path:
    src_parts = src_real.parts
    if len(src_parts) >= 3 and src_parts[1] == "host_mnt":
        disk_root = Path("/") / src_parts[1] / src_parts[2]
    else:
        return container_to_host_user_path(dst_container)

    dst_s = str(dst_container)
    if dst_s.startswith("/media"):
        rel = dst_s.removeprefix("/media").lstrip("/")
        return disk_root / "NASDY" / "media" / rel
    return container_to_host_user_path(dst_container)


def stat_device(path: Path):
    try:
        st = os.stat(path if path.exists() else path.parent)
        return st.st_dev
    except Exception:
        return None


def normalize_permissions(path: Path):
    """Best-effort permission normalization for SMB-friendly unRAID folders."""
    try:
        path = Path(path)
        targets = []
        if path.exists():
            targets.append(path)
        for parent in [path.parent, path.parent.parent]:
            if parent.exists():
                targets.append(parent)

        for target in targets:
            try:
                if target.is_dir():
                    os.chmod(target, 0o2775)
                else:
                    os.chmod(target, 0o664)
            except Exception as perm_error:
                log(f"WARN permission normalize failed for {target}: {perm_error}")
    except Exception as e:
        log(f"WARN permission normalize skipped for {path}: {e}")


def diagnostic_for_link(src_container: Path, dst_container: Path):
    src_real = resolve_real_host_path(src_container)
    dst_real = matching_dest_on_source_disk(src_real, dst_container)
    return {
        "src_container": str(src_container),
        "dst_container": str(dst_container),
        "src_real": str(src_real),
        "dst_real": str(dst_real),
        "src_exists": src_real.exists(),
        "dst_exists": dst_real.exists(),
        "src_device": stat_device(src_real),
        "dst_parent_device": stat_device(dst_real.parent),
        "same_device": stat_device(src_real) == stat_device(dst_real.parent),
    }


def create_hard_links(items):
    created = []
    diagnostics = []

    for item in items:
        src_container = Path(item["src"])
        dst_container = Path(item["dst"])
        diag = diagnostic_for_link(src_container, dst_container)
        diagnostics.append(diag)

        src_real = Path(diag["src_real"])
        dst_real = Path(diag["dst_real"])

        log(f"LINK DIAG: {diag}")

        if not src_real.exists():
            raise FileNotFoundError(f"Resolved source does not exist: {src_real}")
        if dst_real.exists():
            raise FileExistsError(f"Already exists: {dst_real}")

        dst_real.parent.mkdir(parents=True, exist_ok=True)
        normalize_permissions(dst_real.parent)
        os.link(src_real, dst_real)
        normalize_permissions(dst_real)
        created.append(str(dst_real))
        log(f"CREATED HARD LINK: {src_real} -> {dst_real}")

    return created, diagnostics
'@

# Clean up known mojibake fallback in app/templates/index.html without embedding bad text in this script.
$indexPath = Join-Path $ProjectRoot "app\templates\index.html"
$index = Get-Content $indexPath -Raw
$index = $index -replace 'APP_VERSION = "v3\.4\.6"', 'APP_VERSION = "v3.4.7"'
$index = $index -replace '\{\{ item\.state if item\.state else "[^"]*" \}\}', '{{ item.state if item.state else "-" }}'
$index = $index -replace 'style\.css\?v=\{\{ version \}\}-cards-final', 'style.css?v={{ version }}-stable'
Write-Utf8NoBom $indexPath $index

# Deploy with correct lowercase folders and normalize existing NASDY permissions from the host.
Write-Host "Building Docker image..."
docker build -t nasdy-media-linker:latest .

Write-Host "Deploying to NASDY..."
ssh root@NASDY 'docker rm -f nasdy-media-organizer 2>/dev/null || true; mkdir -p /mnt/user/appdata/nasdy-media-organizer/data /mnt/user/NASDY/media/tv /mnt/user/NASDY/media/movies /mnt/user/NASDY/downloads; chown -R nobody:users /mnt/user/appdata/nasdy-media-organizer /mnt/user/NASDY/media /mnt/user/NASDY/downloads; chmod -R u+rwX,g+rwX,o-rwx /mnt/user/appdata/nasdy-media-organizer /mnt/user/NASDY/media /mnt/user/NASDY/downloads; find /mnt/user/appdata/nasdy-media-organizer /mnt/user/NASDY/media /mnt/user/NASDY/downloads -type d -exec chmod g+s {} \;'

docker save nasdy-media-linker:latest | ssh root@NASDY 'docker load >/dev/null && docker run -d --name nasdy-media-organizer --restart unless-stopped -p 8088:8088 --user 99:100 -e DATA_ROOT=/data -e DOWNLOADS_ROOT=/downloads -e MOVIES_ROOT=/media/movies -e TV_ROOT=/media/tv -v /mnt:/host_mnt -v /mnt/user/NASDY/downloads:/downloads -v /mnt/user/NASDY/media:/media -v /mnt/user/appdata/nasdy-media-organizer/data:/data nasdy-media-linker:latest && docker ps --filter "name=nasdy-media-organizer" && docker logs nasdy-media-organizer --tail=80'

Write-Host ""
Write-Host "v3.4.7 deployed. Open http://nasdy:8088 and press Ctrl+F5."
