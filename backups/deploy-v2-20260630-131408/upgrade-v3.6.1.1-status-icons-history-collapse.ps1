param(
    [switch]$SkipDeploy
)

$ErrorActionPreference = "Stop"

$Version = "v3.6.1.1-status-icons-history-collapse"
$AppVersion = "v3.6.1.1"
$ProjectRoot = "C:\Projects\nasdy-media-linker"

function Write-Step($Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok($Message) {
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Warn($Message) {
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Fail($Message) {
    Write-Host "[ERROR] $Message" -ForegroundColor Red
    exit 1
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Content
    )
    $Parent = Split-Path -Parent $Path
    if ($Parent -and !(Test-Path $Parent)) {
        New-Item -ItemType Directory -Force -Path $Parent | Out-Null
    }
    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}

function Read-TextFile {
    param([Parameter(Mandatory=$true)][string]$RelativePath)
    $Path = Join-Path $ProjectRoot $RelativePath
    if (!(Test-Path $Path)) {
        Fail "Missing required file: $RelativePath"
    }
    return [System.IO.File]::ReadAllText($Path)
}

function Write-TextFile {
    param(
        [Parameter(Mandatory=$true)][string]$RelativePath,
        [Parameter(Mandatory=$true)][string]$Content
    )
    $Path = Join-Path $ProjectRoot $RelativePath
    Write-Utf8NoBom -Path $Path -Content $Content
    Write-Ok "Wrote $RelativePath"
}

function Backup-File {
    param(
        [Parameter(Mandatory=$true)][string]$RelativePath,
        [Parameter(Mandatory=$true)][string]$BackupPath
    )
    $SourcePath = Join-Path $ProjectRoot $RelativePath
    if (Test-Path $SourcePath) {
        $DestPath = Join-Path $BackupPath $RelativePath
        New-Item -ItemType Directory -Force -Path (Split-Path $DestPath -Parent) | Out-Null
        Copy-Item $SourcePath $DestPath -Force
    }
}

Write-Host ""
Write-Host "NASDY Media Linker $Version"
Write-Host "UI polish release"
Write-Host ""

Write-Step "Checking project folder"
if (!(Test-Path $ProjectRoot)) {
    Fail "Project folder not found: $ProjectRoot"
}

Set-Location $ProjectRoot

if (!(Test-Path ".\app")) {
    Fail "This does not look like the project root. Missing .\app"
}
if (!(Test-Path ".\Deploy.ps1")) {
    Fail "Deploy.ps1 is missing. Run the Deploy v2 foundation upgrade first."
}
if (!(Test-Path ".\.deploy.sh")) {
    Fail ".deploy.sh is missing. Run the Deploy v2 foundation upgrade first."
}

Write-Ok "Project detected: $ProjectRoot"

Write-Step "Creating local backup"
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$BackupRoot = Join-Path $ProjectRoot "backups"
$BackupPath = Join-Path $BackupRoot "$Version-$Stamp"
New-Item -ItemType Directory -Force -Path $BackupPath | Out-Null

$FilesToBackup = @(
    "app\config.py",
    "app\static\app.js",
    "app\static\style.css",
    "DEVELOPMENT.md"
)

foreach ($RelativePath in $FilesToBackup) {
    Backup-File -RelativePath $RelativePath -BackupPath $BackupPath
}

Write-Ok "Backup created: $BackupPath"

Write-Step "Updating app version"
$Config = Read-TextFile "app\config.py"
$ConfigUpdated = [regex]::Replace($Config, 'APP_VERSION\s*=\s*["''][^"''\r\n]+["'']', "APP_VERSION = `"$AppVersion`"")
if ($ConfigUpdated -eq $Config) {
    Write-Warn "APP_VERSION was not found in app\config.py. Leaving config version unchanged."
} else {
    Write-TextFile -RelativePath "app\config.py" -Content $ConfigUpdated
    Write-Ok "Set APP_VERSION to $AppVersion"
}

Write-Step "Patching status renderer and import-history collapse behavior"
$AppJsPath = "app\static\app.js"
$AppJs = Read-TextFile $AppJsPath

$RenderMarker = "function renderSmartImportStatus(row)"
$NextMarker = "function schedulePreview()"

$RenderIndex = $AppJs.IndexOf($RenderMarker)
$NextIndex = $AppJs.IndexOf($NextMarker)

if ($RenderIndex -lt 0) {
    Fail "Could not find renderSmartImportStatus(row) in app\static\app.js. Run the smart status upgrade first."
}

if ($NextIndex -lt 0 -or $NextIndex -le $RenderIndex) {
    Fail "Could not find schedulePreview() after renderSmartImportStatus(row). Not safe to patch."
}

$BeforeRender = $AppJs.Substring(0, $RenderIndex)
$AfterRender = $AppJs.Substring($NextIndex)

$ReplacementBlock = @'
function renderSmartImportStatus(row) {
  const card = smartStatusCardFromRow(row);
  const rawState = String(card.state || "blocked");
  const state = rawState.replace(/[^a-z0-9_-]/gi, "_").toLowerCase();
  const label = card.label || "Blocked";
  const lines = Array.isArray(card.lines) ? card.lines.filter(Boolean) : [];

  // v3.6.1.1: Do not render Unicode emoji from JS/backend.
  // Some NAS/static-file combinations displayed UTF-8 emoji as mojibake.
  // The visible status indicator is now a CSS dot keyed from the state class.
  return `
    <div class="smart-status-card smart-status-${escapeHtml(state)} multi-status" data-row-id="${escapeHtml(row?.row_id || "")}">
      <div class="smart-status-title">
        <span class="smart-status-icon" aria-hidden="true"></span>
        <span>${escapeHtml(label)}</span>
      </div>
      ${lines.map(line => `<div class="smart-status-line">${escapeHtml(line)}</div>`).join("")}
    </div>
  `;
}

function findPanelByHeadingText(headingText) {
  const normalizedNeedle = String(headingText || "").trim().toLowerCase();
  const candidates = Array.from(document.querySelectorAll("h1,h2,h3,h4,h5,.panel-title,.card-title,.section-title,strong,b"));

  const heading = candidates.find((element) => {
    const text = String(element.textContent || "").trim().toLowerCase();
    return text === normalizedNeedle || text.startsWith(`${normalizedNeedle} `);
  });

  if (!heading) return null;

  return heading.closest(".panel, .card, section, aside, .pane, .sidebar, .import-card, .glass-card") ||
    heading.parentElement?.parentElement ||
    heading.parentElement ||
    null;
}

function initImportHistoryCollapse() {
  if (document.body.dataset.importHistoryCollapseInit === "1") return;

  const historyPanel = findPanelByHeadingText("Import History");
  if (!historyPanel) return;

  const layoutParent = historyPanel.parentElement;
  if (!layoutParent) return;

  document.body.dataset.importHistoryCollapseInit = "1";

  historyPanel.classList.add("import-history-panel");
  layoutParent.classList.add("import-history-layout-parent");

  const originalGridTemplateColumns = getComputedStyle(layoutParent).gridTemplateColumns;
  layoutParent.dataset.originalGridTemplateColumns = originalGridTemplateColumns || "";

  const railButton = document.createElement("button");
  railButton.type = "button";
  railButton.className = "history-rail-toggle";
  railButton.textContent = "Import History";
  railButton.setAttribute("aria-expanded", "false");
  railButton.title = "Show Import History";
  document.body.appendChild(railButton);

  const heading = Array.from(historyPanel.querySelectorAll("h1,h2,h3,h4,h5,.panel-title,.card-title,.section-title,strong,b"))
    .find((element) => String(element.textContent || "").trim().toLowerCase().startsWith("import history"));

  const headerButton = document.createElement("button");
  headerButton.type = "button";
  headerButton.className = "history-panel-toggle";
  headerButton.textContent = "Collapse";
  headerButton.setAttribute("aria-expanded", "true");
  headerButton.title = "Collapse Import History";

  if (heading && heading.parentElement) {
    heading.parentElement.classList.add("history-heading-row");
    heading.parentElement.appendChild(headerButton);
  } else {
    historyPanel.insertBefore(headerButton, historyPanel.firstChild);
  }

  function setCollapsed(collapsed) {
    if (collapsed) {
      document.body.classList.add("import-history-collapsed");
      document.body.classList.remove("import-history-expanded");
      historyPanel.setAttribute("aria-hidden", "true");
      railButton.setAttribute("aria-expanded", "false");
      headerButton.setAttribute("aria-expanded", "false");

      // Collapse the right rail so the Import Manager gets the space.
      // The layout is intentionally controlled inline here because older builds
      // have had different wrapper class names.
      if (getComputedStyle(layoutParent).display === "grid") {
        layoutParent.style.gridTemplateColumns = "minmax(280px, 380px) minmax(0, 1fr)";
      }
    } else {
      document.body.classList.remove("import-history-collapsed");
      document.body.classList.add("import-history-expanded");
      historyPanel.setAttribute("aria-hidden", "false");
      railButton.setAttribute("aria-expanded", "true");
      headerButton.setAttribute("aria-expanded", "true");

      if (layoutParent.dataset.originalGridTemplateColumns) {
        layoutParent.style.gridTemplateColumns = layoutParent.dataset.originalGridTemplateColumns;
      } else {
        layoutParent.style.removeProperty("grid-template-columns");
      }
    }
  }

  railButton.addEventListener("click", () => setCollapsed(false));
  headerButton.addEventListener("click", () => setCollapsed(true));

  // Default behavior requested for v3.6.1.1.
  setCollapsed(true);
}

(function registerImportHistoryCollapse() {
  const run = () => {
    try {
      initImportHistoryCollapse();
    } catch (error) {
      console.warn("Import History collapse initialization failed", error);
    }
  };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", run);
  } else {
    window.setTimeout(run, 0);
  }

  window.addEventListener("load", run);
})();

'@

$AppJs = $BeforeRender + $ReplacementBlock + $AfterRender
$AppJs = $AppJs.Replace("v3.6.1.0", $AppVersion)
Write-TextFile -RelativePath $AppJsPath -Content $AppJs
Write-Ok "Updated app.js"

Write-Step "Appending UI polish CSS"
$StylePath = "app\static\style.css"
$Style = Read-TextFile $StylePath

if ($Style -notmatch 'v3\.6\.1\.1 Status Icons and Collapsed Import History') {
    $StyleAdd = @'

/* v3.6.1.1 Status Icons and Collapsed Import History */

/* Replace Unicode emoji status icons with CSS dots to avoid mojibake. */
.smart-status-icon {
  display: inline-block;
  width: 11px;
  height: 11px;
  min-width: 11px;
  border-radius: 999px;
  background: #7c8494;
  box-shadow: 0 0 0 3px rgba(124,132,148,.12), 0 0 12px rgba(124,132,148,.35);
  line-height: 1;
  font-size: 0;
}

.smart-status-ready .smart-status-icon {
  background: #2dbd6e;
  box-shadow: 0 0 0 3px rgba(45,189,110,.13), 0 0 12px rgba(45,189,110,.45);
}

.smart-status-needs_review .smart-status-icon {
  background: #ffcc66;
  box-shadow: 0 0 0 3px rgba(255,204,102,.13), 0 0 12px rgba(255,204,102,.45);
}

.smart-status-duplicate .smart-status-icon {
  background: #d85050;
  box-shadow: 0 0 0 3px rgba(216,80,80,.13), 0 0 12px rgba(216,80,80,.45);
}

.smart-status-upgrade .smart-status-icon {
  background: #5b7cff;
  box-shadow: 0 0 0 3px rgba(91,124,255,.13), 0 0 12px rgba(91,124,255,.45);
}

.smart-status-blocked .smart-status-icon {
  background: #9aa3b2;
  box-shadow: 0 0 0 3px rgba(154,163,178,.13), 0 0 12px rgba(154,163,178,.35);
}

/* Import History is collapsed by default so Import Manager gets more width. */
.import-history-panel {
  position: relative;
}

body.import-history-collapsed .import-history-panel {
  display: none !important;
}

.history-rail-toggle {
  position: fixed;
  right: 18px;
  top: 126px;
  z-index: 80;
  padding: 10px 14px;
  border-radius: 999px;
  border: 1px solid #2ab36a;
  background: #0f3a22;
  color: #b8ffd0;
  font-weight: 950;
  letter-spacing: .01em;
  cursor: pointer;
  box-shadow: 0 10px 30px rgba(0,0,0,.35);
}

.history-rail-toggle:hover {
  filter: brightness(1.12);
}

body.import-history-expanded .history-rail-toggle {
  display: none;
}

.history-heading-row {
  display: flex;
  align-items: center;
  gap: 12px;
}

.history-panel-toggle {
  margin-left: auto;
  padding: 6px 10px;
  border-radius: 999px;
  border: 1px solid #344057;
  background: #101722;
  color: #d7e3f7;
  font-size: 12px;
  font-weight: 900;
  cursor: pointer;
}

.history-panel-toggle:hover {
  border-color: #5b7cff;
  color: #ffffff;
}

body.import-history-collapsed .import-history-layout-parent {
  column-gap: 18px;
}

/* Give the center import table a bit more breathing room when the right panel is collapsed. */
body.import-history-collapsed .smart-status-card {
  max-width: 260px;
}

@media (max-width: 900px) {
  .history-rail-toggle {
    position: static;
    display: inline-flex;
    margin: 8px 0 12px;
  }
}
/* end v3.6.1.1 Status Icons and Collapsed Import History */
'@
    $Style = $Style.TrimEnd() + "`r`n" + $StyleAdd.TrimStart("`r", "`n") + "`r`n"
    Write-Ok "Added v3.6.1.1 CSS"
} else {
    Write-Ok "v3.6.1.1 CSS already present"
}

$Style = $Style.Replace("v3.6.1.0", $AppVersion)
Write-TextFile -RelativePath $StylePath -Content $Style

Write-Step "Updating DEVELOPMENT.md"
$DevelopmentPath = Join-Path $ProjectRoot "DEVELOPMENT.md"
if (!(Test-Path $DevelopmentPath)) {
    Write-Utf8NoBom -Path $DevelopmentPath -Content "# NASDY Media Linker Development Notes`r`n"
}

$Development = [System.IO.File]::ReadAllText($DevelopmentPath)
if ($Development -notmatch 'v3\.6\.1\.1 Status Icons and Collapsed Import History') {
    $DevelopmentAdd = @'

## v3.6.1.1 Status Icons and Collapsed Import History

Polish release after the first Smart Status deployment.

Changes:
- Replaces visible Unicode emoji status icons with CSS status dots.
- Keeps backend status states the same: ready, needs_review, duplicate, upgrade, blocked.
- Collapses Import History by default so the Import Manager can use more horizontal space.
- Adds an `Import History` rail button to expand the history panel.
- Adds a `Collapse` button inside Import History to return to the wider Import Manager layout.

Reason:
Some static-file/browser combinations rendered emoji as mojibake. CSS dots are more reliable, cleaner, and easier to theme.

'@
    $Development = $Development.TrimEnd() + "`r`n" + $DevelopmentAdd.TrimStart("`r", "`n")
    Write-Utf8NoBom -Path $DevelopmentPath -Content $Development
    Write-Ok "Updated DEVELOPMENT.md"
} else {
    Write-Ok "DEVELOPMENT.md already has v3.6.1.1 notes"
}

Write-Step "Cleaning local Python cache files"
Get-ChildItem -Path $ProjectRoot -Directory -Recurse -Force -Filter "__pycache__" -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $ProjectRoot -File -Recurse -Force -Filter "*.pyc" -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue
Write-Ok "Python cache files cleaned"

Write-Step "Showing changed files"
git status --short

if ($SkipDeploy) {
    Write-Warn "Skipped deployment because -SkipDeploy was used."
    Write-Host ""
    Write-Host "Run this when ready:"
    Write-Host "  powershell -ExecutionPolicy Bypass -File .\Deploy.ps1"
    exit 0
}

Write-Step "Deploying with permanent Deploy.ps1"
powershell -ExecutionPolicy Bypass -File ".\Deploy.ps1"

if ($LASTEXITCODE -ne 0) {
    Fail "Deploy.ps1 failed."
}

Write-Host ""
Write-Host "NASDY Media Linker $Version complete" -ForegroundColor Green
Write-Host ""
Write-Host "Verify in browser:"
Write-Host "  1. Hard refresh http://NASDY:8088"
Write-Host "  2. Confirm version shows $AppVersion"
Write-Host "  3. Confirm Status cards show colored dots instead of mojibake"
Write-Host "  4. Confirm Import History is collapsed by default"
Write-Host "  5. Click Import History and confirm the Import pane shrinks"
Write-Host ""
Write-Host "Suggested commit:"
Write-Host '  git add app/config.py app/static/app.js app/static/style.css DEVELOPMENT.md'
Write-Host '  git commit -m "Polish status cards and collapse import history"'
Write-Host ""
