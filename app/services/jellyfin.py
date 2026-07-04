import re
from typing import Any, Dict, Tuple
from urllib.parse import urlparse, urlunparse

import requests

from app.services.logger import log


def normalize_jellyfin_url(value: Any) -> str:
    """
    Return a clean Jellyfin server base URL.

    This intentionally fixes the easy-to-miss settings typo seen in the UI:
    http://http://192.168.x.x:8096 -> http://192.168.x.x:8096
    """
    text = str(value or "").strip()
    if not text:
        return ""

    # Remove accidental spaces copied from browser/address bars.
    text = re.sub(r"\s+", "", text)

    # Fix repeated protocol prefixes without changing the user's intended scheme.
    # Examples:
    #   http://http://host -> http://host
    #   https://https://host -> https://host
    #   https://http://host -> https://host
    for _ in range(5):
        updated = re.sub(r"^(https?://)(https?://)", r"\1", text, flags=re.I)
        if updated == text:
            break
        text = updated

    if not re.match(r"^https?://", text, flags=re.I):
        text = "http://" + text

    text = text.rstrip("/")

    parsed = urlparse(text)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        return ""

    # If the browser app URL was pasted, trim it back to the server root.
    path = parsed.path or ""
    if path.lower().startswith("/web") or path.lower().endswith("/web/index.html"):
        path = ""

    normalized = urlunparse((parsed.scheme, parsed.netloc, path.rstrip("/"), "", "", ""))
    return normalized.rstrip("/")


def _api_key(settings: Dict[str, Any]) -> str:
    return str((settings or {}).get("jellyfin_api_key") or "").strip()


def _headers(api_key: str) -> Dict[str, str]:
    return {
        "X-Emby-Token": api_key,
        "X-MediaBrowser-Token": api_key,
        "Accept": "application/json",
    }


def _status_message(prefix: str, response: requests.Response) -> str:
    body = ""
    try:
        body = (response.text or "").strip()
    except Exception:
        body = ""
    if body:
        body = body.replace("\n", " ").replace("\r", " ")[:180]
        return f"{prefix} Jellyfin returned HTTP {response.status_code}: {body}"
    return f"{prefix} Jellyfin returned HTTP {response.status_code}."


def test_jellyfin(settings: Dict[str, Any]) -> Tuple[bool, str]:
    url = normalize_jellyfin_url((settings or {}).get("jellyfin_url"))
    api_key = _api_key(settings or {})

    if not url:
        return False, "Jellyfin URL is missing or invalid. Use something like http://192.168.0.109:8096."
    if not api_key:
        return False, "Jellyfin API key is missing."

    try:
        response = requests.get(f"{url}/System/Info", headers=_headers(api_key), timeout=8)
        if response.status_code == 200:
            try:
                data = response.json() or {}
            except Exception:
                data = {}
            server_name = data.get("ServerName") or data.get("LocalAddress") or "Jellyfin"
            version = data.get("Version") or ""
            version_text = f" {version}" if version else ""

            library_text = ""
            try:
                folders = requests.get(f"{url}/Library/VirtualFolders", headers=_headers(api_key), timeout=8)
                if folders.status_code == 200:
                    folder_data = folders.json() or []
                    if isinstance(folder_data, list):
                        library_text = f" {len(folder_data)} library folder(s) visible."
            except Exception:
                library_text = ""

            return True, f"Connected to {server_name}{version_text}.{library_text}".strip()

        if response.status_code in (401, 403):
            return False, "Jellyfin rejected the API key. Create/copy a new API key from the Jellyfin dashboard."

        return False, _status_message("Could not connect.", response)
    except requests.exceptions.RequestException as error:
        return False, f"Could not reach Jellyfin at {url}: {error}"
    except Exception as error:
        return False, f"Jellyfin test failed: {error}"


def jellyfin_refresh(settings: Dict[str, Any]) -> Tuple[bool, str]:
    url = normalize_jellyfin_url((settings or {}).get("jellyfin_url"))
    api_key = _api_key(settings or {})

    if not url:
        return False, "Jellyfin refresh not configured: URL is missing or invalid."
    if not api_key:
        return False, "Jellyfin refresh not configured: API key is missing."

    try:
        response = requests.post(f"{url}/Library/Refresh", headers=_headers(api_key), timeout=12)
        if response.status_code in (200, 202, 204):
            message = "Jellyfin library scan requested. New items may appear after Jellyfin finishes scanning."
            log(f"Jellyfin refresh requested successfully: url={url} status={response.status_code}")
            return True, message

        if response.status_code in (401, 403):
            message = "Jellyfin refresh failed: API key was rejected."
            log(f"WARN {message} status={response.status_code}")
            return False, message

        message = _status_message("Jellyfin refresh failed.", response)
        log(f"WARN {message}")
        return False, message
    except requests.exceptions.RequestException as error:
        message = f"Jellyfin refresh failed: could not reach {url}: {error}"
        log(f"WARN {message}")
        return False, message
    except Exception as error:
        message = f"Jellyfin refresh failed: {error}"
        log(f"WARN {message}")
        return False, message