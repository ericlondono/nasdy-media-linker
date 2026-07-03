#Requires -Version 5.1
param(
  [string]$NasHost = "192.168.0.109",
  [string]$NasUser = "root",
  [string]$RemoteBuildPath = "/mnt/user/appdata/nasdy-media-organizer/build",
  [string]$ImageName = "nasdy-media-linker:latest",
  [string]$ContainerName = "nasdy-media-organizer",
  [string]$HostPort = "8088",
  [switch]$SkipDeploy
)

$ErrorActionPreference = "Stop"

function Write-Step($Message) {
  Write-Host ""
  Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Good($Message) {
  Write-Host $Message -ForegroundColor Green
}

function Write-Warn($Message) {
  Write-Host $Message -ForegroundColor Yellow
}

function Require-Command($Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required command '$Name' was not found."
  }
}

function Write-Utf8NoBom($Path, $Content) {
  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Invoke-Native($Description, [scriptblock]$Command) {
  Write-Step $Description
  & $Command
  if ($LASTEXITCODE -ne 0) {
    throw "$Description failed with exit code $LASTEXITCODE."
  }
}

$ProjectRoot = (Get-Location).Path
$ConfigPath = Join-Path $ProjectRoot "app\config.py"
$UtilsPath = Join-Path $ProjectRoot "app\services\utils.py"
$LinkerPath = Join-Path $ProjectRoot "app\services\linker.py"
$QueuePath = Join-Path $ProjectRoot "app\services\queue.py"
$QbitPath = Join-Path $ProjectRoot "app\services\qbittorrent.py"
$IndexPath = Join-Path $ProjectRoot "app\templates\index.html"

if (-not (Test-Path $ConfigPath)) {
  throw "Run this from the NASDY Media Linker project folder, e.g. C:\\Projects\\nasdy-media-linker"
}
foreach ($required in @($UtilsPath, $LinkerPath, $QueuePath, $QbitPath, $IndexPath)) {
  if (-not (Test-Path $required)) { throw "Could not find $required" }
}

$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$BackupDir = Join-Path $ProjectRoot "backup-before-v3503-movie-collection-$Stamp"

Write-Step "Creating local backup"
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
Copy-Item -Path (Join-Path $ProjectRoot "app") -Destination (Join-Path $BackupDir "app") -Recurse -Force
if (Test-Path (Join-Path $ProjectRoot "Dockerfile")) { Copy-Item (Join-Path $ProjectRoot "Dockerfile") $BackupDir -Force }
if (Test-Path (Join-Path $ProjectRoot "requirements.txt")) { Copy-Item (Join-Path $ProjectRoot "requirements.txt") $BackupDir -Force }
Write-Good "Backup created: $BackupDir"

Write-Step "Applying v3.5.0.3 movie collection fix"

$config = [System.IO.File]::ReadAllText($ConfigPath)
$config = [regex]::Replace($config, 'APP_VERSION\s*=\s*"[^"]+"', 'APP_VERSION = "v3.5.0.3"')
Write-Utf8NoBom $ConfigPath $config

$UtilsContent = @'
import re
from pathlib import Path
from app.config import VIDEO_EXTENSIONS, QUALITY_WORDS

SKIP_VIDEO_HINTS = {
    "sample", "samples", "trailer", "trailers", "extras", "extra",
    "featurette", "featurettes", "behind the scenes", "bts"
}

def clean_spaces(text: str) -> str:
    return re.sub(r"\s+", " ", str(text)).strip()

def pretty(text: str) -> str:
    text = str(text).replace(".", " ").replace("_", " ")
    text = re.sub(r"\s+-\s+", " ", text)
    return clean_spaces(text)

def safe_name(text: str) -> str:
    text = re.sub(r'[\\/:*?"<>|]', "-", str(text))
    return clean_spaces(text)

def title_case_guess(text: str) -> str:
    small = {"of","the","a","an","and","or","in","on","at","to","for","with","by","from"}
    out = []
    for i, w in enumerate(str(text).split()):
        if w.upper() in {"TV", "FBI", "CSI", "NCIS", "UHD", "USA", "DC"}:
            out.append(w.upper())
        elif i != 0 and w.lower() in small:
            out.append(w.lower())
        else:
            out.append(w[:1].upper() + w[1:])
    return " ".join(out)

def detect_year(text: str) -> str:
    years = re.findall(r"\b(19\d{2}|20\d{2})\b", str(text))
    return years[0] if years else ""

def detect_season(text: str) -> str:
    text = str(text)
    m = re.search(r"\bS(\d{1,2})\b", text, re.I)
    if m:
        return f"{int(m.group(1)):02d}"
    m = re.search(r"\bSeason[ ._-]*(\d{1,2})\b", text, re.I)
    if m:
        return f"{int(m.group(1)):02d}"
    return "01"

def detect_episode(filename: str) -> str:
    filename = str(filename)
    m = re.search(r"\bS\d{1,2}E(\d{1,3})\b", filename, re.I)
    if m:
        return f"{int(m.group(1)):02d}"
    m = re.search(r"\b\d{1,2}x(\d{1,3})\b", filename, re.I)
    if m:
        return f"{int(m.group(1)):02d}"
    return ""

def strip_release_words(text: str) -> str:
    original = str(text)
    text = pretty(text)
    text = re.sub(r"\s+S\d{1,2}.*$", "", text, flags=re.I)
    text = re.sub(r"\s+Season\s*\d{1,2}.*$", "", text, flags=re.I)
    text = re.sub(r"\s+\b(19\d{2}|20\d{2})\b.*$", "", text)
    for word in QUALITY_WORDS:
        text = re.sub(rf"\s+\b{re.escape(word)}\b.*$", "", text, flags=re.I)
    text = re.sub(r"\[[^\]]+\]|\([^\)]*?(remux|x264|x265|hevc|web|bluray|hdr)[^\)]*?\)", "", text, flags=re.I)
    text = clean_spaces(text)
    return title_case_guess(text) if text else original

def is_skippable_video(path: Path) -> bool:
    """Skip sample/trailer/extras clips so they do not become imports."""
    p = Path(path)
    parts = [str(part).lower() for part in p.parts]
    name = p.name.lower()
    stem = p.stem.lower()

    for hint in SKIP_VIDEO_HINTS:
        if hint in parts or hint in name or hint in stem:
            return True

    # Common release-group sample names like Sample.mkv or movie.sample.mkv.
    if re.search(r"(^|[ ._\-\[\(])sample([ ._\-\]\)]|$)", name, re.I):
        return True

    return False

def find_videos(folder: Path):
    folder = Path(folder)
    if not folder.exists():
        return []
    return sorted(
        [
            p for p in folder.rglob("*")
            if p.is_file()
            and p.suffix.lower() in VIDEO_EXTENSIONS
            and not is_skippable_video(p)
        ],
        key=lambda p: str(p).lower()
    )

def looks_like_tv_name(name: str) -> bool:
    return bool(re.search(r"\bS\d{1,2}\b|\bS\d{1,2}E\d{1,3}\b|\bSeason[ ._-]*\d{1,2}\b|\b\d{1,2}x\d{1,3}\b", str(name), re.I))

def looks_like_multi_movie_folder(folder: Path) -> bool:
    """Detect a download folder that contains multiple separate movie folders.

    Example:
      Minions.2015-2022.../
        Minions.2015.../movie.mkv
        Minions.The.Rise.of.Gru.2022.../movie.mkv

    That should default to Movie / Movie Collection, not TV.
    """
    folder = Path(folder)
    if not folder.exists() or not folder.is_dir():
        return False

    child_movie_dirs = []
    for child in folder.iterdir():
        if not child.is_dir():
            continue
        if child.name.lower() in {"sample", "samples", "subs", "subtitles", "extras", "trailers"}:
            continue
        videos = find_videos(child)
        if videos:
            child_movie_dirs.append(child)

    if len(child_movie_dirs) < 2:
        return False

    # If the folder names look like TV seasons/episodes, do not call it a movie collection.
    if any(looks_like_tv_name(child.name) for child in child_movie_dirs):
        return False

    # A year in at least one child folder is a strong signal for separate movies.
    if any(detect_year(child.name) for child in child_movie_dirs):
        return True

    # Distinct child folders with one main video each are still likely a movie pack.
    return True

def guess_type(name: str, video_count: int) -> str:
    if re.search(r"\bS\d{1,2}\b|\bSeason[ ._-]*\d{1,2}\b", str(name), re.I):
        return "tv"
    if video_count >= 3:
        return "tv"
    return "movie"

'@
Write-Utf8NoBom $UtilsPath $UtilsContent.TrimStart("`r", "`n")

$LinkerContent = @'
import os
from collections import defaultdict
from pathlib import Path

from app.config import MOVIES_ROOT, TV_ROOT, HOST_MNT_ROOT
from app.services.utils import find_videos, detect_episode, safe_name, strip_release_words, detect_year, looks_like_multi_movie_folder
from app.services.logger import log


def movie_group_name(source_path: Path, src: Path) -> str:
    try:
        rel = src.relative_to(source_path)
        if len(rel.parts) > 1:
            return rel.parts[0]
    except Exception:
        pass
    return src.stem


def build_movie_collection_plan(source_path: Path, videos, fallback_title: str, fallback_year: str):
    items = []
    groups = defaultdict(list)
    for src in videos:
        groups[movie_group_name(source_path, src)].append(src)

    for group_name in sorted(groups.keys(), key=lambda x: x.lower()):
        group_videos = sorted(groups[group_name], key=lambda p: str(p).lower())
        movie_title = strip_release_words(group_name) or fallback_title or group_name
        movie_year = detect_year(group_name) or detect_year(group_videos[0].name) or fallback_year
        display = f"{movie_title} ({movie_year})" if movie_year else movie_title
        dest_dir = MOVIES_ROOT / safe_name(display)

        if len(group_videos) == 1:
            src = group_videos[0]
            new_name = safe_name(f"{display}{src.suffix.lower()}")
            items.append({"src": src, "dst": dest_dir / new_name, "new_name": new_name, "movie_title": movie_title, "movie_year": movie_year})
        else:
            # Rare, but keeps multi-part movies inside that movie's own folder.
            for idx, src in enumerate(group_videos, start=1):
                new_name = safe_name(f"{display} - Part {idx}{src.suffix.lower()}")
                items.append({"src": src, "dst": dest_dir / new_name, "new_name": new_name, "movie_title": movie_title, "movie_year": movie_year})

    return MOVIES_ROOT, items


def build_plan(media_type: str, source: str, title: str, year: str, season: str):
    source_path = Path(source)
    videos = find_videos(source_path)
    title = title.strip()
    year = year.strip()
    season = season.strip() or "01"

    if not source_path.exists():
        raise ValueError(f"Source folder does not exist: {source_path}")
    if not title:
        raise ValueError("Title is required.")
    if not videos:
        raise ValueError("No video files found.")

    items = []
    if media_type == "tv":
        season = f"{int(season):02d}"
        display = f"{title} ({year})" if year else title
        dest_dir = TV_ROOT / safe_name(display) / f"Season {season}"
        fallback = 1
        for src in videos:
            ep = detect_episode(src.name)
            episode_detected = bool(ep)
            if not ep:
                ep = f"{fallback:02d}"
                fallback += 1
            new_name = safe_name(f"{display} - S{season}E{ep}{src.suffix.lower()}")
            items.append({
                "src": src,
                "dst": dest_dir / new_name,
                "new_name": new_name,
                "episode": ep,
                "episode_detected": episode_detected,
            })
    else:
        display = f"{title} ({year})" if year else title

        # v3.5.0.3: a torrent/download can be a movie pack with one folder per movie.
        # In that case, create one movie folder per child release instead of naming
        # everything "Parent Title - Part 1/2/3".
        if looks_like_multi_movie_folder(source_path):
            return build_movie_collection_plan(source_path, videos, title, year)

        dest_dir = MOVIES_ROOT / safe_name(display)
        if len(videos) == 1:
            src = videos[0]
            new_name = safe_name(f"{display}{src.suffix.lower()}")
            items.append({"src": src, "dst": dest_dir / new_name, "new_name": new_name})
        else:
            for idx, src in enumerate(videos, start=1):
                new_name = safe_name(f"{display} - Part {idx}{src.suffix.lower()}")
                items.append({"src": src, "dst": dest_dir / new_name, "new_name": new_name})
    return dest_dir, items


def container_to_host_user_path(container_path: Path) -> Path:
    p = Path(container_path)
    s = str(p)
    if s.startswith("/downloads"):
        rel = s.removeprefix("/downloads").lstrip("/")
        return HOST_MNT_ROOT / "user" / "NASDY" / "downloads" / rel
    if s.startswith("/media"):
        rel = s.removeprefix("/media").lstrip("/")
        return HOST_MNT_ROOT / "user" / "NASDY" / "media" / rel
    return p


def resolve_real_host_path(container_path: Path) -> Path:
    user_path = container_to_host_user_path(container_path)
    s = str(user_path)
    marker = "/host_mnt/user/"
    if s.startswith(marker):
        rel = s.removeprefix(marker)
    else:
        return user_path

    candidates = []
    for root in [HOST_MNT_ROOT / "cache"] + sorted(HOST_MNT_ROOT.glob("disk*")):
        candidates.append(root / rel)

    for c in candidates:
        if c.exists():
            return c

    return user_path


def matching_dest_on_source_disk(src_real: Path, dst_container: Path) -> Path:
    src_parts = src_real.parts
    if len(src_parts) >= 3 and src_parts[1] == "host_mnt":
        disk_root = Path("/") / src_parts[1] / src_parts[2]
    else:
        return container_to_host_user_path(dst_container)

    dst_s = str(dst_container)
    if dst_s.startswith("/media"):
        rel = dst_s.removeprefix("/media").lstrip("/")
        return disk_root / "NASDY" / "media" / rel
    return container_to_host_user_path(dst_container)


def stat_device(path: Path):
    try:
        st = os.stat(path if path.exists() else path.parent)
        return st.st_dev
    except Exception:
        return None


def normalize_permissions(path: Path):
    """Best-effort permission normalization for SMB-friendly unRAID folders."""
    try:
        path = Path(path)
        targets = []
        if path.exists():
            targets.append(path)
        for parent in [path.parent, path.parent.parent]:
            if parent.exists():
                targets.append(parent)

        for target in targets:
            try:
                if target.is_dir():
                    os.chmod(target, 0o2775)
                else:
                    os.chmod(target, 0o664)
            except Exception as perm_error:
                log(f"WARN permission normalize failed for {target}: {perm_error}")
    except Exception as e:
        log(f"WARN permission normalize skipped for {path}: {e}")


def diagnostic_for_link(src_container: Path, dst_container: Path):
    src_real = resolve_real_host_path(src_container)
    dst_real = matching_dest_on_source_disk(src_real, dst_container)
    return {
        "src_container": str(src_container),
        "dst_container": str(dst_container),
        "src_real": str(src_real),
        "dst_real": str(dst_real),
        "src_exists": src_real.exists(),
        "dst_exists": dst_real.exists(),
        "src_device": stat_device(src_real),
        "dst_parent_device": stat_device(dst_real.parent),
        "same_device": stat_device(src_real) == stat_device(dst_real.parent),
    }


def create_hard_links(items):
    created = []
    diagnostics = []

    for item in items:
        src_container = Path(item["src"])
        dst_container = Path(item["dst"])
        diag = diagnostic_for_link(src_container, dst_container)
        diagnostics.append(diag)

        src_real = Path(diag["src_real"])
        dst_real = Path(diag["dst_real"])

        log(f"LINK DIAG: {diag}")

        if not src_real.exists():
            raise FileNotFoundError(f"Resolved source does not exist: {src_real}")
        if dst_real.exists():
            log(f"SKIPPED EXISTING HARD LINK DESTINATION: {dst_real}")
            continue

        dst_real.parent.mkdir(parents=True, exist_ok=True)
        normalize_permissions(dst_real.parent)
        os.link(src_real, dst_real)
        normalize_permissions(dst_real)
        created.append(str(dst_real))
        log(f"CREATED HARD LINK: {src_real} -> {dst_real}")

    return created, diagnostics

'@
Write-Utf8NoBom $LinkerPath $LinkerContent.TrimStart("`r", "`n")

# Update folder queue detection so movie packs do not start in TV mode.
$queue = [System.IO.File]::ReadAllText($QueuePath)
$queue = $queue.Replace(
  'from app.services.utils import find_videos, guess_type, strip_release_words, detect_year, detect_season',
  'from app.services.utils import find_videos, guess_type, strip_release_words, detect_year, detect_season, looks_like_multi_movie_folder'
)
$queue = [regex]::Replace($queue, 'media_type\s*=\s*guess_type\(p\.name,\s*len\(videos\)\)', 'media_type = "movie" if looks_like_multi_movie_folder(p) else guess_type(p.name, len(videos))')
$queue = [regex]::Replace($queue, '"type_label":\s*"TV Show" if media_type == "tv" else "Movie",', '"type_label": "TV Show" if media_type == "tv" else ("Movie Collection" if looks_like_multi_movie_folder(p) else "Movie"),')
Write-Utf8NoBom $QueuePath $queue

# Update qBittorrent queue detection the same way.
$qbit = [System.IO.File]::ReadAllText($QbitPath)
$qbit = $qbit.Replace(
  'from app.services.utils import guess_type, strip_release_words, detect_year, detect_season',
  'from app.services.utils import guess_type, strip_release_words, detect_year, detect_season, looks_like_multi_movie_folder'
)
$qbit = [regex]::Replace($qbit, 'media_type\s*=\s*guess_type\(name,\s*len\(videos\)\)', 'media_type = "movie" if looks_like_multi_movie_folder(source_path) else guess_type(name, len(videos))')
$qbit = [regex]::Replace($qbit, '"type_label":\s*"TV Show" if media_type == "tv" else "Movie",', '"type_label": "TV Show" if media_type == "tv" else ("Movie Collection" if looks_like_multi_movie_folder(source_path) else "Movie"),')
Write-Utf8NoBom $QbitPath $qbit

# Cache-bust template URLs in case the browser keeps old JS/CSS around.
$index = [System.IO.File]::ReadAllText($IndexPath)
$index = $index.Replace('-queuefix', '-v3503')
$index = $index.Replace('-stable', '-v3503')
Write-Utf8NoBom $IndexPath $index

Write-Good "Local files updated for v3.5.0.3."
Write-Host "- Sample/trailer videos are skipped."
Write-Host "- Multi-movie folders default to Movie Collection instead of TV."
Write-Host "- Selecting Movie now creates one movie folder per child movie instead of Part 1/2 names."

# Make sure the project still has build files. These are only created if missing.
$DockerfilePath = Join-Path $ProjectRoot "Dockerfile"
$RequirementsPath = Join-Path $ProjectRoot "requirements.txt"

if (-not (Test-Path $DockerfilePath)) {
  $Dockerfile = @'
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8088"]
'@
  Write-Utf8NoBom $DockerfilePath $Dockerfile
}

if (-not (Test-Path $RequirementsPath)) {
  $Requirements = @'
fastapi
uvicorn[standard]
jinja2
python-multipart
requests
'@
  Write-Utf8NoBom $RequirementsPath $Requirements
}

if ($SkipDeploy) {
  Write-Warn "SkipDeploy was used. Local files are patched, but the NAS container was not rebuilt."
  return
}

Require-Command ssh
Require-Command scp
Require-Command tar

$Remote = "$NasUser@$NasHost"
$ArchiveName = "nasdy-v3503-movie-collection-$Stamp.tgz"
$LocalArchive = Join-Path $env:TEMP $ArchiveName
$RemoteArchive = "/tmp/$ArchiveName"
$LocalDeployScript = Join-Path $env:TEMP "nasdy-v3503-deploy-$Stamp.sh"
$RemoteDeployScript = "/tmp/nasdy-v3503-deploy-$Stamp.sh"

Write-Step "Creating deployment archive"
if (Test-Path $LocalArchive) { Remove-Item $LocalArchive -Force }
& tar -czf $LocalArchive -C $ProjectRoot app Dockerfile requirements.txt
if ($LASTEXITCODE -ne 0) {
  throw "Could not create deployment archive."
}
Write-Good "Created $LocalArchive"

$RemoteScript = @'
#!/bin/sh
set -eu

BUILD_PATH="__REMOTE_BUILD_PATH__"
ARCHIVE="__REMOTE_ARCHIVE__"
IMAGE_NAME="__IMAGE_NAME__"
CONTAINER_NAME="__CONTAINER_NAME__"
REQUESTED_HOST_PORT="__HOST_PORT__"
APP_PORT="8088"
DATA_PATH="/mnt/user/appdata/nasdy-media-organizer/data"

printf '\nDeploying NASDY Media Linker v3.5.0.3 movie collection fix...\n'
printf 'Build path: %s\n' "$BUILD_PATH"
printf 'Container:  %s\n' "$CONTAINER_NAME"
printf 'Image:      %s\n' "$IMAGE_NAME"

mkdir -p "$BUILD_PATH"
rm -rf "$BUILD_PATH/app"
tar -xzf "$ARCHIVE" -C "$BUILD_PATH"
cd "$BUILD_PATH"

docker build -t "$IMAGE_NAME" .

# Preserve the current working external web port when possible.
CURRENT_HOST_PORT=""
if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  CURRENT_HOST_PORT=$(docker inspect -f '{{with index .NetworkSettings.Ports "8088/tcp"}}{{(index . 0).HostPort}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)
fi
if [ -z "$CURRENT_HOST_PORT" ]; then
  CURRENT_HOST_PORT="$REQUESTED_HOST_PORT"
fi

printf '\nRestarting container with mapping host %s -> container %s...\n' "$CURRENT_HOST_PORT" "$APP_PORT"

docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
mkdir -p "$DATA_PATH"

docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  -p "${CURRENT_HOST_PORT}:${APP_PORT}" \
  -e DOWNLOADS_ROOT=/downloads \
  -e MOVIES_ROOT=/media/movies \
  -e TV_ROOT=/media/tv \
  -e DATA_ROOT=/data \
  -e HOST_DOWNLOADS_ROOT=/mnt/user/NASDY/downloads \
  -e HOST_MEDIA_ROOT=/mnt/user/NASDY/media \
  -e HOST_MNT_ROOT=/host_mnt \
  -v /mnt/user/NASDY/downloads:/downloads \
  -v /mnt/user/NASDY/media:/media \
  -v "$DATA_PATH":/data \
  -v /mnt:/host_mnt \
  "$IMAGE_NAME" \
  uvicorn app.main:app --host 0.0.0.0 --port "$APP_PORT"

sleep 3

echo ""
echo "Container status:"
docker ps --filter "name=$CONTAINER_NAME"

echo ""
echo "Recent logs:"
docker logs --tail=30 "$CONTAINER_NAME" || true

echo ""
echo "Health check from NAS:"
if command -v curl >/dev/null 2>&1; then
  curl -fsS "http://127.0.0.1:${CURRENT_HOST_PORT}/health" || true
elif command -v wget >/dev/null 2>&1; then
  wget -qO- "http://127.0.0.1:${CURRENT_HOST_PORT}/health" || true
else
  echo "curl/wget not available on NAS, skipping local health check."
fi

echo ""
echo "Open: http://__NAS_HOST__:${CURRENT_HOST_PORT}"
echo "Also try: http://nasdy:${CURRENT_HOST_PORT}"
'@

$RemoteScript = $RemoteScript.Replace("__REMOTE_BUILD_PATH__", $RemoteBuildPath)
$RemoteScript = $RemoteScript.Replace("__REMOTE_ARCHIVE__", $RemoteArchive)
$RemoteScript = $RemoteScript.Replace("__IMAGE_NAME__", $ImageName)
$RemoteScript = $RemoteScript.Replace("__CONTAINER_NAME__", $ContainerName)
$RemoteScript = $RemoteScript.Replace("__HOST_PORT__", $HostPort)
$RemoteScript = $RemoteScript.Replace("__NAS_HOST__", $NasHost)
Write-Utf8NoBom $LocalDeployScript $RemoteScript

Invoke-Native "Copying deployment archive to NAS" {
  & scp $LocalArchive "${Remote}:$RemoteArchive"
}

Invoke-Native "Copying deployment script to NAS" {
  & scp $LocalDeployScript "${Remote}:$RemoteDeployScript"
}

Invoke-Native "Building and restarting on NAS" {
  & ssh $Remote "sh '$RemoteDeployScript'"
}

Write-Good "v3.5.0.3 movie collection fix deployed."
Write-Host "Open: http://$NasHost`:$HostPort"
Write-Host "Or:   http://nasdy`:$HostPort"
Write-Warn "Use Ctrl+F5 in the browser so the updated JS/CSS is loaded."

