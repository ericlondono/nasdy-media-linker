import json
from app.config import HISTORY_FILE, IMPORT_DB_FILE, SETTINGS_FILE

DEFAULT_SETTINGS = {
    "qbittorrent_enabled": False,
    "qbittorrent_url": "",
    "qbittorrent_username": "",
    "qbittorrent_password": "",
    "tmdb_api_key": "",
    "jellyfin_url": "",
    "jellyfin_api_key": "",
    "developer_mode": True,
}

def load_json(path, default):
    if not path.exists():
        return default.copy() if isinstance(default, dict) else default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default.copy() if isinstance(default, dict) else default

def save_json(path, data):
    path.write_text(json.dumps(data, indent=2), encoding="utf-8")

def load_settings():
    data = DEFAULT_SETTINGS.copy()
    data.update(load_json(SETTINGS_FILE, {}))
    return data

def save_settings(data):
    cleaned = DEFAULT_SETTINGS.copy()
    cleaned.update(data)
    save_json(SETTINGS_FILE, cleaned)

def load_import_db():
    return load_json(IMPORT_DB_FILE, {})

def save_import_db(db):
    save_json(IMPORT_DB_FILE, db)

def append_history(entry):
    with HISTORY_FILE.open("a", encoding="utf-8") as f:
        f.write(json.dumps(entry) + "\n")

def read_history(limit=30):
    if not HISTORY_FILE.exists():
        return []
    lines = HISTORY_FILE.read_text(encoding="utf-8").splitlines()
    out = []
    for line in reversed(lines[-limit:]):
        try:
            out.append(json.loads(line))
        except Exception:
            pass
    return out
