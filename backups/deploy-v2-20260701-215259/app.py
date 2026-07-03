#!/usr/bin/env python3
import os
import re
import json
from pathlib import Path
from datetime import datetime
from typing import Optional

import requests
from fastapi import FastAPI, Request, Form
from fastapi.responses import HTMLResponse, RedirectResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

APP_NAME = "NASDY Media Linker"
APP_VERSION = "v2.0"

DOWNLOADS_ROOT = Path(os.environ.get("DOWNLOADS_ROOT", "/downloads"))
MOVIES_ROOT = Path(os.environ.get("MOVIES_ROOT", "/media/Movies"))
TV_ROOT = Path(os.environ.get("TV_ROOT", "/media/TV Shows"))
DATA_ROOT = Path(os.environ.get("DATA_ROOT", "/data"))

TMDB_API_KEY = os.environ.get("TMDB_API_KEY", "").strip()
JELLYFIN_URL = os.environ.get("JELLYFIN_URL", "").strip().rstrip("/")
JELLYFIN_API_KEY = os.environ.get("JELLYFIN_API_KEY", "").strip()

QBITTORRENT_URL = os.environ.get("QBITTORRENT_URL", "").strip().rstrip("/")
QBITTORRENT_USERNAME = os.environ.get("QBITTORRENT_USERNAME", "").strip()
QBITTORRENT_PASSWORD = os.environ.get("QBITTORRENT_PASSWORD", "").strip()

VIDEO_EXTENSIONS = {".mkv", ".mp4", ".avi", ".mov", ".m4v", ".wmv"}
IGNORE_NAMES = {"audiobooks", "books", "print", "movies", "tv shows", "tv", "music", "media organizer", "lost+found", "media linker"}
QUALITY_WORDS = [
    "2160p","1080p","720p","480p","webrip","web-rip","web-dl","webdl","bluray","blu-ray","brrip",
    "hdrip","dvdrip","uhd","truehd","remux","x264","x265","h264","h265","hevc","av1","flac","aac",
    "truehd","atmos","dts","dts-hd","ma","hdr","hdr10","dv","dolby","vision","proper","repack",
    "extended","unrated","directors","director","cut","amzn","amazon","nf","netflix","hulu","max",
    "lama","trolluhd","playweb","ddp","dd5","5.1","7.1","10bit","8bit","yts","rarbg", "eac3", "siqma"
]

app = FastAPI(title=APP_NAME)
app.mount("/static", StaticFiles(directory="static"), name="static")
templates = Jinja2Templates(directory="templates")

DATA_ROOT.mkdir(parents=True, exist_ok=True)
HISTORY_FILE = DATA_ROOT / "history.jsonl"
IMPORT_DB_FILE = DATA_ROOT / "imports.json"

def load_import_db():
    if not IMPORT_DB_FILE.exists():
        return {}
    try:
        return json.loads(IMPORT_DB_FILE.read_text(encoding="utf-8"))
    except Exception:
        return {}

def save_import_db(db):
    IMPORT_DB_FILE.write_text(json.dumps(db, indent=2), encoding="utf-8")

def clean_spaces(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()

def pretty(text: str) -> str:
    text = text.replace(".", " ").replace("_", " ")
    text = re.sub(r"\s+-\s+", " ", text)
    return clean_spaces(text)

def safe_name(text: str) -> str:
    text = re.sub(r'[\\/:*?"<>|]', "-", text)
    return clean_spaces(text)

def title_case_guess(text: str) -> str:
    small = {"of","the","a","an","and","or","in","on","at","to","for","with","by","from"}
    out = []
    for i, w in enumerate(text.split()):
        if w.upper() in {"TV", "FBI", "CSI", "NCIS", "UHD", "USA", "DC"}:
            out.append(w.upper())
        elif i != 0 and w.lower() in small:
            out.append(w.lower())
        else:
            out.append(w[:1].upper() + w[1:])
    return " ".join(out)

def detect_year(text: str) -> str:
    years = re.findall(r"\b(19\d{2}|20\d{2})\b", text)
    return years[0] if years else ""

def detect_season(text: str) -> str:
    m = re.search(r"\bS(\d{1,2})\b", text, re.I)
    if m:
        return f"{int(m.group(1)):02d}"
    m = re.search(r"\bSeason[ ._-]*(\d{1,2})\b", text, re.I)
    if m:
        return f"{int(m.group(1)):02d}"
    return "01"

def detect_episode(filename: str) -> str:
    m = re.search(r"\bS\d{1,2}E(\d{1,3})\b", filename, re.I)
    if m:
        return f"{int(m.group(1)):02d}"
    m = re.search(r"\b\d{1,2}x(\d{1,3})\b", filename, re.I)
    if m:
        return f"{int(m.group(1)):02d}"
    return ""

def strip_release_words(text: str) -> str:
    original = text
    text = pretty(text)
    text = re.sub(r"\s+S\d{1,2}.*$", "", text, flags=re.I)
    text = re.sub(r"\s+Season\s*\d{1,2}.*$", "", text, flags=re.I)
    text = re.sub(r"\s+\b(19\d{2}|20\d{2})\b.*$", "", text)
    for word in QUALITY_WORDS:
        text = re.sub(rf"\s+\b{re.escape(word)}\b.*$", "", text, flags=re.I)
    text = re.sub(r"\[[^\]]+\]|\([^\)]*?(remux|x264|x265|hevc|web|bluray|hdr)[^\)]*?\)", "", text, flags=re.I)
    text = clean_spaces(text)
    return title_case_guess(text) if text else original

def find_videos(folder: Path):
    if not folder.exists():
        return []
    return sorted([p for p in folder.rglob("*") if p.is_file() and p.suffix.lower() in VIDEO_EXTENSIONS], key=lambda p: str(p).lower())

def guess_type(name: str, video_count: int) -> str:
    if re.search(r"\bS\d{1,2}\b|\bSeason[ ._-]*\d{1,2}\b", name, re.I):
        return "tv"
    if video_count >= 3:
        return "tv"
    return "movie"

def normalize_source_path(raw_path: str):
    if not raw_path:
        return ""
    # Convert qBittorrent host path into container path when possible.
    p = raw_path
    p = p.replace("/mnt/user/NASDY/downloads", "/downloads")
    p = p.replace("\\", "/")
    return p

def qbittorrent_ready():
    return bool(QBITTORRENT_URL and QBITTORRENT_USERNAME)

def qbit_completed_items():
    if not qbittorrent_ready():
        return []
    session = requests.Session()
    try:
        login = session.post(
            f"{QBITTORRENT_URL}/api/v2/auth/login",
            data={"username": QBITTORRENT_USERNAME, "password": QBITTORRENT_PASSWORD},
            timeout=8,
        )
        if login.status_code != 200 or "Ok." not in login.text:
            return []
        r = session.get(f"{QBITTORRENT_URL}/api/v2/torrents/info", timeout=10)
        r.raise_for_status()
        torrents = r.json()
        items = []
        db = load_import_db()
        for t in torrents:
            progress = float(t.get("progress", 0))
            state = t.get("state", "")
            if progress < 1:
                continue
            content_path = normalize_source_path(t.get("content_path") or t.get("save_path") or "")
            source_path = Path(content_path)
            if source_path.is_file():
                source_path = source_path.parent
            if not source_path.exists():
                continue
            videos = find_videos(source_path)
            if not videos:
                continue
            name = t.get("name", source_path.name)
            media_type = guess_type(name, len(videos))
            key = t.get("hash") or str(source_path)
            imported = key in db
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
                "imported": imported,
                "hash": t.get("hash", ""),
            })
        return sorted(items, key=lambda x: (x["imported"], x["name"].lower()))
    except Exception:
        return []

def folder_items():
    folders = []
    if not DOWNLOADS_ROOT.exists():
        return folders
    db = load_import_db()
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
        })
    return folders

def queue_items():
    qbit = qbit_completed_items()
    if qbit:
        return qbit, "qBittorrent"
    return folder_items(), "Folders"

def build_plan(media_type: str, source: str, title: str, year: str, season: str):
    source_path = Path(source)
    videos = find_videos(source_path)
    title = title.strip()
    year = year.strip()
    season = season.strip() or "01"

    if not source_path.exists():
        raise ValueError("Source folder does not exist.")
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

def device_ok(a: Path, b: Path) -> bool:
    def existing(p: Path):
        while not p.exists() and p != p.parent:
            p = p.parent
        return p
    try:
        return os.stat(existing(a)).st_dev == os.stat(existing(b)).st_dev
    except Exception:
        return False

def append_history(entry):
    with HISTORY_FILE.open("a", encoding="utf-8") as f:
        f.write(json.dumps(entry) + "\n")

def read_history(limit=30):
    if not HISTORY_FILE.exists():
        return []
    lines = HISTORY_FILE.read_text(encoding="utf-8").splitlines()
    out = []
    for line in reversed(lines[-limit:]):
        try:
            out.append(json.loads(line))
        except Exception:
            pass
    return out

def tmdb_search(media_type: str, title: str, year: str):
    if not TMDB_API_KEY or not title:
        return None
    endpoint = "tv" if media_type == "tv" else "movie"
    url = f"https://api.themoviedb.org/3/search/{endpoint}"
    params = {"api_key": TMDB_API_KEY, "query": title}
    if year:
        params["first_air_date_year" if media_type == "tv" else "year"] = year
    try:
        r = requests.get(url, params=params, timeout=8)
        r.raise_for_status()
        results = r.json().get("results", [])
        if not results:
            return None
        item = results[0]
        poster = item.get("poster_path")
        return {
            "title": item.get("name") or item.get("title") or title,
            "year": (item.get("first_air_date") or item.get("release_date") or "")[:4],
            "overview": item.get("overview", ""),
            "poster": f"https://image.tmdb.org/t/p/w342{poster}" if poster else "",
            "score": item.get("vote_average", ""),
        }
    except Exception:
        return None

def jellyfin_refresh():
    if not JELLYFIN_URL or not JELLYFIN_API_KEY:
        return False, "Jellyfin refresh not configured."
    try:
        r = requests.post(f"{JELLYFIN_URL}/Library/Refresh", headers={"X-Emby-Token": JELLYFIN_API_KEY}, timeout=8)
        if r.status_code in (200, 204):
            return True, "Jellyfin scan requested."
        return False, f"Jellyfin returned HTTP {r.status_code}."
    except Exception as e:
        return False, str(e)

@app.get("/", response_class=HTMLResponse)
def index(request: Request):
    items, source_label = queue_items()
    return templates.TemplateResponse("index.html", {
        "request": request,
        "app_name": APP_NAME,
        "version": APP_VERSION,
        "items": items,
        "source_label": source_label,
        "history": read_history(),
        "tmdb_enabled": bool(TMDB_API_KEY),
        "jellyfin_enabled": bool(JELLYFIN_URL and JELLYFIN_API_KEY),
        "qbittorrent_enabled": qbittorrent_ready(),
    })

@app.post("/api/preview")
async def api_preview(request: Request):
    data = await request.json()
    try:
        dest_dir, items = build_plan(
            data.get("media_type","tv"),
            data.get("source",""),
            data.get("title",""),
            data.get("year",""),
            data.get("season","01"),
        )
        meta = tmdb_search(data.get("media_type","tv"), data.get("title",""), data.get("year",""))
        db = load_import_db()
        source_key = data.get("source_key") or data.get("source") or ""
        imported = db.get(source_key)
        return JSONResponse({
            "ok": True,
            "destination": str(dest_dir),
            "same_device": device_ok(Path(data.get("source","")), dest_dir),
            "metadata": meta,
            "imported": imported,
            "items": [{
                "src": str(i["src"]),
                "dst": str(i["dst"]),
                "new_name": i["new_name"],
                "exists": i["dst"].exists()
            } for i in items],
        })
    except Exception as e:
        return JSONResponse({"ok": False, "error": str(e)})

@app.post("/organize")
def organize(
    media_type: str = Form(...),
    source: str = Form(...),
    source_key: str = Form(""),
    title: str = Form(...),
    year: str = Form(""),
    season: str = Form("01"),
    refresh_jellyfin: Optional[str] = Form(None),
):
    try:
        dest_dir, items = build_plan(media_type, source, title, year, season)
        created = []
        for item in items:
            src, dst = item["src"], item["dst"]
            if dst.exists():
                raise FileExistsError(f"Already exists: {dst}")
            dst.parent.mkdir(parents=True, exist_ok=True)
            os.link(src, dst)
            created.append(str(dst))

        jf_msg = ""
        if refresh_jellyfin:
            _, jf_msg = jellyfin_refresh()

        entry = {
            "time": datetime.now().strftime("%Y-%m-%d %H:%M"),
            "type": media_type,
            "title": title,
            "year": year,
            "season": season if media_type == "tv" else "",
            "count": len(created),
            "destination": str(dest_dir),
            "jellyfin": jf_msg,
            "status": "success",
            "source": source,
        }
        append_history(entry)

        db = load_import_db()
        db[source_key or source] = entry
        save_import_db(db)

        return RedirectResponse("/", status_code=303)
    except Exception as e:
        append_history({
            "time": datetime.now().strftime("%Y-%m-%d %H:%M"),
            "type": "error",
            "title": title,
            "error": str(e),
            "status": "error",
        })
        return RedirectResponse("/", status_code=303)

@app.post("/api/jellyfin/refresh")
def api_jellyfin_refresh():
    ok, msg = jellyfin_refresh()
    return JSONResponse({"ok": ok, "message": msg})

@app.get("/health")
def health():
    return {
        "ok": True,
        "name": APP_NAME,
        "version": APP_VERSION,
        "downloads": str(DOWNLOADS_ROOT),
        "movies": str(MOVIES_ROOT),
        "tv": str(TV_ROOT),
        "qbit_configured": qbittorrent_ready(),
    }
