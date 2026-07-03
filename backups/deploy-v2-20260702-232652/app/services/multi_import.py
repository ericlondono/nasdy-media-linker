from pathlib import Path
from typing import Any, Dict, List, Optional
import re

from app.services.library import find_library_match
from app.services.linker import build_plan
from app.services.tmdb import tmdb_search_with_imdb, tmdb_search_best_any, tmdb_lookup_identifier
from app.services.quality import quality_advice_for_import
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


TV_EPISODE_PATTERN = re.compile(
    r"\bS0*(?P<s_season>\d{1,2})\s*E\s*(?P<s_episode>\d{1,3})\b|\b0*(?P<x_season>\d{1,2})\s*x\s*(?P<x_episode>\d{1,3})\b",
    re.I,
)


def _explicit_season_number(value: Any, default: str = "") -> str:
    """Return a season only when the text contains an explicit season signal."""
    text = str(value or "").strip()
    if not text:
        return default

    patterns = [
        r"\bS0*(\d{1,2})\s*E\s*\d{1,3}\b",
        r"\bS0*(\d{1,2})\b",
        r"\b(?:Season|Series)[ ._\-]*0*(\d{1,2})\b",
        r"\b0*(\d{1,2})\s*x\s*\d{1,3}\b",
    ]

    for pattern in patterns:
        match = re.search(pattern, text, re.I)
        if match:
            try:
                return f"{int(match.group(1)):02d}"
            except Exception:
                return default

    return default


def _season_number(value: Any, default: str = "01") -> str:
    explicit = _explicit_season_number(value, "")
    if explicit:
        return explicit

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
    return _explicit_season_number(name, "") or None


def _season_from_videos(path: Path) -> Optional[str]:
    try:
        videos = find_videos(path)
    except Exception:
        videos = []

    counts: Dict[str, int] = {}
    for video in videos[:100]:
        season = _explicit_season_number(f"{video.name} {video.parent.name}", "")
        if season:
            counts[season] = counts.get(season, 0) + 1

    if not counts:
        return None
    return sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))[0][0]


def _clean_media_title(value: str) -> str:
    text = strip_release_words(value or "")
    text = re.sub(r"[\(\[\{]?\b(19\d{2}|20\d{2})\b[\)\]\}]?", " ", text)
    text = re.sub(r"\s+", " ", text).strip(" ._-()[]{}")
    return title_case_guess(text) if text else strip_release_words(value or "")


def _clean_tv_show_title(value: Any) -> str:
    text = str(value or "").strip()
    if not text:
        return ""

    text = strip_release_words(text)
    text = re.sub(r"\b(?:Season|Series)[ ._\-]*0*\d{1,2}\b.*$", " ", text, flags=re.I)
    text = re.sub(r"\bS0*\d{1,2}\b.*$", " ", text, flags=re.I)
    text = re.sub(r"\b0*\d{1,2}\s*x\s*\d{1,3}\b.*$", " ", text, flags=re.I)
    text = re.sub(
        r"\b(?:Complete(?:[ ._\-]*(?:Series|Season|Collection))?|All[ ._\-]*Seasons?|Full[ ._\-]*Series|Collection|Box[ ._\-]*Set|Pack)\b.*$",
        " ",
        text,
        flags=re.I,
    )
    text = re.sub(r"\b(?:DVD|DVDRip|BluRay|WEB[- ._]?DL|WEBRip|HDTV|x264|x265|XviD)\b.*$", " ", text, flags=re.I)
    text = re.sub(r"[._]+", " ", text)
    text = re.sub(r"\s+", " ", text).strip(" -_.()[]{}")
    return title_case_guess(text) if text else ""


def _tv_title_key(value: Any) -> str:
    return re.sub(r"[^a-z0-9]+", "", str(value or "").lower())


def _tv_title_looks_polluted(value: Any) -> bool:
    return bool(re.search(
        r"\b(?:complete|all[ ._\-]*seasons?|full[ ._\-]*series|collection|box[ ._\-]*set|pack|season[ ._\-]*\d+|series[ ._\-]*\d+|S\d{1,2}|dvd|dvdrip|xvid|webrip|web[- ._]?dl|hdtv|bluray)\b",
        str(value or ""),
        re.I,
    ))


def _episode_show_title_from_filename(path: Any) -> str:
    stem = Path(str(path or "")).stem
    if not stem:
        return ""

    match = re.search(
        r"^(?P<title>.+?)(?:\s*[-._]+\s*|\s+)(?:S0*\d{1,2}\s*E\s*\d{1,3}|0*\d{1,2}\s*x\s*\d{1,3})\b",
        stem,
        re.I,
    )
    if not match:
        return ""

    return _clean_tv_show_title(match.group("title"))


def _best_tv_show_title(fallback_title: str, source_path: Path, videos: Optional[List[Path]] = None) -> str:
    explicit_raw = str(fallback_title or "").strip()
    explicit = _clean_tv_show_title(explicit_raw)

    candidates: List[str] = []
    for video in list(videos or [])[:30]:
        candidate = _episode_show_title_from_filename(video.name)
        if candidate:
            candidates.append(candidate)

    for raw in (
        getattr(source_path, "name", ""),
        getattr(getattr(source_path, "parent", None), "name", ""),
    ):
        candidate = _clean_tv_show_title(raw)
        if candidate and candidate.lower() not in {"downloads", "download", "tv", "television", "media"}:
            candidates.append(candidate)

    cleaned: List[str] = []
    seen = set()
    for candidate in candidates:
        candidate = _clean_tv_show_title(candidate)
        key = _tv_title_key(candidate)
        if not candidate or not key or key in seen:
            continue
        seen.add(key)
        cleaned.append(candidate)

    if explicit:
        explicit_key = _tv_title_key(explicit)
        if not _tv_title_looks_polluted(explicit_raw):
            for candidate in cleaned:
                if _tv_title_key(candidate) == explicit_key and len(candidate) > len(explicit):
                    return candidate
            return explicit
        return explicit

    if cleaned:
        return cleaned[0]

    return explicit_raw


def _clean_parent_title(value: str) -> str:
    return _clean_tv_show_title(value or "") or strip_release_words(value or "")

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
    try:
        parent_videos = find_videos(source_path)
    except Exception:
        parent_videos = []

    parent_title = _best_tv_show_title(fallback_title or "", source_path, parent_videos) or _clean_parent_title(source_path.name)
    parent_year = fallback_year or detect_year(source_path.name)

    season_children = []
    for child in _child_dirs_with_videos(source_path):
        season = _season_from_folder(child.name) or _season_from_videos(child)
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


def _identifier_input(row: Dict[str, Any]) -> str:
    for key in ("imdb_id", "tmdb_id"):
        value = str((row or {}).get(key) or "").strip()
        if value:
            return value
    return ""


def _row_has_metadata_identifier(row: Dict[str, Any]) -> bool:
    return bool(_identifier_input(row))


def _source_tv_signal(row: Dict[str, Any]) -> bool:
    source = Path(str((row or {}).get("source") or ""))
    texts = [
        str((row or {}).get("detected") or ""),
        str((row or {}).get("title") or ""),
        source.name,
        str(source),
    ]

    try:
        videos = find_videos(source) if source.exists() else []
    except Exception:
        videos = []

    episode_like = 0
    season_like = 0
    for video in videos[:80]:
        text = f"{video.name} {video.parent.name}"
        texts.append(text)
        if TV_EPISODE_PATTERN.search(text):
            episode_like += 1
        if _explicit_season_number(text, ""):
            season_like += 1

    combined = " ".join(texts)
    if TV_EPISODE_PATTERN.search(combined):
        return True

    if episode_like >= 2:
        return True

    if videos and season_like >= max(2, min(5, len(videos) // 2)):
        return True

    return False

def _filename_movie_title_year(value: Any) -> Dict[str, str]:
    text = str(value or "")
    stem = Path(text).stem if text else ""
    cleaned = re.sub(r"[._]+", " ", stem)
    cleaned = re.sub(r"\s+", " ", cleaned).strip()

    year_match = re.search(r"[\(\[\{]?\b(19\d{2}|20\d{2})\b[\)\]\}]?", cleaned)
    year = year_match.group(1) if year_match else ""

    if year_match:
        title_part = cleaned[:year_match.start()]
    else:
        title_part = cleaned

    title_part = re.sub(
        r"\b(?:1080p|720p|2160p|4320p|4k|8k|uhd|bluray|blu ray|web dl|webdl|webrip|hdtv|remux|hevc|x265|x264|h264|h265|avc|hdr|dd5 1|dts|truehd|atmos)\b.*$",
        "",
        title_part,
        flags=re.I,
    )
    title_part = re.sub(r"[-_]+", " ", title_part)
    title_part = re.sub(r"\s+", " ", title_part).strip(" -_.()[]{}")
    title = title_case_guess(title_part) if title_part else title_case_guess(stem)

    return {"title": title, "year": year}

def _source_movie_signal(row: Dict[str, Any]) -> bool:
    """
    Detect movie-pack rows inside a TV-heavy mixed folder.

    Example:
    Stargate - The Movies/
      Stargate (1994).mkv
      Stargate Continuum (2008).mkv
      Stargate The Ark of Truth (2008).mkv

    These have years and no SxxEyy episode pattern, so they should route as movies,
    not as S01E01/S01E02 TV episodes.
    """
    source = Path(str((row or {}).get("source") or ""))

    try:
        videos = find_videos(source) if source.exists() else []
    except Exception:
        videos = []

    if not videos:
        return False

    texts = [
        str((row or {}).get("detected") or ""),
        str((row or {}).get("title") or ""),
        source.name,
        str(source),
    ]

    path_text = " ".join(texts).lower()
    path_movie_word = bool(re.search(r"\b(movie|movies|film|films|trilogy|duology)\b", path_text, re.I))

    episode_like = 0
    year_like = 0
    direct_like = 0
    distinct_titles = set()

    for video in videos[:100]:
        try:
            rel = video.relative_to(source)
            if len(rel.parts) == 1:
                direct_like += 1
        except Exception:
            pass

        text = f"{video.name} {video.parent.name}"
        if re.search(r"\bS\d{1,2}\s*E\s*\d{1,3}\b|\b\d{1,2}\s*x\s*\d{1,3}\b", text, re.I):
            episode_like += 1
            continue

        parsed = _filename_movie_title_year(video.name)
        if parsed.get("year"):
            year_like += 1
        if parsed.get("title"):
            distinct_titles.add(parsed.get("title", "").lower())

    # A real TV folder should not be forced to movie if most files have episode patterns.
    if episode_like >= max(1, len(videos) // 3):
        return False

    # Strong signal: a direct folder of multiple year-bearing movie files.
    if len(videos) >= 2 and year_like >= 2 and direct_like >= 2:
        return True

    # Strong signal: path says movies/films and files do not look episodic.
    if path_movie_word and episode_like == 0:
        return True

    # Single movie folder/file inside a mixed pack.
    if len(videos) == 1 and year_like == 1 and episode_like == 0:
        return True

    # Multiple distinct non-episode titles with years are likely a movie pack.
    if year_like >= 2 and len(distinct_titles) >= 2 and episode_like == 0:
        return True

    return False

def _infer_tv_season_from_source(row: Dict[str, Any]) -> str:
    # Do not trust the normalized default row season first. A default "01" can
    # mask a filename like 5x01, so inspect detected/source/video signals first.
    for value in (
        (row or {}).get("detected"),
        (row or {}).get("source"),
    ):
        season = _explicit_season_number(value, "")
        if season:
            return season

    source = Path(str((row or {}).get("source") or ""))
    try:
        videos = find_videos(source) if source.exists() else []
    except Exception:
        videos = []

    counts: Dict[str, int] = {}
    for video in videos[:100]:
        season = _explicit_season_number(f"{video.name} {video.parent.name}", "")
        if season:
            counts[season] = counts.get(season, 0) + 1

    if counts:
        return sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))[0][0]

    season = _explicit_season_number((row or {}).get("season"), "")
    if season:
        return season

    return "01"

def _apply_metadata_to_row(row: Dict[str, Any], metadata: Dict[str, Any], source_label: str = "") -> Dict[str, Any]:
    row = dict(row)
    old_media_type = "tv" if row.get("media_type") == "tv" else "movie"
    new_media_type = "tv" if (metadata or {}).get("media_type") == "tv" else "movie"

    row["media_type"] = new_media_type
    row["media_type_label"] = "TV Show" if new_media_type == "tv" else "Movie"
    row["tmdb_id"] = str((metadata or {}).get("id") or row.get("tmdb_id") or "")
    row["imdb_id"] = (metadata or {}).get("imdb_id") or (row.get("imdb_id") if str(row.get("imdb_id") or "").lower().startswith("tt") else "")
    row["title"] = (metadata or {}).get("title") or row.get("title", "")
    row["year"] = (metadata or {}).get("year") or row.get("year", "")
    row["poster"] = (metadata or {}).get("poster") or row.get("poster", "")
    row["match_score"] = (metadata or {}).get("match_score") or row.get("match_score") or ""
    row["match_confidence"] = (metadata or {}).get("match_confidence") or row.get("match_confidence") or ""
    row["confidence_level"] = (metadata or {}).get("confidence_level") or row.get("confidence_level") or ""
    row["confidence_label"] = (metadata or {}).get("confidence_label") or row.get("confidence_label") or ""
    row["alternatives"] = (metadata or {}).get("alternatives") or row.get("alternatives") or []

    if new_media_type == "tv":
        row["season"] = _infer_tv_season_from_source(row)
    else:
        row["season"] = ""

    route_changed = old_media_type != new_media_type
    label = (metadata or {}).get("route_label") or source_label or ""
    if label:
        row["route_reason"] = label

    confidence = 0
    try:
        confidence = int(row.get("match_confidence") or 0)
    except Exception:
        confidence = 0

    if route_changed:
        row["match_status"] = f"Auto routed as {'TV show' if new_media_type == 'tv' else 'Movie'}"
        row["match_level"] = "good" if confidence >= 85 or row.get("imdb_id") else "warning"
    elif row.get("imdb_id") and confidence >= 85:
        row["match_status"] = "Auto matched"
        row["match_level"] = "good"
    elif row.get("imdb_id"):
        row["match_status"] = "Review match"
        row["match_level"] = "warning"
    elif row.get("tmdb_id"):
        row["match_status"] = "Matched; IMDb unavailable"
        row["match_level"] = "warning"
    else:
        row["match_status"] = "Needs match"
        row["match_level"] = "warning"

    return row



def _is_direct_child(base: Path, path: Path) -> bool:
    try:
        return len(path.relative_to(base).parts) == 1
    except Exception:
        return False


def _direct_movie_file_candidates(row: Dict[str, Any]) -> List[Path]:
    """
    Return direct child movie files that should become individual editable rows.

    This deliberately excludes TV episode-looking files. It is intended for folders like:
      Stargate - The Movies/
        Stargate (1994).mkv
        Stargate Continuum (2008).mkv
        Stargate The Ark of Truth (2008).mkv
    """
    source = Path(str((row or {}).get("source") or ""))
    if not source.exists() or not source.is_dir():
        return []

    try:
        videos = find_videos(source)
    except Exception:
        return []

    direct_videos = [video for video in videos if _is_direct_child(source, video)]
    if len(direct_videos) < 2:
        return []

    episode_like = 0
    year_like = 0
    distinct_titles = set()

    for video in direct_videos[:100]:
        text = video.name
        if re.search(r"\bS\d{1,2}\s*E\s*\d{1,3}\b|\b\d{1,2}\s*x\s*\d{1,3}\b", text, re.I):
            episode_like += 1
            continue

        parsed = _filename_movie_title_year(video.name)
        if parsed.get("year"):
            year_like += 1
        if parsed.get("title"):
            distinct_titles.add(parsed.get("title", "").lower())

    if episode_like:
        return []

    source_text = f"{source.name} {source}".lower()
    movie_word = bool(re.search(r"\b(movie|movies|film|films|trilogy|duology)\b", source_text, re.I))

    if year_like >= 2 and len(distinct_titles) >= 2:
        return sorted(direct_videos, key=lambda p: str(p).lower())

    if movie_word and year_like >= 1:
        return sorted(direct_videos, key=lambda p: str(p).lower())

    return []


def _expand_direct_movie_file_rows(rows: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """
    Split direct movie-file packs into one Import Manager row per movie file.

    The linker already knows how to route those files to /media/movies, but a single
    grouped row means one IMDb/TMDb field is shared by all movies. Splitting here gives
    each movie its own editable metadata row before preview/import.
    """
    expanded: List[Dict[str, Any]] = []

    for raw in rows or []:
        row = dict(raw or {})

        # Rows created by this splitter are already one file per row.
        if row.get("split_from_movie_pack"):
            expanded.append(row)
            continue

        candidates = _direct_movie_file_candidates(row)
        if len(candidates) < 2:
            expanded.append(row)
            continue

        parent_source = str(row.get("source") or "")
        parent_title = str(row.get("title") or row.get("detected") or Path(parent_source).name)

        for index, video in enumerate(candidates, start=1):
            parsed = _filename_movie_title_year(video.name)
            title = parsed.get("title") or parent_title or video.stem
            year = parsed.get("year") or str(row.get("year") or "")

            child = dict(row)
            child.update({
                "row_id": f"{row.get('row_id') or 'movie-pack'}-file-{index}",
                "enabled": row.get("enabled", True),
                "media_type": "movie",
                "media_type_label": "Movie",
                "source": str(video),
                "source_key": str(video),
                "parent_source": parent_source,
                "detected": video.stem,
                "title": title,
                "year": year,
                "season": "",
                "imdb_id": "",
                "tmdb_id": "",
                "alternatives": [],
                "match_status": "",
                "match_level": "",
                "match_score": "",
                "match_confidence": "",
                "confidence_level": "",
                "confidence_label": "",
                "file_count": 1,
                "split_from_movie_pack": True,
                "route_reason": "Direct movie file split from mixed pack",
            })
            expanded.append(child)

    return expanded

def _route_by_filesystem_signal(row: Dict[str, Any]) -> Dict[str, Any]:
    row = dict(row)
    if _source_tv_signal(row):
        row["media_type"] = "tv"
        row["media_type_label"] = "TV Show"
        row["season"] = _infer_tv_season_from_source(row)
        row["match_status"] = row.get("match_status") or "Routed by episode pattern"
        row["match_level"] = row.get("match_level") or "warning"
        row["route_reason"] = "Episode pattern detected"
    elif _source_movie_signal(row):
        row["media_type"] = "movie"
        row["media_type_label"] = "Movie"
        row["season"] = ""
        row["match_status"] = row.get("match_status") or "Routed by movie filename pattern"
        row["match_level"] = row.get("match_level") or "warning"
        row["route_reason"] = "Movie filename pattern detected"
    else:
        row["media_type"] = "movie" if row.get("media_type") == "movie" else row.get("media_type", "movie")
        if row.get("media_type") != "tv":
            row["media_type_label"] = "Movie"
            row["season"] = ""
    return row


def _apply_tmdb_match(settings: Dict[str, Any], row: Dict[str, Any], allow_search: bool = True) -> Dict[str, Any]:
    row = dict(row)

    identifier = _identifier_input(row)
    metadata = None

    if identifier:
        metadata = tmdb_lookup_identifier(
            settings,
            identifier,
            preferred_media_type=row.get("media_type", ""),
            query_title=row.get("title", ""),
            query_year=row.get("year", ""),
        )
    elif allow_search:
        metadata = tmdb_search_best_any(
            settings,
            row.get("title", ""),
            row.get("year", ""),
            preferred_media_type=row.get("media_type", ""),
        )

    if metadata:
        return _apply_metadata_to_row(
            row,
            metadata,
            source_label="ID resolved" if identifier else "Auto routed",
        )

    row = _route_by_filesystem_signal(row)

    if identifier:
        row["match_status"] = row.get("match_status") or "ID lookup unavailable"
        row["match_level"] = row.get("match_level") or "warning"
        row["confidence_level"] = row.get("confidence_level") or "low"
        row["confidence_label"] = row.get("confidence_label") or "Identifier not resolved"
        row["alternatives"] = row.get("alternatives") or []
        return row

    if allow_search:
        row["match_status"] = row.get("match_status") or "Needs match"
        row["match_level"] = row.get("match_level") or "warning"
        row["match_confidence"] = row.get("match_confidence") or ""
        row["confidence_level"] = row.get("confidence_level") or "low"
        row["confidence_label"] = row.get("confidence_label") or "No TMDb match"
        row["alternatives"] = row.get("alternatives") or []

    return row

def _normalize_row(row: Dict[str, Any], index: int) -> Dict[str, Any]:
    media_type = "movie" if row.get("media_type") == "movie" else "tv"
    source = str(row.get("source") or "").strip()
    title = str(row.get("title") or "").strip()
    year = str(row.get("year") or "").strip()
    season = "" if media_type == "movie" else _season_number(row.get("season") or "01")
    imdb_id = str(row.get("imdb_id") or "").strip()

    if media_type == "tv":
        source_path = Path(source or "")
        try:
            videos = find_videos(source_path) if source_path.exists() else []
        except Exception:
            videos = []
        title = _best_tv_show_title(title, source_path, videos) or title

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

def _legacy_status_from_plan(row: Dict[str, Any], planned_items: List[Dict[str, Any]], library_match: Optional[Dict[str, Any]], error: str = "") -> Dict[str, Any]:
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



def _quality_summary(quality_part: Optional[Dict[str, Any]]) -> str:
    quality_part = quality_part or {}
    summary = str(quality_part.get("summary") or "").strip()
    if summary and summary.lower() != "unknown quality":
        return summary
    tags = quality_part.get("tags") or []
    if tags:
        return " ".join(str(tag) for tag in tags if str(tag).strip())
    return ""


def _confidence_percent(row: Dict[str, Any]) -> Optional[int]:
    for key in ("match_confidence", "match_score"):
        value = row.get(key)
        if value in ("", None):
            continue
        try:
            number = int(float(value))
            if number > 100:
                # Older local TMDb scores can exceed 100. Clamp for display.
                number = 100
            if number < 0:
                number = 0
            return number
        except Exception:
            continue
    return None


def _status_card(state: str, icon: str, label: str, lines: List[str]) -> Dict[str, Any]:
    clean_lines = []
    for line in lines or []:
        text = str(line or "").strip()
        if text and text not in clean_lines:
            clean_lines.append(text)

    return {
        "state": state,
        "icon": icon,
        "label": label,
        "lines": clean_lines,
    }


def _match_line(row: Dict[str, Any]) -> str:
    confidence = _confidence_percent(row)
    if row.get("imdb_id"):
        return f"Auto matched ({confidence}%)" if confidence is not None else "Auto matched"
    if row.get("match_status"):
        return str(row.get("match_status"))
    return "Metadata pending"


def _smart_import_status_card(
    row: Dict[str, Any],
    result: Dict[str, Any],
    planned_items: List[Dict[str, Any]],
    library_match: Optional[Dict[str, Any]],
    quality: Optional[Dict[str, Any]] = None,
    error: str = "",
) -> Dict[str, Any]:
    quality = quality or {}
    comparison = quality.get("comparison") or {}
    incoming = quality.get("incoming") or {}
    existing = quality.get("existing") or {}

    label = str((result or {}).get("status_label") or row.get("match_status") or "").strip()
    level = str((result or {}).get("status_level") or row.get("match_level") or "").strip().lower()
    comparison_level = str(comparison.get("level") or "").strip().lower()
    confidence = _confidence_percent(row)

    incoming_summary = _quality_summary(incoming)
    existing_summary = _quality_summary(existing)

    destination_existing = []
    for item in planned_items or []:
        try:
            if Path(item.get("dst", "")).exists():
                destination_existing.append(item)
        except Exception:
            pass

    if error or level == "error":
        return _status_card(
            "blocked",
            "âš«",
            "Blocked",
            [
                str(error or label or "Import plan failed"),
                "Manual review required",
            ],
        )

    if not row.get("enabled", True):
        return _status_card(
            "blocked",
            "âš«",
            "Skipped",
            [
                "Row unchecked",
                "Will not import",
            ],
        )

    if comparison_level == "upgrade" or "upgrade" in label.lower():
        return _status_card(
            "upgrade",
            "ðŸ”µ",
            "Upgrade",
            [
                f"Existing: {existing_summary}" if existing_summary else "Existing item found",
                f"Incoming: {incoming_summary}" if incoming_summary else "Incoming quality appears higher",
                "Non-destructive review",
            ],
        )

    if level == "duplicate" or "duplicate" in label.lower() or (
        planned_items and len(destination_existing) == len(planned_items)
    ):
        return _status_card(
            "duplicate",
            "ðŸ”´",
            "Duplicate",
            [
                "Already exists in library",
                f"Existing: {existing_summary}" if existing_summary else "",
                f"Incoming: {incoming_summary}" if incoming_summary else "",
            ],
        )

    alternatives = row.get("alternatives") or []
    needs_review_lines = []

    if alternatives:
        needs_review_lines.append(f"{len(alternatives) + 1} TMDb matches found")

    if confidence is not None and confidence < 90:
        needs_review_lines.append(f"Match confidence {confidence}%")

    if comparison_level in {"downgrade", "unknown", "similar"} and library_match:
        if comparison_level == "downgrade":
            needs_review_lines.append("Incoming may be lower quality")
        elif comparison_level == "unknown":
            needs_review_lines.append("Quality could not be confirmed")
        else:
            needs_review_lines.append("Existing library item found")

    if level in {"warning", "attention"}:
        needs_review_lines.append(label or "Review recommended")

    if not row.get("imdb_id"):
        needs_review_lines.append("IMDb ID missing")

    if needs_review_lines:
        return _status_card(
            "needs_review",
            "ðŸŸ¡",
            "Needs Review",
            needs_review_lines,
        )

    media_type = row.get("media_type") or "movie"
    return _status_card(
        "ready",
        "ðŸŸ¢",
        "Ready",
        [
            _match_line(row),
            "New movie" if media_type == "movie" else "New TV item",
            "Destination available",
        ],
    )


def _status_from_plan(
    row: Dict[str, Any],
    planned_items: List[Dict[str, Any]],
    library_match: Optional[Dict[str, Any]],
    quality: Optional[Dict[str, Any]] = None,
    error: str = "",
) -> Dict[str, Any]:
    try:
        result = _legacy_status_from_plan(row, planned_items, library_match, quality=quality, error=error)
    except TypeError:
        result = _legacy_status_from_plan(row, planned_items, library_match, error)

    result = dict(result or {})
    card = _smart_import_status_card(
        row=row,
        result=result,
        planned_items=planned_items,
        library_match=library_match,
        quality=quality or {},
        error=error,
    )

    result["status_card"] = card
    result["status_state"] = card.get("state")
    result["status_icon"] = card.get("icon")
    result["status_lines"] = card.get("lines", [])
    return result
def preview_multi_rows(rows: List[Dict[str, Any]], settings: Optional[Dict[str, Any]] = None, auto_match: bool = False, mode: str = "custom") -> Dict[str, Any]:
    settings = settings or {}
    rows = _expand_direct_movie_file_rows(rows)
    output_rows = []
    all_items = []
    enabled_count = 0
    ready_count = 0
    warning_count = 0
    duplicate_count = 0
    error_count = 0

    for index, raw in enumerate(rows or [], start=1):
        row = _normalize_row(raw, index)
        if auto_match or _row_has_metadata_identifier(row) or _source_tv_signal(row) or _source_movie_signal(row):
            row = _apply_tmdb_match(settings, row, allow_search=auto_match)

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

        quality = quality_advice_for_import(row.get("source", ""), planned_items, library_match)
        row_status = _status_from_plan(row, planned_items, library_match, quality=quality, error=error)
        row.update(row_status)
        row["quality"] = quality
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
        title = "Import Manager"
        recommendation = "Review each movie row, confirm the IMDb IDs, then create hard links for the selected rows."
    elif mode == "tv_season_pack":
        title = "Import Manager"
        recommendation = "Review each season row, confirm the show metadata, then import the selected seasons independently."
    else:
        title = "Import Manager"
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