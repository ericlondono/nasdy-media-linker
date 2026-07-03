param(
  [string]$Message = "",
  [switch]$Deploy
)

$ErrorActionPreference = "Stop"

Write-Host "NASDY Media Linker Developer Update" -ForegroundColor Cyan

Write-Host "`nChecking Python files..." -ForegroundColor Cyan
python -m py_compile app\main.py
Get-ChildItem app\services -Filter *.py | ForEach-Object {
  python -m py_compile $_.FullName
}

Write-Host "Python compile OK." -ForegroundColor Green

$status = git status --porcelain

if (-not $status) {
  Write-Host "No changes to commit." -ForegroundColor Yellow
} else {
  if (-not $Message) {
    $Message = Read-Host "Commit message"
  }

  git add .
  git commit -m "$Message"
  git push
}

if ($Deploy) {
  Write-Host "`nDeploying to NASDY..." -ForegroundColor Cyan

  ssh root@NASDY "cd /mnt/user/appdata/nasdy-media-organizer && git pull && chmod +x install-unraid.sh && ./install-unraid.sh"

  Write-Host "`nChecking container logs..." -ForegroundColor Cyan
  ssh root@NASDY "docker logs nasdy-media-organizer --tail=40"

  Start-Process "http://nasdy:8088"
}

Write-Host "`nDone." -ForegroundColor Green
