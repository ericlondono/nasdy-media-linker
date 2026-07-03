from pathlib import Path
from typing import Dict, List, Any

from app.services.utils import detect_episode


def _episode_int(value):
    try:
        return int(str(value).strip())
    except Exception:
        return None


def _episode_ranges(numbers: List[int]) -> str:
    nums = sorted({int(n) for n in numbers if n is not None})
    if not nums:
        return "none"

    ranges = []
    start = prev = nums[0]

    for num in nums[1:]:
        if num == prev + 1:
            prev = num
            continue
        ranges.append((start, prev))
        start = prev = num

    ranges.append((start, prev))

    labels = []
    for a, b in ranges:
        if a == b:
            labels.append(f"Episode {a}")
        else:
            labels.append(f"Episodes {a}-{b}")

    return ", ".join(labels)


def _incoming_episodes(items: List[Dict[str, Any]]) -> List[int]:
    episodes = []
    fallback = 1

    for item in items or []:
        ep = item.get("episode") or detect_episode(str(item.get("src", ""))) or detect_episode(str(item.get("new_name", "")))
        if not ep:
            ep = fallback
            fallback += 1

        ep_num = _episode_int(ep)
        if ep_num is not None:
            episodes.append(ep_num)

    return sorted(episodes)


def build_smart_advisor(media_type: str, title: str, year: str, season: str, destination, items, library_match, imported):
    """
    Phase 1 Smart Import Advisor.

    This does not change import behavior yet. It analyzes the selected queue item and returns:
    - status bucket for the UI
    - duplicate/missing episode information
    - human-readable recommendation text
    - suggested future duplicate action
    """
    destination = str(destination or "")
    season = str(season or "01").zfill(2)
    items = items or []

    dst_exists = [item for item in items if Path(item.get("dst", "")).exists()]
    incoming_count = len(items)

    advisor = {
        "bucket": "recommended",
        "bucket_label": "Recommended",
        "severity": "green",
        "headline": "Ready to import",
        "summary": "Media Linker built an import plan for this item.",
        "recommendation": "Create hard links using the generated plan.",
        "duplicate_policy": "safe",
        "details": [],
        "incoming_count": incoming_count,
        "duplicate_count": 0,
        "missing_count": incoming_count,
        "incoming_episodes": [],
        "duplicate_episodes": [],
        "missing_episodes": [],
        "existing_episodes": [],
        "destination_exists": bool(dst_exists),
    }

    if imported:
        advisor.update({
            "bucket": "imported",
            "bucket_label": "Already Imported",
            "severity": "blue",
            "headline": "Already imported",
            "summary": "This item is already recorded in Media Linker import tracking.",
            "recommendation": "No action needed.",
            "duplicate_policy": "none",
            "missing_count": 0,
        })
        advisor["details"].append("Import tracking already contains this source.")
        return advisor

    if media_type == "movie":
        movie_already_exists = bool(dst_exists)
        if library_match and library_match.get("kind") == "movie":
            advisor["details"].append(f"Existing movie folder found: {library_match.get('title', '')}")
            advisor["details"].append(f"Videos already in folder: {library_match.get('video_count', 0)}")

        if movie_already_exists:
            advisor.update({
                "bucket": "duplicate",
                "bucket_label": "Duplicate",
                "severity": "red",
                "headline": "Movie file already exists",
                "summary": "At least one planned destination file already exists.",
                "recommendation": "Do not import until you decide whether to keep the existing file or replace it manually.",
                "duplicate_policy": "block",
                "duplicate_count": len(dst_exists),
                "missing_count": max(0, incoming_count - len(dst_exists)),
            })
        elif library_match and library_match.get("kind") == "movie":
            advisor.update({
                "headline": "Existing movie folder found",
                "summary": "Media Linker found an existing movie folder in your library.",
                "recommendation": "Import into the existing movie folder if this is the same release/title.",
            })
        else:
            advisor.update({
                "headline": "New movie folder",
                "summary": "No existing movie folder was found.",
                "recommendation": "Create a new movie folder.",
            })

        return advisor

    incoming_eps = _incoming_episodes(items)
    existing_eps = []
    if library_match and library_match.get("kind") == "tv":
        existing_eps = [_episode_int(e) for e in library_match.get("existing_episodes", [])]
        existing_eps = sorted({e for e in existing_eps if e is not None})

    duplicate_eps = sorted(set(incoming_eps).intersection(existing_eps))
    missing_eps = sorted(set(incoming_eps).difference(existing_eps))

    advisor["incoming_episodes"] = incoming_eps
    advisor["existing_episodes"] = existing_eps
    advisor["duplicate_episodes"] = duplicate_eps
    advisor["missing_episodes"] = missing_eps
    advisor["duplicate_count"] = len(duplicate_eps)
    advisor["missing_count"] = len(missing_eps) if incoming_eps else max(0, incoming_count - len(dst_exists))

    if incoming_eps:
        advisor["details"].append(f"Incoming torrent contains {_episode_ranges(incoming_eps)}.")
    if existing_eps:
        advisor["details"].append(f"Existing library has {_episode_ranges(existing_eps)}.")
    if duplicate_eps:
        advisor["details"].append(f"Duplicates detected: {_episode_ranges(duplicate_eps)}.")
    if missing_eps:
        advisor["details"].append(f"Missing/new episodes: {_episode_ranges(missing_eps)}.")

    if library_match and library_match.get("kind") == "tv":
        show = library_match.get("title", title)
        advisor["headline"] = f"Existing show found: {show}"
        advisor["summary"] = f"This appears to belong in Season {season} of the existing show."
        advisor["recommendation"] = f"Import into the existing Season {season} folder."

        if duplicate_eps and missing_eps:
            advisor.update({
                "bucket": "attention",
                "bucket_label": "Needs Attention",
                "severity": "yellow",
                "headline": "Some episodes already exist",
                "summary": f"Season {season} has duplicates and new episodes.",
                "recommendation": f"Best next step: import only missing episodes ({_episode_ranges(missing_eps)}). Duplicate skipping will be added in the next phase.",
                "duplicate_policy": "import_missing_only_soon",
            })
        elif duplicate_eps and not missing_eps:
            advisor.update({
                "bucket": "duplicate",
                "bucket_label": "Duplicate",
                "severity": "red",
                "headline": "All detected episodes already exist",
                "summary": f"Season {season} already appears to contain the incoming episodes.",
                "recommendation": "No import recommended unless you intentionally want to replace files manually.",
                "duplicate_policy": "block",
            })
        elif missing_eps:
            advisor.update({
                "bucket": "recommended",
                "bucket_label": "Recommended",
                "severity": "green",
                "headline": f"Import missing episodes into Season {season}",
                "summary": f"Incoming item appears to add {_episode_ranges(missing_eps)}.",
                "recommendation": f"Import into the existing Season {season} folder.",
                "duplicate_policy": "safe",
            })
    else:
        advisor.update({
            "bucket": "attention",
            "bucket_label": "Needs Attention",
            "severity": "yellow",
            "headline": "No existing show match found",
            "summary": "Media Linker could not confidently match this to an existing TV show folder.",
            "recommendation": "Verify the title, season, and IMDb ID before creating a new TV folder.",
            "duplicate_policy": "verify",
        })

    if dst_exists and not duplicate_eps:
        advisor.update({
            "bucket": "attention",
            "bucket_label": "Needs Attention",
            "severity": "yellow",
            "headline": "Destination filename conflict",
            "summary": "At least one planned destination filename already exists.",
            "recommendation": "Review the dry-run preview before importing.",
            "duplicate_policy": "verify",
        })

    return advisor
