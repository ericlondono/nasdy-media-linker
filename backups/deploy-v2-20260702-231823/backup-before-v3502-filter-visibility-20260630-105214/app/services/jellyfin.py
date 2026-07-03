import requests

def jellyfin_refresh(settings):
    url = settings.get("jellyfin_url", "").rstrip("/")
    api_key = settings.get("jellyfin_api_key", "")
    if not url or not api_key:
        return False, "Jellyfin refresh not configured."
    try:
        r = requests.post(f"{url}/Library/Refresh", headers={"X-Emby-Token": api_key}, timeout=8)
        if r.status_code in (200, 204):
            return True, "Jellyfin scan requested."
        return False, f"Jellyfin returned HTTP {r.status_code}."
    except Exception as e:
        return False, str(e)
