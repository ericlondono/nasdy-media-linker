from pathlib import Path
import os
from typing import Any, Dict, Iterable, List, Optional, Set, Tuple

from app.config import HOST_MNT_ROOT, VIDEO_EXTENSIONS
from app.services.logger import log
from app.services.utils import find_videos, is_skippable_video
from app.services.linker import resolve_real_host_path

Signature = Tuple[int, int, int]


def _is_video_file(path: Path) -> bool:
    try:
        return path.is_file() and path.suffix.lower() in VIDEO_EXTENSIONS and not is_skippable_video(path)
    except Exception:
        return False


def source_videos(source: Any) -> List[Path]:
    path = Path(str(source or ""))
    try:
        if _is_video_file(path):
            return [path]
        if path.exists() and path.is_dir():
            return find_videos(path)
    except Exception:
        return []
    return []


def _stat_signature(path: Path, resolve_source: bool = False) -> Optional[Signature]:
    try:
        real_path = resolve_real_host_path(path) if resolve_source else path
        st = os.stat(real_path)
        return (int(st.st_dev), int(st.st_ino), int(st.st_size))
    except Exception:
        return None


def _source_signature(path: Path) -> Optional[Signature]:
    return _stat_signature(path, resolve_source=True)


def _media_signature(path: Path) -> Optional[Signature]:
    return _stat_signature(path, resolve_source=False)


def _dedupe_paths(paths: Iterable[Path]) -> List[Path]:
    out: List[Path] = []
    seen: Set[str] = set()
    for path in paths:
        try:
            key = str(path.resolve()) if path.exists() else str(path)
        except Exception:
            key = str(path)
        if key in seen:
            continue
        seen.add(key)
        out.append(path)
    return out


def candidate_media_roots() -> List[Path]:
    roots: List[Path] = []

    # Prefer real unRAID disk paths because hard links are created there.
    try:
        roots.append(HOST_MNT_ROOT / "cache" / "NASDY" / "media")
        roots.extend(sorted(HOST_MNT_ROOT.glob("disk*/NASDY/media")))
        roots.append(HOST_MNT_ROOT / "user" / "NASDY" / "media")
    except Exception:
        pass

    # Fallback to the container media mount. This helps in dev/test environments.
    roots.append(Path("/media"))

    return _dedupe_paths([root for root in roots if root.exists() and root.is_dir()])


def _iter_media_videos(root: Path):
    try:
        for path in root.rglob("*"):
            if _is_video_file(path):
                yield path
    except Exception as error:
        log(f"WARN hardlink reconcile scan skipped root={root}: {error}")


def scan_media_for_signatures(wanted: Set[Signature]) -> Dict[Signature, List[Path]]:
    found: Dict[Signature, List[Path]] = {}
    if not wanted:
        return found

    remaining = set(wanted)
    for root in candidate_media_roots():
        for path in _iter_media_videos(root):
            sig = _media_signature(path)
            if sig not in wanted:
                continue
            found.setdefault(sig, []).append(path)
            remaining.discard(sig)
        if not remaining:
            break

    return found


def _pretty_media_path(path: Path) -> str:
    text = str(path)
    replacements = []
    try:
        replacements.extend([
            (str(HOST_MNT_ROOT / "user" / "NASDY" / "media"), "/media"),
            (str(HOST_MNT_ROOT / "cache" / "NASDY" / "media"), "/media"),
        ])
        for disk_root in sorted(HOST_MNT_ROOT.glob("disk*/NASDY/media")):
            replacements.append((str(disk_root), "/media"))
    except Exception:
        pass

    for prefix, replacement in replacements:
        if text == prefix:
            return replacement
        if text.startswith(prefix + "/"):
            return replacement + text[len(prefix):]

    return text


def _destination_summary(paths: List[Path]) -> str:
    if not paths:
        return ""

    parents = []
    seen = set()
    for path in paths:
        parent = _pretty_media_path(path.parent)
        if parent not in seen:
            seen.add(parent)
            parents.append(parent)

    if len(parents) == 1:
        return parents[0]
    if len(parents) <= 4:
        return "; ".join(parents)
    return f"{len(paths)} hard-linked file(s) across {len(parents)} media folders"


def _reconciled_entry(item: Dict[str, Any], linked_paths: List[Path], video_count: int) -> Dict[str, Any]:
    media_type = item.get("type") or item.get("media_type") or "movie"
    title = item.get("title") or item.get("name") or ""
    year = item.get("year") or ""
    season = item.get("season") or ""
    source = item.get("path") or item.get("source") or ""
    source_key = item.get("source_key") or source

    return {
        "time": "Auto-detected on queue refresh",
        "type": media_type,
        "title": title,
        "year": year,
        "imdb_id": item.get("imdb_id", ""),
        "season": season if media_type == "tv" else "",
        "count": int(video_count or 0),
        "destination": _destination_summary(linked_paths),
        "jellyfin": "",
        "status": "success",
        "import_type": "reconciled-hardlink",
        "source": source,
        "source_key": source_key,
        "diagnostics": [],
        "linked_paths": [_pretty_media_path(p) for p in linked_paths[:50]],
    }


def reconcile_queue_items(items: List[Dict[str, Any]]) -> Tuple[List[Dict[str, Any]], Dict[str, Any]]:
    """
    Mark queue items imported when their source video files already have matching
    hard links somewhere under the media library.

    This deliberately uses device/inode identity, not title-only matching. If a new
    torrent is a different file, such as a higher-quality upgrade, it will not be
    marked imported by this reconciler.
    """
    output: List[Dict[str, Any]] = [dict(item or {}) for item in (items or [])]
    item_signatures: Dict[int, List[Signature]] = {}
    item_video_counts: Dict[int, int] = {}
    wanted: Set[Signature] = set()

    for index, item in enumerate(output):
        # Keep manual/user-tracked imported items untouched.
        if item.get("imported"):
            continue

        videos = source_videos(item.get("path") or item.get("source") or "")
        signatures: List[Signature] = []
        for video in videos:
            sig = _source_signature(video)
            if sig:
                signatures.append(sig)
                wanted.add(sig)

        if signatures:
            item_signatures[index] = signatures
            item_video_counts[index] = len(videos)

    media_index = scan_media_for_signatures(wanted)

    fully_linked = 0
    partially_linked = 0

    for index, signatures in item_signatures.items():
        item = output[index]
        linked_paths: List[Path] = []
        missing_count = 0

        for sig in signatures:
            matches = media_index.get(sig) or []
            if matches:
                linked_paths.append(matches[0])
            else:
                missing_count += 1

        if linked_paths and missing_count == 0:
            fully_linked += 1
            entry = _reconciled_entry(item, linked_paths, item_video_counts.get(index, len(signatures)))
            item["imported"] = True
            item["imported_record"] = entry
            item["auto_reconciled"] = True
            item["advisor_level"] = "imported"
            item["advisor_label"] = "Imported"
            item["advisor_reason"] = "Already hard-linked in media library"
            item["advisor_recommendation"] = "No action needed. NML found matching hard links already present in /media."
        elif linked_paths:
            partially_linked += 1
            item["hardlink_reconcile"] = {
                "state": "partial",
                "matched": len(linked_paths),
                "missing": missing_count,
                "linked_paths": [_pretty_media_path(p) for p in linked_paths[:20]],
            }
            if not item.get("advisor_reason"):
                item["advisor_reason"] = f"{len(linked_paths)} already hard-linked, {missing_count} still missing"

    output.sort(key=lambda x: (bool(x.get("imported")), str(x.get("title") or x.get("name") or "").lower()))

    return output, {
        "fully_linked": fully_linked,
        "partially_linked": partially_linked,
        "wanted_signatures": len(wanted),
    }


def reconciled_import_record(
    media_type: str,
    source: str,
    source_key: str = "",
    title: str = "",
    year: str = "",
    season: str = "01",
) -> Optional[Dict[str, Any]]:
    item = {
        "name": Path(str(source or "")).name,
        "path": source,
        "source": source,
        "source_key": source_key or source,
        "type": media_type or "movie",
        "title": title or Path(str(source or "")).stem,
        "year": year or "",
        "season": season or "01",
        "imported": False,
    }
    reconciled, _summary = reconcile_queue_items([item])
    if reconciled and reconciled[0].get("imported") and reconciled[0].get("imported_record"):
        return reconciled[0].get("imported_record")
    return None
