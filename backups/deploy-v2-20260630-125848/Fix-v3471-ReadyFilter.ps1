$ErrorActionPreference = "Stop"

$ProjectRoot = "C:\Projects\nasdy-media-linker"
$CssPath = Join-Path $ProjectRoot "app\static\style.css"
$ConfigPath = Join-Path $ProjectRoot "app\config.py"
$BackupRoot = Join-Path $ProjectRoot ("backup-before-v3471-" + (Get-Date -Format "yyyyMMdd-HHmmss"))

Write-Host "Creating backup: $BackupRoot"
New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
Copy-Item -Path (Join-Path $ProjectRoot "app") -Destination $BackupRoot -Recurse -Force

if (!(Test-Path $CssPath)) {
  throw "Could not find $CssPath"
}

$css = Get-Content $CssPath -Raw
$marker = "/* v3.4.7.1 force queue tab visibility */"
$patch = @'

/* v3.4.7.1 force queue tab visibility */
.queue-tabs:has(.queue-tab[data-filter="ready"].active) ~ .folder-list .torrent-card[data-imported="true"] {
  display: none !important;
}

.queue-tabs:has(.queue-tab[data-filter="imported"].active) ~ .folder-list .torrent-card[data-imported="false"] {
  display: none !important;
}
/* end v3.4.7.1 */
'@

if ($css -notlike "*$marker*") {
  Add-Content -Path $CssPath -Value $patch -Encoding UTF8
  Write-Host "Added Ready/Imported CSS visibility override."
} else {
  Write-Host "Ready/Imported CSS visibility override already present."
}

if (Test-Path $ConfigPath) {
  $config = Get-Content $ConfigPath -Raw
  $config = $config -replace 'APP_VERSION = "v3\.4\.7"', 'APP_VERSION = "v3.4.7.1"'
  $config = $config -replace 'APP_VERSION = "v3\.4\.6"', 'APP_VERSION = "v3.4.7.1"'
  Set-Content -Path $ConfigPath -Value $config -Encoding UTF8
  Write-Host "Version set to v3.4.7.1."
}

Write-Host "Copying project to NASDY..."
scp -r $ProjectRoot root@NASDY:/mnt/user/appdata/nasdy-media-linker-build

Write-Host "Building and redeploying on NASDY..."
ssh root@NASDY 'cd /mnt/user/appdata/nasdy-media-linker-build && docker build -t nasdy-media-linker:latest . && docker rm -f nasdy-media-organizer 2>/dev/null || true; docker run -d --name nasdy-media-organizer --restart unless-stopped -p 8088:8088 --user 99:100 -e DATA_ROOT=/data -e DOWNLOADS_ROOT=/downloads -e MOVIES_ROOT=/media/movies -e TV_ROOT=/media/tv -v /mnt:/host_mnt -v /mnt/user/NASDY/downloads:/downloads -v /mnt/user/NASDY/media:/media -v /mnt/user/appdata/nasdy-media-organizer/data:/data nasdy-media-linker:latest; docker logs nasdy-media-organizer --tail=80'

Write-Host "Done. Open http://nasdy:8088 and press Ctrl+F5."
