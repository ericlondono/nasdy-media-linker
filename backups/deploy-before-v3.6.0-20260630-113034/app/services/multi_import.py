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