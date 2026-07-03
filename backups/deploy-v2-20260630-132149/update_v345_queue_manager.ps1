# NASDY Media Linker v3.4.5 Queue Manager
# Run from PowerShell on your Windows machine.

$ErrorActionPreference = "Stop"
$ProjectRoot = "C:\Projects\nasdy-media-linker"

if (!(Test-Path $ProjectRoot)) {
  throw "Project folder not found: $ProjectRoot"
}

Set-Location $ProjectRoot

Write-Host "Creating safety backup..." -ForegroundColor Cyan
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = "backup-before-v345-$stamp"
New-Item -ItemType Directory -Path $backup -Force | Out-Null
Copy-Item app\config.py "$backup\config.py" -Force
Copy-Item app\main.py "$backup\main.py" -Force
Copy-Item app\templates\index.html "$backup\index.html" -Force
Copy-Item app\static\app.js "$backup\app.js" -Force
Copy-Item app\static\style.css "$backup\style.css" -Force

Write-Host "Writing v3.4.5 replacement files..." -ForegroundColor Cyan

@'
import os
from pathlib import Path

APP_NAME = "NASDY Media Linker"
APP_VERSION = "v3.4.5"

DOWNLOADS_ROOT = Path(os.environ.get("DOWNLOADS_ROOT", "/downloads"))
MOVIES_ROOT = Path(os.environ.get("MOVIES_ROOT", "/media/Movies"))
TV_ROOT = Path(os.environ.get("TV_ROOT", "/media/TV Shows"))
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
'@ | Set-Content -Path "app\config.py" -Encoding UTF8

@'
from datetime import datetime
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, Request, Form
from fastapi.responses import HTMLResponse, RedirectResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from app.config import APP_NAME, APP_VERSION
from app.services.storage import load_settings, save_settings, load_import_db, save_import_db, append_history, read_history
from app.services.queue import queue_items
from app.services.linker import build_plan, create_hard_links, diagnostic_for_link
from app.services.tmdb import tmdb_search
from app.services.jellyfin import jellyfin_refresh
from app.services.qbittorrent import normalize_source_path
from app.services.qbittorrent import test_qbit
from app.services.library import find_library_match
from app.services.logger import read_log, log

app = FastAPI(title=APP_NAME)
app.mount("/static", StaticFiles(directory="app/static"), name="static")
templates = Jinja2Templates(directory="app/templates")


def history_counts(history):
    success = sum(1 for h in history if h.get("status") == "success")
    error = sum(1 for h in history if h.get("status") == "error" or h.get("type") == "error")
    imported = success
    return {
        "success_count": {"value": success},
        "error_count": {"value": error},
        "imported_count": {"value": imported},
    }


def import_alias_keys(source_key, source):
    keys = {
        source_key or "",
        source or "",
        normalize_source_path(source or ""),
        str(Path(source)) if source else "",
    }
    return {str(key or "").strip() for key in keys if str(key or "").strip()}


def save_import_aliases(db, source_key, source, entry):
    for key in import_alias_keys(source_key, source):
        db[key] = entry
    return db


def remove_import_aliases(db, source_key, source):
    targets = import_alias_keys(source_key, source)
    normalized_targets = {normalize_source_path(k) for k in targets if k}

    for key in list(db.keys()):
        key_norm = normalize_source_path(key)
        entry = db.get(key) or {}
        entry_source = str(entry.get("source", "")) if isinstance(entry, dict) else ""
        entry_source_key = str(entry.get("source_key", "")) if isinstance(entry, dict) else ""
        entry_values = {
            entry_source,
            entry_source_key,
            normalize_source_path(entry_source),
            normalize_source_path(entry_source_key),
        }

        if key in targets or key_norm in normalized_targets or entry_values.intersection(targets) or entry_values.intersection(normalized_targets):
            db.pop(key, None)

    return db


def find_import_record(db, source_key, source):
    candidates = import_alias_keys(source_key, source)
    for key in candidates:
        if key in db:
            return db.get(key)

    normalized_candidates = {normalize_source_path(k) for k in candidates}
    for key, entry in (db or {}).items():
        if normalize_source_path(key) in normalized_candidates:
            return entry
        if isinstance(entry, dict):
            entry_source = str(entry.get("source", ""))
            entry_source_key = str(entry.get("source_key", ""))
            if entry_source in candidates or entry_source_key in candidates:
                return entry
            if normalize_source_path(entry_source) in normalized_candidates:
                return entry
            if normalize_source_path(entry_source_key) in normalized_candidates:
                return entry
    return None


@app.get("/", response_class=HTMLResponse)
def index(request: Request):
    settings = load_settings()
    items, source_label, queue_error = queue_items(settings)
    history = read_history()
    counts = history_counts(history)

    return templates.TemplateResponse("index.html", {
        "request": request,
        "app_name": APP_NAME,
        "version": APP_VERSION,
        "items": items,
        "source_label": source_label,
        "queue_error": queue_error,
        "history": history,
        "settings": settings,
        "tmdb_enabled": bool(settings.get("tmdb_api_key")),
        "jellyfin_enabled": bool(settings.get("jellyfin_url") and settings.get("jellyfin_api_key")),
        "qbittorrent_enabled": bool(settings.get("qbittorrent_enabled")),
        **counts,
    })


@app.get("/settings", response_class=HTMLResponse)
def settings_page(request: Request):
    return templates.TemplateResponse("settings.html", {
        "request": request,
        "app_name": APP_NAME,
        "version": APP_VERSION,
        "settings": load_settings(),
    })


@app.post("/settings")
def save_settings_route(
    qbittorrent_enabled: Optional[str] = Form(None),
    qbittorrent_url: str = Form(""),
    qbittorrent_username: str = Form(""),
    qbittorrent_password: str = Form(""),
    tmdb_api_key: str = Form(""),
    jellyfin_url: str = Form(""),
    jellyfin_api_key: str = Form(""),
    developer_mode: Optional[str] = Form(None),
):
    save_settings({
        "qbittorrent_enabled": bool(qbittorrent_enabled),
        "qbittorrent_url": qbittorrent_url.strip().rstrip("/"),
        "qbittorrent_username": qbittorrent_username.strip(),
        "qbittorrent_password": qbittorrent_password,
        "tmdb_api_key": tmdb_api_key.strip(),
        "jellyfin_url": jellyfin_url.strip().rstrip("/"),
        "jellyfin_api_key": jellyfin_api_key.strip(),
        "developer_mode": bool(developer_mode),
    })
    return RedirectResponse("/settings?saved=1", status_code=303)


@app.post("/api/qbit/test")
async def api_qbit_test(request: Request):
    data = await request.json()
    settings = load_settings()
    settings.update(data)
    try:
        completed = test_qbit(settings)
        return JSONResponse({"ok": True, "message": f"Connected. {completed} completed torrent(s) found."})
    except Exception as e:
        return JSONResponse({"ok": False, "message": str(e)})


@app.post("/api/preview")
async def api_preview(request: Request):
    data = await request.json()
    try:
        media_type = data.get("media_type", "tv")
        source = data.get("source", "")
        title = data.get("title", "")
        year = data.get("year", "")
        imdb_id = data.get("imdb_id", "").strip()
        season = data.get("season", "01")

        dest_dir, items = build_plan(media_type, source, title, year, season)
        settings = load_settings()

        meta = tmdb_search(settings, media_type, title, year) or {}
        library_match = find_library_match(media_type, title, year, season)

        db = load_import_db()
        source_key = data.get("source_key") or source or ""
        imported = find_import_record(db, source_key, source)

        diagnostics = []
        for i in items:
            diagnostics.append(diagnostic_for_link(Path(i["src"]), Path(i["dst"])))

        return JSONResponse({
            "ok": True,
            "destination": str(dest_dir),
            "metadata": {
                **meta,
                "imdb_id": imdb_id,
            },
            "library_match": library_match,
            "imported": imported,
            "diagnostics": diagnostics,
            "items": [{
                "src": str(i["src"]),
                "dst": str(i["dst"]),
                "new_name": i["new_name"],
                "exists": Path(i["dst"]).exists()
            } for i in items],
        })
    except Exception as e:
        return JSONResponse({"ok": False, "error": str(e)})


@app.post("/api/imports/mark")
async def api_imports_mark(request: Request):
    data = await request.json()
    try:
        media_type = data.get("media_type", "tv")
        source = data.get("source", "")
        source_key = data.get("source_key") or source or ""
        title = data.get("title", "")
        year = data.get("year", "")
        imdb_id = data.get("imdb_id", "").strip()
        season = data.get("season", "01")

        if not source:
            return JSONResponse({"ok": False, "error": "No source item selected."})
        if not title:
            return JSONResponse({"ok": False, "error": "Title is required before marking imported."})

        destination = ""
        try:
            dest_dir, _ = build_plan(media_type, source, title, year, season)
            destination = str(dest_dir)
        except Exception as plan_error:
            log(f"WARN manual mark could not build destination preview: {plan_error}")

        entry = {
            "time": datetime.now().strftime("%Y-%m-%d %H:%M"),
            "type": media_type,
            "title": title,
            "year": year,
            "imdb_id": imdb_id,
            "season": season if media_type == "tv" else "",
            "count": 0,
            "destination": destination,
            "jellyfin": "",
            "status": "success",
            "import_type": "manual",
            "source": source,
            "source_key": source_key,
            "diagnostics": [],
        }

        db = load_import_db()
        db = save_import_aliases(db, source_key, source, entry)
        save_import_db(db)

        log(f"Manual import mark: {title} ({year}) source={source} source_key={source_key}")
        return JSONResponse({"ok": True, "entry": entry})
    except Exception as e:
        log(f"ERROR manual import mark: {e}")
        return JSONResponse({"ok": False, "error": str(e)})


@app.post("/api/imports/mark-bulk")
async def api_imports_mark_bulk(request: Request):
    data = await request.json()
    try:
        raw_items = data.get("items", []) if isinstance(data, dict) else []
        if not isinstance(raw_items, list) or not raw_items:
            return JSONResponse({"ok": False, "error": "No queue items selected."})

        db = load_import_db()
        marked = []
        errors = []

        for index, item in enumerate(raw_items, start=1):
            if not isinstance(item, dict):
                errors.append({"index": index, "error": "Invalid selected item."})
                continue

            media_type = item.get("media_type", "tv")
            source = item.get("source", "")
            source_key = item.get("source_key") or source or ""
            title = item.get("title", "")
            year = item.get("year", "")
            imdb_id = item.get("imdb_id", "").strip()
            season = item.get("season", "01")

            if not source:
                errors.append({"index": index, "title": title, "error": "No source item selected."})
                continue
            if not title:
                errors.append({"index": index, "source": source, "error": "Title is required before marking imported."})
                continue

            destination = ""
            try:
                dest_dir, _ = build_plan(media_type, source, title, year, season)
                destination = str(dest_dir)
            except Exception as plan_error:
                log(f"WARN bulk manual mark could not build destination preview: {plan_error}")

            entry = {
                "time": datetime.now().strftime("%Y-%m-%d %H:%M"),
                "type": media_type,
                "title": title,
                "year": year,
                "imdb_id": imdb_id,
                "season": season if media_type == "tv" else "",
                "count": 0,
                "destination": destination,
                "jellyfin": "",
                "status": "success",
                "import_type": "manual",
                "source": source,
                "source_key": source_key,
                "diagnostics": [],
            }

            db = save_import_aliases(db, source_key, source, entry)
            marked.append({"title": title, "source": source, "source_key": source_key})

        save_import_db(db)
        log(f"Bulk manual import mark: marked={len(marked)} errors={len(errors)}")
        return JSONResponse({"ok": True, "marked": marked, "errors": errors})
    except Exception as e:
        log(f"ERROR bulk manual import mark: {e}")
        return JSONResponse({"ok": False, "error": str(e)})


@app.post("/api/imports/unmark")
async def api_imports_unmark(request: Request):
    data = await request.json()
    try:
        source = data.get("source", "")
        source_key = data.get("source_key") or source or ""
        if not source and not source_key:
            return JSONResponse({"ok": False, "error": "No import record selected."})

        db = load_import_db()
        before = len(db)
        db = remove_import_aliases(db, source_key, source)
        removed = before - len(db)
        save_import_db(db)

        log(f"Manual import unmark: removed {removed} import alias(es) source={source} source_key={source_key}")
        return JSONResponse({"ok": True, "removed": removed})
    except Exception as e:
        log(f"ERROR manual import unmark: {e}")
        return JSONResponse({"ok": False, "error": str(e)})


@app.post("/organize")
def organize(
    media_type: str = Form(...),
    source: str = Form(...),
    source_key: str = Form(""),
    title: str = Form(...),
    year: str = Form(""),
    imdb_id: str = Form(""),
    season: str = Form("01"),
    refresh_jellyfin: Optional[str] = Form(None),
):
    try:
        settings = load_settings()
        dest_dir, items = build_plan(media_type, source, title, year, season)
        created, diagnostics = create_hard_links(items)

        jf_msg = ""
        if refresh_jellyfin:
            _, jf_msg = jellyfin_refresh(settings)

        entry = {
            "time": datetime.now().strftime("%Y-%m-%d %H:%M"),
            "type": media_type,
            "title": title,
            "year": year,
            "imdb_id": imdb_id.strip(),
            "season": season if media_type == "tv" else "",
            "count": len(created),
            "destination": str(dest_dir),
            "jellyfin": jf_msg,
            "status": "success",
            "import_type": "linked",
            "source": source,
            "source_key": source_key,
            "diagnostics": diagnostics,
        }

        append_history(entry)

        db = load_import_db()
        db = save_import_aliases(db, source_key, source, entry)
        save_import_db(db)

        return RedirectResponse("/", status_code=303)
    except Exception as e:
        log(f"ERROR organize: {e}")
        append_history({
            "time": datetime.now().strftime("%Y-%m-%d %H:%M"),
            "type": "error",
            "title": title,
            "error": str(e),
            "status": "error",
            "source": source,
            "source_key": source_key,
        })
        return RedirectResponse("/", status_code=303)


@app.get("/dev", response_class=HTMLResponse)
def dev_page(request: Request):
    settings = load_settings()
    return templates.TemplateResponse("dev.html", {
        "request": request,
        "app_name": APP_NAME,
        "version": APP_VERSION,
        "settings": settings,
        "log": read_log(),
    })


@app.post("/api/jellyfin/refresh")
def api_jellyfin_refresh():
    ok, msg = jellyfin_refresh(load_settings())
    return JSONResponse({"ok": ok, "message": msg})


@app.get("/health")
def health():
    return {
        "ok": True,
        "name": APP_NAME,
        "version": APP_VERSION,
    }
'@ | Set-Content -Path "app\main.py" -Encoding UTF8

@'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{{ app_name }} {{ version }}</title>
  <link rel="stylesheet" href="/static/style.css?v={{ version }}">
</head>
<body>
  <main class="shell">
    <section class="hero">
      <div>
        <h1>{{ app_name }}</h1>
        <p>Hard-link completed media into Jellyfin-friendly folders while qBittorrent keeps seeding.</p>
      </div>

      <nav class="hero-actions">
        <a class="navlink" href="/settings">Settings</a>
        {% if settings.developer_mode %}
          <a class="navlink" href="/dev">Dev</a>
        {% endif %}
        <span class="badge">{{ version }}</span>
        <span class="pill {% if tmdb_enabled %}good{% endif %}">
          {% if tmdb_enabled %}TMDb on{% else %}TMDb off{% endif %}
        </span>
        <span class="pill {% if jellyfin_enabled %}good{% endif %}">
          {% if jellyfin_enabled %}Jellyfin on{% else %}Jellyfin off{% endif %}
        </span>
        <span class="pill {% if qbittorrent_enabled %}good{% endif %}">
          {% if qbittorrent_enabled %}qBit on{% else %}Folder mode{% endif %}
        </span>
      </nav>
    </section>

    {% if queue_error %}
      <div class="alert error">{{ queue_error }}</div>
    {% endif %}

    <section class="layout">
      <aside class="card">
        <div class="card-head">
          <div>
            <h2>{% if qbittorrent_enabled %}Completed Torrents{% else %}Folders{% endif %}</h2>
            <p class="section-subtitle">
              {% if qbittorrent_enabled %}
                Completed video torrents ready to import.
              {% else %}
                Download folders ready to scan.
              {% endif %}
            </p>
          </div>
          <span>{{ items|length }} total</span>
        </div>

        {% if qbittorrent_enabled %}
          {% set ready_count = namespace(value=0) %}
          {% set imported_count = namespace(value=0) %}
          {% for item in items %}
            {% if item.imported %}
              {% set imported_count.value = imported_count.value + 1 %}
            {% else %}
              {% set ready_count.value = ready_count.value + 1 %}
            {% endif %}
          {% endfor %}

          <div class="queue-tabs" role="tablist" aria-label="Queue filters">
            <button class="queue-tab active" type="button" data-filter="ready">
              Ready <span>{{ ready_count.value }}</span>
            </button>
            <button class="queue-tab" type="button" data-filter="imported">
              Imported <span>{{ imported_count.value }}</span>
            </button>
            <button class="queue-tab" type="button" data-filter="all">
              All <span>{{ items|length }}</span>
            </button>
          </div>
        {% endif %}

        <input id="queueSearch" class="search" placeholder="Search queue..." autocomplete="off">

        <div class="bulk-toolbar">
          <label class="bulk-select-all">
            <input type="checkbox" id="selectAllReady">
            <span>Select visible</span>
          </label>
          <span id="selectedCount" class="selected-count">0 selected</span>
          <button id="bulkMarkImportedBtn" class="secondary small" type="button" disabled>Mark Selected Imported</button>
          <button id="clearSelectionBtn" class="small ghost" type="button" disabled>Clear</button>
        </div>

        <div class="folder-list" id="queueList">
          {% if items %}
            {% for item in items %}
              <button
                class="folder torrent-card {% if item.imported %}imported{% endif %}"
                type="button"
                data-source="{{ item.path }}"
                data-source-key="{{ item.source_key if item.source_key else item.path }}"
                data-title="{{ item.title }}"
                data-year="{{ item.year }}"
                data-season="{{ item.season }}"
                data-type="{{ item.type }}"
                data-imported="{% if item.imported %}true{% else %}false{% endif %}"
              >
                <span class="select-box-wrap" aria-hidden="true">
                  <input
                    class="queue-select"
                    type="checkbox"
                    tabindex="-1"
                    data-source="{{ item.path }}"
                    data-source-key="{{ item.source_key if item.source_key else item.path }}"
                    data-title="{{ item.title }}"
                    data-year="{{ item.year }}"
                    data-season="{{ item.season }}"
                    data-type="{{ item.type }}"
                    data-imported="{% if item.imported %}true{% else %}false{% endif %}"
                  >
                </span>
                <span class="torrent-topline">
                  <span class="torrent-icon">{{ item.icon }}</span>
                  <span class="torrent-heading">
                    <span class="folder-title">{{ item.title if item.title else item.name }}</span>
                    {% if item.year %}
                      <span class="year-pill">{{ item.year }}</span>
                    {% endif %}
                  </span>
                </span>

                <span class="release-name">{{ item.name }}</span>

                <span class="torrent-status-row">
                  <span class="status-chip {% if item.imported %}imported{% else %}ready{% endif %}">
                    {% if item.imported %}Imported{% else %}Ready{% endif %}
                  </span>
                  <span class="mini-pill">{{ item.type_label }}</span>
                  <span class="mini-pill">{{ item.video_count }} video{% if item.video_count != 1 %}s{% endif %}</span>
                </span>

                {% if qbittorrent_enabled %}
                  <span class="metric-grid">
                    <span class="metric">
                      <span class="metric-label">Ratio</span>
                      <span class="metric-value">{{ item.ratio }}</span>
                    </span>
                    <span class="metric">
                      <span class="metric-label">State</span>
                      <span class="metric-value">{{ item.state if item.state else "â€”" }}</span>
                    </span>
                    {% if item.category %}
                      <span class="metric wide">
                        <span class="metric-label">Category</span>
                        <span class="metric-value">{{ item.category }}</span>
                      </span>
                    {% endif %}
                  </span>
                {% else %}
                  <span class="folder-meta">{{ item.modified }}</span>
                {% endif %}
              </button>
            {% endfor %}
          {% else %}
            <p>No completed video items found.</p>
          {% endif %}
        </div>

        <div id="queueEmpty" class="queue-empty hidden">
          No items match this filter.
        </div>
      </aside>

      <section class="card">
        <h2>Import</h2>

        <form method="post" action="/organize">
          <input type="hidden" id="source" name="source">
          <input type="hidden" id="sourceKey" name="source_key">

          <label>Media Type</label>
          <div class="segmented">
            <label>
              <input type="radio" name="media_type" value="tv" checked>
              <span>ðŸ“º TV Show</span>
            </label>
            <label>
              <input type="radio" name="media_type" value="movie">
              <span>ðŸŽ¬ Movie</span>
            </label>
          </div>

          <label for="title">Title</label>
          <input id="title" name="title" autocomplete="off">

          <div class="grid">
            <div>
              <label for="year">Year</label>
              <input id="year" name="year" placeholder="optional" autocomplete="off">
            </div>
        <div>
            <label for="imdb_id">IMDb ID</label>
            <input id="imdb_id" name="imdb_id" placeholder="optional, e.g. tt13056008" autocomplete="off">
        </div>
            <div id="seasonWrap">
              <label for="season">Season</label>
              <input id="season" name="season" value="01" autocomplete="off">
            </div>
          </div>

          <label class="checkline">
            <input type="checkbox" name="refresh_jellyfin">
            Refresh Jellyfin after link
          </label>

          <div id="metadata" class="metadata hidden"></div>
          <div id="importedBox" class="imported-box hidden"></div>
          <div id="warning" class="warning"></div>

          <div class="actions">
            <button id="previewBtn" class="secondary" type="button">Preview</button>
            <button type="submit">Create Hard Links</button>
            <button id="markImportedBtn" class="secondary" type="button">âœ“ Mark Imported</button>
            {% if settings.developer_mode %}
              <button id="unmarkImportedBtn" class="danger hidden" type="button">Unmark Imported</button>
            {% endif %}
          </div>
        </form>

        <h3>Dry Run Preview</h3>
        <div id="preview" class="preview-box">
          <div class="empty-preview">Select a queue item to begin.</div>
        </div>

        {% if settings.developer_mode %}
          <h3>Link Diagnostics</h3>
          <pre id="diagnostics" class="diag-box">Preview an item to see path diagnostics.</pre>
        {% endif %}
      </section>

      <aside class="card">
        <h2>Import History</h2>
        <div class="history-tabs">
          <button class="history-tab active" type="button" data-history-filter="success">Success</button>
          <button class="history-tab" type="button" data-history-filter="error">Errors</button>
          <button class="history-tab" type="button" data-history-filter="all">All</button>
        </div>

        <div class="history">
          {% if history %}
            {% for item in history %}
              <div class="history-item {% if item.type == 'error' %}bad{% endif %}" data-history-type="{% if item.type == 'error' %}error{% else %}success{% endif %}">
                <strong>
                  {% if item.type == 'tv' %}ðŸ“º{% elif item.type == 'movie' %}ðŸŽ¬{% else %}âš ï¸{% endif %}
                  {{ item.title }}
                </strong>
                <span>{{ item.time }}</span>
                {% if item.type == 'error' %}
                  <small>{{ item.error }}</small>
                {% else %}
                  <small>{{ item.count }} link(s) â†’ {{ item.destination }}</small>
                {% endif %}
              </div>
            {% endfor %}
          {% else %}
            <p>No hard links created yet.</p>
          {% endif %}
        </div>
      </aside>
    </section>
  </main>

  <script src="/static/app.js?v={{ version }}"></script>
  <script>
    (function () {
      const tabs = document.querySelectorAll(".queue-tab");
      const cards = document.querySelectorAll(".torrent-card");
      const search = document.querySelector("#queueSearch");
      const empty = document.querySelector("#queueEmpty");
      let activeFilter = "ready";

      function cardMatchesFilter(card) {
        const imported = card.dataset.imported === "true";
        if (activeFilter === "ready") return !imported;
        if (activeFilter === "imported") return imported;
        return true;
      }

      function cardMatchesSearch(card) {
        if (!search) return true;
        const term = search.value.trim().toLowerCase();
        if (!term) return true;
        return card.textContent.toLowerCase().includes(term);
      }

      function applyFilters() {
        let visibleCount = 0;

        cards.forEach(card => {
          const visible = cardMatchesFilter(card) && cardMatchesSearch(card);
          card.classList.toggle("hidden", !visible);
          if (visible) visibleCount += 1;
        });

        if (empty) empty.classList.toggle("hidden", visibleCount !== 0);
        document.dispatchEvent(new CustomEvent("queueFiltersChanged"));
      }

      tabs.forEach(tab => {
        tab.addEventListener("click", () => {
          tabs.forEach(t => t.classList.remove("active"));
          tab.classList.add("active");
          activeFilter = tab.dataset.filter || "ready";
          applyFilters();
        });
      });

      if (search) search.addEventListener("input", applyFilters);
      applyFilters();
    })();
  </script>

<script>
document.addEventListener("DOMContentLoaded", () => {
  const tabs = document.querySelectorAll(".history-tab");
  const items = document.querySelectorAll(".history-item");

  function applyHistoryFilter(filter) {
    items.forEach(item => {
      const type = item.dataset.historyType || "success";
      item.classList.toggle("hidden", !(filter === "all" || filter === type));
    });
  }

  tabs.forEach(tab => {
    tab.addEventListener("click", () => {
      tabs.forEach(t => t.classList.remove("active"));
      tab.classList.add("active");
      applyHistoryFilter(tab.dataset.historyFilter || "success");
    });
  });

  applyHistoryFilter("success");
});
</script>
\n</body>
</html>
'@ | Set-Content -Path "app\templates\index.html" -Encoding UTF8

@'
const $ = (selector) => document.querySelector(selector);

let previewTimer = null;

function setMediaType(type) {
  const radio = document.querySelector(`input[name="media_type"][value="${type}"]`);
  if (radio) radio.checked = true;
  updateSeasonVisibility();
}

function getMediaType() {
  const checked = document.querySelector('input[name="media_type"]:checked');
  return checked ? checked.value : "tv";
}

function getImportButton() {
  return document.querySelector('form[action="/organize"] button[type="submit"]');
}

function setImportButton(text, disabled = false) {
  const btn = getImportButton();
  if (!btn) return;
  btn.textContent = text;
  btn.disabled = disabled;
  btn.classList.toggle("disabled", disabled);
}

function setManualButtons(imported = false) {
  const markBtn = $("#markImportedBtn");
  const unmarkBtn = $("#unmarkImportedBtn");
  if (markBtn) markBtn.classList.toggle("hidden", imported);
  if (unmarkBtn) unmarkBtn.classList.toggle("hidden", !imported);
}

function setActionMessage(message, isError = false) {
  const warning = $("#warning");
  if (!warning) return;
  warning.textContent = message || "";
  warning.classList.toggle("bad-text", !!isError);
}

function selectedPayload() {
  return {
    source: $("#source")?.value || "",
    source_key: $("#sourceKey")?.value || "",
    media_type: getMediaType(),
    title: $("#title")?.value || "",
    year: $("#year")?.value || "",
    imdb_id: $("#imdb_id")?.value || "",
    season: $("#season")?.value || "01",
  };
}

function updateSeasonVisibility() {
  const seasonWrap = $("#seasonWrap");
  if (!seasonWrap) return;
  seasonWrap.style.display = getMediaType() === "movie" ? "none" : "block";
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function schedulePreview() {
  clearTimeout(previewTimer);
  previewTimer = setTimeout(previewSelected, 350);
}

function fillFromCard(card) {
  if (!card) return;

  document.querySelectorAll(".folder").forEach(el => el.classList.remove("active"));
  card.classList.add("active");

  $("#source").value = card.dataset.source || "";
  $("#sourceKey").value = card.dataset.sourceKey || card.dataset.source || "";
  $("#title").value = card.dataset.title || "";
  $("#year").value = card.dataset.year || "";
  $("#season").value = card.dataset.season || "01";
  const imdbInput = $("#imdb_id");
  if (imdbInput) imdbInput.value = "";
  setActionMessage("");
  setManualButtons(card.dataset.imported === "true");

  setMediaType(card.dataset.type || "tv");
  setImportButton("Checking...", true);

  $("#metadata").innerHTML = `
    <div>
      <h3>Import Advisor</h3>
      <p>Checking your library and building an import plan...</p>
    </div>
  `;

  $("#preview").innerHTML = '<div class="empty-preview">Checking import plan...</div>';

  schedulePreview();
}

function renderImportAdvisor(data) {
  const metadata = $("#metadata");
  if (!metadata) return;

  if (data.imported) {
    const importType = data.imported.import_type || "linked";
    const heading = importType === "manual" ? "Manually Marked Imported" : "Previously Hard Linked";
    const verb = importType === "manual" ? "Marked" : "Linked";

    setImportButton("Already Imported", true);
    setManualButtons(true);

    metadata.innerHTML = `
      <div>
        <h3>${escapeHtml(heading)}</h3>
        <p>This item is already recorded in Media Linker import tracking.</p>
        <p><strong>Destination:</strong><br>${escapeHtml(data.imported.destination || "")}</p>
        <p><strong>${escapeHtml(verb)}:</strong> ${escapeHtml(data.imported.time || "")}</p>
        <p><strong>Import Type:</strong> ${escapeHtml(importType)}</p>
        <p><strong>Recommendation:</strong> No action needed.</p>
      </div>
    `;
    return;
  }

  setManualButtons(false);

  const match = data.library_match;
  const mediaType = getMediaType();

  if (!match) {
    if (mediaType === "movie") {
      setImportButton("Create New Movie", false);
    } else {
      setImportButton("Create New TV Folder", false);
    }

    metadata.innerHTML = `
      <div>
        <h3>New Library Folder</h3>
        <p>No existing library match was found.</p>
        <p><strong>Recommendation:</strong> Create a new destination folder.</p>
        <p><strong>Destination:</strong><br>${escapeHtml(data.destination || "")}</p>
      </div>
    `;
    return;
  }

  if (match.kind === "movie") {
    setImportButton("Import into Existing Movie", false);
    metadata.innerHTML = `
      <div>
        <h3>Existing Movie Found</h3>
        <p><strong>${escapeHtml(match.title)}</strong></p>
        <p>Media Linker found an existing movie folder in your library.</p>
        <p><strong>Videos already there:</strong> ${escapeHtml(match.video_count)}</p>
        <p><strong>Confidence:</strong> ${escapeHtml(match.confidence)} / Score ${escapeHtml(match.score)}</p>
        <p><strong>Recommendation:</strong> Import into the existing movie folder.</p>
        <p><strong>Path:</strong><br>${escapeHtml(match.path)}</p>
      </div>
    `;
    return;
  }

  const episodes = Array.isArray(match.existing_episodes) && match.existing_episodes.length
    ? match.existing_episodes.map(e => String(e).padStart(2, "0")).join(", ")
    : "None detected";

  setImportButton(`Import into Season ${match.season}`, false);

  metadata.innerHTML = `
    <div>
      <h3>Existing Show Found</h3>
      <p><strong>${escapeHtml(match.title)}</strong></p>
      <p>Media Linker found this show in your TV library.</p>
      <p><strong>Season ${escapeHtml(match.season)}:</strong> ${match.season_exists ? "Exists" : "Not found yet"}</p>
      <p><strong>Episodes already there:</strong> ${escapeHtml(episodes)}</p>
      <p><strong>Confidence:</strong> ${escapeHtml(match.confidence)} / Score ${escapeHtml(match.score)}</p>
      <p><strong>Recommendation:</strong> Import into the existing show/season folder.</p>
      <p><strong>Path:</strong><br>${escapeHtml(match.season_path || match.path)}</p>
    </div>
  `;
}

function renderPreview(data) {
  const preview = $("#preview");
  if (!preview) return;

  if (!data.ok) {
    setImportButton("Import Unavailable", true);
    preview.innerHTML = `<div class="empty-preview bad-text">${escapeHtml(data.error || "Preview failed")}</div>`;
    return;
  }

  const rows = (data.items || []).map(item => `
    <tr>
      <td>${escapeHtml(item.src)}</td>
      <td>${escapeHtml(item.new_name || item.dst)}</td>
      <td>${item.exists ? '<span class="exists">Exists</span>' : '<span class="good-text">Ready</span>'}</td>
    </tr>
  `).join("");

  preview.innerHTML = `
    <div class="destination"><strong>Destination:</strong><br>${escapeHtml(data.destination || "")}</div>
    <table class="preview-table">
      <thead>
        <tr>
          <th>Original</th>
          <th>New filename</th>
          <th>Status</th>
        </tr>
      </thead>
      <tbody>${rows}</tbody>
    </table>
  `;
}

function renderDiagnostics(data) {
  const diag = $("#diagnostics");
  if (!diag) return;
  diag.textContent = JSON.stringify(data.diagnostics || [], null, 2);
}

async function previewSelected() {
  const payload = selectedPayload();

  if (!payload.source) return;

  const response = await fetch("/api/preview", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload)
  });

  const data = await response.json();

  renderImportAdvisor(data);
  renderPreview(data);
  renderDiagnostics(data);
}

async function postJson(url, payload) {
  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload)
  });
  return await response.json();
}

async function markSelectedImported() {
  const payload = selectedPayload();
  if (!payload.source) {
    setActionMessage("Select a queue item first.", true);
    return;
  }

  const btn = $("#markImportedBtn");
  if (btn) {
    btn.disabled = true;
    btn.textContent = "Marking...";
  }

  const data = await postJson("/api/imports/mark", payload);
  if (!data.ok) {
    setActionMessage(data.error || "Could not mark this item imported.", true);
    if (btn) {
      btn.disabled = false;
      btn.textContent = "âœ“ Mark Imported";
    }
    return;
  }

  setActionMessage("Marked imported. Refreshing queue...");
  window.location.reload();
}

async function unmarkSelectedImported() {
  const payload = selectedPayload();
  if (!payload.source) {
    setActionMessage("Select a queue item first.", true);
    return;
  }

  const btn = $("#unmarkImportedBtn");
  if (btn) {
    btn.disabled = true;
    btn.textContent = "Unmarking...";
  }

  const data = await postJson("/api/imports/unmark", payload);
  if (!data.ok) {
    setActionMessage(data.error || "Could not unmark this item.", true);
    if (btn) {
      btn.disabled = false;
      btn.textContent = "Unmark Imported";
    }
    return;
  }

  setActionMessage("Import mark removed. Refreshing queue...");
  window.location.reload();
}


function selectedQueueItems() {
  return Array.from(document.querySelectorAll(".queue-select:checked")).map(box => ({
    source: box.dataset.source || "",
    source_key: box.dataset.sourceKey || box.dataset.source || "",
    media_type: box.dataset.type || "tv",
    title: box.dataset.title || "",
    year: box.dataset.year || "",
    imdb_id: "",
    season: box.dataset.season || "01",
  }));
}

function visibleQueueCheckboxes() {
  return Array.from(document.querySelectorAll(".torrent-card:not(.hidden) .queue-select"))
    .filter(box => box.dataset.imported !== "true");
}

function updateBulkControls() {
  const selected = selectedQueueItems();
  const count = selected.length;
  const countEl = $("#selectedCount");
  const bulkBtn = $("#bulkMarkImportedBtn");
  const clearBtn = $("#clearSelectionBtn");
  const selectAll = $("#selectAllReady");
  const visible = visibleQueueCheckboxes();
  const checkedVisible = visible.filter(box => box.checked);

  if (countEl) countEl.textContent = `${count} selected`;
  if (bulkBtn) bulkBtn.disabled = count === 0;
  if (clearBtn) clearBtn.disabled = count === 0;

  if (selectAll) {
    selectAll.checked = visible.length > 0 && checkedVisible.length === visible.length;
    selectAll.indeterminate = checkedVisible.length > 0 && checkedVisible.length < visible.length;
    selectAll.disabled = visible.length === 0;
  }

  document.querySelectorAll(".torrent-card").forEach(card => {
    const box = card.querySelector(".queue-select");
    card.classList.toggle("selected", !!box && box.checked);
  });
}

function clearQueueSelection() {
  document.querySelectorAll(".queue-select").forEach(box => { box.checked = false; });
  updateBulkControls();
}

async function bulkMarkSelectedImported() {
  const items = selectedQueueItems();
  if (!items.length) {
    setActionMessage("Select one or more Ready items first.", true);
    return;
  }

  const btn = $("#bulkMarkImportedBtn");
  if (btn) {
    btn.disabled = true;
    btn.textContent = "Marking...";
  }

  const data = await postJson("/api/imports/mark-bulk", { items });
  if (!data.ok) {
    setActionMessage(data.error || "Could not mark selected items imported.", true);
    if (btn) {
      btn.disabled = false;
      btn.textContent = "Mark Selected Imported";
    }
    updateBulkControls();
    return;
  }

  const marked = Array.isArray(data.marked) ? data.marked.length : 0;
  const errors = Array.isArray(data.errors) ? data.errors.length : 0;
  setActionMessage(`Marked ${marked} item(s) imported${errors ? `, with ${errors} error(s)` : ""}. Refreshing queue...`, errors > 0);
  window.location.reload();
}

document.addEventListener("DOMContentLoaded", () => {
  document.querySelectorAll(".folder").forEach(card => {
    card.addEventListener("click", (event) => {
      if (event.target && event.target.classList && event.target.classList.contains("queue-select")) {
        event.stopPropagation();
        updateBulkControls();
        return;
      }
      fillFromCard(card);
    });
  });

  document.querySelectorAll(".queue-select").forEach(box => {
    box.addEventListener("click", event => event.stopPropagation());
    box.addEventListener("change", updateBulkControls);
  });

  const selectAllReady = $("#selectAllReady");
  if (selectAllReady) {
    selectAllReady.addEventListener("change", () => {
      visibleQueueCheckboxes().forEach(box => { box.checked = selectAllReady.checked; });
      updateBulkControls();
    });
  }

  const clearSelectionBtn = $("#clearSelectionBtn");
  if (clearSelectionBtn) clearSelectionBtn.addEventListener("click", clearQueueSelection);

  const bulkMarkBtn = $("#bulkMarkImportedBtn");
  if (bulkMarkBtn) bulkMarkBtn.addEventListener("click", bulkMarkSelectedImported);

  document.addEventListener("queueFiltersChanged", updateBulkControls);

  document.querySelectorAll('input[name="media_type"]').forEach(radio => {
    radio.addEventListener("change", () => {
      updateSeasonVisibility();
      schedulePreview();
    });
  });

  ["#title", "#year", "#season", "#imdb_id"].forEach(selector => {
    const el = $(selector);
    if (el) el.addEventListener("input", schedulePreview);
  });

  const previewBtn = $("#previewBtn");
  if (previewBtn) previewBtn.style.display = "none";

  const markBtn = $("#markImportedBtn");
  if (markBtn) markBtn.addEventListener("click", markSelectedImported);

  const unmarkBtn = $("#unmarkImportedBtn");
  if (unmarkBtn) unmarkBtn.addEventListener("click", unmarkSelectedImported);

  const first = document.querySelector('.torrent-card[data-imported="false"]')
    || document.querySelector(".torrent-card")
    || document.querySelector(".folder");

  if (first) fillFromCard(first);

  updateBulkControls();
  updateSeasonVisibility();
});
'@ | Set-Content -Path "app\static\app.js" -Encoding UTF8

@'
* { box-sizing: border-box; }
body {
  margin: 0;
  background: radial-gradient(circle at top left, #172033, #0f1117 38%);
  color: #f5f7fb;
  font-family: system-ui, -apple-system, Segoe UI, Roboto, Arial, sans-serif;
}
.shell { max-width: 1540px; margin: 0 auto; padding: 34px 22px; }
.shell.narrow { max-width: 900px; }
.hero { display: flex; justify-content: space-between; gap: 18px; align-items: flex-start; margin-bottom: 22px; }
h1 { margin: 0 0 8px; font-size: 42px; letter-spacing: -1px; }
h2 { margin-top: 0; }
h3 { margin-top: 22px; }
p { color: #b8bfcc; }
.section-subtitle { margin: -6px 0 0; font-size: 13px; }
.hero-actions { display: flex; gap: 8px; flex-wrap: wrap; justify-content: flex-end; }
.badge, .pill, .navlink {
  background: #1f6feb;
  padding: 8px 12px;
  border-radius: 999px;
  font-weight: 800;
  color: white;
  text-decoration: none;
}
.pill { background: #2a2f3b; color: #c8cfdb; }
.pill.good { background: #12351e; color: #85f0a3; border: 1px solid #2dbd6e; }
.navlink { background: #2a2f3b; }
.layout { display: grid; grid-template-columns: 0.95fr 1.25fr 0.8fr; gap: 18px; }
.card {
  background: rgba(25, 28, 36, 0.96);
  border: 1px solid #313644;
  border-radius: 18px;
  padding: 20px;
  min-width: 0;
  box-shadow: 0 18px 50px rgba(0,0,0,.24);
}
.card-head { display: flex; justify-content: space-between; align-items: flex-start; gap: 12px; }
.card-head span { color: #aeb6c5; font-weight: 800; white-space: nowrap; }
.search { margin: 0 0 12px; }
.queue-tabs {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 8px;
  margin: 14px 0 12px;
}
.queue-tab {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 6px;
  padding: 9px 10px;
  border: 1px solid #343a49;
  background: #10141d;
  color: #cfd6e3;
  border-radius: 12px;
  font-weight: 900;
  cursor: pointer;
}
.queue-tab span {
  background: #242a37;
  color: #aeb6c5;
  border-radius: 999px;
  padding: 2px 7px;
  font-size: 12px;
}
.queue-tab.active {
  border-color: #2dbd6e;
  background: #12351e;
  color: #85f0a3;
}
.queue-tab.active span {
  background: #0d2514;
  color: #85f0a3;
}
.queue-empty {
  margin-top: 12px;
  padding: 14px;
  border: 1px dashed #3d4351;
  border-radius: 12px;
  color: #aeb6c5;
  text-align: center;
}
.folder-list { display: grid; gap: 12px; max-height: 68vh; overflow: auto; padding-right: 4px; }
.folder {
  text-align: left;
  padding: 0;
  border: 1px solid #343a49;
  background: #11141b;
  color: #f5f7fb;
  border-radius: 16px;
  cursor: pointer;
  overflow: hidden;
}
.folder:hover, .folder.active {
  border-color: #2dbd6e;
  background: linear-gradient(135deg, #142018, #11141b 72%);
}
.folder.imported { opacity: .62; }
.torrent-card { display: block; padding: 15px; position: relative; }
.torrent-card::before {
  content: "";
  position: absolute;
  inset: 0 auto 0 0;
  width: 4px;
  background: #2dbd6e;
  opacity: .9;
}
.torrent-card.imported::before { background: #6e8cff; }
.torrent-topline {
  display: grid;
  grid-template-columns: 30px minmax(0, 1fr);
  gap: 10px;
  align-items: start;
  margin-bottom: 8px;
}
.torrent-icon {
  width: 30px;
  height: 30px;
  display: grid;
  place-items: center;
  border-radius: 10px;
  background: #202634;
  font-size: 16px;
  line-height: 1;
}
.torrent-heading {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 8px;
  min-width: 0;
}
.folder-title {
  display: block;
  font-weight: 950;
  line-height: 1.18;
  overflow-wrap: anywhere;
}
.year-pill {
  flex: 0 0 auto;
  background: #0c1119;
  border: 1px solid #2b303d;
  border-radius: 999px;
  color: #aeb6c5;
  font-size: 11px;
  font-weight: 900;
  padding: 3px 7px;
}
.release-name {
  display: block;
  margin-left: 40px;
  margin-bottom: 10px;
  color: #7f8aa0;
  font-size: 11px;
  line-height: 1.25;
  overflow-wrap: anywhere;
}
.torrent-status-row {
  display: flex;
  gap: 7px;
  flex-wrap: wrap;
  align-items: center;
  margin-left: 40px;
  margin-bottom: 10px;
}
.mini-pill {
  background: #151a24;
  border: 1px solid #2b303d;
  border-radius: 999px;
  color: #b7c0d1;
  font-size: 11px;
  font-weight: 850;
  padding: 4px 8px;
}
.metric-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 8px;
  margin-left: 40px;
}
.metric {
  background: #0c1119;
  border: 1px solid #2b303d;
  border-radius: 11px;
  padding: 8px;
  min-width: 0;
}
.metric.wide { grid-column: 1 / -1; }
.metric-label {
  display: block;
  color: #778399;
  font-size: 10px;
  font-weight: 900;
  text-transform: uppercase;
  letter-spacing: .04em;
  margin-bottom: 3px;
}
.metric-value {
  display: block;
  color: #dce6f7;
  font-size: 12px;
  font-weight: 950;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.status-chip {
  border-radius: 999px;
  padding: 4px 9px;
  font-size: 11px;
  font-weight: 950;
  border: 1px solid transparent;
  text-transform: uppercase;
  letter-spacing: .02em;
}
.status-chip.ready { background: #12351e; color: #85f0a3; border-color: #2dbd6e; }
.status-chip.imported { background: #1b2b4a; color: #9db3ff; border-color: #375dae; }
.folder-meta { display: block; color: #aeb6c5; font-size: 13px; }
label { display: block; margin-top: 14px; margin-bottom: 7px; font-weight: 750; }
input {
  width: 100%;
  padding: 12px;
  border-radius: 11px;
  border: 1px solid #3d4351;
  background: #0f1218;
  color: white;
  font-size: 15px;
}
.grid { display: grid; grid-template-columns: 1fr 1fr; gap: 14px; }
.segmented { display: flex; gap: 10px; }
.segmented label { flex: 1; margin: 0; cursor: pointer; }
.segmented input { display: none; }
.segmented span { display: block; text-align: center; padding: 12px; border: 1px solid #3d4351; border-radius: 11px; background: #0f1218; font-weight: 850; }
.segmented input:checked + span { border-color: #2dbd6e; background: #15351f; }
.checkline { display: flex; align-items: center; gap: 10px; color: #cfd6e3; }
.checkline input { width: auto; }
.actions { display: flex; gap: 10px; margin-top: 18px; }
button { padding: 12px 16px; border: 0; border-radius: 11px; background: #2dbd6e; color: white; font-weight: 850; cursor: pointer; }
button.secondary { background: #1f6feb; }
.preview-box { min-height: 260px; background: #0b0d12; border: 1px solid #303644; border-radius: 13px; padding: 0; overflow: auto; }
.empty-preview { padding: 14px; color: #aeb6c5; }
.preview-table { width: 100%; border-collapse: collapse; font-size: 13px; }
.preview-table th, .preview-table td { text-align: left; vertical-align: top; border-bottom: 1px solid #262b36; padding: 10px; }
.preview-table th { color: #9db3d9; background: #111620; position: sticky; top: 0; }
.preview-table td { overflow-wrap: anywhere; }
.destination { padding: 12px 14px; border-bottom: 1px solid #303644; color: #cfd6e3; }
.exists { color: #ffcc66; font-weight: 900; }
.warning { color: #ffcc66; font-weight: 800; }
.metadata, .imported-box { display: flex; gap: 14px; margin: 18px 0; padding: 14px; border: 1px solid #313644; border-radius: 14px; background: #11141b; }
.imported-box { display:block; border-color:#ffcc66; }
.metadata img { width: 92px; border-radius: 8px; object-fit: cover; }
.metadata h3 { margin: 0 0 6px; }
.metadata p { margin: 0 0 8px; }
.hidden { display: none !important; }
.history { display: grid; gap: 10px; max-height: 72vh; overflow: auto; }
.history-item { padding: 12px; background: #11141b; border: 1px solid #343a49; border-radius: 12px; }
.history-item strong, .history-item span, .history-item small { display: block; }
.history-item span { color: #aeb6c5; font-size: 12px; margin-top: 3px; }
.history-item small { color: #b8bfcc; margin-top: 5px; overflow-wrap: anywhere; }
.history-item.bad, .alert.error { border-color: #d85050; }
.alert { padding: 13px 16px; border-radius: 12px; margin-bottom: 14px; background:#11141b; border:1px solid #343a49; }
.diag-box { white-space: pre-wrap; background:#0b0d12; border:1px solid #303644; border-radius:13px; padding:15px; overflow:auto; max-height:420px; }
.good-text { color:#85f0a3; font-weight:800; }
.bad-text { color:#ff7373; font-weight:800; }
@media (max-width: 1150px) { .layout { grid-template-columns: 1fr; } }

.history-tabs {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 8px;
  margin: 12px 0;
}

.history-tab {
  padding: 9px 10px;
  border: 1px solid #343a49;
  background: #10141d;
  color: #cfd6e3;
  border-radius: 12px;
  font-weight: 900;
  cursor: pointer;
}

.history-tab.active {
  border-color: #2dbd6e;
  background: #12351e;
  color: #85f0a3;
}

.history-item.success {
  border-color: #2dbd6e;
}


.history-tabs {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 8px;
  margin: 12px 0;
}

.history-tab {
  padding: 9px 10px;
  border: 1px solid #343a49;
  background: #10141d;
  color: #cfd6e3;
  border-radius: 12px;
  font-weight: 900;
  cursor: pointer;
}

.history-tab.active {
  border-color: #2dbd6e;
  background: #12351e;
  color: #85f0a3;
}

.history-item.success {
  border-color: #2dbd6e;
}


button.disabled,
button:disabled {
  opacity: 0.55;
  cursor: not-allowed;
}

.bulk-toolbar {
  display: grid;
  grid-template-columns: auto 1fr auto auto;
  gap: 8px;
  align-items: center;
  margin: 0 0 12px;
  padding: 10px;
  border: 1px solid #343a49;
  background: #0f131c;
  border-radius: 13px;
}
.bulk-select-all {
  display: flex;
  align-items: center;
  gap: 8px;
  margin: 0;
  color: #cfd6e3;
  font-size: 12px;
  font-weight: 900;
  white-space: nowrap;
}
.bulk-select-all input { width: auto; }
.selected-count {
  color: #aeb6c5;
  font-size: 12px;
  font-weight: 850;
}
button.small {
  padding: 8px 10px;
  border-radius: 9px;
  font-size: 12px;
}
button.ghost {
  background: #2a2f3b;
  color: #c8cfdb;
}
.select-box-wrap {
  position: absolute;
  top: 12px;
  right: 12px;
  z-index: 3;
  width: 24px;
  height: 24px;
  display: grid;
  place-items: center;
  background: #0c1119;
  border: 1px solid #343a49;
  border-radius: 8px;
}
.queue-select {
  width: 16px;
  height: 16px;
  margin: 0;
  cursor: pointer;
}
.torrent-card.selected {
  border-color: #6e8cff;
  background: linear-gradient(135deg, #171f3a, #11141b 72%);
}
.torrent-card.selected::before { background: #6e8cff; }
.torrent-card.imported .select-box-wrap {
  opacity: .35;
  pointer-events: none;
}
@media (max-width: 720px) {
  .bulk-toolbar { grid-template-columns: 1fr; }
}

'@ | Set-Content -Path "app\static\style.css" -Encoding UTF8

Write-Host "Local files updated. Checking git diff summary..." -ForegroundColor Cyan
git status --short

Write-Host "Copying to NASDY and rebuilding container..." -ForegroundColor Cyan
ssh root@NASDY "mkdir -p /mnt/user/appdata/nasdy-media-organizer/build"
scp -r .\app .\Dockerfile .\requirements.txt root@NASDY:/mnt/user/appdata/nasdy-media-organizer/build/
ssh root@NASDY "cd /mnt/user/appdata/nasdy-media-organizer/build && docker build -t nasdy-media-linker:latest . && docker stop nasdy-media-organizer || true && docker rm nasdy-media-organizer || true && docker run -d --name nasdy-media-organizer --restart unless-stopped -p 8088:8088 -v /mnt/user/NASDY/downloads:/downloads -v /mnt/user/NASDY/media:/media -v /mnt/user/appdata/nasdy-media-organizer/data:/app/data nasdy-media-linker:latest"

Write-Host "Container logs:" -ForegroundColor Cyan
ssh root@NASDY "docker logs nasdy-media-organizer --tail=80"

Write-Host "v3.4.5 Queue Manager deployed. Open the app and press Ctrl+F5 once." -ForegroundColor Green
