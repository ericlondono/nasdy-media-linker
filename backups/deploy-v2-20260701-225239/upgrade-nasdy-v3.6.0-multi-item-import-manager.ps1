# NASDY Media Linker v3.6.0 - Multi-Item Import Manager Upgrade
# Run this script from the NASDY Media Linker project root.

$ErrorActionPreference = "Stop"

$ProjectRoot = (Get-Location).Path
$Required = Join-Path $ProjectRoot "app\main.py"
if (-not (Test-Path $Required)) {
    throw "Run this script from the NASDY Media Linker project root. Could not find app\main.py in $ProjectRoot"
}

$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$BackupDir = Join-Path $ProjectRoot "backups\v3.6.0-multi-item-import-manager-$Stamp"
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

$FilesToPatch = @(
    "app\config.py",
    "app\main.py",
    "app\services\linker.py",
    "app\services\tmdb.py",
    "app\services\multi_import.py",
    "app\static\app.js",
    "app\static\style.css",
    "app\templates\index.html"
)

foreach ($RelativePath in $FilesToPatch) {
    $SourcePath = Join-Path $ProjectRoot $RelativePath
    if (Test-Path $SourcePath) {
        $BackupPath = Join-Path $BackupDir $RelativePath
        New-Item -ItemType Directory -Force -Path (Split-Path $BackupPath -Parent) | Out-Null
        Copy-Item $SourcePath $BackupPath -Force
    }
}

function Write-Utf8File {
    param(
        [Parameter(Mandatory=$true)][string]$RelativePath,
        [Parameter(Mandatory=$true)][string]$Content
    )

    $TargetPath = Join-Path $ProjectRoot $RelativePath
    New-Item -ItemType Directory -Force -Path (Split-Path $TargetPath -Parent) | Out-Null
    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($TargetPath, $Content, $Utf8NoBom)
    Write-Host "Wrote $RelativePath"
}

Write-Utf8File -RelativePath 'app\config.py' -Content @'
import os
from pathlib import Path

APP_NAME = "NASDY Media Linker"
APP_VERSION = "v3.6.0"

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

Write-Utf8File -RelativePath 'app\main.py' -Content @'
import json
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
from app.services.tmdb import tmdb_search, test_tmdb
from app.services.jellyfin import jellyfin_refresh
from app.services.qbittorrent import normalize_source_path
from app.services.qbittorrent import test_qbit
from app.services.library import find_library_match
from app.services.advisor import analyze_import
from app.services.logger import read_log, log
from app.services.multi_import import build_multi_import_preview, preview_multi_rows, public_multi_import_payload

app = FastAPI(title=APP_NAME)
app.mount("/static", StaticFiles(directory="app/static"), name="static")
templates = Jinja2Templates(directory="app/templates")


def history_counts(history):
    success = sum(
        1 for h in history
        if h.get("status") == "success" and h.get("type") != "error"
    )
    error = sum(
        1 for h in history
        if h.get("status") == "error" or h.get("type") == "error"
    )
    return {
        "success_count": {"value": success},
        "error_count": {"value": error},
        "history_total_count": {"value": success + error},
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


def _episode_number(value):
    try:
        return int(str(value))
    except Exception:
        return None


def _response_items_from_plan(items, advisor=None):
    advisor = advisor or {}
    duplicate_eps = {
        int(e) for e in advisor.get("duplicate_episodes", [])
        if _episode_number(e) is not None
    }

    diagnostics = []
    response_items = []
    for item in items or []:
        diag = diagnostic_for_link(Path(item["src"]), Path(item["dst"]))
        diagnostics.append(diag)

        ep_num = _episode_number(item.get("episode"))
        destination_exists = Path(item["dst"]).exists()
        duplicate_episode = bool(ep_num is not None and ep_num in duplicate_eps)

        response_items.append({
            "src": str(item["src"]),
            "dst": str(item["dst"]),
            "new_name": item.get("new_name") or Path(item["dst"]).name,
            "episode": item.get("episode", ""),
            "exists": destination_exists,
            "duplicate_episode": destination_exists or duplicate_episode,
            "status": "duplicate" if (destination_exists or duplicate_episode) else "ready",
        })

    return response_items, diagnostics


def _response_items_from_multi(preview):
    diagnostics = []
    response_items = []
    for item in preview.get("planned_items", []) or []:
        src = Path(item.get("src", ""))
        dst = Path(item.get("dst", ""))
        diag = diagnostic_for_link(src, dst)
        diagnostics.append(diag)
        destination_exists = dst.exists()
        response_items.append({
            "src": str(src),
            "dst": str(dst),
            "new_name": item.get("new_name") or dst.name,
            "episode": item.get("episode", ""),
            "exists": destination_exists,
            "duplicate_episode": destination_exists,
            "status": "duplicate" if destination_exists else "ready",
            "row_id": item.get("row_id", ""),
            "row_title": item.get("row_title", ""),
            "row_year": item.get("row_year", ""),
            "row_media_type": item.get("row_media_type", ""),
            "row_status": item.get("row_status", ""),
        })
    return response_items, diagnostics


def _multi_advisor(preview):
    summary = preview.get("summary", {}) or {}
    warnings = []
    if summary.get("errors"):
        warnings.append(f"{summary.get('errors')} row(s) need attention before they can import.")
    if summary.get("warnings"):
        warnings.append(f"{summary.get('warnings')} row(s) have match or duplicate warnings.")

    return {
        "level": "attention" if summary.get("errors") or summary.get("warnings") else "recommended",
        "label": "Multi-Item",
        "headline": preview.get("title") or "Multi-Item Import Manager",
        "recommendation": preview.get("recommendation") or "Review each row before importing.",
        "action_button": preview.get("action_button") or "Create Selected Hard Links",
        "import_allowed": preview.get("import_allowed", True),
        "import_policy": "skip_existing",
        "destination": "Multiple destinations",
        "facts": [
            f"Detected {summary.get('total', 0)} import row(s).",
            f"{summary.get('enabled', 0)} row(s) selected for import.",
            f"{summary.get('ready', 0)} row(s) ready, {summary.get('duplicates', 0)} duplicate, {summary.get('warnings', 0)} warning, {summary.get('errors', 0)} error.",
        ],
        "warnings": warnings,
        "errors": [],
    }


def _json_multi_items(raw: str):
    if not raw or not str(raw).strip():
        return []
    parsed = json.loads(raw)
    if not isinstance(parsed, list):
        raise ValueError("Multi-item payload must be a list.")
    return parsed


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


@app.post("/api/tmdb/test")
async def api_tmdb_test(request: Request):
    data = await request.json()
    settings = load_settings()
    settings.update(data)
    try:
        test_tmdb(settings)
        return JSONResponse({"ok": True, "message": "TMDb connection successful."})
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
        settings = load_settings()
        db = load_import_db()
        source_key = data.get("source_key") or source or ""
        imported = find_import_record(db, source_key, source)

        if imported:
            try:
                dest_dir, items = build_plan(media_type, source, title, year, season)
            except Exception:
                dest_dir, items = "", []
            advisor = analyze_import(
                media_type=media_type,
                source=source,
                title=title,
                year=year,
                season=season,
                imported=imported,
                metadata={},
                planned_items=items,
                destination=Path(dest_dir) if dest_dir else None,
                library_match=None,
            )
            response_items, diagnostics = _response_items_from_plan(items, advisor)
            return JSONResponse({
                "ok": True,
                "destination": str(dest_dir or imported.get("destination", "")),
                "metadata": {"imdb_id": imdb_id},
                "library_match": None,
                "imported": imported,
                "advisor": advisor,
                "multi_import": {"enabled": False, "mode": "single", "items": []},
                "diagnostics": diagnostics,
                "items": response_items,
            })

        multi_preview = build_multi_import_preview(settings, media_type, source, title, year, season)
        if multi_preview.get("enabled"):
            response_items, diagnostics = _response_items_from_multi(multi_preview)
            advisor = _multi_advisor(multi_preview)
            return JSONResponse({
                "ok": True,
                "destination": "Multiple destinations",
                "metadata": {},
                "library_match": None,
                "imported": None,
                "advisor": advisor,
                "multi_import": public_multi_import_payload(multi_preview),
                "diagnostics": diagnostics,
                "items": response_items,
            })

        dest_dir, items = build_plan(media_type, source, title, year, season)
        meta = tmdb_search(settings, media_type, title, year) or {}
        library_match = find_library_match(media_type, title, year, season)

        advisor = analyze_import(
            media_type=media_type,
            source=source,
            title=title,
            year=year,
            season=season,
            imported=imported,
            metadata=meta,
            planned_items=items,
            destination=dest_dir,
            library_match=library_match,
        )

        response_items, diagnostics = _response_items_from_plan(items, advisor)

        return JSONResponse({
            "ok": True,
            "destination": str(dest_dir),
            "metadata": {
                **meta,
                "imdb_id": imdb_id or meta.get("imdb_id", ""),
            },
            "library_match": library_match,
            "imported": imported,
            "advisor": advisor,
            "multi_import": {"enabled": False, "mode": "single", "items": []},
            "diagnostics": diagnostics,
            "items": response_items,
        })
    except Exception as e:
        return JSONResponse({"ok": False, "error": str(e), "multi_import": {"enabled": False}})


@app.post("/api/multi-preview")
async def api_multi_preview(request: Request):
    data = await request.json()
    try:
        settings = load_settings()
        rows = data.get("items", []) if isinstance(data, dict) else []
        mode = data.get("mode", "custom") if isinstance(data, dict) else "custom"
        multi_preview = preview_multi_rows(rows, settings=settings, auto_match=False, mode=mode)
        response_items, diagnostics = _response_items_from_multi(multi_preview)
        advisor = _multi_advisor(multi_preview)
        return JSONResponse({
            "ok": True,
            "destination": "Multiple destinations",
            "metadata": {},
            "library_match": None,
            "imported": None,
            "advisor": advisor,
            "multi_import": public_multi_import_payload(multi_preview),
            "diagnostics": diagnostics,
            "items": response_items,
        })
    except Exception as e:
        return JSONResponse({"ok": False, "error": str(e), "multi_import": {"enabled": False}})


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


def _organize_multi_items(raw_rows, source, source_key, duplicate_policy, refresh_jellyfin):
    settings = load_settings()
    rows = preview_multi_rows(raw_rows, settings=settings, auto_match=False, mode="custom").get("items", [])
    selected = [row for row in rows if row.get("enabled")]
    if not selected:
        raise ValueError("No multi-import rows are selected.")

    link_policy = "skip" if duplicate_policy in {"skip", "skip_existing", "import_missing"} else "error"
    db = load_import_db()
    row_results = []
    all_diagnostics = []
    total_created = 0
    total_skipped = 0
    errors = []

    for row in selected:
        if row.get("status_level") == "error":
            errors.append({"title": row.get("title", ""), "error": row.get("error", "Row has an error.")})
            continue

        try:
            dest_dir, items = build_plan(
                row.get("media_type", "movie"),
                row.get("source", ""),
                row.get("title", ""),
                row.get("year", ""),
                row.get("season") or "01",
            )
            created, diagnostics = create_hard_links(items, existing_policy=link_policy)
            skipped = sum(1 for d in diagnostics if d.get("action") == "skipped_existing")
            all_diagnostics.extend(diagnostics)
            total_created += len(created)
            total_skipped += skipped

            row_entry = {
                "title": row.get("title", ""),
                "year": row.get("year", ""),
                "imdb_id": row.get("imdb_id", ""),
                "media_type": row.get("media_type", "movie"),
                "season": row.get("season", "") if row.get("media_type") == "tv" else "",
                "source": row.get("source", ""),
                "source_key": row.get("source_key") or row.get("source", ""),
                "destination": str(dest_dir),
                "count": len(created),
                "skipped": skipped,
            }
            row_results.append(row_entry)

            db = save_import_aliases(
                db,
                row_entry["source_key"],
                row_entry["source"],
                {
                    "time": datetime.now().strftime("%Y-%m-%d %H:%M"),
                    "type": row_entry["media_type"],
                    "title": row_entry["title"],
                    "year": row_entry["year"],
                    "imdb_id": row_entry["imdb_id"],
                    "season": row_entry["season"],
                    "count": row_entry["count"],
                    "skipped": row_entry["skipped"],
                    "destination": row_entry["destination"],
                    "jellyfin": "",
                    "status": "success",
                    "import_type": "multi-row",
                    "source": row_entry["source"],
                    "source_key": row_entry["source_key"],
                    "diagnostics": diagnostics,
                },
            )
        except Exception as row_error:
            errors.append({"title": row.get("title", ""), "error": str(row_error)})
            log(f"ERROR multi-row import {row.get('title', '')}: {row_error}")

    jf_msg = ""
    if refresh_jellyfin:
        _, jf_msg = jellyfin_refresh(settings)

    entry_title = "Multi-Item Import"
    if row_results:
        entry_title = f"Multi-Item Import: {row_results[0].get('title', '')}"
        if len(row_results) > 1:
            entry_title += f" + {len(row_results) - 1} more"

    aggregate_entry = {
        "time": datetime.now().strftime("%Y-%m-%d %H:%M"),
        "type": "multi",
        "title": entry_title,
        "year": "",
        "imdb_id": "",
        "season": "",
        "count": total_created,
        "skipped": total_skipped,
        "destination": "Multiple destinations",
        "jellyfin": jf_msg,
        "status": "success" if row_results else "error",
        "import_type": "multi-item",
        "source": source,
        "source_key": source_key,
        "diagnostics": all_diagnostics,
        "rows": row_results,
        "errors": errors,
    }

    append_history(aggregate_entry)
    if row_results:
        db = save_import_aliases(db, source_key, source, aggregate_entry)
    save_import_db(db)

    if errors and not row_results:
        raise ValueError("Multi-item import failed: " + "; ".join(e.get("error", "") for e in errors))

    log(f"Multi-item import complete: rows={len(row_results)} created={total_created} skipped={total_skipped} errors={len(errors)}")
    return aggregate_entry


@app.post("/organize")
def organize(
    media_type: str = Form(...),
    source: str = Form(...),
    source_key: str = Form(""),
    title: str = Form(...),
    year: str = Form(""),
    imdb_id: str = Form(""),
    season: str = Form("01"),
    duplicate_policy: str = Form("skip"),
    refresh_jellyfin: Optional[str] = Form(None),
    multi_items: str = Form(""),
):
    try:
        raw_multi_rows = _json_multi_items(multi_items)
        if raw_multi_rows:
            _organize_multi_items(raw_multi_rows, source, source_key or source, duplicate_policy, refresh_jellyfin)
            return RedirectResponse("/", status_code=303)

        settings = load_settings()
        dest_dir, items = build_plan(media_type, source, title, year, season)
        link_policy = "skip" if duplicate_policy in {"skip", "skip_existing", "import_missing"} else "error"
        created, diagnostics = create_hard_links(items, existing_policy=link_policy)
        skipped = sum(1 for d in diagnostics if d.get("action") == "skipped_existing")

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
            "skipped": skipped,
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
'@

Write-Utf8File -RelativePath 'app\services\linker.py' -Content @'
import os
from collections import defaultdict
from pathlib import Path

from app.config import MOVIES_ROOT, TV_ROOT, HOST_MNT_ROOT
from app.services.utils import find_videos, detect_episode, safe_name, strip_release_words, detect_year, looks_like_multi_movie_folder
from app.services.logger import log


def movie_group_name(source_path: Path, src: Path) -> str:
    try:
        rel = src.relative_to(source_path)
        if len(rel.parts) > 1:
            return rel.parts[0]
    except Exception:
        pass
    return src.stem


def build_movie_collection_plan(source_path: Path, videos, fallback_title: str, fallback_year: str):
    items = []
    groups = defaultdict(list)
    for src in videos:
        groups[movie_group_name(source_path, src)].append(src)

    for group_name in sorted(groups.keys(), key=lambda x: x.lower()):
        group_videos = sorted(groups[group_name], key=lambda p: str(p).lower())
        movie_title = strip_release_words(group_name) or fallback_title or group_name
        movie_year = detect_year(group_name) or detect_year(group_videos[0].name) or fallback_year
        display = f"{movie_title} ({movie_year})" if movie_year else movie_title
        dest_dir = MOVIES_ROOT / safe_name(display)

        if len(group_videos) == 1:
            src = group_videos[0]
            new_name = safe_name(f"{display}{src.suffix.lower()}")
            items.append({"src": src, "dst": dest_dir / new_name, "new_name": new_name, "movie_title": movie_title, "movie_year": movie_year})
        else:
            # Rare, but keeps multi-part movies inside that movie's own folder.
            for idx, src in enumerate(group_videos, start=1):
                new_name = safe_name(f"{display} - Part {idx}{src.suffix.lower()}")
                items.append({"src": src, "dst": dest_dir / new_name, "new_name": new_name, "movie_title": movie_title, "movie_year": movie_year})

    return MOVIES_ROOT, items


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
            episode_detected = bool(ep)
            if not ep:
                ep = f"{fallback:02d}"
                fallback += 1
            new_name = safe_name(f"{display} - S{season}E{ep}{src.suffix.lower()}")
            items.append({
                "src": src,
                "dst": dest_dir / new_name,
                "new_name": new_name,
                "episode": ep,
                "episode_detected": episode_detected,
            })
    else:
        display = f"{title} ({year})" if year else title

        # v3.6.0: a torrent/download can be a movie pack with one folder per movie.
        # In that case, create one movie folder per child release instead of naming
        # everything "Parent Title - Part 1/2/3".
        if looks_like_multi_movie_folder(source_path):
            return build_movie_collection_plan(source_path, videos, title, year)

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


def create_hard_links(items, existing_policy="skip"):
    created = []
    diagnostics = []
    skip_existing = existing_policy in {"skip", "skip_existing", "import_missing"}

    for item in items:
        src_container = Path(item["src"])
        dst_container = Path(item["dst"])
        diag = diagnostic_for_link(src_container, dst_container)

        src_real = Path(diag["src_real"])
        dst_real = Path(diag["dst_real"])

        log(f"LINK DIAG: {diag}")

        if not src_real.exists():
            diag["action"] = "error"
            diag["error"] = f"Resolved source does not exist: {src_real}"
            diagnostics.append(diag)
            raise FileNotFoundError(diag["error"])

        if dst_real.exists():
            if skip_existing:
                diag["action"] = "skipped_existing"
                diagnostics.append(diag)
                log(f"SKIPPED EXISTING HARD LINK DESTINATION: {dst_real}")
                continue
            diag["action"] = "error"
            diag["error"] = f"Destination already exists: {dst_real}"
            diagnostics.append(diag)
            raise FileExistsError(diag["error"])

        dst_real.parent.mkdir(parents=True, exist_ok=True)
        normalize_permissions(dst_real.parent)
        os.link(src_real, dst_real)
        normalize_permissions(dst_real)
        created.append(str(dst_real))
        diag["action"] = "created"
        diagnostics.append(diag)
        log(f"CREATED HARD LINK: {src_real} -> {dst_real}")

    return created, diagnostics
'@

Write-Utf8File -RelativePath 'app\services\tmdb.py' -Content @'
import re
import requests


def _normalize_title(value: str) -> str:
    return "".join(ch.lower() for ch in str(value or "") if ch.isalnum())


def _tmdb_get(settings, path: str, params=None):
    api_key = settings.get("tmdb_api_key", "").strip()
    if not api_key:
        return None

    query = dict(params or {})
    query["api_key"] = api_key

    response = requests.get(
        f"https://api.themoviedb.org/3{path}",
        params=query,
        timeout=8,
    )
    response.raise_for_status()
    return response.json()


def _result_year(item):
    release_date = item.get("first_air_date") or item.get("release_date") or ""
    return str(release_date or "")[:4]


def _score_candidate(query_title: str, query_year: str, candidate: dict) -> float:
    query_norm = _normalize_title(query_title)
    title = candidate.get("title") or ""
    title_norm = _normalize_title(title)
    year = str(candidate.get("year") or "")

    score = 0.0
    if query_norm and title_norm:
        if query_norm == title_norm:
            score += 100
        elif query_norm in title_norm or title_norm in query_norm:
            score += 70
        else:
            query_words = set(re.findall(r"[a-z0-9]+", str(query_title).lower()))
            title_words = set(re.findall(r"[a-z0-9]+", str(title).lower()))
            if query_words and title_words:
                score += 45 * (len(query_words.intersection(title_words)) / max(len(query_words), len(title_words)))

    if query_year and year:
        score += 35 if str(query_year) == year else -25

    score += min(float(candidate.get("votes") or 0), 5000) / 5000 * 10
    score += min(float(candidate.get("popularity") or 0), 100) / 100 * 5
    return round(score, 3)


def _normalize_result(item: dict, media_type: str, fallback_title: str, query_title: str, query_year: str) -> dict:
    poster_path = item.get("poster_path")
    backdrop_path = item.get("backdrop_path")
    release_date = item.get("first_air_date") or item.get("release_date") or ""
    title = item.get("name") or item.get("title") or fallback_title

    normalized = {
        "id": item.get("id"),
        "media_type": media_type,
        "title": title,
        "year": str(release_date or "")[:4],
        "overview": item.get("overview", ""),
        "poster": f"https://image.tmdb.org/t/p/w342{poster_path}" if poster_path else "",
        "backdrop": f"https://image.tmdb.org/t/p/w780{backdrop_path}" if backdrop_path else "",
        "score": round(float(item.get("vote_average", 0)), 1),
        "votes": int(item.get("vote_count", 0)),
        "popularity": float(item.get("popularity", 0) or 0),
    }
    normalized["match_score"] = _score_candidate(query_title, query_year, normalized)
    return normalized


def tmdb_search_candidates(settings, media_type: str, title: str, year: str = "", limit: int = 5):
    """
    Search TMDb and return normalized candidates sorted by a local title/year score.
    """
    api_key = settings.get("tmdb_api_key", "").strip()
    if not api_key or not title:
        return []

    media_type = "tv" if media_type == "tv" else "movie"
    endpoint = "tv" if media_type == "tv" else "movie"

    params = {
        "query": title,
        "include_adult": "false",
        "language": "en-US",
        "page": 1,
    }

    if year:
        if media_type == "tv":
            params["first_air_date_year"] = year
        else:
            params["year"] = year

    try:
        data = _tmdb_get(settings, f"/search/{endpoint}", params)
        results = (data or {}).get("results", [])

        if not results and year:
            params.pop("first_air_date_year", None)
            params.pop("year", None)
            data = _tmdb_get(settings, f"/search/{endpoint}", params)
            results = (data or {}).get("results", [])

        candidates = [
            _normalize_result(item, media_type, title, title, year)
            for item in results or []
            if item.get("id")
        ]
        candidates.sort(key=lambda item: item.get("match_score", 0), reverse=True)
        return candidates[: max(1, int(limit or 5))]
    except Exception:
        return []


def tmdb_external_ids(settings, media_type: str, tmdb_id):
    """Return TMDb external IDs for a movie or TV show."""
    api_key = settings.get("tmdb_api_key", "").strip()
    if not api_key or not tmdb_id:
        return {}

    media_type = "tv" if media_type == "tv" else "movie"
    endpoint = "tv" if media_type == "tv" else "movie"

    try:
        return _tmdb_get(settings, f"/{endpoint}/{tmdb_id}/external_ids", {}) or {}
    except Exception:
        return {}


def tmdb_search_with_imdb(settings, media_type: str, title: str, year: str = ""):
    """
    Return the best TMDb match plus IMDb ID when TMDb exposes one.
    """
    candidates = tmdb_search_candidates(settings, media_type, title, year, limit=1)
    if not candidates:
        return None

    item = candidates[0]
    external = tmdb_external_ids(settings, media_type, item.get("id"))
    item["imdb_id"] = (external or {}).get("imdb_id") or ""
    item["external_ids"] = external or {}
    return item


def tmdb_search(settings, media_type: str, title: str, year: str = ""):
    """
    Search TMDb for a movie or TV show.

    Returns a small normalized metadata object or None.
    """
    item = tmdb_search_with_imdb(settings, media_type, title, year)
    if item:
        return item
    return None


def test_tmdb(settings):
    """
    Validate the TMDb API key by calling the configuration endpoint.
    """
    api_key = settings.get("tmdb_api_key", "").strip()
    if not api_key:
        raise ValueError("TMDb API key is required.")

    response = requests.get(
        "https://api.themoviedb.org/3/configuration",
        params={"api_key": api_key},
        timeout=8,
    )

    if response.status_code != 200:
        raise ValueError(f"TMDb connection failed. HTTP {response.status_code}: {response.text[:100]}")

    return True
'@

Write-Utf8File -RelativePath 'app\services\multi_import.py' -Content @'
from pathlib import Path
from typing import Any, Dict, List, Optional
import re

from app.services.library import find_library_match
from app.services.linker import build_plan
from app.services.tmdb import tmdb_search_with_imdb
from app.services.utils import detect_season, detect_year, find_videos, strip_release_words, title_case_guess


IGNORED_CHILD_DIRS = {
    "sample", "samples", "subs", "subtitles", "extras", "extra", "trailers", "trailer",
    "featurettes", "featurette", "proof", "screens", "screenshots",
}


SEASON_PATTERNS = [
    re.compile(r"\bSeason[ ._\-]*(\d{1,2})\b", re.I),
    re.compile(r"\bS(\d{1,2})\b", re.I),
    re.compile(r"\bSeries[ ._\-]*(\d{1,2})\b", re.I),
]


def _as_bool(value: Any, default: bool = True) -> bool:
    if isinstance(value, bool):
        return value
    if value is None:
        return default
    return str(value).strip().lower() not in {"0", "false", "no", "off", ""}


def _season_number(value: Any, default: str = "01") -> str:
    text = str(value or "").strip()
    if not text:
        text = default
    try:
        return f"{int(text):02d}"
    except Exception:
        detected = detect_season(text)
        try:
            return f"{int(detected):02d}"
        except Exception:
            return str(default or "01").zfill(2)


def _season_from_folder(name: str) -> Optional[str]:
    text = str(name or "")
    for pattern in SEASON_PATTERNS:
        match = pattern.search(text)
        if match:
            return f"{int(match.group(1)):02d}"
    return None




def _clean_media_title(value: str) -> str:
    text = strip_release_words(value or "")
    text = re.sub(r"[\(\[\{]?\b(19\d{2}|20\d{2})\b[\)\]\}]?", " ", text)
    text = re.sub(r"\s+", " ", text).strip(" ._-()[]{}")
    return title_case_guess(text) if text else strip_release_words(value or "")


def _clean_parent_title(value: str) -> str:
    title = _clean_media_title(value or "")
    title = re.sub(r"\bComplete\b", "", title, flags=re.I)
    title = re.sub(r"\bSeries\b", "", title, flags=re.I)
    title = re.sub(r"\bCollection\b", "", title, flags=re.I)
    title = re.sub(r"\bPack\b", "", title, flags=re.I)
    title = re.sub(r"\s+", " ", title).strip()
    return title_case_guess(title) if title else strip_release_words(value or "")


def _video_count(path: Path) -> int:
    try:
        return len(find_videos(path))
    except Exception:
        return 0


def _child_dirs_with_videos(source_path: Path) -> List[Path]:
    children = []
    if not source_path.exists() or not source_path.is_dir():
        return children

    for child in sorted(source_path.iterdir(), key=lambda p: p.name.lower()):
        if not child.is_dir():
            continue
        if child.name.strip().lower() in IGNORED_CHILD_DIRS:
            continue
        if _video_count(child) > 0:
            children.append(child)
    return children


def detect_movie_collection_rows(source: str, fallback_title: str = "", fallback_year: str = "") -> List[Dict[str, Any]]:
    source_path = Path(source or "")
    rows = []

    for index, child in enumerate(_child_dirs_with_videos(source_path), start=1):
        title = _clean_media_title(child.name) or fallback_title or child.name
        year = detect_year(child.name)
        videos = find_videos(child)
        if not year and videos:
            year = detect_year(videos[0].name)
        if not year:
            year = fallback_year or ""

        rows.append({
            "row_id": f"movie-{index}",
            "enabled": True,
            "media_type": "movie",
            "source": str(child),
            "source_key": str(child),
            "detected": child.name,
            "title": title,
            "year": year,
            "imdb_id": "",
            "tmdb_id": "",
            "season": "",
            "file_count": len(videos),
        })

    return rows if len(rows) >= 2 else []


def detect_tv_season_rows(source: str, fallback_title: str = "", fallback_year: str = "") -> List[Dict[str, Any]]:
    source_path = Path(source or "")
    rows = []
    parent_title = fallback_title or _clean_parent_title(source_path.name)
    parent_year = fallback_year or detect_year(source_path.name)

    season_children = []
    for child in _child_dirs_with_videos(source_path):
        season = _season_from_folder(child.name)
        if season:
            season_children.append((child, season))

    if len(season_children) < 2:
        return []

    for index, (child, season) in enumerate(season_children, start=1):
        videos = find_videos(child)
        rows.append({
            "row_id": f"tv-{index}",
            "enabled": True,
            "media_type": "tv",
            "source": str(child),
            "source_key": str(child),
            "detected": child.name,
            "title": parent_title,
            "year": parent_year,
            "imdb_id": "",
            "tmdb_id": "",
            "season": season,
            "file_count": len(videos),
        })

    return rows


def detect_multi_import_rows(media_type: str, source: str, title: str = "", year: str = "", season: str = "01") -> Dict[str, Any]:
    source_path = Path(source or "")
    if not source_path.exists() or not source_path.is_dir():
        return {"enabled": False, "mode": "single", "items": []}

    media_type = "movie" if media_type == "movie" else "tv"
    movie_rows = detect_movie_collection_rows(source, title, year)
    tv_rows = detect_tv_season_rows(source, title, year)

    if media_type == "movie" and movie_rows:
        return {"enabled": True, "mode": "movie_collection", "items": movie_rows}

    if media_type == "tv" and tv_rows:
        return {"enabled": True, "mode": "tv_season_pack", "items": tv_rows}

    # Helpful fallback for queue items that were guessed incorrectly.
    if tv_rows and not movie_rows:
        return {"enabled": True, "mode": "tv_season_pack", "items": tv_rows}

    if movie_rows:
        return {"enabled": True, "mode": "movie_collection", "items": movie_rows}

    return {"enabled": False, "mode": "single", "items": []}


def _apply_tmdb_match(settings: Dict[str, Any], row: Dict[str, Any]) -> Dict[str, Any]:
    row = dict(row)
    if row.get("imdb_id") or row.get("tmdb_id"):
        return row

    metadata = tmdb_search_with_imdb(settings, row.get("media_type", "movie"), row.get("title", ""), row.get("year", ""))
    if not metadata:
        row["match_status"] = "Needs match"
        row["match_level"] = "warning"
        return row

    row["tmdb_id"] = str(metadata.get("id") or "")
    row["imdb_id"] = metadata.get("imdb_id") or ""
    row["title"] = metadata.get("title") or row.get("title", "")
    row["year"] = metadata.get("year") or row.get("year", "")
    row["poster"] = metadata.get("poster") or ""
    row["match_score"] = metadata.get("match_score") or ""

    if row.get("imdb_id"):
        row["match_status"] = "Auto matched"
        row["match_level"] = "good"
    else:
        row["match_status"] = "Matched; IMDb unavailable"
        row["match_level"] = "warning"

    return row


def _normalize_row(row: Dict[str, Any], index: int) -> Dict[str, Any]:
    media_type = "movie" if row.get("media_type") == "movie" else "tv"
    source = str(row.get("source") or "").strip()
    title = str(row.get("title") or "").strip()
    year = str(row.get("year") or "").strip()
    season = "" if media_type == "movie" else _season_number(row.get("season") or "01")
    imdb_id = str(row.get("imdb_id") or "").strip()

    return {
        "row_id": str(row.get("row_id") or f"row-{index}"),
        "enabled": _as_bool(row.get("enabled"), True),
        "media_type": media_type,
        "source": source,
        "source_key": str(row.get("source_key") or source),
        "detected": str(row.get("detected") or Path(source).name),
        "title": title,
        "year": year,
        "imdb_id": imdb_id,
        "tmdb_id": str(row.get("tmdb_id") or ""),
        "season": season,
        "file_count": int(row.get("file_count") or 0),
        "poster": str(row.get("poster") or ""),
        "match_status": str(row.get("match_status") or ("Manual IMDb" if imdb_id else "Needs match")),
        "match_level": str(row.get("match_level") or ("good" if imdb_id else "warning")),
        "match_score": row.get("match_score") or "",
    }


def _status_from_plan(row: Dict[str, Any], planned_items: List[Dict[str, Any]], library_match: Optional[Dict[str, Any]], error: str = "") -> Dict[str, Any]:
    if error:
        return {
            "status_label": "Error",
            "status_level": "error",
            "import_allowed": False,
            "error": error,
        }

    if not row.get("enabled", True):
        return {
            "status_label": "Skipped",
            "status_level": "skipped",
            "import_allowed": False,
            "error": "",
        }

    destination_existing = []
    for item in planned_items or []:
        try:
            if Path(item.get("dst", "")).exists():
                destination_existing.append(item)
        except Exception:
            pass

    if planned_items and len(destination_existing) == len(planned_items):
        return {
            "status_label": "Duplicate / Skip",
            "status_level": "duplicate",
            "import_allowed": True,
            "error": "",
        }

    if destination_existing:
        return {
            "status_label": "Partial duplicate",
            "status_level": "warning",
            "import_allowed": True,
            "error": "",
        }

    if row.get("media_type") == "movie" and library_match and int(library_match.get("video_count") or 0) > 0:
        return {
            "status_label": "Possible duplicate",
            "status_level": "warning",
            "import_allowed": True,
            "error": "",
        }

    if row.get("match_status"):
        return {
            "status_label": row.get("match_status"),
            "status_level": row.get("match_level") or "good",
            "import_allowed": True,
            "error": "",
        }

    return {
        "status_label": "Ready",
        "status_level": "good",
        "import_allowed": True,
        "error": "",
    }


def preview_multi_rows(rows: List[Dict[str, Any]], settings: Optional[Dict[str, Any]] = None, auto_match: bool = False, mode: str = "custom") -> Dict[str, Any]:
    settings = settings or {}
    output_rows = []
    all_items = []
    enabled_count = 0
    ready_count = 0
    warning_count = 0
    duplicate_count = 0
    error_count = 0

    for index, raw in enumerate(rows or [], start=1):
        row = _normalize_row(raw, index)
        if auto_match:
            row = _apply_tmdb_match(settings, row)

        planned_items = []
        destination = ""
        library_match = None
        error = ""

        if row.get("enabled"):
            enabled_count += 1

        try:
            if not row.get("source"):
                raise ValueError("Source folder is missing.")
            if not row.get("title"):
                raise ValueError("Title is required.")
            destination_path, planned_items = build_plan(
                row.get("media_type", "movie"),
                row.get("source", ""),
                row.get("title", ""),
                row.get("year", ""),
                row.get("season") or "01",
            )
            destination = str(destination_path)
            library_match = find_library_match(
                row.get("media_type", "movie"),
                row.get("title", ""),
                row.get("year", ""),
                row.get("season") or "01",
            )
        except Exception as exc:
            error = str(exc)

        row_status = _status_from_plan(row, planned_items, library_match, error)
        row.update(row_status)
        row["destination"] = destination
        row["library_match"] = library_match
        row["file_count"] = len(planned_items) if planned_items else row.get("file_count", 0)
        row["planned_items"] = [
            {
                **item,
                "src": str(item.get("src", "")),
                "dst": str(item.get("dst", "")),
            }
            for item in planned_items or []
        ]

        if row["status_level"] == "error":
            error_count += 1
        elif row["status_level"] == "duplicate":
            duplicate_count += 1
        elif row["status_level"] == "warning":
            warning_count += 1
        elif row.get("enabled"):
            ready_count += 1

        for item in row["planned_items"]:
            all_items.append({
                **item,
                "row_id": row["row_id"],
                "row_title": row["title"],
                "row_year": row["year"],
                "row_media_type": row["media_type"],
                "row_status": row["status_label"],
            })

        output_rows.append(row)

    if mode == "movie_collection":
        title = "Movie Collection Import Manager"
        recommendation = "Review each movie row, confirm the IMDb IDs, then create hard links for the selected rows."
    elif mode == "tv_season_pack":
        title = "TV Season Pack Import Manager"
        recommendation = "Review each season row, confirm the show metadata, then import the selected seasons independently."
    else:
        title = "Multi-Item Import Manager"
        recommendation = "Review each selected row before creating hard links."

    import_allowed = enabled_count > 0 and error_count < enabled_count

    return {
        "enabled": True,
        "mode": mode,
        "title": title,
        "summary": {
            "total": len(output_rows),
            "enabled": enabled_count,
            "ready": ready_count,
            "warnings": warning_count,
            "duplicates": duplicate_count,
            "errors": error_count,
        },
        "recommendation": recommendation,
        "import_allowed": import_allowed,
        "action_button": "Create Selected Hard Links" if import_allowed else "Review Rows Before Import",
        "items": output_rows,
        "planned_items": all_items,
    }


def build_multi_import_preview(settings: Dict[str, Any], media_type: str, source: str, title: str = "", year: str = "", season: str = "01") -> Dict[str, Any]:
    detected = detect_multi_import_rows(media_type, source, title, year, season)
    if not detected.get("enabled"):
        return detected

    return preview_multi_rows(
        detected.get("items", []),
        settings=settings,
        auto_match=True,
        mode=detected.get("mode", "custom"),
    )


def public_multi_import_payload(preview: Dict[str, Any]) -> Dict[str, Any]:
    """Strip internal-only fields while keeping enough data for the browser editor."""
    if not preview or not preview.get("enabled"):
        return {"enabled": False, "mode": "single", "items": []}

    items = []
    for row in preview.get("items", []):
        clean = dict(row)
        clean.pop("planned_items", None)
        clean.pop("library_match", None)
        items.append(clean)

    return {
        **{k: v for k, v in preview.items() if k not in {"items", "planned_items"}},
        "items": items,
    }
'@

Write-Utf8File -RelativePath 'app\static\app.js' -Content @'
const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => Array.from(document.querySelectorAll(selector));

let previewTimer = null;
let multiPreviewTimer = null;
let activeQueueFilter = "recommended";
let activeHistoryFilter = "success";
let multiImportState = { enabled: false, mode: "single", items: [] };

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

function setDuplicatePolicy(value = "skip") {
  const field = $("#duplicatePolicy");
  if (field) field.value = value;
}

function setManualButtons(imported = false) {
  const markBtn = $("#markImportedBtn");
  const unmarkBtn = $("#unmarkImportedBtn");
  if (markBtn) markBtn.classList.toggle("hidden", imported || multiImportState.enabled);
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

function asArray(value) {
  return Array.isArray(value) ? value : [];
}

function schedulePreview() {
  clearTimeout(previewTimer);
  previewTimer = setTimeout(previewSelected, 350);
}

function setSingleImportFieldsVisible(visible = true) {
  const single = $("#singleImportFields");
  if (single) single.classList.toggle("hidden", !visible);
}

function resetMultiImportUI() {
  multiImportState = { enabled: false, mode: "single", items: [] };
  clearTimeout(multiPreviewTimer);
  const hidden = $("#multiItems");
  if (hidden) hidden.value = "";
  const manager = $("#multiImportManager");
  if (manager) {
    manager.classList.add("hidden");
    manager.innerHTML = "";
  }
  setSingleImportFieldsVisible(true);
}

function fillFromCard(card) {
  if (!card) return;

  $$(".folder").forEach(el => el.classList.remove("active"));
  card.classList.add("active");

  resetMultiImportUI();

  $("#source").value = card.dataset.source || "";
  $("#sourceKey").value = card.dataset.sourceKey || card.dataset.source || "";
  $("#title").value = card.dataset.title || "";
  $("#year").value = card.dataset.year || "";
  $("#season").value = card.dataset.season || "01";
  const imdbInput = $("#imdb_id");
  if (imdbInput) imdbInput.value = "";
  setDuplicatePolicy("skip");
  setActionMessage("");
  setManualButtons(card.dataset.imported === "true");

  setMediaType(card.dataset.type || "tv");
  setImportButton("Checking...", true);

  const metadata = $("#metadata");
  if (metadata) {
    metadata.classList.remove("hidden");
    metadata.innerHTML = `
      <div class="advisor-panel checking">
        <h3>Smart Import Advisor</h3>
        <p>Checking your library, incoming files, and duplicate risk...</p>
      </div>
    `;
  }

  const preview = $("#preview");
  if (preview) preview.innerHTML = '<div class="empty-preview">Checking import plan...</div>';

  schedulePreview();
}

function renderMiniFacts(advisor) {
  const chips = [
    ["Incoming", advisor.incoming_summary],
    ["Existing", advisor.existing_summary],
    ["Missing", advisor.missing_summary],
    ["Duplicates", advisor.duplicate_summary],
  ].filter(pair => pair[1]);

  if (!chips.length) return "";

  return `
    <div class="advisor-chip-row">
      ${chips.map(([label, value]) => `
        <span class="advisor-mini-chip">
          <strong>${escapeHtml(label)}</strong>
          ${escapeHtml(value)}
        </span>
      `).join("")}
    </div>
  `;
}

function renderAdvisorFacts(advisor) {
  const facts = asArray(advisor.facts);
  if (!facts.length) return "";
  return `
    <div class="advisor-facts">
      ${facts.map(fact => `<p>${escapeHtml(fact)}</p>`).join("")}
    </div>
  `;
}

function renderAdvisorWarnings(advisor) {
  const warnings = asArray(advisor.warnings).concat(asArray(advisor.errors));
  if (!warnings.length) return "";
  return `
    <div class="advisor-warnings">
      ${warnings.map(warning => `<p>${escapeHtml(warning)}</p>`).join("")}
    </div>
  `;
}

function multiStatusClass(level) {
  if (level === "error") return "error";
  if (level === "duplicate") return "duplicate";
  if (level === "warning") return "attention";
  if (level === "skipped") return "imported";
  return "recommended";
}

function renderMultiAdvisor(data) {
  const metadata = $("#metadata");
  if (!metadata) return;
  metadata.classList.remove("hidden");

  const multi = data.multi_import || {};
  if (multi.enabled) multiImportState.enabled = true;
  const advisor = data.advisor || {};
  const summary = multi.summary || {};
  const level = advisor.level || (summary.errors || summary.warnings ? "attention" : "recommended");
  const label = advisor.label || "Multi-Item";
  const importAllowed = multi.import_allowed !== false;

  setDuplicatePolicy("skip_existing");
  setImportButton(multi.action_button || advisor.action_button || "Create Selected Hard Links", !importAllowed);
  setManualButtons(false);

  metadata.innerHTML = `
    <div class="advisor-panel ${escapeHtml(level)}">
      <div class="advisor-heading-row">
        <h3>Smart Import Advisor</h3>
        <span class="status-chip advisor-chip ${escapeHtml(level)}">${escapeHtml(label)}</span>
      </div>
      <p class="advisor-headline">${escapeHtml(advisor.headline || multi.title || "Multi-Item Import Manager")}</p>
      <div class="advisor-chip-row">
        <span class="advisor-mini-chip"><strong>Total rows</strong>${escapeHtml(summary.total ?? 0)}</span>
        <span class="advisor-mini-chip"><strong>Selected</strong>${escapeHtml(summary.enabled ?? 0)}</span>
        <span class="advisor-mini-chip"><strong>Ready</strong>${escapeHtml(summary.ready ?? 0)}</span>
        <span class="advisor-mini-chip"><strong>Warnings</strong>${escapeHtml((summary.warnings ?? 0) + (summary.errors ?? 0))}</span>
      </div>
      ${renderAdvisorFacts(advisor)}
      ${renderAdvisorWarnings(advisor)}
      <p><strong>Recommendation:</strong> ${escapeHtml(advisor.recommendation || multi.recommendation || "Review each row before importing.")}</p>
      <p><strong>Destination:</strong><br>Multiple destinations</p>
    </div>
  `;
}

function renderMultiImportManager(multi) {
  const manager = $("#multiImportManager");
  if (!manager || !multi || !multi.enabled) return;

  multiImportState = {
    ...multi,
    items: asArray(multi.items),
  };

  setSingleImportFieldsVisible(false);
  manager.classList.remove("hidden");

  const rows = multiImportState.items.map(row => {
    const isTv = row.media_type === "tv";
    const statusClass = multiStatusClass(row.status_level || row.match_level);
    const checked = row.enabled === false ? "" : "checked";
    const seasonInput = isTv
      ? `<input class="multi-field multi-season" value="${escapeHtml(row.season || "01")}" autocomplete="off">`
      : `<span class="muted-dash">-</span>`;

    return `
      <tr
        data-row-id="${escapeHtml(row.row_id)}"
        data-media-type="${escapeHtml(row.media_type || "movie")}" 
        data-source="${escapeHtml(row.source || "")}" 
        data-source-key="${escapeHtml(row.source_key || row.source || "")}" 
        data-detected="${escapeHtml(row.detected || "")}" 
        data-tmdb-id="${escapeHtml(row.tmdb_id || "")}" 
        data-poster="${escapeHtml(row.poster || "")}" 
        data-match-status="${escapeHtml(row.match_status || "")}" 
        data-match-level="${escapeHtml(row.match_level || "")}" 
        data-match-score="${escapeHtml(row.match_score || "")}" 
      >
        <td class="multi-check-cell">
          <input class="multi-enabled" type="checkbox" ${checked} aria-label="Import ${escapeHtml(row.title || row.detected || "row")}">
        </td>
        <td>
          <strong>${escapeHtml(row.detected || row.source || "Detected item")}</strong>
          <small>${escapeHtml(row.source || "")}</small>
          <small class="multi-file-count">${escapeHtml(row.file_count || 0)} file${Number(row.file_count || 0) === 1 ? "" : "s"}</small>
        </td>
        <td><input class="multi-field multi-title" value="${escapeHtml(row.title || "")}" autocomplete="off"></td>
        <td><input class="multi-field multi-year" value="${escapeHtml(row.year || "")}" autocomplete="off"></td>
        <td>${seasonInput}</td>
        <td><input class="multi-field multi-imdb" value="${escapeHtml(row.imdb_id || "")}" placeholder="tt..." autocomplete="off"></td>
        <td class="multi-destination" data-row-id="${escapeHtml(row.row_id)}">${escapeHtml(row.destination || "")}</td>
        <td><span class="status-chip advisor-chip ${statusClass} multi-status" data-row-id="${escapeHtml(row.row_id)}">${escapeHtml(row.status_label || row.match_status || "Ready")}</span></td>
      </tr>
    `;
  }).join("");

  manager.innerHTML = `
    <section class="multi-manager-card">
      <div class="multi-manager-head">
        <div>
          <h3>${escapeHtml(multi.title || "Multi-Item Import Manager")}</h3>
          <p>${escapeHtml(multi.recommendation || "Each detected item can be edited and imported independently.")}</p>
        </div>
        <span class="status-chip advisor-chip recommended">v3.6.0</span>
      </div>
      <div class="multi-table-wrap">
        <table class="multi-import-table" id="multiImportTable">
          <thead>
            <tr>
              <th>Import</th>
              <th>Detected folder</th>
              <th>Title / Show</th>
              <th>Year</th>
              <th>Season</th>
              <th>IMDb</th>
              <th>Destination preview</th>
              <th>Status</th>
            </tr>
          </thead>
          <tbody>${rows}</tbody>
        </table>
      </div>
      <p class="multi-help">Unchecked rows are skipped. Edited rows are previewed again before import.</p>
    </section>
  `;

  updateMultiItemsHidden();
}

function collectMultiRows() {
  const tableRows = $$("#multiImportTable tbody tr");
  return tableRows.map(row => {
    const mediaType = row.dataset.mediaType || "movie";
    return {
      row_id: row.dataset.rowId || "",
      enabled: !!row.querySelector(".multi-enabled")?.checked,
      media_type: mediaType,
      source: row.dataset.source || "",
      source_key: row.dataset.sourceKey || row.dataset.source || "",
      detected: row.dataset.detected || "",
      title: row.querySelector(".multi-title")?.value || "",
      year: row.querySelector(".multi-year")?.value || "",
      imdb_id: row.querySelector(".multi-imdb")?.value || "",
      season: mediaType === "tv" ? (row.querySelector(".multi-season")?.value || "01") : "",
      tmdb_id: row.dataset.tmdbId || "",
      poster: row.dataset.poster || "",
      match_status: row.dataset.matchStatus || "",
      match_level: row.dataset.matchLevel || "",
      match_score: row.dataset.matchScore || "",
    };
  });
}

function updateMultiItemsHidden() {
  const hidden = $("#multiItems");
  if (!hidden) return;
  if (!multiImportState.enabled) {
    hidden.value = "";
    return;
  }
  hidden.value = JSON.stringify(collectMultiRows());
}

function scheduleMultiPreview() {
  if (!multiImportState.enabled) return;
  updateMultiItemsHidden();
  clearTimeout(multiPreviewTimer);
  multiPreviewTimer = setTimeout(previewMultiRows, 450);
}

function syncMultiComputed(multi) {
  if (!multi || !multi.enabled) return;

  multiImportState = {
    ...multiImportState,
    ...multi,
    items: asArray(multi.items),
  };

  for (const row of multiImportState.items) {
    const tr = document.querySelector(`#multiImportTable tbody tr[data-row-id="${CSS.escape(row.row_id)}"]`);
    if (!tr) continue;

    const destination = tr.querySelector(".multi-destination");
    if (destination) destination.textContent = row.destination || "";

    const fileCount = tr.querySelector(".multi-file-count");
    if (fileCount) {
      const count = Number(row.file_count || 0);
      fileCount.textContent = `${count} file${count === 1 ? "" : "s"}`;
    }

    const status = tr.querySelector(".multi-status");
    if (status) {
      status.textContent = row.status_label || row.match_status || "Ready";
      status.className = `status-chip advisor-chip ${multiStatusClass(row.status_level || row.match_level)} multi-status`;
    }
  }

  updateMultiItemsHidden();
}

async function previewMultiRows() {
  if (!multiImportState.enabled) return;
  const payload = {
    mode: multiImportState.mode || "custom",
    items: collectMultiRows(),
  };

  try {
    const data = await postJson("/api/multi-preview", payload);
    if (!data.ok) {
      setImportButton("Review Rows Before Import", true);
      setActionMessage(data.error || "Multi-row preview failed.", true);
      return;
    }

    renderMultiAdvisor(data);
    syncMultiComputed(data.multi_import || {});
    renderMultiFilePreview(data);
    renderDiagnostics(data);
    setActionMessage("");
  } catch (error) {
    setImportButton("Review Rows Before Import", true);
    setActionMessage(`Multi-row preview failed: ${error}`, true);
  }
}

function renderImportAdvisor(data) {
  const metadata = $("#metadata");
  if (!metadata) return;
  metadata.classList.remove("hidden");

  if (!data.ok) {
    resetMultiImportUI();
    setImportButton("Import Unavailable", true);
    metadata.innerHTML = `
      <div class="advisor-panel attention">
        <h3>Smart Import Advisor</h3>
        <p class="bad-text">${escapeHtml(data.error || "Preview failed")}</p>
      </div>
    `;
    return;
  }

  if (data.multi_import && data.multi_import.enabled) {
    renderMultiAdvisor(data);
    renderMultiImportManager(data.multi_import);
    return;
  }

  resetMultiImportUI();

  if (data.imported) {
    const importType = data.imported.import_type || "linked";
    const heading = importType === "manual" ? "Manually Marked Imported" : "Previously Hard Linked";
    const verb = importType === "manual" ? "Marked" : "Linked";

    setImportButton("Already Imported", true);
    setManualButtons(true);

    metadata.innerHTML = `
      <div class="advisor-panel imported">
        <div class="advisor-heading-row">
          <h3>${escapeHtml(heading)}</h3>
          <span class="status-chip advisor-chip imported">Imported</span>
        </div>
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

  const advisor = data.advisor || {};
  const level = advisor.level || "recommended";
  const label = advisor.label || "Recommended";
  const importAllowed = advisor.import_allowed !== false;
  const actionButton = advisor.action_button || "Create Hard Links";
  setDuplicatePolicy(advisor.import_policy || "skip");

  setImportButton(actionButton, !importAllowed);

  const poster = data.metadata && data.metadata.poster
    ? `<img src="${escapeHtml(data.metadata.poster)}" alt="">`
    : "";

  const destination = advisor.destination || data.destination || "";
  const recommendation = advisor.recommendation || "Review the dry run preview before importing.";

  metadata.innerHTML = `
    ${poster}
    <div class="advisor-panel ${escapeHtml(level)}">
      <div class="advisor-heading-row">
        <h3>Smart Import Advisor</h3>
        <span class="status-chip advisor-chip ${escapeHtml(level)}">${escapeHtml(label)}</span>
      </div>
      <p class="advisor-headline">${escapeHtml(advisor.headline || "Import analysis ready")}</p>
      ${renderMiniFacts(advisor)}
      ${renderAdvisorFacts(advisor)}
      ${renderAdvisorWarnings(advisor)}
      <p><strong>Recommendation:</strong> ${escapeHtml(recommendation)}</p>
      <p><strong>Destination:</strong><br>${escapeHtml(destination)}</p>
    </div>
  `;
}

function renderMultiFilePreview(data) {
  const preview = $("#preview");
  if (!preview) return;

  const rows = (data.items || []).map(item => {
    const duplicate = item.exists || item.duplicate_episode || item.status === "duplicate";
    const statusHtml = duplicate
      ? '<span class="exists">Duplicate / Skip</span>'
      : '<span class="good-text">Ready</span>';

    const displayTitle = item.row_year
      ? `${item.row_title} (${item.row_year})`
      : item.row_title;

    return `
      <tr class="${duplicate ? "preview-duplicate" : "preview-ready"}">
        <td>${escapeHtml(displayTitle || item.row_id || "")}</td>
        <td>${escapeHtml(item.src)}</td>
        <td>${escapeHtml(item.dst || item.new_name)}</td>
        <td>${statusHtml}</td>
      </tr>
    `;
  }).join("");

  preview.innerHTML = `
    <div class="destination"><strong>Destination:</strong><br>Multiple destinations</div>
    <table class="preview-table">
      <thead><tr><th>Import row</th><th>Original</th><th>New destination</th><th>Status</th></tr></thead>
      <tbody>${rows || '<tr><td colspan="4">No selected files to preview.</td></tr>'}</tbody>
    </table>
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

  if (data.multi_import && data.multi_import.enabled) {
    renderMultiFilePreview(data);
    return;
  }

  const rows = (data.items || []).map(item => {
    const duplicate = item.exists || item.duplicate_episode || item.status === "duplicate";
    const statusHtml = duplicate
      ? '<span class="exists">Duplicate / Skip</span>'
      : '<span class="good-text">Ready</span>';

    return `
      <tr class="${duplicate ? "preview-duplicate" : "preview-ready"}">
        <td>${escapeHtml(item.src)}</td>
        <td>${escapeHtml(item.new_name || item.dst)}</td>
        <td>${statusHtml}</td>
      </tr>
    `;
  }).join("");

  preview.innerHTML = `
    <div class="destination"><strong>Destination:</strong><br>${escapeHtml(data.destination || "")}</div>
    <table class="preview-table">
      <thead><tr><th>Original</th><th>New filename</th><th>Status</th></tr></thead>
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

  try {
    const response = await fetch("/api/preview", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload)
    });

    const data = await response.json();
    renderImportAdvisor(data);
    renderPreview(data);
    renderDiagnostics(data);
  } catch (error) {
    setImportButton("Import Unavailable", true);
    setActionMessage(`Preview failed: ${error}`, true);
  }
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
  if (btn) { btn.disabled = true; btn.textContent = "Marking..."; }

  const data = await postJson("/api/imports/mark", payload);
  if (!data.ok) {
    setActionMessage(data.error || "Could not mark this item imported.", true);
    if (btn) { btn.disabled = false; btn.textContent = "Mark Imported"; }
    return;
  }
  window.location.reload();
}

async function unmarkSelectedImported() {
  const payload = selectedPayload();
  if (!payload.source) {
    setActionMessage("Select a queue item first.", true);
    return;
  }
  const btn = $("#unmarkImportedBtn");
  if (btn) { btn.disabled = true; btn.textContent = "Unmarking..."; }

  const data = await postJson("/api/imports/unmark", payload);
  if (!data.ok) {
    setActionMessage(data.error || "Could not unmark this item.", true);
    if (btn) { btn.disabled = false; btn.textContent = "Unmark Imported"; }
    return;
  }
  window.location.reload();
}

function selectedQueueItems() {
  return $$(".queue-select:checked").map(box => ({
    source: box.dataset.source || "",
    source_key: box.dataset.sourceKey || box.dataset.source || "",
    media_type: box.dataset.type || "tv",
    title: box.dataset.title || "",
    year: box.dataset.year || "",
    imdb_id: "",
    season: box.dataset.season || "01",
  }));
}

function matchesQueueFilter(card, filter) {
  const imported = card.dataset.imported === "true";
  const level = card.dataset.advisorLevel || (imported ? "imported" : "recommended");

  if (filter === "all") return true;
  if (filter === "ready") return !imported;
  if (filter === "imported") return imported || level === "imported";
  if (filter === "recommended") return !imported && level === "recommended";
  if (filter === "attention") return !imported && level === "attention";
  if (filter === "duplicate") return !imported && level === "duplicate";
  return true;
}

function cardShouldShow(card) {
  const filterOk = matchesQueueFilter(card, activeQueueFilter);
  const term = ($("#queueSearch")?.value || "").trim().toLowerCase();
  const searchOk = !term || card.textContent.toLowerCase().includes(term);
  return filterOk && searchOk;
}

function setQueueFilter(filter) {
  activeQueueFilter = filter;
  $$(".queue-tab").forEach(tab => {
    tab.classList.toggle("active", (tab.dataset.filter || "") === filter);
  });
  applyQueueFilters();
}

function chooseInitialQueueFilter() {
  const cards = $$(".torrent-card");
  const filters = ["recommended", "attention", "duplicate", "imported", "all"];
  const firstFilterWithItems = filters.find(filter => cards.some(card => matchesQueueFilter(card, filter))) || "all";
  setQueueFilter(firstFilterWithItems);
}

function applyQueueFilters() {
  const cards = $$(".torrent-card");
  let visibleCount = 0;

  cards.forEach(card => {
    const show = cardShouldShow(card);
    card.hidden = !show;
    if (show) {
      card.style.removeProperty("display");
    } else {
      card.style.setProperty("display", "none", "important");
    }
    card.classList.toggle("hidden", !show);
    if (!show) {
      const box = card.querySelector(".queue-select");
      if (box) box.checked = false;
    } else {
      visibleCount += 1;
    }
  });

  const empty = $("#queueEmpty");
  if (empty) empty.classList.toggle("hidden", visibleCount !== 0);
  updateBulkControls();
}

function visibleQueueCheckboxes() {
  return $$(".torrent-card")
    .filter(card => cardShouldShow(card) && card.dataset.imported !== "true")
    .map(card => card.querySelector(".queue-select"))
    .filter(Boolean);
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

  $$(".torrent-card").forEach(card => {
    const box = card.querySelector(".queue-select");
    card.classList.toggle("selected", !!box && box.checked);
  });
}

function clearQueueSelection() {
  $$(".queue-select").forEach(box => { box.checked = false; });
  updateBulkControls();
}

async function bulkMarkSelectedImported() {
  const items = selectedQueueItems();
  if (!items.length) {
    setActionMessage("Select one or more visible items first.", true);
    return;
  }
  const btn = $("#bulkMarkImportedBtn");
  if (btn) { btn.disabled = true; btn.textContent = "Marking..."; }

  const data = await postJson("/api/imports/mark-bulk", { items });
  if (!data.ok) {
    setActionMessage(data.error || "Could not mark selected items imported.", true);
    if (btn) { btn.disabled = false; btn.textContent = "Mark Selected Imported"; }
    updateBulkControls();
    return;
  }
  window.location.reload();
}

function applyHistoryFilter() {
  $$(".history-item").forEach(item => {
    const show = activeHistoryFilter === "all" || (item.dataset.historyType || "success") === activeHistoryFilter;
    item.hidden = !show;
    item.style.display = show ? "" : "none";
    item.classList.toggle("hidden", !show);
  });
}

document.addEventListener("DOMContentLoaded", () => {
  $$(".folder").forEach(card => {
    card.addEventListener("click", event => {
      if (event.target && event.target.classList && event.target.classList.contains("queue-select")) {
        event.stopPropagation();
        updateBulkControls();
        return;
      }
      fillFromCard(card);
    });
  });

  $$(".queue-select").forEach(box => {
    box.addEventListener("click", event => event.stopPropagation());
    box.addEventListener("change", updateBulkControls);
  });

  $$(".queue-tab").forEach(tab => {
    tab.addEventListener("click", event => {
      event.preventDefault();
      setQueueFilter(tab.dataset.filter || "recommended");
    });
  });

  const search = $("#queueSearch");
  if (search) search.addEventListener("input", applyQueueFilters);

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

  $$(('input[name="media_type"]')).forEach(radio => {
    radio.addEventListener("change", () => {
      updateSeasonVisibility();
      schedulePreview();
    });
  });

  ["#title", "#year", "#season", "#imdb_id"].forEach(selector => {
    const el = $(selector);
    if (el) el.addEventListener("input", schedulePreview);
  });

  const manager = $("#multiImportManager");
  if (manager) {
    manager.addEventListener("input", event => {
      if (event.target && event.target.classList && event.target.classList.contains("multi-field")) {
        scheduleMultiPreview();
      }
    });
    manager.addEventListener("change", event => {
      if (event.target && event.target.classList && (event.target.classList.contains("multi-field") || event.target.classList.contains("multi-enabled"))) {
        scheduleMultiPreview();
      }
    });
  }

  const previewBtn = $("#previewBtn");
  if (previewBtn) previewBtn.style.display = "none";

  const markBtn = $("#markImportedBtn");
  if (markBtn) markBtn.addEventListener("click", markSelectedImported);

  const unmarkBtn = $("#unmarkImportedBtn");
  if (unmarkBtn) unmarkBtn.addEventListener("click", unmarkSelectedImported);

  $$(".history-tab").forEach(tab => {
    tab.addEventListener("click", event => {
      event.preventDefault();
      $$(".history-tab").forEach(t => t.classList.remove("active"));
      tab.classList.add("active");
      activeHistoryFilter = tab.dataset.historyFilter || "success";
      applyHistoryFilter();
    });
  });

  chooseInitialQueueFilter();
  applyHistoryFilter();

  const first =
    document.querySelector('.torrent-card[data-imported="false"][data-advisor-level="recommended"]') ||
    document.querySelector('.torrent-card[data-imported="false"][data-advisor-level="attention"]') ||
    document.querySelector('.torrent-card[data-imported="false"][data-advisor-level="duplicate"]') ||
    document.querySelector(".torrent-card") ||
    document.querySelector(".folder");
  if (first) fillFromCard(first);

  updateSeasonVisibility();
});
'@

Write-Utf8File -RelativePath 'app\static\style.css' -Content @'
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
  grid-template-columns: 34px minmax(0, 1fr) 44px;
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
  justify-content: flex-start;
  gap: 8px;
  min-width: 0;
  padding-right: 0;
}
.folder-title {
  display: block;
  font-weight: 950;
  line-height: 1.18;
  overflow-wrap: anywhere;
  min-width: 0;
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
  margin-left: 44px;
  margin-right: 44px;
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
  margin-left: 44px;
  margin-right: 44px;
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
  margin-left: 44px;
  margin-right: 44px;
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




/* v3.4.5 card layout final reset */
.bulk-toolbar {
  display: grid !important;
  grid-template-columns: auto minmax(0, 1fr) auto !important;
  gap: 9px !important;
  align-items: center !important;
  margin: 12px 0 12px !important;
  padding: 12px !important;
  border: 1px solid #343a49 !important;
  border-radius: 14px !important;
  background: #10141d !important;
}

.bulk-select-all {
  grid-column: 1 !important;
  display: flex !important;
  align-items: center !important;
  gap: 8px !important;
  margin: 0 !important;
  color: #cfd6e3 !important;
  font-size: 12px !important;
  font-weight: 900 !important;
  white-space: nowrap !important;
}

.bulk-select-all input {
  width: 16px !important;
  height: 16px !important;
  padding: 0 !important;
  margin: 0 !important;
}

.selected-count,
#selectedCount {
  grid-column: 2 !important;
  color: #aeb6c5 !important;
  font-size: 12px !important;
  font-weight: 900 !important;
  white-space: nowrap !important;
}

#clearSelectionBtn {
  grid-column: 3 !important;
  justify-self: end !important;
}

#bulkMarkImportedBtn {
  grid-column: 1 / -1 !important;
  width: 100% !important;
  justify-self: stretch !important;
}

button.small {
  padding: 9px 12px !important;
  border-radius: 10px !important;
  font-size: 12px !important;
  line-height: 1.2 !important;
}

button.ghost {
  background: #2a2f3b !important;
  color: #c8cfdb !important;
}

.folder-list {
  gap: 12px !important;
}

.folder.torrent-card,
.torrent-card.folder {
  position: relative !important;
  display: block !important;
  width: 100% !important;
  padding: 16px 60px 15px 16px !important;
  overflow: hidden !important;
  min-height: 0 !important;
}

.torrent-card::before {
  content: "" !important;
  position: absolute !important;
  inset: 0 auto 0 0 !important;
  width: 4px !important;
  background: #2dbd6e !important;
  opacity: .9 !important;
}

.torrent-card.imported::before {
  background: #6e8cff !important;
}

.torrent-card.selected::before {
  background: #6e8cff !important;
}

.select-box-wrap {
  position: absolute !important;
  top: 16px !important;
  right: 16px !important;
  z-index: 10 !important;
  width: 26px !important;
  height: 26px !important;
  display: grid !important;
  place-items: center !important;
  background: #0c1119 !important;
  border: 1px solid #343a49 !important;
  border-radius: 8px !important;
}

.queue-select {
  position: static !important;
  display: block !important;
  width: 16px !important;
  height: 16px !important;
  min-width: 16px !important;
  padding: 0 !important;
  margin: 0 !important;
  cursor: pointer !important;
  accent-color: #2dbd6e !important;
}

.torrent-topline {
  display: grid !important;
  grid-template-columns: 40px minmax(0, 1fr) !important;
  gap: 12px !important;
  align-items: start !important;
  margin: 0 0 8px !important;
  min-width: 0 !important;
}

.torrent-icon {
  grid-column: 1 !important;
  width: 34px !important;
  min-width: 34px !important;
  height: 30px !important;
  display: grid !important;
  place-items: center !important;
  border-radius: 10px !important;
  background: #202634 !important;
  color: #f5f7fb !important;
  font-size: 13px !important;
  font-weight: 950 !important;
  line-height: 1 !important;
  overflow: hidden !important;
  white-space: nowrap !important;
}

.torrent-heading {
  grid-column: 2 !important;
  display: grid !important;
  grid-template-columns: minmax(0, 1fr) auto !important;
  gap: 8px !important;
  align-items: start !important;
  justify-content: stretch !important;
  min-width: 0 !important;
  padding-right: 0 !important;
}

.folder-title {
  display: block !important;
  min-width: 0 !important;
  max-width: 100% !important;
  font-weight: 950 !important;
  line-height: 1.18 !important;
  white-space: normal !important;
  overflow: visible !important;
  text-overflow: clip !important;
  overflow-wrap: anywhere !important;
  padding-right: 0 !important;
}

.year-pill {
  position: static !important;
  justify-self: end !important;
  align-self: start !important;
  flex: 0 0 auto !important;
  width: auto !important;
  min-width: 44px !important;
  max-width: none !important;
  margin: 0 !important;
  padding: 3px 8px !important;
  text-align: center !important;
  white-space: nowrap !important;
  overflow: visible !important;
  text-overflow: clip !important;
}

.release-name,
.torrent-status-row,
.metric-grid {
  margin-left: 52px !important;
  margin-right: 0 !important;
}

.release-name {
  display: block !important;
  margin-bottom: 10px !important;
  color: #7f8aa0 !important;
  font-size: 11px !important;
  line-height: 1.25 !important;
  overflow-wrap: anywhere !important;
}

.torrent-status-row {
  display: flex !important;
  gap: 7px !important;
  flex-wrap: wrap !important;
  align-items: center !important;
  margin-bottom: 10px !important;
}

.metric-grid {
  display: grid !important;
  grid-template-columns: repeat(2, minmax(0, 1fr)) !important;
  gap: 8px !important;
}

.metric-value,
.status-chip,
.mini-pill {
  white-space: nowrap !important;
}

.folder-meta {
  display: block !important;
  margin-left: 52px !important;
  color: #aeb6c5 !important;
  font-size: 13px !important;
}

.torrent-card.imported .select-box-wrap {
  opacity: .35 !important;
  pointer-events: none !important;
}

@media (max-width: 720px) {
  .bulk-toolbar {
    grid-template-columns: 1fr !important;
  }
  .bulk-select-all,
  .selected-count,
  #clearSelectionBtn,
  #bulkMarkImportedBtn {
    grid-column: 1 !important;
    justify-self: stretch !important;
    width: 100% !important;
  }
}
/* end v3.4.5 card layout final reset */

/* v3.4.6 queue/history filtering and counters */
.hidden { display: none !important; }
.history-tab {
  display: flex !important;
  justify-content: space-between !important;
  align-items: center !important;
  gap: 8px !important;
}
.history-tab span {
  background: #242a37;
  color: #aeb6c5;
  border-radius: 999px;
  padding: 2px 7px;
  font-size: 12px;
  font-weight: 900;
}
.history-tab.active span {
  background: #0d2514;
  color: #85f0a3;
}
.history-item strong {
  overflow-wrap: anywhere;
}
/* end v3.4.6 queue/history filtering and counters */

/* v3.4.7.1 force queue tab visibility */
.queue-tabs:has(.queue-tab[data-filter="ready"].active) ~ .folder-list .torrent-card[data-imported="true"] {
  display: none !important;
}

.queue-tabs:has(.queue-tab[data-filter="imported"].active) ~ .folder-list .torrent-card[data-imported="false"] {
  display: none !important;
}
/* end v3.4.7.1 */

/* v3.4.7.2 queue filters are controlled by app/static/app.js */




/* v3.5.0 Smart Import Advisor */
.advisor {
  display: block !important;
  border-left: 5px solid #2dbd6e;
}

.advisor-green {
  border-color: #2dbd6e !important;
  background: linear-gradient(135deg, #102318, #11141b 72%) !important;
}

.advisor-yellow {
  border-color: #ffcc66 !important;
  background: linear-gradient(135deg, #2a2212, #11141b 72%) !important;
}

.advisor-red {
  border-color: #ff7373 !important;
  background: linear-gradient(135deg, #2a1414, #11141b 72%) !important;
}

.advisor-blue {
  border-color: #6e8cff !important;
  background: linear-gradient(135deg, #171f3a, #11141b 72%) !important;
}

.advisor-kicker {
  display: inline-block;
  margin: 0 0 8px;
  padding: 4px 9px;
  border-radius: 999px;
  background: #0c1119;
  border: 1px solid #343a49;
  color: #cfd6e3;
  font-size: 11px;
  font-weight: 950;
  text-transform: uppercase;
  letter-spacing: .04em;
}

.advisor-details {
  margin: 10px 0 12px;
  padding-left: 22px;
  color: #cfd6e3;
}

.advisor-details li {
  margin: 4px 0;
  color: #cfd6e3;
}
/* end v3.5.0 */

/* v3.5.0 Smart Import Advisor */
.smart-queue-tabs {
  grid-template-columns: repeat(5, minmax(0, 1fr)) !important;
}
.advisor-tab {
  font-size: 12px;
  padding: 9px 8px;
}
.torrent-card.advisor-recommended::before { background: #2dbd6e !important; }
.torrent-card.advisor-attention::before { background: #ffcc66 !important; }
.torrent-card.advisor-duplicate::before { background: #d85050 !important; }
.torrent-card.advisor-imported::before { background: #6e8cff !important; }

.status-chip.advisor-chip.recommended {
  background: #12351e;
  color: #85f0a3;
  border-color: #2dbd6e;
}
.status-chip.advisor-chip.attention {
  background: #3a2c0b;
  color: #ffdd88;
  border-color: #ffcc66;
}
.status-chip.advisor-chip.duplicate {
  background: #3a1010;
  color: #ff9b9b;
  border-color: #d85050;
}
.status-chip.advisor-chip.imported {
  background: #1b2b4a;
  color: #9db3ff;
  border-color: #375dae;
}
.advisor-reason {
  max-width: 100%;
  white-space: normal !important;
  overflow-wrap: anywhere;
}
.advisor-panel {
  width: 100%;
}
.advisor-panel h3 {
  margin: 0;
}
.advisor-heading-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  margin-bottom: 8px;
}
.advisor-headline {
  color: #f5f7fb;
  font-size: 17px;
  font-weight: 900;
  margin: 0 0 10px !important;
}
.advisor-chip-row {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 8px;
  margin: 12px 0;
}
.advisor-mini-chip {
  display: block;
  background: #0c1119;
  border: 1px solid #2b303d;
  border-radius: 11px;
  padding: 9px;
  color: #dce6f7;
  font-weight: 850;
}
.advisor-mini-chip strong {
  display: block;
  color: #778399;
  font-size: 10px;
  font-weight: 950;
  text-transform: uppercase;
  letter-spacing: .04em;
  margin-bottom: 3px;
}
.advisor-facts,
.advisor-warnings {
  margin: 10px 0;
  padding: 10px;
  border-radius: 12px;
  background: #0c1119;
  border: 1px solid #2b303d;
}
.advisor-facts p,
.advisor-warnings p {
  margin: 0 0 6px !important;
}
.advisor-facts p:last-child,
.advisor-warnings p:last-child {
  margin-bottom: 0 !important;
}
.advisor-warnings {
  border-color: #ffcc66;
}
.preview-table tr.preview-duplicate td {
  background: rgba(216, 80, 80, 0.08);
}
.preview-table tr.preview-ready td {
  background: rgba(45, 189, 110, 0.05);
}
button.danger {
  background: #8b2f2f;
}
@media (max-width: 720px) {
  .smart-queue-tabs {
    grid-template-columns: 1fr 1fr !important;
  }
  .advisor-chip-row {
    grid-template-columns: 1fr;
  }
}
/* end v3.5.0 Smart Import Advisor */

/* v3.5.0.1 queue filter button polish */
.queue-tabs.smart-queue-tabs {
  display: grid !important;
  grid-template-columns: repeat(2, minmax(0, 1fr)) !important;
  gap: 9px !important;
  margin: 14px 0 12px !important;
}

.smart-queue-tabs .advisor-tab {
  min-width: 0 !important;
  width: 100% !important;
  display: flex !important;
  align-items: center !important;
  justify-content: space-between !important;
  gap: 8px !important;
  padding: 10px 11px !important;
  border-radius: 13px !important;
  font-size: 13px !important;
  line-height: 1.15 !important;
  letter-spacing: 0 !important;
  white-space: nowrap !important;
  overflow: hidden !important;
  text-overflow: ellipsis !important;
}

.smart-queue-tabs .advisor-tab.all {
  grid-column: 1 / -1 !important;
}

.smart-queue-tabs .advisor-tab span {
  flex: 0 0 auto !important;
  display: inline-flex !important;
  align-items: center !important;
  justify-content: center !important;
  min-width: 26px !important;
  padding: 2px 7px !important;
  margin-left: 4px !important;
  border-radius: 999px !important;
  font-size: 11px !important;
  font-weight: 950 !important;
  background: #242a37 !important;
  color: #cfd6e3 !important;
}

.smart-queue-tabs .advisor-tab.recommended.active {
  border-color: #2dbd6e !important;
  background: #12351e !important;
  color: #85f0a3 !important;
}
.smart-queue-tabs .advisor-tab.recommended.active span {
  background: #0d2514 !important;
  color: #85f0a3 !important;
}

.smart-queue-tabs .advisor-tab.attention.active {
  border-color: #ffcc66 !important;
  background: #3a2c0b !important;
  color: #ffdd88 !important;
}
.smart-queue-tabs .advisor-tab.attention.active span {
  background: #211906 !important;
  color: #ffdd88 !important;
}

.smart-queue-tabs .advisor-tab.duplicate.active {
  border-color: #d85050 !important;
  background: #3a1010 !important;
  color: #ff9b9b !important;
}
.smart-queue-tabs .advisor-tab.duplicate.active span {
  background: #230909 !important;
  color: #ff9b9b !important;
}

.smart-queue-tabs .advisor-tab.imported.active {
  border-color: #375dae !important;
  background: #1b2b4a !important;
  color: #9db3ff !important;
}
.smart-queue-tabs .advisor-tab.imported.active span {
  background: #111d35 !important;
  color: #9db3ff !important;
}

.smart-queue-tabs .advisor-tab.all.active {
  border-color: #6e8cff !important;
  background: #1f2740 !important;
  color: #cbd6ff !important;
}
.smart-queue-tabs .advisor-tab.all.active span {
  background: #151b2e !important;
  color: #cbd6ff !important;
}

@media (max-width: 720px) {
  .queue-tabs.smart-queue-tabs {
    grid-template-columns: 1fr !important;
  }
  .smart-queue-tabs .advisor-tab.all {
    grid-column: 1 !important;
  }
}
/* end v3.5.0.1 queue filter button polish */

/* v3.5.0.2 queue filter visibility fix */
#queueList .folder.torrent-card.hidden,
#queueList .torrent-card.folder.hidden,
#queueList .folder.torrent-card[hidden],
#queueList .torrent-card.folder[hidden],
.folder-list .folder.torrent-card.hidden,
.folder-list .torrent-card.folder.hidden,
.folder-list .folder.torrent-card[hidden],
.folder-list .torrent-card.folder[hidden] {
  display: none !important;
}
/* end v3.5.0.2 queue filter visibility fix */

/* v3.6.0 Multi-Item Import Manager */
.multi-import-manager {
  margin: 16px 0 10px;
}
.multi-manager-card {
  border: 1px solid #343a49;
  background: #10141d;
  border-radius: 16px;
  padding: 14px;
}
.multi-manager-head {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  gap: 12px;
  margin-bottom: 12px;
}
.multi-manager-head h3 {
  margin: 0 0 5px;
}
.multi-manager-head p,
.multi-help {
  margin: 0;
  color: #aeb6c5;
  font-size: 13px;
}
.multi-help {
  margin-top: 10px;
}
.multi-table-wrap {
  overflow: auto;
  border: 1px solid #2b303d;
  border-radius: 13px;
  background: #0b0d12;
}
.multi-import-table {
  width: 100%;
  min-width: 980px;
  border-collapse: collapse;
  font-size: 12px;
}
.multi-import-table th,
.multi-import-table td {
  text-align: left;
  vertical-align: top;
  border-bottom: 1px solid #262b36;
  padding: 9px;
}
.multi-import-table th {
  color: #9db3d9;
  background: #111620;
  position: sticky;
  top: 0;
  z-index: 2;
}
.multi-import-table td {
  overflow-wrap: anywhere;
}
.multi-import-table tr:last-child td {
  border-bottom: 0;
}
.multi-import-table small {
  display: block;
  margin-top: 4px;
  color: #7f8aa0;
  line-height: 1.25;
}
.multi-import-table input {
  width: 100%;
  min-width: 90px;
  padding: 9px;
  border-radius: 9px;
  font-size: 13px;
}
.multi-import-table .multi-title {
  min-width: 170px;
}
.multi-import-table .multi-imdb {
  min-width: 120px;
}
.multi-import-table .multi-year,
.multi-import-table .multi-season {
  min-width: 68px;
}
.multi-check-cell {
  text-align: center !important;
}
.multi-enabled {
  width: 17px !important;
  min-width: 17px !important;
  height: 17px;
  padding: 0 !important;
  margin: 3px auto 0 !important;
  accent-color: #2dbd6e;
}
.multi-destination {
  min-width: 220px;
  color: #cfd6e3;
  font-weight: 750;
}
.multi-status {
  display: inline-flex;
  white-space: nowrap;
}
.muted-dash {
  display: inline-block;
  color: #778399;
  padding: 9px 0;
}
.status-chip.advisor-chip.error {
  background: #3a1010;
  color: #ff9b9b;
  border-color: #d85050;
}
@media (max-width: 720px) {
  .multi-manager-head {
    display: block;
  }
  .multi-import-table {
    min-width: 900px;
  }
}
/* end v3.6.0 Multi-Item Import Manager */
'@

Write-Utf8File -RelativePath 'app\templates\index.html' -Content @'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{{ app_name }} {{ version }}</title>
  <link rel="stylesheet" href="/static/style.css?v={{ version }}-multi-item">
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
              Smart queue sorted by recommendation, attention, duplicate, and imported status.
            </p>
          </div>
          <span>{{ items|length }} total</span>
        </div>

        {% set recommended_count = namespace(value=0) %}
        {% set attention_count = namespace(value=0) %}
        {% set duplicate_count = namespace(value=0) %}
        {% set imported_count = namespace(value=0) %}
        {% for item in items %}
          {% set level = item.advisor_level if item.advisor_level else ('imported' if item.imported else 'recommended') %}
          {% if item.imported or level == 'imported' %}
            {% set imported_count.value = imported_count.value + 1 %}
          {% elif level == 'duplicate' %}
            {% set duplicate_count.value = duplicate_count.value + 1 %}
          {% elif level == 'attention' %}
            {% set attention_count.value = attention_count.value + 1 %}
          {% else %}
            {% set recommended_count.value = recommended_count.value + 1 %}
          {% endif %}
        {% endfor %}

        <div class="queue-tabs smart-queue-tabs" role="tablist" aria-label="Smart queue filters">
          <button class="queue-tab active advisor-tab recommended" type="button" data-filter="recommended">
            Recommended <span>{{ recommended_count.value }}</span>
          </button>
          <button class="queue-tab advisor-tab attention" type="button" data-filter="attention">
            Attention <span>{{ attention_count.value }}</span>
          </button>
          <button class="queue-tab advisor-tab duplicate" type="button" data-filter="duplicate">
            Duplicate <span>{{ duplicate_count.value }}</span>
          </button>
          <button class="queue-tab advisor-tab imported" type="button" data-filter="imported">
            Imported <span>{{ imported_count.value }}</span>
          </button>
          <button class="queue-tab advisor-tab all" type="button" data-filter="all">
            All <span>{{ items|length }}</span>
          </button>
        </div>

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
              {% set level = item.advisor_level if item.advisor_level else ('imported' if item.imported else 'recommended') %}
              {% set label = item.advisor_label if item.advisor_label else ('Imported' if item.imported else 'Recommended') %}
              <button
                class="folder torrent-card advisor-{{ level }} {% if item.imported %}imported{% endif %}"
                type="button"
                data-source="{{ item.path }}"
                data-source-key="{{ item.source_key if item.source_key else item.path }}"
                data-title="{{ item.title }}"
                data-year="{{ item.year }}"
                data-season="{{ item.season }}"
                data-type="{{ item.type }}"
                data-imported="{% if item.imported %}true{% else %}false{% endif %}"
                data-advisor-level="{{ level }}"
                data-advisor-label="{{ label }}"
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
                  <span class="status-chip advisor-chip {{ level }}">{{ label }}</span>
                  <span class="mini-pill">{{ item.type_label }}</span>
                  <span class="mini-pill">{{ item.video_count }} video{% if item.video_count != 1 %}s{% endif %}</span>
                  {% if item.advisor_reason %}
                    <span class="mini-pill advisor-reason">{{ item.advisor_reason }}</span>
                  {% endif %}
                </span>

                {% if qbittorrent_enabled %}
                  <span class="metric-grid">
                    <span class="metric">
                      <span class="metric-label">Ratio</span>
                      <span class="metric-value">{{ item.ratio }}</span>
                    </span>
                    <span class="metric">
                      <span class="metric-label">State</span>
                      <span class="metric-value">{{ item.state if item.state else "-" }}</span>
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
          <input type="hidden" id="duplicatePolicy" name="duplicate_policy" value="skip">
          <input type="hidden" id="multiItems" name="multi_items" value="">

          <label>Media Type</label>
          <div class="segmented">
            <label>
              <input type="radio" name="media_type" value="tv" checked>
              <span>TV Show</span>
            </label>
            <label>
              <input type="radio" name="media_type" value="movie">
              <span>Movie</span>
            </label>
          </div>

          <div id="singleImportFields">
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
          </div>

          <div id="multiImportManager" class="multi-import-manager hidden"></div>

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
            <button id="markImportedBtn" class="secondary" type="button">Mark Imported</button>
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
        <div class="history-tabs" role="tablist" aria-label="Import history filters">
          <button class="history-tab active" type="button" data-history-filter="success">
            Success <span>{{ success_count.value }}</span>
          </button>
          <button class="history-tab" type="button" data-history-filter="error">
            Errors <span>{{ error_count.value }}</span>
          </button>
          <button class="history-tab" type="button" data-history-filter="all">
            All <span>{{ history_total_count.value }}</span>
          </button>
        </div>

        <div class="history" id="historyList">
          {% if history %}
            {% for item in history %}
              {% set htype = 'error' if item.status == 'error' or item.type == 'error' else 'success' %}
              <div class="history-item {% if htype == 'error' %}bad{% else %}success{% endif %}" data-history-type="{{ htype }}">
                <strong>
                  {% if htype == 'error' %}Error{% elif item.type == 'tv' %}TV{% elif item.type == 'movie' %}Movie{% else %}Import{% endif %}
                  - {{ item.title }}
                </strong>
                <span>{{ item.time }}</span>
                {% if htype == 'error' %}
                  <small>{{ item.error }}</small>
                {% else %}
                  <small>
                    {{ item.count }} link(s)
                    {% if item.skipped %}, {{ item.skipped }} skipped{% endif %}
                    -> {{ item.destination }}
                  </small>
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

  <script src="/static/app.js?v={{ version }}-multi-item"></script>
</body>
</html>
'@


Write-Host ""
Write-Host "NASDY Media Linker v3.6.0 upgrade applied." -ForegroundColor Green
Write-Host "Backup created at: $BackupDir"
Write-Host "Restart the NASDY Media Linker app/container so the new Python, template, CSS, and JS files are loaded."
