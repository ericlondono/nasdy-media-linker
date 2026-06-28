#!/bin/bash
set -e

APP_DIR="/mnt/user/appdata/nasdy-media-organizer"
IMAGE_NAME="nasdy-media-linker:latest"
CONTAINER_NAME="nasdy-media-organizer"

echo "Stopping old container if it exists..."
docker stop "$CONTAINER_NAME" 2>/dev/null || true
docker rm "$CONTAINER_NAME" 2>/dev/null || true

mkdir -p "$APP_DIR/data"

echo "Building NASDY Media Linker v3.0..."
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
  -e HOST_DOWNLOADS_ROOT="/mnt/user/NASDY/downloads" \
  -e HOST_MEDIA_ROOT="/mnt/user/NASDY/media" \
  -v "/mnt/user/NASDY/downloads:/downloads" \
  -v "/mnt/user/NASDY/media:/media" \
  -v "/mnt/user/appdata/nasdy-media-organizer/data:/data" \
  -v "/mnt:/host_mnt" \
  "$IMAGE_NAME"

echo
echo "Done. Open: http://NASDY:8088"
echo
echo "v3.0 includes Developer Mode and a real hard-link resolver."
