import os
from pathlib import Path

APP_NAME = "NASDY Media Linker"
APP_VERSION = "v3.6.1.5"

DOWNLOADS_ROOT = Path(os.environ.get("DOWNLOADS_ROOT", "/downloads"))
MOVIES_ROOT = Path(os.environ.get("MOVIES_ROOT", "/media/movies"))
TV_ROOT = Path(os.environ.get("TV_ROOT", "/media/tv"))
DATA_ROOT = Path(os.environ.get("DATA_ROOT", "/data"))

HOST_DOWNLOADS_ROOT = os.environ.get("HOST_DOWNLOADS_ROOT", "/mnt/user/NASDY/downloads")
HOST_MEDIA_ROOT = os.environ.get("HOST_MEDIA_ROOT", "/mnt/user/NASDY/media")
HOST_MNT_ROOT = Path(os.environ.get("HOST_MNT_ROOT", "/host_mnt"))

VIDEO_EXTENSIONS = {".mkv", ".mp4", ".avi", ".mov", ".m4v", ".wmv"}

IGNORE_NAMES = {
    "audiobooks", "books", "print", "movies", "tv shows", "tv", "music",
    "media organizer", "lost+found", "media linker"
}

QUALITY_WORDS = [
    "2160p","1080p","720p","480p","webrip","web-rip","web-dl","webdl","bluray","blu-ray","brrip",
    "hdrip","dvdrip","uhd","truehd","remux","x264","x265","h264","h265","hevc","av1","flac","aac",
    "truehd","atmos","dts","dts-hd","ma","hdr","hdr10","dv","dolby","vision","proper","repack",
    "extended","unrated","directors","director","cut","amzn","amazon","nf","netflix","hulu","max",
    "lama","trolluhd","playweb","ddp","dd5","5.1","7.1","10bit","8bit","yts","rarbg", "eac3", "siqma"
]

DATA_ROOT.mkdir(parents=True, exist_ok=True)

HISTORY_FILE = DATA_ROOT / "history.jsonl"
IMPORT_DB_FILE = DATA_ROOT / "imports.json"
SETTINGS_FILE = DATA_ROOT / "settings.json"
LOG_FILE = DATA_ROOT / "media-linker.log"