import requests

def tmdb_search(settings, media_type: str, title: str, year: str):
    api_key = settings.get("tmdb_api_key", "")
    if not api_key or not title:
        return None

    endpoint = "tv" if media_type == "tv" else "movie"
    url = f"https://api.themoviedb.org/3/search/{endpoint}"
    params = {"api_key": api_key, "query": title}
    if year:
        params["first_air_date_year" if media_type == "tv" else "year"] = year

    try:
        r = requests.get(url, params=params, timeout=8)
        r.raise_for_status()
        results = r.json().get("results", [])
        if not results:
            return None
        item = results[0]
        poster = item.get("poster_path")
        return {
            "title": item.get("name") or item.get("title") or title,
            "year": (item.get("first_air_date") or item.get("release_date") or "")[:4],
            "overview": item.get("overview", ""),
            "poster": f"https://image.tmdb.org/t/p/w342{poster}" if poster else "",
            "score": item.get("vote_average", ""),
        }
    except Exception:
        return None
