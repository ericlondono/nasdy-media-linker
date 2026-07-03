# NASDY Media Linker v3.4.5 final card layout cleanup
# Fixes queue tile spacing after bulk-select was added.

$ErrorActionPreference = "Stop"

$ProjectRoot = "C:\Projects\nasdy-media-linker"
if (!(Test-Path $ProjectRoot)) {
  throw "Project folder not found: $ProjectRoot"
}

Set-Location $ProjectRoot

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = "backup-v345-cards-final-$stamp"
New-Item -ItemType Directory -Force -Path $backup | Out-Null
Copy-Item -Recurse -Force app "$backup\app"
Copy-Item -Force Dockerfile "$backup\Dockerfile"
Copy-Item -Force requirements.txt "$backup\requirements.txt"

function Write-Utf8NoBom($Path, $Content) {
  $resolved = (Resolve-Path $Path).Path
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($resolved, $Content, $utf8NoBom)
}

# Keep icon labels compact so they don't collide with titles.
foreach ($pyPath in @("app\services\queue.py", "app\services\qbittorrent.py")) {
  if (Test-Path $pyPath) {
    $py = Get-Content $pyPath -Raw
    $py = [regex]::Replace(
      $py,
      '"icon":\s*"[^"]*"\s*if\s*media_type\s*==\s*"tv"\s*else\s*"[^"]*"',
      '"icon": "TV" if media_type == "tv" else "M"'
    )
    Write-Utf8NoBom $pyPath $py
  }
}

# Force a fresh CSS URL so the browser stops holding the old layout.
$indexPath = "app\templates\index.html"
$index = Get-Content $indexPath -Raw
$index = [regex]::Replace(
  $index,
  '<link\s+rel="stylesheet"\s+href="/static/style\.css(?:\?v=[^"]*)?">',
  '<link rel="stylesheet" href="/static/style.css?v={{ version }}-cards-final">'
)
Write-Utf8NoBom $indexPath $index

# Remove earlier attempted cleanup blocks, then append one high-specificity final reset.
$cssPath = "app\static\style.css"
$css = Get-Content $cssPath -Raw

$patternsToRemove = @(
  '(?s)/\* v3\.4\.5 cleanup: bulk select layout \*/.*?(?=/\* v3\.4\.5|$)',
  '(?s)/\* v3\.4\.5 tile layout cleanup \*/.*?/\* end v3\.4\.5 tile layout cleanup \*/\s*',
  '(?s)/\* v3\.4\.5 card layout final reset \*/.*?/\* end v3\.4\.5 card layout final reset \*/\s*'
)
foreach ($pattern in $patternsToRemove) {
  $css = [regex]::Replace($css, $pattern, '')
}

$css += @'

/* v3.4.5 card layout final reset */
.bulk-toolbar {
  display: grid !important;
  grid-template-columns: auto minmax(0, 1fr) auto !important;
  gap: 9px !important;
  align-items: center !important;
  margin: 12px 0 12px !important;
  padding: 12px !important;
  border: 1px solid #343a49 !important;
  border-radius: 14px !important;
  background: #10141d !important;
}

.bulk-select-all {
  grid-column: 1 !important;
  display: flex !important;
  align-items: center !important;
  gap: 8px !important;
  margin: 0 !important;
  color: #cfd6e3 !important;
  font-size: 12px !important;
  font-weight: 900 !important;
  white-space: nowrap !important;
}

.bulk-select-all input {
  width: 16px !important;
  height: 16px !important;
  padding: 0 !important;
  margin: 0 !important;
}

.selected-count,
#selectedCount {
  grid-column: 2 !important;
  color: #aeb6c5 !important;
  font-size: 12px !important;
  font-weight: 900 !important;
  white-space: nowrap !important;
}

#clearSelectionBtn {
  grid-column: 3 !important;
  justify-self: end !important;
}

#bulkMarkImportedBtn {
  grid-column: 1 / -1 !important;
  width: 100% !important;
  justify-self: stretch !important;
}

button.small {
  padding: 9px 12px !important;
  border-radius: 10px !important;
  font-size: 12px !important;
  line-height: 1.2 !important;
}

button.ghost {
  background: #2a2f3b !important;
  color: #c8cfdb !important;
}

.folder-list {
  gap: 12px !important;
}

.folder.torrent-card,
.torrent-card.folder {
  position: relative !important;
  display: block !important;
  width: 100% !important;
  padding: 16px 60px 15px 16px !important;
  overflow: hidden !important;
  min-height: 0 !important;
}

.torrent-card::before {
  content: "" !important;
  position: absolute !important;
  inset: 0 auto 0 0 !important;
  width: 4px !important;
  background: #2dbd6e !important;
  opacity: .9 !important;
}

.torrent-card.imported::before {
  background: #6e8cff !important;
}

.torrent-card.selected::before {
  background: #6e8cff !important;
}

.select-box-wrap {
  position: absolute !important;
  top: 16px !important;
  right: 16px !important;
  z-index: 10 !important;
  width: 26px !important;
  height: 26px !important;
  display: grid !important;
  place-items: center !important;
  background: #0c1119 !important;
  border: 1px solid #343a49 !important;
  border-radius: 8px !important;
}

.queue-select {
  position: static !important;
  display: block !important;
  width: 16px !important;
  height: 16px !important;
  min-width: 16px !important;
  padding: 0 !important;
  margin: 0 !important;
  cursor: pointer !important;
  accent-color: #2dbd6e !important;
}

.torrent-topline {
  display: grid !important;
  grid-template-columns: 40px minmax(0, 1fr) !important;
  gap: 12px !important;
  align-items: start !important;
  margin: 0 0 8px !important;
  min-width: 0 !important;
}

.torrent-icon {
  grid-column: 1 !important;
  width: 34px !important;
  min-width: 34px !important;
  height: 30px !important;
  display: grid !important;
  place-items: center !important;
  border-radius: 10px !important;
  background: #202634 !important;
  color: #f5f7fb !important;
  font-size: 13px !important;
  font-weight: 950 !important;
  line-height: 1 !important;
  overflow: hidden !important;
  white-space: nowrap !important;
}

.torrent-heading {
  grid-column: 2 !important;
  display: grid !important;
  grid-template-columns: minmax(0, 1fr) auto !important;
  gap: 8px !important;
  align-items: start !important;
  justify-content: stretch !important;
  min-width: 0 !important;
  padding-right: 0 !important;
}

.folder-title {
  display: block !important;
  min-width: 0 !important;
  max-width: 100% !important;
  font-weight: 950 !important;
  line-height: 1.18 !important;
  white-space: normal !important;
  overflow: visible !important;
  text-overflow: clip !important;
  overflow-wrap: anywhere !important;
  padding-right: 0 !important;
}

.year-pill {
  position: static !important;
  justify-self: end !important;
  align-self: start !important;
  flex: 0 0 auto !important;
  width: auto !important;
  min-width: 44px !important;
  max-width: none !important;
  margin: 0 !important;
  padding: 3px 8px !important;
  text-align: center !important;
  white-space: nowrap !important;
  overflow: visible !important;
  text-overflow: clip !important;
}

.release-name,
.torrent-status-row,
.metric-grid {
  margin-left: 52px !important;
  margin-right: 0 !important;
}

.release-name {
  display: block !important;
  margin-bottom: 10px !important;
  color: #7f8aa0 !important;
  font-size: 11px !important;
  line-height: 1.25 !important;
  overflow-wrap: anywhere !important;
}

.torrent-status-row {
  display: flex !important;
  gap: 7px !important;
  flex-wrap: wrap !important;
  align-items: center !important;
  margin-bottom: 10px !important;
}

.metric-grid {
  display: grid !important;
  grid-template-columns: repeat(2, minmax(0, 1fr)) !important;
  gap: 8px !important;
}

.metric-value,
.status-chip,
.mini-pill {
  white-space: nowrap !important;
}

.folder-meta {
  display: block !important;
  margin-left: 52px !important;
  color: #aeb6c5 !important;
  font-size: 13px !important;
}

.torrent-card.imported .select-box-wrap {
  opacity: .35 !important;
  pointer-events: none !important;
}

@media (max-width: 720px) {
  .bulk-toolbar {
    grid-template-columns: 1fr !important;
  }
  .bulk-select-all,
  .selected-count,
  #clearSelectionBtn,
  #bulkMarkImportedBtn {
    grid-column: 1 !important;
    justify-self: stretch !important;
    width: 100% !important;
  }
}
/* end v3.4.5 card layout final reset */
'@

Write-Utf8NoBom $cssPath $css

# Quick syntax check before deploying.
python -m py_compile app\config.py app\main.py app\services\queue.py app\services\qbittorrent.py

# Deploy to NASDY the normal way.
ssh root@NASDY "mkdir -p /mnt/user/appdata/nasdy-media-organizer/build"
scp -r .\app .\Dockerfile .\requirements.txt root@NASDY:/mnt/user/appdata/nasdy-media-organizer/build/
ssh root@NASDY "cd /mnt/user/appdata/nasdy-media-organizer/build && docker build -t nasdy-media-linker:latest . && docker stop nasdy-media-organizer || true && docker rm nasdy-media-organizer || true && docker run -d --name nasdy-media-organizer --restart unless-stopped -p 8088:8088 -v /mnt/user/NASDY/downloads:/downloads -v /mnt/user/NASDY/media:/media -v /mnt/user/appdata/nasdy-media-organizer/data:/app/data nasdy-media-linker:latest"
ssh root@NASDY "docker logs nasdy-media-organizer --tail=80"

Write-Host ""
Write-Host "v3.4.5 final card layout cleanup complete." -ForegroundColor Green
Write-Host "Backup saved to: $backup" -ForegroundColor Cyan
Write-Host "Refresh the browser once. Ctrl+F5 is best." -ForegroundColor Yellow
