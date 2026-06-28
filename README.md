# NASDY Media Linker v3.0

A lightweight unRAID app that hard-links completed downloads into Jellyfin-friendly folders while preserving qBittorrent seeding.

## v3.0

- Reorganized project structure
- Hard-link resolver for unRAID cache/disk paths
- Developer Mode page
- Link diagnostics
- qBittorrent settings remain in the web UI
- Folder mode fallback
- Import tracking

## Install / update on unRAID

```bash
cd /mnt/user/appdata/nasdy-media-organizer
git pull
chmod +x install-unraid.sh
./install-unraid.sh
```

Open:

```text
http://NASDY:8088
```

## Important volume

v3.0 mounts `/mnt` into the container at `/host_mnt` so Media Linker can resolve real unRAID paths like:

```text
/host_mnt/cache/NASDY/downloads/...
/host_mnt/disk1/NASDY/media/...
```

That is what lets it avoid `Invalid cross-device link` issues.
