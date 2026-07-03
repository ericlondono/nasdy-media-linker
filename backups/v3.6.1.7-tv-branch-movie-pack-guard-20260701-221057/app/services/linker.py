import re
import os
from collections import defaultdict
from pathlib import Path

from app.config import MOVIES_ROOT, TV_ROOT, HOST_MNT_ROOT
from app.services.utils import find_videos, detect_episode, detect_season, safe_name, strip_release_words, detect_year, looks_like_multi_movie_folder
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



def _normalize_tv_season(value, default="01"):
    """
    Normalize season values from detect_season(), folder names, or filenames.

    Important: older code tried int("S02"), which failed and fell back to 01.
    This helper turns S02, S02E04, Season 2, and 2 into "02".
    """
    text = str(value or "").strip()
    if not text:
        return default

    patterns = [
        r"\bS0*(\d{1,2})E\d{1,3}\b",
        r"\bS0*(\d{1,2})\b",
        r"\bSeason[ ._-]*0*(\d{1,2})\b",
        r"^\s*0*(\d{1,2})\s*$",
    ]

    for pattern in patterns:
        match = re.search(pattern, text, re.I)
        if match:
            try:
                return f"{int(match.group(1)):02d}"
            except Exception:
                return default

    return default


def _detect_tv_season_for_file(src, fallback="01"):
    fallback = _normalize_tv_season(fallback, "01")

    # Prefer the strongest signal first: SxxEyy in the actual filename.
    for raw in (
        getattr(src, "name", ""),
        getattr(src, "stem", ""),
        getattr(getattr(src, "parent", None), "name", ""),
        str(getattr(src, "parent", "")),
    ):
        direct = _normalize_tv_season(raw, "")
        if direct:
            return direct

        try:
            detected = detect_season(str(raw or ""))
            normalized = _normalize_tv_season(detected, "")
            if normalized:
                return normalized
        except Exception:
            pass

    return fallback


def _episode_title_from_filename(src):
    stem = str(getattr(src, "stem", "") or "")
    match = re.search(r"\b(?:S\d{1,2}E\d{1,3}|\d{1,2}x\d{1,3})[ ._-]+(.+)$", stem, re.I)
    if not match:
        return ""

    title = match.group(1)

    # Strip common release/quality tail tokens while keeping the episode title.
    title = re.split(
        r"[ ._-]+(?:"
        r"480p|576p|720p|1080p|2160p|4320p|4k|8k|uhd|"
        r"bluray|blu[- ._]?ray|bdrip|brrip|web[- ._]?dl|webdl|webrip|hdtv|remux|"
        r"hdrip|dvdrip|x264|x265|h264|h265|hevc|avc|av1|"
        r"hdr10\+?|hdr|dolby[ ._-]?vision|truehd|atmos|dts[- ._]?hd|dts|"
        r"ddp?5?\.?1?|dd5\.1|aac|ac3|eac3"
        r")\b",
        title,
        maxsplit=1,
        flags=re.I,
    )[0]

    title = re.sub(r"[._]+", " ", title)
    title = re.sub(r"\s+", " ", title).strip(" -_.")
    title = re.sub(r"\s*-\s*$", "", title).strip()

    if not title:
        return ""

    if re.fullmatch(r"episode\s*\d+", title, re.I):
        return ""

    # Avoid huge filenames if a release tail slips through.
    if len(title) > 80:
        title = title[:80].rstrip(" -_.")

    return title


def _movie_title_year_from_filename(src, fallback_title="", fallback_year=""):
    stem = str(getattr(src, "stem", "") or "")
    cleaned = re.sub(r"[._]+", " ", stem)
    cleaned = re.sub(r"\s+", " ", cleaned).strip()

    year = detect_year(cleaned) or fallback_year or ""
    year_match = re.search(r"\b(19\d{2}|20\d{2})\b", cleaned)

    if year_match:
        title_text = cleaned[:year_match.start()]
    else:
        title_text = cleaned

    title_text = re.split(
        r"\b(?:480p|576p|720p|1080p|2160p|4320p|4k|8k|uhd|bluray|blu[- ]?ray|bdrip|brrip|web[- ]?dl|webdl|webrip|hdtv|remux|hevc|x265|x264|h264|h265|avc|hdr|dd5\.?1|dts|truehd|atmos)\b",
        title_text,
        maxsplit=1,
        flags=re.I,
    )[0]

    title_text = re.sub(r"[-_]+", " ", title_text)
    title_text = re.sub(r"\s+", " ", title_text).strip(" -_.")
    title = strip_release_words(title_text) or title_text or fallback_title or stem

    return title.strip(), str(year or "").strip()


def _is_direct_child(source_path, src):
    try:
        return len(src.relative_to(source_path).parts) == 1
    except Exception:
        return False


def _looks_like_direct_movie_file_collection(source_path, videos):
    if not videos or len(videos) < 2:
        return False

    direct_videos = [src for src in videos if _is_direct_child(source_path, src)]
    if len(direct_videos) < 2:
        return False

    episode_like = 0
    year_like = 0
    distinct_titles = set()

    for src in direct_videos:
        if detect_episode(src.name):
            episode_like += 1
            continue

        title, year = _movie_title_year_from_filename(src)
        if year:
            year_like += 1
        if title:
            distinct_titles.add(title.lower())

    if episode_like >= max(1, len(direct_videos) // 3):
        return False

    path_text = f"{source_path.name} {source_path}".lower()
    path_movie_word = bool(re.search(r"\b(movie|movies|film|films|trilogy|duology)\b", path_text, re.I))

    if year_like >= 2 and len(distinct_titles) >= 2:
        return True

    if path_movie_word and episode_like == 0:
        return True

    return False


def build_direct_movie_file_collection_plan(source_path, videos, fallback_title="", fallback_year=""):
    items = []
    direct_videos = sorted(
        [src for src in videos if _is_direct_child(source_path, src)],
        key=lambda p: str(p).lower(),
    )

    for src in direct_videos:
        movie_title, movie_year = _movie_title_year_from_filename(src, fallback_title, fallback_year)
        display = f"{movie_title} ({movie_year})" if movie_year else movie_title
        dest_dir = MOVIES_ROOT / safe_name(display)
        new_name = safe_name(f"{display}{src.suffix.lower()}")
        items.append({
            "src": src,
            "dst": dest_dir / new_name,
            "new_name": new_name,
            "movie_title": movie_title,
            "movie_year": movie_year,
            "movie_detected_from": "filename",
        })

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
        # v3.6.1.6: TV source folders can contain multiple seasons and episode titles.
        # Route each video by the season detected in its own filename/path.
        # Preserve the episode title from the source filename when available.
        display = f"{title} ({year})" if year else title
        show_dir = TV_ROOT / safe_name(display)

        requested_season = _normalize_tv_season(season or "01", "01")
        fallback_by_season = {}
        detected_seasons = set()

        for src in videos:
            src_season = _detect_tv_season_for_file(src, requested_season)
            detected_seasons.add(src_season)

            ep = detect_episode(src.name)
            episode_detected = bool(ep)
            if not ep:
                fallback = fallback_by_season.get(src_season, 1)
                ep = f"{fallback:02d}"
                fallback_by_season[src_season] = fallback + 1

            episode_title = _episode_title_from_filename(src)
            dest_dir = show_dir / f"Season {src_season}"

            base_name = f"{display} - S{src_season}E{ep}"
            if episode_title:
                base_name = f"{base_name} - {episode_title}"

            new_name = safe_name(f"{base_name}{src.suffix.lower()}")
            items.append({
                "src": src,
                "dst": dest_dir / new_name,
                "new_name": new_name,
                "season": src_season,
                "episode": ep,
                "episode_title": episode_title,
                "episode_detected": episode_detected,
            })

        if len(detected_seasons) == 1:
            only_season = sorted(detected_seasons)[0]
            return show_dir / f"Season {only_season}", items

        return show_dir, items
    else:
        display = f"{title} ({year})" if year else title

        # v3.6.1.6: a TV-heavy pack can include a direct folder of movie files.
        # In that case, create one movie folder per movie filename instead of
        # forcing them into Season 01 TV episodes or a single "Part 1/2/3" movie.
        if _looks_like_direct_movie_file_collection(source_path, videos):
            return build_direct_movie_file_collection_plan(source_path, videos, title, year)

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