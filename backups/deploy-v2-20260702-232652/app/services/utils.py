import re
from pathlib import Path
from app.config import VIDEO_EXTENSIONS, QUALITY_WORDS

SKIP_VIDEO_HINTS = {
    "sample", "samples", "trailer", "trailers", "extras", "extra",
    "featurette", "featurettes", "behind the scenes", "bts"
}

def clean_spaces(text: str) -> str:
    return re.sub(r"\s+", " ", str(text)).strip()

def pretty(text: str) -> str:
    text = str(text).replace(".", " ").replace("_", " ")
    text = re.sub(r"\s+-\s+", " ", text)
    return clean_spaces(text)

def safe_name(text: str) -> str:
    text = re.sub(r'[\\/:*?"<>|]', "-", str(text))
    return clean_spaces(text)

def title_case_guess(text: str) -> str:
    small = {"of","the","a","an","and","or","in","on","at","to","for","with","by","from"}
    out = []
    for i, w in enumerate(str(text).split()):
        if w.upper() in {"TV", "FBI", "CSI", "NCIS", "UHD", "USA", "DC"}:
            out.append(w.upper())
        elif i != 0 and w.lower() in small:
            out.append(w.lower())
        else:
            out.append(w[:1].upper() + w[1:])
    return " ".join(out)

def detect_year(text: str) -> str:
    years = re.findall(r"\b(19\d{2}|20\d{2})\b", str(text))
    return years[0] if years else ""

def detect_season(text: str) -> str:
    text = str(text)

    m = re.search(r"\bS0*(\d{1,2})\s*E\s*\d{1,3}\b", text, re.I)
    if m:
        return f"{int(m.group(1)):02d}"

    m = re.search(r"\bS0*(\d{1,2})\b", text, re.I)
    if m:
        return f"{int(m.group(1)):02d}"

    m = re.search(r"\b(?:Season|Series)[ ._-]*0*(\d{1,2})\b", text, re.I)
    if m:
        return f"{int(m.group(1)):02d}"

    # Legacy TV scene naming: 5x01, 05x01, or 5 x 01.
    m = re.search(r"\b0*(\d{1,2})\s*x\s*\d{1,3}\b", text, re.I)
    if m:
        return f"{int(m.group(1)):02d}"

    return "01"


def detect_episode(filename: str) -> str:
    filename = str(filename)
    m = re.search(r"\bS\d{1,2}\s*E\s*(\d{1,3})\b", filename, re.I)
    if m:
        return f"{int(m.group(1)):02d}"
    m = re.search(r"\b\d{1,2}\s*x\s*(\d{1,3})\b", filename, re.I)
    if m:
        return f"{int(m.group(1)):02d}"
    return ""

def strip_release_words(text: str) -> str:
    original = str(text)
    text = pretty(text)
    text = re.sub(r"\s+S\d{1,2}.*$", "", text, flags=re.I)
    text = re.sub(r"\s+Season\s*\d{1,2}.*$", "", text, flags=re.I)
    text = re.sub(r"\s+\b(19\d{2}|20\d{2})\b.*$", "", text)
    for word in QUALITY_WORDS:
        text = re.sub(rf"\s+\b{re.escape(word)}\b.*$", "", text, flags=re.I)
    text = re.sub(r"\[[^\]]+\]|\([^\)]*?(remux|x264|x265|hevc|web|bluray|hdr)[^\)]*?\)", "", text, flags=re.I)
    text = clean_spaces(text)
    return title_case_guess(text) if text else original

def is_skippable_video(path: Path) -> bool:
    """Skip sample/trailer/extras clips so they do not become imports."""
    p = Path(path)
    parts = [str(part).lower() for part in p.parts]
    name = p.name.lower()
    stem = p.stem.lower()

    for hint in SKIP_VIDEO_HINTS:
        if hint in parts or hint in name or hint in stem:
            return True

    # Common release-group sample names like Sample.mkv or movie.sample.mkv.
    if re.search(r"(^|[ ._\-\[\(])sample([ ._\-\]\)]|$)", name, re.I):
        return True

    return False

def find_videos(folder: Path):
    folder = Path(folder)
    if not folder.exists():
        return []
    return sorted(
        [
            p for p in folder.rglob("*")
            if p.is_file()
            and p.suffix.lower() in VIDEO_EXTENSIONS
            and not is_skippable_video(p)
        ],
        key=lambda p: str(p).lower()
    )

def looks_like_tv_name(name: str) -> bool:
    return bool(re.search(r"\bS\d{1,2}\b|\bS\d{1,2}\s*E\s*\d{1,3}\b|\bSeason[ ._-]*\d{1,2}\b|\b\d{1,2}\s*x\s*\d{1,3}\b", str(name), re.I))

def looks_like_multi_movie_folder(folder: Path) -> bool:
    """Detect a download folder that contains multiple separate movie folders.

    Example:
      Minions.2015-2022.../
        Minions.2015.../movie.mkv
        Minions.The.Rise.of.Gru.2022.../movie.mkv

    That should default to Movie / Movie Collection, not TV.
    """
    folder = Path(folder)
    if not folder.exists() or not folder.is_dir():
        return False

    child_movie_dirs = []
    for child in folder.iterdir():
        if not child.is_dir():
            continue
        if child.name.lower() in {"sample", "samples", "subs", "subtitles", "extras", "trailers"}:
            continue
        videos = find_videos(child)
        if videos:
            child_movie_dirs.append(child)

    if len(child_movie_dirs) < 2:
        return False

    # If the folder names look like TV seasons/episodes, do not call it a movie collection.
    if any(looks_like_tv_name(child.name) for child in child_movie_dirs):
        return False

    # A year in at least one child folder is a strong signal for separate movies.
    if any(detect_year(child.name) for child in child_movie_dirs):
        return True

    # Distinct child folders with one main video each are still likely a movie pack.
    return True

def guess_type(name: str, video_count: int) -> str:
    if re.search(r"\bS\d{1,2}\b|\bSeason[ ._-]*\d{1,2}\b", str(name), re.I):
        return "tv"
    if video_count >= 3:
        return "tv"
    return "movie"
