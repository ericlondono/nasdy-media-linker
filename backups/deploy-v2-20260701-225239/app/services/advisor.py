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