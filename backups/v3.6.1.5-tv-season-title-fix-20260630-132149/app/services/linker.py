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
        # v3.6.1.4: TV source folders can contain multiple seasons.
        # Route each video by the season detected in its own filename/path instead
        # of forcing every episode into the row's single season value.
        display = f"{title} ({year})" if year else title
        show_dir = TV_ROOT / safe_name(display)

        try:
            requested_season = f"{int(str(season or '01')):02d}"
        except Exception:
            requested_season = detect_season(str(season or "")) or "01"

        fallback_by_season = {}
        detected_seasons = set()

        for src in videos:
            src_season = (
                detect_season(src.name)
                or detect_season(str(src.parent))
                or requested_season
                or "01"
            )
            try:
                src_season = f"{int(str(src_season)):02d}"
            except Exception:
                src_season = "01"

            detected_seasons.add(src_season)

            ep = detect_episode(src.name)
            episode_detected = bool(ep)
            if not ep:
                fallback = fallback_by_season.get(src_season, 1)
                ep = f"{fallback:02d}"
                fallback_by_season[src_season] = fallback + 1

            dest_dir = show_dir / f"Season {src_season}"
            new_name = safe_name(f"{display} - S{src_season}E{ep}{src.suffix.lower()}")
            items.append({
                "src": src,
                "dst": dest_dir / new_name,
                "new_name": new_name,
                "season": src_season,
                "episode": ep,
                "episode_detected": episode_detected,
            })

        if len(detected_seasons) == 1:
            only_season = sorted(detected_seasons)[0]
            return show_dir / f"Season {only_season}", items

        return show_dir, items
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