#Requires -Version 5.1
param(
  [string]$NasHost = "192.168.0.109",
  [string]$NasUser = "root",
  [string]$NasBuildPath = "/mnt/user/appdata/nasdy-media-organizer/build",
  [string]$ImageName = "nasdy-media-linker:latest",
  [string]$ContainerName = "nasdy-media-organizer",
  [string]$HostPort = "",
  [switch]$SkipDeploy
)

$ErrorActionPreference = "Stop"

function Write-Step($Message) {
  Write-Host ""
  Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Good($Message) {
  Write-Host $Message -ForegroundColor Green
}

function Write-Warn($Message) {
  Write-Host $Message -ForegroundColor Yellow
}

function Require-Command($Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required command '$Name' was not found. Install/enable it first, then rerun this script."
  }
}

function Write-Utf8NoBom($Path, $Content) {
  $parent = Split-Path -Parent $Path
  if ($parent -and -not (Test-Path $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Copy-ForBackup($RelativePath, $BackupRoot) {
  $source = Join-Path $ProjectRoot $RelativePath
  if (-not (Test-Path $source)) {
    return
  }
  $dest = Join-Path $BackupRoot $RelativePath
  $parent = Split-Path -Parent $dest
  if ($parent -and -not (Test-Path $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  Copy-Item $source $dest -Force
}

function Invoke-Native($Description, [scriptblock]$Command) {
  Write-Step $Description
  & $Command
  if ($LASTEXITCODE -ne 0) {
    throw "$Description failed with exit code $LASTEXITCODE."
  }
}

$ProjectRoot = (Get-Location).Path
if (-not (Test-Path (Join-Path $ProjectRoot "app"))) {
  throw "Run this from the NASDY project root, for example: C:\Projects\nasdy-media-linker"
}

$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$BackupRoot = Join-Path $ProjectRoot "backup-before-v350-smart-advisor-$Stamp"

Write-Step "Creating local backup"
New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
$BackupFiles = @(
  "app\config.py",
  "app\main.py",
  "app\services\advisor.py",
  "app\services\linker.py",
  "app\services\queue.py",
  "app\static\app.js",
  "app\static\style.css",
  "app\templates\index.html",
  "Dockerfile",
  "requirements.txt"
)
foreach ($file in $BackupFiles) {
  Copy-ForBackup $file $BackupRoot
}
Write-Good "Backup created: $BackupRoot"

Write-Step "Writing v3.5.0 Smart Import Advisor files"
$Content1 = @'
import os
from pathlib import Path

APP_NAME = "NASDY Media Linker"
APP_VERSION = "v3.5.0"

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
Write-Utf8NoBom (Join-Path $ProjectRoot "app\config.py") $Content1
$Content2 = @'
from pathlib import Path
from typing import Any, Dict, List, Optional

from app.services.library import find_library_match
from app.services.linker import build_plan


def _to_int(value: Any) -> Optional[int]:
    try:
        text = str(value).strip()
        if not text:
            return None
        return int(text)
    except Exception:
        return None


def _unique_numbers(values: List[Any]) -> List[int]:
    numbers = []
    seen = set()
    for value in values or []:
        number = _to_int(value)
        if number is None or number in seen:
            continue
        seen.add(number)
        numbers.append(number)
    return sorted(numbers)


def _episode_range(numbers: List[Any], empty: str = "None detected") -> str:
    nums = _unique_numbers(numbers)
    if not nums:
        return empty

    ranges = []
    start = nums[0]
    prev = nums[0]

    for number in nums[1:]:
        if number == prev + 1:
            prev = number
            continue

        ranges.append(f"{start}" if start == prev else f"{start}-{prev}")
        start = prev = number

    ranges.append(f"{start}" if start == prev else f"{start}-{prev}")
    return ", ".join(ranges)


def _season_display(season: str) -> str:
    number = _to_int(season)
    return str(number) if number is not None else str(season or "1")


def _planned_episode_numbers(items: List[Dict[str, Any]]) -> List[int]:
    return _unique_numbers([item.get("episode") for item in items or [] if item.get("episode")])


def _destination_exists(item: Dict[str, Any]) -> bool:
    try:
        return Path(item.get("dst", "")).exists()
    except Exception:
        return False


def _metadata_title(metadata: Optional[Dict[str, Any]], fallback: str) -> str:
    metadata = metadata or {}
    return str(metadata.get("title") or fallback or "").strip()


def _base_result(media_type: str, title: str, year: str, season: str) -> Dict[str, Any]:
    return {
        "level": "recommended",
        "label": "Recommended",
        "headline": "",
        "queue_reason": "",
        "recommendation": "",
        "action_button": "Create Hard Links",
        "import_allowed": True,
        "import_policy": "skip_existing",
        "media_type": media_type,
        "title": title,
        "year": year,
        "season": str(season or "01").zfill(2) if media_type == "tv" else "",
        "destination": "",
        "library_match": None,
        "incoming_episodes": [],
        "existing_episodes": [],
        "duplicate_episodes": [],
        "missing_episodes": [],
        "incoming_summary": "",
        "existing_summary": "",
        "duplicate_summary": "",
        "missing_summary": "",
        "facts": [],
        "warnings": [],
        "errors": [],
    }


def analyze_import(
    media_type: str,
    source: str,
    title: str,
    year: str = "",
    season: str = "01",
    imported: Optional[Dict[str, Any]] = None,
    metadata: Optional[Dict[str, Any]] = None,
    planned_items: Optional[List[Dict[str, Any]]] = None,
    destination: Optional[Path] = None,
    library_match: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """
    Smart Import Advisor Phase 1.

    This deliberately returns plain JSON-friendly data so both the queue and the
    preview panel can consume the same recommendation engine.
    """
    media_type = "movie" if media_type == "movie" else "tv"
    title = str(title or "").strip()
    year = str(year or "").strip()
    season = str(season or "01").zfill(2) if media_type == "tv" else ""
    display_title = _metadata_title(metadata, title or Path(str(source or "")).name)
    result = _base_result(media_type, display_title, year, season or "01")

    if imported:
        result.update({
            "level": "imported",
            "label": "Imported",
            "headline": "Already imported",
            "queue_reason": "Already tracked in Import History",
            "recommendation": "No action needed. This source is already recorded in Media Linker import tracking.",
            "action_button": "Already Imported",
            "import_allowed": False,
        })
        return result

    try:
        if planned_items is None or destination is None:
            destination, planned_items = build_plan(media_type, source, title, year, season or "01")
    except Exception as error:
        result.update({
            "level": "attention",
            "label": "Needs Attention",
            "headline": "Could not build an import plan",
            "queue_reason": "Preview failed",
            "recommendation": "Fix the title, season, source path, or media type before importing.",
            "action_button": "Import Unavailable",
            "import_allowed": False,
            "errors": [str(error)],
        })
        return result

    planned_items = planned_items or []
    result["destination"] = str(destination or "")

    try:
        if library_match is None:
            library_match = find_library_match(media_type, title, year, season or "01")
    except Exception as error:
        library_match = None
        result["warnings"].append(f"Library scan failed: {error}")

    result["library_match"] = library_match

    destination_existing = [item for item in planned_items if _destination_exists(item)]
    all_destinations_exist = bool(planned_items) and len(destination_existing) == len(planned_items)

    if media_type == "movie":
        return _analyze_movie(
            result=result,
            title=display_title,
            year=year,
            planned_items=planned_items,
            library_match=library_match,
            all_destinations_exist=all_destinations_exist,
            destination_existing_count=len(destination_existing),
        )

    return _analyze_tv(
        result=result,
        title=display_title,
        season=season or "01",
        planned_items=planned_items,
        library_match=library_match,
        all_destinations_exist=all_destinations_exist,
        destination_existing_count=len(destination_existing),
    )


def _analyze_movie(
    result: Dict[str, Any],
    title: str,
    year: str,
    planned_items: List[Dict[str, Any]],
    library_match: Optional[Dict[str, Any]],
    all_destinations_exist: bool,
    destination_existing_count: int,
) -> Dict[str, Any]:
    name = f"{title} ({year})" if year else title
    video_word = "video" if len(planned_items) == 1 else "videos"
    result["facts"].append(f"Incoming item contains {len(planned_items)} {video_word}.")

    if library_match:
        result["facts"].append(f"Existing movie folder: {library_match.get('title', '')}.")
        result["facts"].append(f"Existing videos in that folder: {library_match.get('video_count', 0)}.")

    if all_destinations_exist or (library_match and int(library_match.get("video_count") or 0) > 0):
        confidence = (library_match or {}).get("confidence", "")
        if confidence == "high" or all_destinations_exist:
            result.update({
                "level": "duplicate",
                "label": "Duplicate",
                "headline": f"{name} already appears to exist",
                "queue_reason": "Movie already exists",
                "recommendation": "Do not hard-link this automatically yet. Use Mark Imported if this torrent is only being kept for seeding. Replace/upgrade controls can be added in a later v3.5.x release.",
                "action_button": "Duplicate - Import Disabled",
                "import_allowed": False,
            })
        else:
            result.update({
                "level": "attention",
                "label": "Needs Attention",
                "headline": f"Possible existing movie match for {name}",
                "queue_reason": "Possible movie match",
                "recommendation": "Review the title/year before importing. The existing folder may be the same movie with slightly different naming.",
                "action_button": "Review Before Import",
                "import_allowed": False,
            })
        return result

    if destination_existing_count:
        result.update({
            "level": "attention",
            "label": "Needs Attention",
            "headline": f"Some destination files already exist for {name}",
            "queue_reason": "Destination file exists",
            "recommendation": "Review the preview table before importing. Existing files will be skipped.",
            "action_button": "Import Missing Files",
            "import_allowed": True,
        })
        return result

    if library_match:
        result.update({
            "level": "recommended",
            "label": "Recommended",
            "headline": f"Existing movie folder found for {name}",
            "queue_reason": "Existing folder found",
            "recommendation": "Import into the existing movie folder.",
            "action_button": "Import into Existing Movie",
            "import_allowed": True,
        })
        return result

    result.update({
        "level": "recommended",
        "label": "Recommended",
        "headline": f"New movie import: {name}",
        "queue_reason": "New movie folder",
        "recommendation": "Create a new movie folder.",
        "action_button": "Create New Movie",
        "import_allowed": True,
    })
    return result


def _analyze_tv(
    result: Dict[str, Any],
    title: str,
    season: str,
    planned_items: List[Dict[str, Any]],
    library_match: Optional[Dict[str, Any]],
    all_destinations_exist: bool,
    destination_existing_count: int,
) -> Dict[str, Any]:
    season_display = _season_display(season)
    incoming = _planned_episode_numbers(planned_items)
    existing = _unique_numbers((library_match or {}).get("existing_episodes", []))
    duplicate = sorted(set(incoming).intersection(existing))
    missing = sorted([number for number in incoming if number not in set(existing)])

    result["incoming_episodes"] = incoming
    result["existing_episodes"] = existing
    result["duplicate_episodes"] = duplicate
    result["missing_episodes"] = missing
    result["incoming_summary"] = _episode_range(incoming)
    result["existing_summary"] = _episode_range(existing)
    result["duplicate_summary"] = _episode_range(duplicate)
    result["missing_summary"] = _episode_range(missing)

    if incoming:
        result["facts"].append(f"Incoming torrent contains Episodes {_episode_range(incoming)}.")
    else:
        result["facts"].append("Incoming episode numbers could not be reliably detected.")
        result["warnings"].append("Episode numbers were not detected from every incoming filename, so the preview may use fallback numbering.")

    if library_match:
        show_name = library_match.get("title") or title
        result["facts"].append(f"Existing library show: {show_name}.")
        if library_match.get("season_exists"):
            result["facts"].append(f"Season {season_display} already exists.")
        else:
            result["facts"].append(f"The show exists, but Season {season_display} was not found yet.")
        if existing:
            result["facts"].append(f"Episodes {_episode_range(existing)} already exist.")
        else:
            result["facts"].append("No existing episode numbers were detected in that season.")
    else:
        result["facts"].append("No existing TV library match was found.")

    if all_destinations_exist or (incoming and duplicate and not missing):
        result.update({
            "level": "duplicate",
            "label": "Duplicate",
            "headline": f"{title} Season {season_display}: no new episodes detected",
            "queue_reason": "Episode already exists",
            "recommendation": "No automatic hard-link is needed. Use Mark Imported if this torrent is only being kept for seeding.",
            "action_button": "Duplicate - Import Disabled",
            "import_allowed": False,
        })
        return result

    if duplicate and missing:
        result.update({
            "level": "attention",
            "label": "Needs Attention",
            "headline": f"{title} Season {season_display}: missing and duplicate episodes found",
            "queue_reason": f"Missing {_episode_range(missing)}, duplicate {_episode_range(duplicate)}",
            "recommendation": "Import only the missing episodes. Duplicate destination files will be skipped automatically.",
            "action_button": "Import Missing Episodes",
            "import_allowed": True,
        })
        return result

    if destination_existing_count:
        result.update({
            "level": "attention",
            "label": "Needs Attention",
            "headline": f"{title} Season {season_display}: destination conflict",
            "queue_reason": "Destination file exists",
            "recommendation": "Review the preview table. Existing destination files will be skipped automatically.",
            "action_button": "Import Missing Episodes",
            "import_allowed": True,
        })
        return result

    if not incoming:
        result.update({
            "level": "attention",
            "label": "Needs Attention",
            "headline": f"{title} Season {season_display}: episode numbers need review",
            "queue_reason": "Episode numbers unclear",
            "recommendation": "Review the generated filenames before importing.",
            "action_button": "Review Before Import",
            "import_allowed": True,
        })
        return result

    if library_match and library_match.get("season_exists"):
        result.update({
            "level": "recommended",
            "label": "Recommended",
            "headline": f"This appears to be {title} Season {season_display}",
            "queue_reason": f"Import Episodes {_episode_range(incoming)}",
            "recommendation": f"Import into the existing Season {str(season).zfill(2)} folder.",
            "action_button": f"Import into Season {str(season).zfill(2)}",
            "import_allowed": True,
        })
        return result

    if library_match:
        result.update({
            "level": "recommended",
            "label": "Recommended",
            "headline": f"This appears to be {title} Season {season_display}",
            "queue_reason": f"Create Season {str(season).zfill(2)}",
            "recommendation": f"Create a new Season {str(season).zfill(2)} folder inside the existing show folder.",
            "action_button": f"Create Season {str(season).zfill(2)}",
            "import_allowed": True,
        })
        return result

    result.update({
        "level": "recommended",
        "label": "Recommended",
        "headline": f"New TV import: {title} Season {season_display}",
        "queue_reason": f"Import Episodes {_episode_range(incoming)}",
        "recommendation": "Create a new show folder and season folder.",
        "action_button": "Create New TV Folder",
        "import_allowed": True,
    })
    return result


def summarize_queue_item(item: Dict[str, Any]) -> Dict[str, Any]:
    if item.get("imported"):
        return {
            "advisor_level": "imported",
            "advisor_label": "Imported",
            "advisor_reason": "Already tracked",
            "advisor_recommendation": "No action needed.",
        }

    advice = analyze_import(
        media_type=item.get("type", "tv"),
        source=item.get("path", ""),
        title=item.get("title", ""),
        year=item.get("year", ""),
        season=item.get("season", "01"),
    )

    return {
        "advisor_level": advice.get("level", "recommended"),
        "advisor_label": advice.get("label", "Recommended"),
        "advisor_reason": advice.get("queue_reason") or advice.get("recommendation", ""),
        "advisor_recommendation": advice.get("recommendation", ""),
    }
'@
Write-Utf8NoBom (Join-Path $ProjectRoot "app\services\advisor.py") $Content2
$Content3 = @'
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
'@
Write-Utf8NoBom (Join-Path $ProjectRoot "app\services\linker.py") $Content3
$Content4 = @'
from pathlib import Path
from datetime import datetime

from app.config import DOWNLOADS_ROOT, IGNORE_NAMES
from app.services.utils import find_videos, guess_type, strip_release_words, detect_year, detect_season
from app.services.storage import load_import_db
from app.services.qbittorrent import qbit_completed_items, normalize_source_path, imported_from_db
from app.services.advisor import summarize_queue_item


ADVISOR_SORT_ORDER = {
    "recommended": 0,
    "attention": 1,
    "duplicate": 2,
    "imported": 3,
}


def _apply_advisor(items):
    enriched = []
    for item in items:
        try:
            item.update(summarize_queue_item(item))
        except Exception as error:
            item["advisor_level"] = "attention"
            item["advisor_label"] = "Needs Attention"
            item["advisor_reason"] = f"Advisor unavailable: {error}"
            item["advisor_recommendation"] = "Open the item to review the preview."
        enriched.append(item)

    return sorted(
        enriched,
        key=lambda x: (
            ADVISOR_SORT_ORDER.get(x.get("advisor_level", "recommended"), 9),
            str(x.get("title") or x.get("name") or "").lower(),
        ),
    )


def folder_items():
    folders = []
    db = load_import_db()

    if not DOWNLOADS_ROOT.exists():
        return folders

    for p in sorted(DOWNLOADS_ROOT.iterdir(), key=lambda x: x.stat().st_mtime if x.exists() else 0, reverse=True):
        if not p.is_dir() or p.name.lower() in IGNORE_NAMES:
            continue

        videos = find_videos(p)
        if not videos:
            continue

        media_type = guess_type(p.name, len(videos))
        stat = p.stat()
        key = str(p)
        title = strip_release_words(p.name)
        year = detect_year(p.name)
        season = detect_season(p.name)

        imported = imported_from_db(db, {
            key,
            normalize_source_path(key),
            p.name,
        })

        folders.append({
            "name": p.name,
            "path": str(p),
            "video_count": len(videos),
            "type": media_type,
            "icon": "TV" if media_type == "tv" else "Movie",
            "type_label": "TV Show" if media_type == "tv" else "Movie",
            "title": title,
            "year": year,
            "season": season,
            "modified": datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M"),
            "source_kind": "folder",
            "source_key": key,
            "imported": imported,
            "hash": "",
            "state": "",
            "ratio": "",
        })

    return folders


def queue_items(settings):
    if settings.get("qbittorrent_enabled"):
        try:
            items = qbit_completed_items(settings)
            return _apply_advisor(items), "qBittorrent", None
        except Exception as e:
            return _apply_advisor(folder_items()), "Folders", f"qBittorrent error: {e}"

    return _apply_advisor(folder_items()), "Folders", None
'@
Write-Utf8NoBom (Join-Path $ProjectRoot "app\services\queue.py") $Content4
$Content5 = @'
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

        dest_dir, items = build_plan(media_type, source, title, year, season)
        settings = load_settings()

        meta = tmdb_search(settings, media_type, title, year) or {}
        library_match = find_library_match(media_type, title, year, season)

        db = load_import_db()
        source_key = data.get("source_key") or source or ""
        imported = find_import_record(db, source_key, source)

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

        duplicate_eps = {
            int(e) for e in advisor.get("duplicate_episodes", [])
            if _episode_number(e) is not None
        }

        diagnostics = []
        response_items = []
        for i in items:
            diag = diagnostic_for_link(Path(i["src"]), Path(i["dst"]))
            diagnostics.append(diag)

            ep_num = _episode_number(i.get("episode"))
            destination_exists = Path(i["dst"]).exists()
            duplicate_episode = bool(ep_num is not None and ep_num in duplicate_eps)

            response_items.append({
                "src": str(i["src"]),
                "dst": str(i["dst"]),
                "new_name": i["new_name"],
                "episode": i.get("episode", ""),
                "exists": destination_exists,
                "duplicate_episode": destination_exists or duplicate_episode,
                "status": "duplicate" if (destination_exists or duplicate_episode) else "ready",
            })

        return JSONResponse({
            "ok": True,
            "destination": str(dest_dir),
            "metadata": {
                **meta,
                "imdb_id": imdb_id,
            },
            "library_match": library_match,
            "imported": imported,
            "advisor": advisor,
            "diagnostics": diagnostics,
            "items": response_items,
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
    duplicate_policy: str = Form("skip"),
    refresh_jellyfin: Optional[str] = Form(None),
):
    try:
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
Write-Utf8NoBom (Join-Path $ProjectRoot "app\main.py") $Content5
$Content6 = @'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{{ app_name }} {{ version }}</title>
  <link rel="stylesheet" href="/static/style.css?v={{ version }}-smart-advisor">
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

  <script src="/static/app.js?v={{ version }}-smart-advisor"></script>
</body>
</html>
'@
Write-Utf8NoBom (Join-Path $ProjectRoot "app\templates\index.html") $Content6
$Content7 = @'
const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => Array.from(document.querySelectorAll(selector));

let previewTimer = null;
let activeQueueFilter = "recommended";
let activeHistoryFilter = "success";

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

function asArray(value) {
  return Array.isArray(value) ? value : [];
}

function schedulePreview() {
  clearTimeout(previewTimer);
  previewTimer = setTimeout(previewSelected, 350);
}

function fillFromCard(card) {
  if (!card) return;

  $$(".folder").forEach(el => el.classList.remove("active"));
  card.classList.add("active");

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

function renderImportAdvisor(data) {
  const metadata = $("#metadata");
  if (!metadata) return;
  metadata.classList.remove("hidden");

  if (!data.ok) {
    setImportButton("Import Unavailable", true);
    metadata.innerHTML = `
      <div class="advisor-panel attention">
        <h3>Smart Import Advisor</h3>
        <p class="bad-text">${escapeHtml(data.error || "Preview failed")}</p>
      </div>
    `;
    return;
  }

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

function renderPreview(data) {
  const preview = $("#preview");
  if (!preview) return;

  if (!data.ok) {
    setImportButton("Import Unavailable", true);
    preview.innerHTML = `<div class="empty-preview bad-text">${escapeHtml(data.error || "Preview failed")}</div>`;
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
    card.style.display = show ? "" : "none";
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

  $$('input[name="media_type"]').forEach(radio => {
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
Write-Utf8NoBom (Join-Path $ProjectRoot "app\static\app.js") $Content7
$DockerfileContent = @'
FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
'@
$RequirementsContent = @'
fastapi
uvicorn[standard]
jinja2
python-multipart
requests
'@

if (-not (Test-Path (Join-Path $ProjectRoot "Dockerfile"))) {
  Write-Utf8NoBom (Join-Path $ProjectRoot "Dockerfile") $DockerfileContent
}
if (-not (Test-Path (Join-Path $ProjectRoot "requirements.txt"))) {
  Write-Utf8NoBom (Join-Path $ProjectRoot "requirements.txt") $RequirementsContent
}
$CssAppend = @'

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
'@

$StylePath = Join-Path $ProjectRoot "app\static\style.css"
if (-not (Test-Path $StylePath)) {
  Write-Utf8NoBom $StylePath $CssAppend
} else {
  $ExistingStyle = [System.IO.File]::ReadAllText($StylePath)
  $ExistingStyle = [regex]::Replace(
    $ExistingStyle,
    "(?s)\r?\n?/\* v3\.5\.0 Smart Import Advisor \*/.*?/\* end v3\.5\.0 Smart Import Advisor \*/",
    ""
  )
  Write-Utf8NoBom $StylePath ($ExistingStyle.TrimEnd() + "`r`n`r`n" + $CssAppend.Trim() + "`r`n")
}
Write-Good "Local files updated for v3.5.0."

if ($SkipDeploy) {
  Write-Warn "SkipDeploy was set, so NAS build/deploy was not run."
  Write-Host "Local patch complete. Backup is at: $BackupRoot"
  exit 0
}

Write-Step "Checking SSH deployment tools"
Require-Command ssh
Require-Command scp
Require-Command tar

$Remote = "$NasUser@$NasHost"
Write-Host "Remote target: $Remote"
Write-Host "Remote build path: $NasBuildPath"
Write-Host "Container name: $ContainerName"
Write-Host "Image name: $ImageName"
Write-Host "Requested host port: $(if ($HostPort) { $HostPort } else { 'preserve existing, else 8181' })"

$ArchiveName = "nasdy-v350-smart-advisor-$Stamp.tgz"
$ArchivePath = Join-Path $env:TEMP $ArchiveName
if (Test-Path $ArchivePath) {
  Remove-Item $ArchivePath -Force
}

Invoke-Native "Creating deployment archive" {
  Push-Location $ProjectRoot
  try {
    & tar -czf $ArchivePath app Dockerfile requirements.txt
  } finally {
    Pop-Location
  }
}

Invoke-Native "Preparing remote build folder" {
  & ssh $Remote "mkdir -p '$NasBuildPath' && rm -rf '$NasBuildPath/app' '$NasBuildPath/Dockerfile' '$NasBuildPath/requirements.txt'"
}

Invoke-Native "Copying deployment archive to NAS" {
  & scp $ArchivePath "${Remote}:/tmp/$ArchiveName"
}

Invoke-Native "Extracting deployment archive on NAS" {
  & ssh $Remote "tar -xzf '/tmp/$ArchiveName' -C '$NasBuildPath'"
}

$RemoteDeploy = @'
#!/bin/sh
set -eu

IMAGE_NAME="__IMAGE_NAME__"
CONTAINER_NAME="__CONTAINER_NAME__"
NAS_BUILD_PATH="__NAS_BUILD_PATH__"
REQUESTED_HOST_PORT="__HOST_PORT__"

echo "Building NASDY Media Linker v3.5.0 on NAS..."
mkdir -p "$NAS_BUILD_PATH"
mkdir -p /mnt/user/appdata/nasdy-media-organizer/data
cd "$NAS_BUILD_PATH"

OLD_HOST_PORT=""
if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  OLD_HOST_PORT=$(docker inspect -f '{{with (index .NetworkSettings.Ports "8000/tcp")}}{{(index . 0).HostPort}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)
fi

HOST_PORT="$REQUESTED_HOST_PORT"
if [ -z "$HOST_PORT" ] && [ -n "$OLD_HOST_PORT" ]; then
  HOST_PORT="$OLD_HOST_PORT"
fi
if [ -z "$HOST_PORT" ]; then
  HOST_PORT="8181"
fi

docker build -t "$IMAGE_NAME" .

docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  -p "${HOST_PORT}:8000" \
  -e DOWNLOADS_ROOT=/downloads \
  -e MOVIES_ROOT=/media/movies \
  -e TV_ROOT=/media/tv \
  -e DATA_ROOT=/data \
  -e HOST_DOWNLOADS_ROOT=/mnt/user/NASDY/downloads \
  -e HOST_MEDIA_ROOT=/mnt/user/NASDY/media \
  -e HOST_MNT_ROOT=/host_mnt \
  -v /mnt/user/NASDY/downloads:/downloads \
  -v /mnt/user/NASDY/media:/media \
  -v /mnt/user/appdata/nasdy-media-organizer/data:/data \
  -v /mnt:/host_mnt \
  "$IMAGE_NAME"

sleep 3

echo ""
echo "Container status:"
docker ps --filter "name=$CONTAINER_NAME"

echo ""
echo "Recent logs:"
docker logs --tail 60 "$CONTAINER_NAME" || true

echo ""
echo "NASDY Media Linker v3.5.0 deployed."
echo "Open: http://__NAS_HOST__:${HOST_PORT}"
'@

$RemoteDeploy = $RemoteDeploy.Replace("__IMAGE_NAME__", $ImageName)
$RemoteDeploy = $RemoteDeploy.Replace("__CONTAINER_NAME__", $ContainerName)
$RemoteDeploy = $RemoteDeploy.Replace("__NAS_BUILD_PATH__", $NasBuildPath)
$RemoteDeploy = $RemoteDeploy.Replace("__HOST_PORT__", $HostPort)
$RemoteDeploy = $RemoteDeploy.Replace("__NAS_HOST__", $NasHost)

$RemoteScriptName = "nasdy-v350-deploy-$Stamp.sh"
$RemoteScriptLocal = Join-Path $env:TEMP $RemoteScriptName
Write-Utf8NoBom $RemoteScriptLocal $RemoteDeploy

Invoke-Native "Copying remote deploy script to NAS" {
  & scp $RemoteScriptLocal "${Remote}:/tmp/$RemoteScriptName"
}

Invoke-Native "Building and restarting Docker container on NAS" {
  & ssh $Remote "sh '/tmp/$RemoteScriptName'"
}

Write-Good "v3.5.0 Smart Import Advisor deployment complete."
Write-Host "Backup folder: $BackupRoot"
Write-Host "Use Ctrl+F5 in the browser so app.js/style.css cache is refreshed."
