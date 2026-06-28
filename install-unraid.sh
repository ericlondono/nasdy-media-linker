#!/bin/bash
set -e

APP_DIR="/mnt/user/appdata/nasdy-media-organizer"
IMAGE_NAME="nasdy-media-linker:latest"
CONTAINER_NAME="nasdy-media-organizer"

echo "Stopping old container if it exists..."
docker stop "$CONTAINER_NAME" 2>/dev/null || true
docker rm "$CONTAINER_NAME" 2>/dev/null || true

mkdir -p "$APP_DIR/data"

echo "Building NASDY Media Linker v2.0..."
cd "$APP_DIR"
docker build -t "$IMAGE_NAME" .

echo "Starting NASDY Media Linker..."
docker run -d \
  --name="$CONTAINER_NAME" \
  --restart unless-stopped \
  -p 8088:8088 \
  -e DOWNLOADS_ROOT=/downloads \
  -e MOVIES_ROOT="/media/Movies" \
  -e TV_ROOT="/media/TV Shows" \
  -e TMDB_API_KEY="${TMDB_API_KEY:-}" \
  -e JELLYFIN_URL="${JELLYFIN_URL:-}" \
  -e JELLYFIN_API_KEY="${JELLYFIN_API_KEY:-}" \
  -e QBITTORRENT_URL="${QBITTORRENT_URL:-}" \
  -e QBITTORRENT_USERNAME="${QBITTORRENT_USERNAME:-}" \
  -e QBITTORRENT_PASSWORD="${QBITTORRENT_PASSWORD:-}" \
  -v "/mnt/user/NASDY/downloads:/downloads" \
  -v "/mnt/user/NASDY/media:/media" \
  -v "/mnt/user/appdata/nasdy-media-organizer/data:/data" \
  "$IMAGE_NAME"

echo
echo "Done. Open: http://NASDY:8088"
echo
echo "qBittorrent is optional. To enable it later, edit this install script and set:"
echo "QBITTORRENT_URL, QBITTORRENT_USERNAME, QBITTORRENT_PASSWORD"
