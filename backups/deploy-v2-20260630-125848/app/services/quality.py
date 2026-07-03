import re
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional

from app.services.utils import find_videos


MISSING = {
    "score": 0,
    "summary": "Unknown quality",
    "tags": [],
    "resolution": "",
    "source": "",
    "codec": "",
    "hdr": "",
    "audio": "",
    "confidence": "low",
}


RESOLUTION_RULES = [
    (re.compile(r"\b(4320p|8k)\b", re.I), "8K", 700),
    (re.compile(r"\b(2160p|4k|uhd)\b", re.I), "2160p", 520),
    (re.compile(r"\b1080p\b", re.I), "1080p", 340),
    (re.compile(r"\b720p\b", re.I), "720p", 220),
    (re.compile(r"\b(576p|480p|dvdrip)\b", re.I), "480p", 120),
]

SOURCE_RULES = [
    (re.compile(r"\b(remux|bdremux)\b", re.I), "Remux", 95),
    (re.compile(r"\b(bluray|blu-ray|bdrip|brrip)\b", re.I), "BluRay", 75),
    (re.compile(r"\b(web[- ._]?dl|webdl)\b", re.I), "WEB-DL", 62),
    (re.compile(r"\bwebrip\b", re.I), "WEBRip", 50),
    (re.compile(r"\bhdtv\b", re.I), "HDTV", 38),
    (re.compile(r"\b(hdrip|dvdrip)\b", re.I), "Rip", 28),
]

CODEC_RULES = [
    (re.compile(r"\b(av1)\b", re.I), "AV1", 42),
    (re.compile(r"\b(hevc|h[ ._]?265|x265)\b", re.I), "HEVC", 36),
    (re.compile(r"\b(h[ ._]?264|x264)\b", re.I), "H.264", 22),
]

HDR_RULES = [
    (re.compile(r"\b(dolby[ ._]?vision|dv)\b", re.I), "Dolby Vision", 40),
    (re.compile(r"\b(hdr10\+|hdr10|hdr)\b", re.I), "HDR", 30),
]

AUDIO_RULES = [
    (re.compile(r"\batmos\b", re.I), "Atmos", 28),
    (re.compile(r"\btruehd\b", re.I), "TrueHD", 26),
    (re.compile(r"\bdts[- ._]?hd\b", re.I), "DTS-HD", 22),
    (re.compile(r"\bdts\b", re.I), "DTS", 16),
    (re.compile(r"\bddp|eac3\b", re.I), "DD+", 12),
    (re.compile(r"\bac3\b", re.I), "AC3", 8),
]

CHANNEL_RULES = [
    (re.compile(r"\b7[ ._]1\b", re.I), "7.1", 12),
    (re.compile(r"\b5[ ._]1\b", re.I), "5.1", 8),
]


def _normalize_texts(texts: Iterable[Any]) -> str:
    return " ".join(str(t or "") for t in texts if str(t or "").strip()).replace("_", " ").replace(".", " ")


def _first_match(text: str, rules):
    for pattern, label, score in rules:
        if pattern.search(text):
            return label, score
    return "", 0


def _all_matches(text: str, rules):
    out = []
    seen = set()
    score = 0
    for pattern, label, points in rules:
        if pattern.search(text) and label not in seen:
            seen.add(label)
            out.append(label)
            score += points
    return out, score


def analyze_quality_from_texts(texts: Iterable[Any]) -> Dict[str, Any]:
    text = _normalize_texts(texts)
    if not text.strip():
        return dict(MISSING)

    resolution, resolution_score = _first_match(text, RESOLUTION_RULES)
    source, source_score = _first_match(text, SOURCE_RULES)
    codec, codec_score = _first_match(text, CODEC_RULES)
    hdr_tags, hdr_score = _all_matches(text, HDR_RULES)
    audio_tags, audio_score = _all_matches(text, AUDIO_RULES)
    channel_tags, channel_score = _all_matches(text, CHANNEL_RULES)

    tags: List[str] = []
    for value in [resolution, source, codec] + hdr_tags + audio_tags + channel_tags:
        if value and value not in tags:
            tags.append(value)

    score = resolution_score + source_score + codec_score + hdr_score + audio_score + channel_score

    if not tags:
        return dict(MISSING)

    signal_count = sum(1 for value in [resolution, source, codec] if value) + len(hdr_tags) + len(audio_tags) + len(channel_tags)
    confidence = "high" if signal_count >= 3 else ("medium" if signal_count >= 2 else "low")

    return {
        "score": int(score),
        "summary": " ".join(tags) if tags else "Unknown quality",
        "tags": tags,
        "resolution": resolution,
        "source": source,
        "codec": codec,
        "hdr": ", ".join(hdr_tags),
        "audio": ", ".join(audio_tags + channel_tags),
        "confidence": confidence,
    }


def quality_for_planned_items(source: Any, planned_items: Optional[List[Dict[str, Any]]] = None) -> Dict[str, Any]:
    texts: List[str] = [Path(str(source or "")).name]
    for item in planned_items or []:
        try:
            src = Path(str(item.get("src") or ""))
            texts.append(src.name)
            if src.parent:
                texts.append(src.parent.name)
        except Exception:
            pass

    quality = analyze_quality_from_texts(texts)
    quality["path"] = str(source or "")
    return quality


def quality_for_library_match(library_match: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    if not library_match:
        return dict(MISSING)

    path = library_match.get("season_path") or library_match.get("path") or ""
    texts: List[str] = [
        library_match.get("title", ""),
        Path(str(path or "")).name,
    ]

    try:
        p = Path(str(path or ""))
        if p.exists():
            if p.is_file():
                texts.append(p.name)
            else:
                videos = find_videos(p)
                texts.extend(str(v.name) for v in videos[:20])
    except Exception:
        pass

    quality = analyze_quality_from_texts(texts)
    quality["path"] = str(path or "")
    return quality


def compare_quality(incoming: Dict[str, Any], existing: Dict[str, Any], library_match: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    incoming_score = int((incoming or {}).get("score") or 0)
    existing_score = int((existing or {}).get("score") or 0)

    if not library_match:
        return {
            "level": "new",
            "label": "New import",
            "recommendation": "No existing library item was found.",
            "score_delta": incoming_score,
        }

    if not incoming_score or not existing_score:
        return {
            "level": "unknown",
            "label": "Quality review",
            "recommendation": "Existing or incoming quality could not be detected from filename signals.",
            "score_delta": incoming_score - existing_score,
        }

    delta = incoming_score - existing_score

    if delta >= 80:
        return {
            "level": "upgrade",
            "label": "Upgrade candidate",
            "recommendation": "Incoming quality appears higher than the existing library item. This release remains non-destructive.",
            "score_delta": delta,
        }

    if delta <= -80:
        return {
            "level": "downgrade",
            "label": "Lower quality",
            "recommendation": "Incoming quality appears lower than the existing library item.",
            "score_delta": delta,
        }

    return {
        "level": "similar",
        "label": "Similar quality",
        "recommendation": "Incoming and existing quality appear similar based on filename signals.",
        "score_delta": delta,
    }


def quality_advice_for_import(source: Any, planned_items: Optional[List[Dict[str, Any]]] = None, library_match: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    incoming = quality_for_planned_items(source, planned_items)
    existing = quality_for_library_match(library_match)
    comparison = compare_quality(incoming, existing, library_match)

    return {
        "incoming": incoming,
        "existing": existing,
        "comparison": comparison,
        "summary": f"Incoming: {incoming.get('summary', 'Unknown quality')} | Existing: {existing.get('summary', 'Unknown quality') if library_match else 'Not found'}",
    }