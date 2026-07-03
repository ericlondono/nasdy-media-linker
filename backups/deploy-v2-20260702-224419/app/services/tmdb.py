import re
import requests


def _normalize_title(value: str) -> str:
    return "".join(ch.lower() for ch in str(value or "") if ch.isalnum())


def _tmdb_get(settings, path: str, params=None):
    api_key = settings.get("tmdb_api_key", "").strip()
    if not api_key:
        return None

    query = dict(params or {})
    query["api_key"] = api_key

    response = requests.get(
        f"https://api.themoviedb.org/3{path}",
        params=query,
        timeout=8,
    )
    response.raise_for_status()
    return response.json()


def _result_year(item):
    release_date = item.get("first_air_date") or item.get("release_date") or ""
    return str(release_date or "")[:4]


def _score_candidate(query_title: str, query_year: str, candidate: dict) -> float:
    query_norm = _normalize_title(query_title)
    title = candidate.get("title") or ""
    title_norm = _normalize_title(title)
    year = str(candidate.get("year") or "")

    score = 0.0
    if query_norm and title_norm:
        if query_norm == title_norm:
            score += 100
        elif query_norm in title_norm or title_norm in query_norm:
            score += 70
        else:
            query_words = set(re.findall(r"[a-z0-9]+", str(query_title).lower()))
            title_words = set(re.findall(r"[a-z0-9]+", str(title).lower()))
            if query_words and title_words:
                score += 45 * (len(query_words.intersection(title_words)) / max(len(query_words), len(title_words)))

    if query_year and year:
        score += 35 if str(query_year) == year else -25

    score += min(float(candidate.get("votes") or 0), 5000) / 5000 * 10
    score += min(float(candidate.get("popularity") or 0), 100) / 100 * 5
    return round(score, 3)


def _normalize_result(item: dict, media_type: str, fallback_title: str, query_title: str, query_year: str) -> dict:
    poster_path = item.get("poster_path")
    backdrop_path = item.get("backdrop_path")
    release_date = item.get("first_air_date") or item.get("release_date") or ""
    title = item.get("name") or item.get("title") or fallback_title

    normalized = {
        "id": item.get("id"),
        "media_type": media_type,
        "title": title,
        "year": str(release_date or "")[:4],
        "overview": item.get("overview", ""),
        "poster": f"https://image.tmdb.org/t/p/w342{poster_path}" if poster_path else "",
        "backdrop": f"https://image.tmdb.org/t/p/w780{backdrop_path}" if backdrop_path else "",
        "score": round(float(item.get("vote_average", 0)), 1),
        "votes": int(item.get("vote_count", 0)),
        "popularity": float(item.get("popularity", 0) or 0),
    }
    normalized["match_score"] = _score_candidate(query_title, query_year, normalized)
    return normalized


def tmdb_search_candidates(settings, media_type: str, title: str, year: str = "", limit: int = 5):
    """
    Search TMDb and return normalized candidates sorted by a local title/year score.
    """
    api_key = settings.get("tmdb_api_key", "").strip()
    if not api_key or not title:
        return []

    media_type = "tv" if media_type == "tv" else "movie"
    endpoint = "tv" if media_type == "tv" else "movie"

    params = {
        "query": title,
        "include_adult": "false",
        "language": "en-US",
        "page": 1,
    }

    if year:
        if media_type == "tv":
            params["first_air_date_year"] = year
        else:
            params["year"] = year

    try:
        data = _tmdb_get(settings, f"/search/{endpoint}", params)
        results = (data or {}).get("results", [])

        if not results and year:
            params.pop("first_air_date_year", None)
            params.pop("year", None)
            data = _tmdb_get(settings, f"/search/{endpoint}", params)
            results = (data or {}).get("results", [])

        candidates = [
            _normalize_result(item, media_type, title, title, year)
            for item in results or []
            if item.get("id")
        ]
        candidates.sort(key=lambda item: item.get("match_score", 0), reverse=True)
        return candidates[: max(1, int(limit or 5))]
    except Exception:
        return []


def tmdb_external_ids(settings, media_type: str, tmdb_id):
    """Return TMDb external IDs for a movie or TV show."""
    api_key = settings.get("tmdb_api_key", "").strip()
    if not api_key or not tmdb_id:
        return {}

    media_type = "tv" if media_type == "tv" else "movie"
    endpoint = "tv" if media_type == "tv" else "movie"

    try:
        return _tmdb_get(settings, f"/{endpoint}/{tmdb_id}/external_ids", {}) or {}
    except Exception:
        return {}


def tmdb_search_with_imdb(settings, media_type: str, title: str, year: str = ""):
    """
    Return the best TMDb match plus IMDb ID when TMDb exposes one.
    """
    candidates = tmdb_search_candidates(settings, media_type, title, year, limit=1)
    if not candidates:
        return None

    item = candidates[0]
    external = tmdb_external_ids(settings, media_type, item.get("id"))
    item["imdb_id"] = (external or {}).get("imdb_id") or ""
    item["external_ids"] = external or {}
    return item



def _media_type_label(media_type: str) -> str:
    return "TV show" if media_type == "tv" else "Movie"


def _rank_metadata_candidate(item: dict, preferred_media_type: str = "", query_title: str = "", query_year: str = "") -> float:
    preferred = "tv" if preferred_media_type == "tv" else ("movie" if preferred_media_type == "movie" else "")
    score = float((item or {}).get("match_score") or 0)

    if preferred and (item or {}).get("media_type") == preferred:
        score += 3

    if (item or {}).get("imdb_id"):
        score += 2

    if query_year and str((item or {}).get("year") or "") == str(query_year):
        score += 8

    return score


def _parse_media_identifier(value: str) -> dict:
    text = str(value or "").strip()
    if not text:
        return {}

    imdb = re.search(r"(tt\d{5,12})", text, re.I)
    if imdb:
        return {"kind": "imdb", "id": imdb.group(1).lower()}

    tmdb_url = re.search(r"themoviedb\.org/(movie|tv)/(\d+)", text, re.I)
    if tmdb_url:
        return {
            "kind": "tmdb",
            "media_type": "tv" if tmdb_url.group(1).lower() == "tv" else "movie",
            "id": tmdb_url.group(2),
        }

    typed = re.search(r"\b(movie|tv)[:/#\s-]*(\d{2,10})\b", text, re.I)
    if typed:
        return {
            "kind": "tmdb",
            "media_type": "tv" if typed.group(1).lower() == "tv" else "movie",
            "id": typed.group(2),
        }

    loose_typed = re.search(r"\btmdb[:#\s-]*(movie|tv)?[:/#\s-]*(\d{2,10})\b", text, re.I)
    if loose_typed:
        media_type = loose_typed.group(1) or ""
        return {
            "kind": "tmdb",
            "media_type": "tv" if media_type.lower() == "tv" else ("movie" if media_type.lower() == "movie" else ""),
            "id": loose_typed.group(2),
        }

    if re.fullmatch(r"\d{2,10}", text):
        return {"kind": "tmdb", "media_type": "", "id": text}

    return {}


def _normalize_detail_result(settings, media_type: str, item: dict, query_title: str = "", query_year: str = "") -> dict:
    if not item or not item.get("id"):
        return {}

    fallback = item.get("name") or item.get("title") or query_title or ""
    normalized = _normalize_result(item, "tv" if media_type == "tv" else "movie", fallback, query_title or fallback, query_year or _result_year(item))
    normalized["match_confidence"] = max(int(normalized.get("match_confidence") or 0), 98)
    normalized["confidence_level"] = "high"
    normalized["confidence_label"] = "ID match"
    external = tmdb_external_ids(settings, normalized.get("media_type"), normalized.get("id"))
    normalized["imdb_id"] = (external or {}).get("imdb_id") or ""
    normalized["external_ids"] = external or {}
    normalized["alternatives"] = []
    normalized["route_label"] = f"Resolved as {_media_type_label(normalized.get('media_type'))}"
    return normalized


def tmdb_lookup_identifier(settings, identifier: str, preferred_media_type: str = "", query_title: str = "", query_year: str = ""):
    """
    Resolve IMDb IDs, TMDb URLs, or TMDb numeric IDs into a normalized movie/TV metadata object.

    This is used by the Import Manager when a row starts as the wrong type but the user pastes
    an identifier, or when a mixed collection needs a TV/movie route decision.
    """
    parsed = _parse_media_identifier(identifier)
    if not parsed:
        return None

    preferred = "tv" if preferred_media_type == "tv" else ("movie" if preferred_media_type == "movie" else "")

    try:
        if parsed.get("kind") == "imdb":
            data = _tmdb_get(settings, f"/find/{parsed.get('id')}", {"external_source": "imdb_id"}) or {}
            candidates = []

            for media_type, key in (("movie", "movie_results"), ("tv", "tv_results")):
                for item in data.get(key, []) or []:
                    normalized = _normalize_detail_result(settings, media_type, item, query_title, query_year)
                    if normalized:
                        normalized["imdb_id"] = parsed.get("id")
                        normalized["confidence_label"] = "IMDb ID match"
                        normalized["source_identifier"] = parsed.get("id")
                        candidates.append(normalized)

            if not candidates:
                return None

            candidates.sort(key=lambda item: _rank_metadata_candidate(item, preferred, query_title, query_year), reverse=True)
            return candidates[0]

        if parsed.get("kind") == "tmdb":
            parsed_media_type = parsed.get("media_type") or ""
            id_value = parsed.get("id")
            media_types = []

            if parsed_media_type:
                media_types = [parsed_media_type]
            else:
                if preferred:
                    media_types.append(preferred)
                media_types.extend(mt for mt in ("movie", "tv") if mt not in media_types)

            candidates = []
            for media_type in media_types:
                endpoint = "tv" if media_type == "tv" else "movie"
                try:
                    detail = _tmdb_get(settings, f"/{endpoint}/{id_value}", {}) or {}
                except Exception:
                    continue

                normalized = _normalize_detail_result(settings, media_type, detail, query_title, query_year)
                if normalized:
                    normalized["source_identifier"] = str(id_value)
                    normalized["confidence_label"] = "TMDb ID match"
                    candidates.append(normalized)

            if not candidates:
                return None

            candidates.sort(key=lambda item: _rank_metadata_candidate(item, preferred, query_title, query_year), reverse=True)
            return candidates[0]
    except Exception:
        return None

    return None


def tmdb_search_best_any(settings, title: str, year: str = "", preferred_media_type: str = ""):
    """
    Search both TMDb movie and TV endpoints, then return the best normalized result.

    This lets mixed folders auto-route rows as movies or TV shows instead of assuming
    every row should keep the queue-level media type.
    """
    title = str(title or "").strip()
    if not title:
        return None

    preferred = "tv" if preferred_media_type == "tv" else ("movie" if preferred_media_type == "movie" else "")
    search_order = []
    if preferred:
        search_order.append(preferred)
    search_order.extend(mt for mt in ("movie", "tv") if mt not in search_order)

    candidates = []
    for media_type in search_order:
        for item in tmdb_search_candidates(settings, media_type, title, year, limit=5) or []:
            item = dict(item)
            item["media_type"] = "tv" if item.get("media_type") == "tv" else "movie"
            candidates.append(item)

    if not candidates:
        return None

    candidates.sort(key=lambda item: _rank_metadata_candidate(item, preferred, title, year), reverse=True)
    best = dict(candidates[0])
    external = tmdb_external_ids(settings, best.get("media_type"), best.get("id"))
    best["imdb_id"] = (external or {}).get("imdb_id") or ""
    best["external_ids"] = external or {}
    best["alternatives"] = [
        {
            "id": alt.get("id"),
            "media_type": alt.get("media_type"),
            "title": alt.get("title"),
            "year": alt.get("year"),
            "poster": alt.get("poster"),
            "match_confidence": alt.get("match_confidence"),
            "confidence_level": alt.get("confidence_level"),
            "confidence_label": alt.get("confidence_label"),
        }
        for alt in candidates[1:4]
    ]
    best["route_label"] = f"Auto routed as {_media_type_label(best.get('media_type'))}"
    return best
def tmdb_search(settings, media_type: str, title: str, year: str = ""):
    """
    Search TMDb for a movie or TV show.

    Returns a small normalized metadata object or None.
    """
    item = tmdb_search_with_imdb(settings, media_type, title, year)
    if item:
        return item
    return None


def test_tmdb(settings):
    """
    Validate the TMDb API key by calling the configuration endpoint.
    """
    api_key = settings.get("tmdb_api_key", "").strip()
    if not api_key:
        raise ValueError("TMDb API key is required.")

    response = requests.get(
        "https://api.themoviedb.org/3/configuration",
        params={"api_key": api_key},
        timeout=8,
    )

    if response.status_code != 200:
        raise ValueError(f"TMDb connection failed. HTTP {response.status_code}: {response.text[:100]}")

    return True