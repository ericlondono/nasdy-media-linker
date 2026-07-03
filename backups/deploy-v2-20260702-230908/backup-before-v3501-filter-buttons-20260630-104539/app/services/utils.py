import re
from pathlib import Path
from app.config import VIDEO_EXTENSIONS, QUALITY_WORDS

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
    m = re.search(r"\bS(\d{1,2})\b", text, re.I)
    if m:
        return f"{int(m.group(1)):02d}"
    m = re.search(r"\bSeason[ ._-]*(\d{1,2})\b", text, re.I)
    if m:
        return f"{int(m.group(1)):02d}"
    return "01"

def detect_episode(filename: str) -> str:
    filename = str(filename)
    m = re.search(r"\bS\d{1,2}E(\d{1,3})\b", filename, re.I)
    if m:
        return f"{int(m.group(1)):02d}"
    m = re.search(r"\b\d{1,2}x(\d{1,3})\b", filename, re.I)
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

def find_videos(folder: Path):
    folder = Path(folder)
    if not folder.exists():
        return []
    return sorted(
        [p for p in folder.rglob("*") if p.is_file() and p.suffix.lower() in VIDEO_EXTENSIONS],
        key=lambda p: str(p).lower()
    )

def guess_type(name: str, video_count: int) -> str:
    if re.search(r"\bS\d{1,2}\b|\bSeason[ ._-]*\d{1,2}\b", str(name), re.I):
        return "tv"
    if video_count >= 3:
        return "tv"
    return "movie"
