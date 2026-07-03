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