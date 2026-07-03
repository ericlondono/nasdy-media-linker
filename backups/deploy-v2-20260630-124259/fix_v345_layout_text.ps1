# NASDY Media Linker v3.4.5 quick cleanup
# Fixes checkbox overlap and removes mojibake/emoji text from visible labels.

$ErrorActionPreference = "Stop"

$ProjectRoot = "C:\Projects\nasdy-media-linker"
if (!(Test-Path $ProjectRoot)) {
  throw "Project folder not found: $ProjectRoot"
}

Set-Location $ProjectRoot

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = "backup-v345-cleanup-$stamp"
New-Item -ItemType Directory -Path $backup | Out-Null
Copy-Item -Recurse -Force app "$backup\app"
Copy-Item -Force Dockerfile,requirements.txt $backup

function Write-Utf8NoBom($Path, $Content) {
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText((Resolve-Path $Path), $Content, $utf8NoBom)
}

# --- Fix visible corrupted labels in index.html ---
$indexPath = "app\templates\index.html"
$index = Get-Content $indexPath -Raw

# Remove emoji/mojibake from media type radio labels while preserving inputs.
$index = [regex]::Replace($index, '(<input\s+type="radio"\s+name="media_type"\s+value="tv"\s+checked>\s*)<span>.*?TV Show</span>', '$1<span>TV Show</span>', 'Singleline')
$index = [regex]::Replace($index, '(<input\s+type="radio"\s+name="media_type"\s+value="movie">\s*)<span>.*?Movie</span>', '$1<span>Movie</span>', 'Singleline')

# Fix manual mark button text.
$index = [regex]::Replace($index, '(<button\s+id="markImportedBtn"[^>]*>).*?(</button>)', '$1Mark Imported$2', 'Singleline')

# Make static asset URLs versioned so Ctrl+F5 is less often needed.
$index = $index -replace '<link rel="stylesheet" href="/static/style\.css">', '<link rel="stylesheet" href="/static/style.css?v={{ version }}">'
$index = $index -replace '<script src="/static/app\.js"></script>', '<script src="/static/app.js?v={{ version }}"></script>'

Write-Utf8NoBom $indexPath $index

# --- Fix JS button reset text if it got corrupted ---
$appJsPath = "app\static\app.js"
$appjs = Get-Content $appJsPath -Raw
$appjs = [regex]::Replace($appjs, 'btn\.textContent\s*=\s*"[^"]*Mark Imported";', 'btn.textContent = "Mark Imported";')
Write-Utf8NoBom $appJsPath $appjs

# --- Add CSS overrides for bulk checkbox layout and cleaner buttons ---
$cssPath = "app\static\style.css"
$css = Get-Content $cssPath -Raw
$css += @'

/* v3.4.5 cleanup: bulk select layout */
.queue-toolbar {
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto auto;
  gap: 8px;
  align-items: center;
  margin: 12px 0;
  padding: 11px;
  border: 1px solid #343a49;
  border-radius: 14px;
  background: #10141d;
}
.queue-toolbar .checkline {
  margin: 0;
  min-width: 0;
}
.queue-toolbar button {
  padding: 10px 13px;
}
.selected-count,
#selectedCount {
  color: #aeb6c5;
  font-size: 12px;
  font-weight: 900;
  white-space: nowrap;
}
.folder.torrent-card {
  position: relative;
  padding-right: 52px;
}
.folder.torrent-card .year-pill {
  margin-right: 30px;
}
.folder.torrent-card input[type="checkbox"] {
  position: absolute;
  top: 15px;
  right: 14px;
  width: 22px;
  height: 22px;
  min-width: 22px;
  padding: 0;
  margin: 0;
  z-index: 10;
  accent-color: #2dbd6e;
}
.folder.torrent-card input[type="checkbox"]:hover {
  cursor: pointer;
}
.actions button.danger,
button.danger {
  background: #9d3030;
}
@media (max-width: 700px) {
  .queue-toolbar {
    grid-template-columns: 1fr;
  }
}
'@
Write-Utf8NoBom $cssPath $css

# Optional: remove emoji icons from Python source to avoid future mojibake in queue cards/history.
$queuePath = "app\services\queue.py"
if (Test-Path $queuePath) {
  $queue = Get-Content $queuePath -Raw
  $queue = [regex]::Replace($queue, '"icon":\s*"[^"]*"\s*if\s*media_type\s*==\s*"tv"\s*else\s*"[^"]*"', '"icon": "TV" if media_type == "tv" else "Movie"')
  Write-Utf8NoBom $queuePath $queue
}

$qbitPath = "app\services\qbittorrent.py"
if (Test-Path $qbitPath) {
  $qbit = Get-Content $qbitPath -Raw
  $qbit = [regex]::Replace($qbit, '"icon":\s*"[^"]*"\s*if\s*media_type\s*==\s*"tv"\s*else\s*"[^"]*"', '"icon": "TV" if media_type == "tv" else "Movie"')
  Write-Utf8NoBom $qbitPath $qbit
}

# Quick syntax check before deploy.
python -m py_compile app\config.py app\main.py app\services\queue.py app\services\qbittorrent.py

# Deploy to NASDY.
ssh root@NASDY "mkdir -p /mnt/user/appdata/nasdy-media-organizer/build"
scp -r .\app .\Dockerfile .\requirements.txt root@NASDY:/mnt/user/appdata/nasdy-media-organizer/build/
ssh root@NASDY "cd /mnt/user/appdata/nasdy-media-organizer/build && docker build -t nasdy-media-linker:latest . && docker stop nasdy-media-organizer || true && docker rm nasdy-media-organizer || true && docker run -d --name nasdy-media-organizer --restart unless-stopped -p 8088:8088 -v /mnt/user/NASDY/downloads:/downloads -v /mnt/user/NASDY/media:/media -v /mnt/user/appdata/nasdy-media-organizer/data:/app/data nasdy-media-linker:latest"
ssh root@NASDY "docker logs nasdy-media-organizer --tail=80"

Write-Host ""
Write-Host "v3.4.5 cleanup applied. Open the page and press Ctrl+F5 once." -ForegroundColor Green
Write-Host "Backup saved to: $backup" -ForegroundColor Cyan
