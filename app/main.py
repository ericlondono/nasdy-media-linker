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
