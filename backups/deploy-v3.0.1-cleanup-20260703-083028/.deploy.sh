#!/bin/sh
set -eu

APP_DIR="${NASDY_REMOTE_APP_PATH:-$(pwd)}"
IMAGE_NAME="${NASDY_IMAGE_NAME:-nasdy-media-linker:latest}"
CONTAINER_NAME="${NASDY_CONTAINER_NAME:-nasdy-media-organizer}"
PORT="${NASDY_PORT:-8088}"
DOWNLOADS_HOST="/mnt/user/NASDY/downloads"
MEDIA_HOST="/mnt/user/NASDY/media"
APP_DATA_HOST="/mnt/user/appdata/nasdy-media-organizer/data"
HOST_ROOT="/mnt"

deploy_start=$(date +%s)

log() {
  printf '%s\n' "[NASDY Remote] $*"
}

fail() {
  printf '%s\n' "[NASDY Remote] ERROR: $*" >&2
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
    printf '%s\n' "[NASDY Remote] Last container logs:" >&2
    docker logs --tail=80 "$CONTAINER_NAME" >&2 || true
  fi
  exit 1
}

fetch_health() {
  url="http://127.0.0.1:${PORT}/health"
  if command -v curl >/dev/null 2>&1; then
    curl -fsS "$url"
    return $?
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -qO- "$url"
    return $?
  fi
  return 127
}

command -v docker >/dev/null 2>&1 || fail "docker command was not found on the NAS."

cd "$APP_DIR" || fail "Could not cd to app dir: $APP_DIR"

mkdir -p "$DOWNLOADS_HOST" "$MEDIA_HOST" "$APP_DATA_HOST"

log "Building Docker image: $IMAGE_NAME"
build_start=$(date +%s)
docker build -t "$IMAGE_NAME" "$APP_DIR" || fail "Docker build failed."
build_end=$(date +%s)
build_seconds=$((build_end - build_start))

env_file_args=""
if [ -f "$APP_DIR/.env" ]; then
  env_file_args="--env-file $APP_DIR/.env"
  log "Using env file: $APP_DIR/.env"
fi

log "Restarting container: $CONTAINER_NAME"
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  docker rm -f "$CONTAINER_NAME" >/dev/null || fail "Could not remove existing container."
fi

container_id=$(docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  -p "${PORT}:8088" \
  -v "${DOWNLOADS_HOST}:/downloads" \
  -v "${MEDIA_HOST}:/media" \
  -v "${APP_DATA_HOST}:/app/data" \
  -v "${HOST_ROOT}:/host_mnt" \
  $env_file_args \
  "$IMAGE_NAME") || fail "Docker run failed."

log "Started container: $container_id"

if ! docker exec "$CONTAINER_NAME" test -d /host_mnt; then
  fail "/host_mnt does not exist inside the running container. Required mount is missing."
fi

health_status="FAILED"
health_body=""
health_attempt=1
while [ "$health_attempt" -le 30 ]; do
  if health_body=$(fetch_health 2>/dev/null); then
    health_status="OK"
    break
  fi
  sleep 2
  health_attempt=$((health_attempt + 1))
done

if [ "$health_status" != "OK" ]; then
  fail "Health check failed at http://127.0.0.1:${PORT}/health"
fi

container_status=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || printf 'unknown')
mounts=$(docker inspect -f '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)
deploy_end=$(date +%s)
deploy_seconds=$((deploy_end - deploy_start))

printf '%s\n' ""
printf '%s\n' "NASDY_DEPLOY_SUMMARY_START"
printf '%s\n' "Build time: ${build_seconds}s"
printf '%s\n' "Deploy time: ${deploy_seconds}s"
printf '%s\n' "Health status: ${health_status}"
printf '%s\n' "Health response: ${health_body}"
printf '%s\n' "Container status: ${container_status}"
printf '%s\n' "Image name: ${IMAGE_NAME}"
printf '%s\n' "Container name: ${CONTAINER_NAME}"
printf '%s\n' "Active port: ${PORT}:8088"
printf '%s\n' "Required mounts:"
printf '%s\n' "  ${DOWNLOADS_HOST}:/downloads"
printf '%s\n' "  ${MEDIA_HOST}:/media"
printf '%s\n' "  ${APP_DATA_HOST}:/app/data"
printf '%s\n' "  ${HOST_ROOT}:/host_mnt"
printf '%s\n' "Container mounts:"
printf '%s\n' "$mounts" | sed 's/^/  /'
printf '%s\n' "NASDY_DEPLOY_SUMMARY_END"
printf '%s\n' ""
