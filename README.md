# NASDY Media Linker v2.0

A lightweight unRAID app for hard-linking completed downloads into Jellyfin-friendly folders while keeping qBittorrent seeding untouched.

## v2.0 highlights

- qBittorrent integration foundation
- Completed torrent queue when qBittorrent is configured
- Folder fallback when qBittorrent is not configured
- Search/filter box
- Better import database
- Duplicate import warnings
- Dry-run table
- TMDb/Jellyfin foundations remain available

## Install / Update

Replace the files in:

```bash
/mnt/user/appdata/nasdy-media-organizer
```

Then run:

```bash
cd /mnt/user/appdata/nasdy-media-organizer
chmod +x install-unraid.sh
./install-unraid.sh
```

Open:

```text
http://NASDY:8088
```

## Optional qBittorrent config

Edit `install-unraid.sh` later and set:

```bash
-e QBITTORRENT_URL="http://192.168.0.109:8080" \
-e QBITTORRENT_USERNAME="your_username" \
-e QBITTORRENT_PASSWORD="your_password" \
```

Then rerun:

```bash
./install-unraid.sh
```
