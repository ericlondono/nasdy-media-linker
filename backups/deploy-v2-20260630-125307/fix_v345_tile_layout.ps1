$ErrorActionPreference = "Stop"

$ProjectRoot = "C:\Projects\nasdy-media-linker"
Set-Location $ProjectRoot

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = "backup-v345-tile-layout-$stamp"
New-Item -ItemType Directory -Force -Path $backup | Out-Null
Copy-Item -Recurse -Force app "$backup\app"
Copy-Item -Force Dockerfile "$backup\Dockerfile"
Copy-Item -Force requirements.txt "$backup\requirements.txt"

$cssPath = "app\static\style.css"
$css = Get-Content $cssPath -Raw

$css = $css -replace '\.torrent-topline \{[^}]*\}', @'
.torrent-topline {
  display: grid;
  grid-template-columns: 34px minmax(0, 1fr) 44px;
  gap: 10px;
  align-items: start;
  margin-bottom: 8px;
}
'@

$css = $css -replace '\.torrent-heading \{[^}]*\}', @'
.torrent-heading {
  display: flex;
  align-items: flex-start;
  justify-content: flex-start;
  gap: 8px;
  min-width: 0;
  padding-right: 0;
}
'@

$css = $css -replace '\.folder-title \{[^}]*\}', @'
.folder-title {
  display: block;
  font-weight: 950;
  line-height: 1.18;
  overflow-wrap: anywhere;
  min-width: 0;
}
'@

$css = $css -replace '\.release-name \{[^}]*\}', @'
.release-name {
  display: block;
  margin-left: 44px;
  margin-right: 44px;
  margin-bottom: 10px;
  color: #7f8aa0;
  font-size: 11px;
  line-height: 1.25;
  overflow-wrap: anywhere;
}
'@

$css = $css -replace '\.torrent-status-row \{[^}]*\}', @'
.torrent-status-row {
  display: flex;
  gap: 7px;
  flex-wrap: wrap;
  align-items: center;
  margin-left: 44px;
  margin-right: 44px;
  margin-bottom: 10px;
}
'@

$css = $css -replace '\.metric-grid \{[^}]*\}', @'
.metric-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 8px;
  margin-left: 44px;
  margin-right: 44px;
}
'@

# Remove any previous tile-fix blocks, then append the clean final layout fixes.
$css = $css -replace '(?s)/\* v3\.4\.5 tile layout cleanup \*/.*?/\* end v3\.4\.5 tile layout cleanup \*/\s*', ''
$css += @'

/* v3.4.5 tile layout cleanup */
.torrent-card {
  display: block;
  padding: 15px 52px 15px 15px;
  position: relative;
}

.queue-check,
.item-check,
.bulk-item-check,
.torrent-card input[type="checkbox"] {
  position: absolute !important;
  top: 18px !important;
  right: 16px !important;
  width: 22px !important;
  height: 22px !important;
  margin: 0 !important;
  z-index: 5;
}

.torrent-card .year-pill {
  position: static !important;
  justify-self: end;
  align-self: start;
  margin-right: 0;
  max-width: 44px;
  text-align: center;
  overflow: hidden;
  text-overflow: ellipsis;
}

.torrent-card .torrent-icon {
  grid-column: 1;
}

.torrent-card .torrent-heading {
  grid-column: 2;
}

.torrent-card .folder-title {
  padding-right: 0;
}

.torrent-card .status-chip,
.torrent-card .mini-pill,
.torrent-card .metric-value {
  white-space: nowrap;
}

.bulk-toolbar,
.queue-bulk-actions,
.queue-selection-bar {
  display: flex;
  align-items: center;
  gap: 10px;
  flex-wrap: wrap;
  margin: 12px 0;
  padding: 10px 12px;
  border: 1px solid #343a49;
  border-radius: 12px;
  background: #10141d;
}

.bulk-toolbar label,
.queue-bulk-actions label,
.queue-selection-bar label {
  margin: 0;
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 12px;
}

.bulk-toolbar input[type="checkbox"],
.queue-bulk-actions input[type="checkbox"],
.queue-selection-bar input[type="checkbox"] {
  width: 16px;
  height: 16px;
}

.bulk-toolbar button,
.queue-bulk-actions button,
.queue-selection-bar button {
  padding: 9px 12px;
}
/* end v3.4.5 tile layout cleanup */
'@

Set-Content $cssPath $css -Encoding UTF8

# Redeploy
ssh root@NASDY "mkdir -p /mnt/user/appdata/nasdy-media-organizer/build"
scp -r .\app .\Dockerfile .\requirements.txt root@NASDY:/mnt/user/appdata/nasdy-media-organizer/build/
ssh root@NASDY "cd /mnt/user/appdata/nasdy-media-organizer/build && docker build -t nasdy-media-linker:latest . && docker stop nasdy-media-organizer || true && docker rm nasdy-media-organizer || true && docker run -d --name nasdy-media-organizer --restart unless-stopped -p 8088:8088 -v /mnt/user/NASDY/downloads:/downloads -v /mnt/user/NASDY/media:/media -v /mnt/user/appdata/nasdy-media-organizer/data:/app/data nasdy-media-linker:latest"
ssh root@NASDY "docker logs nasdy-media-organizer --tail=80"

Write-Host "v3.4.5 tile layout cleanup complete. Press Ctrl+F5 in the browser." -ForegroundColor Green
