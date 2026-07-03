#!/usr/bin/env bash
set -euo pipefail

REMOTE_PATH="/mnt/user/appdata/nasdy-media-organizer"
IMAGE_NAME="nasdy-media-linker:latest"
CONTAINER_NAME="nasdy-media-organizer"
PORT="8088"

echo ""
echo "NASDY Media Linker NAS deploy"
echo "Remote path: ${REMOTE_PATH}"
echo "Image:       ${IMAGE_NAME}"
echo "Container:   ${CONTAINER_NAME}"
echo "Port:        ${PORT}"
echo "Mount:       /mnt:/host_mnt"
echo ""

cd "${REMOTE_PATH}"

echo "==> Cleaning remote Python cache files"
find . -type d -name "__pycache__" -prune -exec rm -rf {} + 2>/dev/null || true
find . -type f -name "*.pyc" -delete 2>/dev/null || true
echo "[OK] Remote Python cache files cleaned"

echo ""
echo "==> Verifying required NAS paths"
for required_path in \
  "/mnt/user/NASDY/downloads" \
  "/mnt/user/NASDY/media" \
  "/mnt/user/appdata/nasdy-media-organizer/data" \
  "/mnt"
do
  if [ ! -e "${required_path}" ]; then
    echo "[ERROR] Required path missing: ${required_path}"
    exit 20
  fi
done
echo "[OK] Required NAS paths exist"

echo ""
echo "==> Building Docker image on NAS"
docker build -t "${IMAGE_NAME}" .
echo "[OK] Docker image built: ${IMAGE_NAME}"

echo ""
echo "==> Restarting container"
docker stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true
docker rm "${CONTAINER_NAME}" >/dev/null 2>&1 || true

docker run -d \
  --name "${CONTAINER_NAME}" \
  --restart unless-stopped \
  -p "${PORT}:8088" \
  -v /mnt/user/NASDY/downloads:/downloads \
  -v /mnt/user/NASDY/media:/media \
  -v /mnt/user/appdata/nasdy-media-organizer/data:/app/data \
  -v /mnt:/host_mnt \
  "${IMAGE_NAME}"

echo "[OK] Container restarted"

echo ""
echo "==> Verifying /host_mnt inside container"
if docker exec "${CONTAINER_NAME}" test -d /host_mnt; then
  echo "[OK] /host_mnt exists inside container"
else
  echo "[ERROR] /host_mnt is missing inside container"
  docker logs "${CONTAINER_NAME}" --tail=120 || true
  exit 25
fi

echo ""
echo "==> Verifying /health"
for i in {1..30}; do
  if curl -fsS "http://127.0.0.1:${PORT}/health" >/tmp/nasdy-health.txt 2>/tmp/nasdy-health-error.txt; then
    echo "[OK] Health check passed"
    cat /tmp/nasdy-health.txt || true
    echo ""
    echo "==> Deployment complete"
    docker ps --filter "name=${CONTAINER_NAME}" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    echo ""
    echo "Summary:"
    echo "  Image:     ${IMAGE_NAME}"
    echo "  Container: ${CONTAINER_NAME}"
    echo "  Port:      ${PORT}"
    echo "  Mount:     /mnt:/host_mnt"
    echo "  Health:    OK"
    exit 0
  fi
  sleep 1
done

echo "[ERROR] Health check failed"
echo ""
echo "Curl error:"
cat /tmp/nasdy-health-error.txt || true
echo ""
echo "Container logs:"
docker logs "${CONTAINER_NAME}" --tail=120 || true
exit 30
