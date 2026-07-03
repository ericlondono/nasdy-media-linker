import requests


def tmdb_search(settings, media_type: str, title: str, year: str = ""):
    """
    Search TMDb for a movie or TV show.

    Returns a small normalized metadata object or None.
    """
    api_key = settings.get("tmdb_api_key", "").strip()
    if not api_key or not title:
        return None

    endpoint = "tv" if media_type == "tv" else "movie"
    url = f"https://api.themoviedb.org/3/search/{endpoint}"

    params = {
        "api_key": api_key,
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
        response = requests.get(url, params=params, timeout=8)
        response.raise_for_status()
        results = response.json().get("results", [])

        if not results and year:
            # Fall back without year if the first search was too strict.
            params.pop("first_air_date_year", None)
            params.pop("year", None)
            response = requests.get(url, params=params, timeout=8)
            response.raise_for_status()
            results = response.json().get("results", [])

        if not results:
            return None

        item = results[0]
        poster_path = item.get("poster_path")
        backdrop_path = item.get("backdrop_path")
        release_date = item.get("first_air_date") or item.get("release_date") or ""

        return {
            "id": item.get("id"),
            "media_type": media_type,
            "title": item.get("name") or item.get("title") or title,
            "year": release_date[:4],
            "overview": item.get("overview", ""),
            "poster": f"https://image.tmdb.org/t/p/w342{poster_path}" if poster_path else "",
            "backdrop": f"https://image.tmdb.org/t/p/w780{backdrop_path}" if backdrop_path else "",
            "score": round(float(item.get("vote_average", 0)), 1),
            "votes": int(item.get("vote_count", 0)),
        }
    except Exception:
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
