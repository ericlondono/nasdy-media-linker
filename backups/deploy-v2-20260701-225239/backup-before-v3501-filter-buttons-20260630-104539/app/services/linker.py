import os
from pathlib import Path

from app.config import MOVIES_ROOT, TV_ROOT, HOST_MNT_ROOT
from app.services.utils import find_videos, detect_episode, safe_name
from app.services.logger import log


def _existing_tv_destination(title: str, year: str, season: str, display: str) -> Path:
    season = f"{int(season):02d}"
    try:
        from app.services.library import find_tv_match

        match = find_tv_match(title, season)
        if match and match.get("path"):
            show_folder = Path(match["path"])
            if show_folder.exists():
                if match.get("season_path"):
                    return Path(match["season_path"])
                return show_folder / f"Season {season}"
    except Exception as error:
        log(f"WARN existing TV destination lookup failed: {error}")

    return TV_ROOT / safe_name(display) / f"Season {season}"


def _existing_movie_destination(title: str, year: str, display: str) -> Path:
    try:
        from app.services.library import find_movie_match

        match = find_movie_match(title, year)
        if match and match.get("path"):
            movie_folder = Path(match["path"])
            if movie_folder.exists():
                return movie_folder
    except Exception as error:
        log(f"WARN existing movie destination lookup failed: {error}")

    return MOVIES_ROOT / safe_name(display)


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
        dest_dir = _existing_tv_destination(title, year, season, display)
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
        dest_dir = _existing_movie_destination(title, year, display)
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


def create_hard_links(items, existing_policy: str = "error"):
    created = []
    diagnostics = []
    skip_existing = str(existing_policy or "").lower() in {"skip", "skip_existing", "import_missing"}

    for item in items:
        src_container = Path(item["src"])
        dst_container = Path(item["dst"])
        diag = diagnostic_for_link(src_container, dst_container)

        src_real = Path(diag["src_real"])
        dst_real = Path(diag["dst_real"])

        log(f"LINK DIAG: {diag}")

        if not src_real.exists():
            diag["action"] = "missing_source"
            diagnostics.append(diag)
            raise FileNotFoundError(f"Resolved source does not exist: {src_real}")

        if dst_real.exists():
            diag["action"] = "skipped_existing" if skip_existing else "already_exists"
            diagnostics.append(diag)
            if skip_existing:
                log(f"SKIPPED EXISTING DESTINATION: {dst_real}")
                continue
            raise FileExistsError(f"Already exists: {dst_real}")

        dst_real.parent.mkdir(parents=True, exist_ok=True)
        normalize_permissions(dst_real.parent)

        try:
            os.link(src_real, dst_real)
        except FileExistsError:
            diag["action"] = "skipped_existing" if skip_existing else "already_exists"
            diagnostics.append(diag)
            if skip_existing:
                log(f"SKIPPED EXISTING DESTINATION AFTER RACE: {dst_real}")
                continue
            raise

        normalize_permissions(dst_real)
        diag["action"] = "created"
        diagnostics.append(diag)
        created.append(str(dst_real))
        log(f"CREATED HARD LINK: {src_real} -> {dst_real}")

    return created, diagnostics