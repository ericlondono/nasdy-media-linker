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
from app.services.jellyfin import jellyfin_refresh, test_jellyfin, normalize_jellyfin_url
from app.services.qbittorrent import normalize_source_path
from app.services.qbittorrent import test_qbit
from app.services.library import find_library_match
from app.services.advisor import analyze_import
from app.services.logger import read_log, log
from app.services.multi_import import build_multi_import_preview, preview_multi_rows, public_multi_import_payload
from app.services.hardlink_reconcile import reconciled_import_record

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
        "headline": preview.get("title") or "Import Manager",
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
        "jellyfin_enabled": bool(normalize_jellyfin_url(settings.get("jellyfin_url", "")) and settings.get("jellyfin_api_key")),
        "qbittorrent_enabled": bool(settings.get("qbittorrent_enabled")),
        **counts,
    })


@app.get("/settings", response_class=HTMLResponse)
def settings_page(request: Request):
    settings = load_settings()
    settings["jellyfin_url"] = normalize_jellyfin_url(settings.get("jellyfin_url", ""))
    return templates.TemplateResponse("settings.html", {
        "request": request,
        "app_name": APP_NAME,
        "version": APP_VERSION,
        "settings": settings,
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
        "jellyfin_url": normalize_jellyfin_url(jellyfin_url),
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


@app.post("/api/jellyfin/test")
async def api_jellyfin_test(request: Request):
    data = await request.json()
    settings = load_settings()
    settings.update(data)
    ok, msg = test_jellyfin(settings)
    return JSONResponse({"ok": ok, "message": msg})


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
        if not imported:
            try:
                imported = reconciled_import_record(
                    media_type=media_type,
                    source=source,
                    source_key=source_key,
                    title=title,
                    year=year,
                    season=season,
                )
            except Exception as reconcile_error:
                log(f"WARN hardlink reconcile preview skipped: {reconcile_error}")

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
async def api_jellyfin_refresh(request: Request):
    settings = load_settings()
    try:
        data = await request.json()
        if isinstance(data, dict):
            settings.update(data)
    except Exception:
        pass
    ok, msg = jellyfin_refresh(settings)
    return JSONResponse({"ok": ok, "message": msg})


@app.get("/health")
def health():
    return {
        "ok": True,
        "name": APP_NAME,
        "version": APP_VERSION,
    }