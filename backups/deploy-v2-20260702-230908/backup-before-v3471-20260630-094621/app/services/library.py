from pathlib import Path
import re

from app.config import MOVIES_ROOT, TV_ROOT, VIDEO_EXTENSIONS


def normalize_text(value: str) -> str:
    return "".join(ch.lower() for ch in str(value or "") if ch.isalnum())


def clean_folder_title(folder_name: str) -> str:
    text = str(folder_name or "")
    text = re.sub(r"\((19\d{2}|20\d{2})\)", " ", text)
    text = re.sub(r"\[(19\d{2}|20\d{2})\]", " ", text)
    text = text.replace(".", " ").replace("_", " ")
    return re.sub(r"\s+", " ", text).strip()


def extract_year(value: str) -> str:
    match = re.search(r"\b(19\d{2}|20\d{2})\b", str(value or ""))
    return match.group(1) if match else ""


def video_count(folder: Path) -> int:
    if not folder.exists():
        return 0
    return sum(
        1 for p in folder.rglob("*")
        if p.is_file() and p.suffix.lower() in VIDEO_EXTENSIONS
    )


def folder_score(query_title: str, query_year: str, folder: Path) -> int:
    folder_name = folder.name
    folder_title = clean_folder_title(folder_name)
    folder_year = extract_year(folder_name)

    query_norm = normalize_text(query_title)
    folder_norm = normalize_text(folder_title)
    folder_full_norm = normalize_text(folder_name)

    if not query_norm:
        return 0

    score = 0

    if query_norm == folder_norm:
        score += 100
    elif query_norm in folder_norm or folder_norm in query_norm:
        score += 75
    elif query_norm in folder_full_norm:
        score += 60

    if query_year and folder_year:
        if query_year == folder_year:
            score += 40
        else:
            score -= 30
    elif query_year and query_year in folder_name:
        score += 25

    return score


def season_folder_candidates(show_folder: Path, season: str):
    season_num = str(season or "01").zfill(2)
    season_int = int(season_num)

    names = [
        f"Season {season_num}",
        f"Season {season_int}",
        f"S{season_num}",
        f"Series {season_num}",
        f"Series {season_int}",
    ]

    return [show_folder / name for name in names]


def existing_episode_numbers(season_folder: Path):
    episodes = set()
    if not season_folder.exists():
        return []

    for file in season_folder.rglob("*"):
        if not file.is_file() or file.suffix.lower() not in VIDEO_EXTENSIONS:
            continue

        text = file.name
        match = re.search(r"\bS\d{1,2}E(\d{1,3})\b", text, re.I)
        if match:
            episodes.add(int(match.group(1)))
            continue

        match = re.search(r"\b\d{1,2}x(\d{1,3})\b", text, re.I)
        if match:
            episodes.add(int(match.group(1)))

    return sorted(episodes)


def find_movie_match(title: str, year: str = ""):
    if not MOVIES_ROOT.exists():
        return None

    best = None
    for folder in MOVIES_ROOT.iterdir():
        if not folder.is_dir():
            continue

        score = folder_score(title, year, folder)
        if score <= 0:
            continue

        current = {
            "kind": "movie",
            "title": folder.name,
            "path": str(folder),
            "score": score,
            "year": extract_year(folder.name),
            "video_count": video_count(folder),
        }

        if best is None or current["score"] > best["score"]:
            best = current

    if best and best["score"] >= 60:
        best["confidence"] = "high" if best["score"] >= 100 else "medium"
        return best

    return None


def find_tv_match(title: str, season: str = "01"):
    if not TV_ROOT.exists():
        return None

    best = None
    for show_folder in TV_ROOT.iterdir():
        if not show_folder.is_dir():
            continue

        score = folder_score(title, "", show_folder)
        if score <= 0:
            continue

        found_season_folder = None
        for candidate in season_folder_candidates(show_folder, season):
            if candidate.exists():
                found_season_folder = candidate
                break

        current = {
            "kind": "tv",
            "title": show_folder.name,
            "path": str(show_folder),
            "score": score,
            "season": str(season or "01").zfill(2),
            "season_exists": bool(found_season_folder),
            "season_path": str(found_season_folder) if found_season_folder else "",
            "existing_episodes": existing_episode_numbers(found_season_folder) if found_season_folder else [],
        }

        if best is None or current["score"] > best["score"]:
            best = current

    if best and best["score"] >= 60:
        best["confidence"] = "high" if best["score"] >= 100 else "medium"
        return best

    return None


def find_library_match(media_type: str, title: str, year: str = "", season: str = "01"):
    if media_type == "movie":
        return find_movie_match(title, year)

    return find_tv_match(title, season)
