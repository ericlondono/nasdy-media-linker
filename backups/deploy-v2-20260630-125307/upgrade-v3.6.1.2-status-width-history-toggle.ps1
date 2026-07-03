param(
    [switch]$SkipDeploy
)

$ErrorActionPreference = "Stop"

$Version = "v3.6.1.2-status-width-history-toggle"
$AppVersion = "v3.6.1.2"
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
Write-Host "Status width + Import History toggle fix"
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

Write-Step "Replacing Import History toggle JavaScript"
$AppJsPath = "app\static\app.js"
$AppJs = Read-TextFile $AppJsPath

$StartMarker = "function findPanelByHeadingText(headingText)"
$EndMarker = "function schedulePreview()"

$StartIndex = $AppJs.IndexOf($StartMarker)
if ($StartIndex -lt 0) {
    Fail "Could not find Import History collapse block start in app\static\app.js."
}

$EndIndex = $AppJs.IndexOf($EndMarker, $StartIndex)
if ($EndIndex -lt 0) {
    Fail "Could not find schedulePreview() after the Import History collapse block."
}

$Before = $AppJs.Substring(0, $StartIndex)
$After = $AppJs.Substring($EndIndex)

$HistoryJs = @'
function findPanelByHeadingText(headingText) {
  const normalizedNeedle = String(headingText || "").trim().toLowerCase();
  const candidates = Array.from(document.querySelectorAll("h1,h2,h3,h4,h5,.panel-title,.card-title,.section-title,strong,b"));

  const heading = candidates.find((element) => {
    const text = String(element.textContent || "").trim().toLowerCase();
    return text === normalizedNeedle || text.startsWith(`${normalizedNeedle} `);
  });

  if (!heading) return null;

  // Walk upward until we find the real layout column/card, not just the heading row.
  let node = heading;
  let fallback = heading.closest(".panel, .card, section, aside, .pane, .sidebar, .import-card, .glass-card");

  for (let depth = 0; node && node !== document.body && depth < 10; depth += 1) {
    const parent = node.parentElement;
    if (!parent) break;

    const parentDisplay = getComputedStyle(parent).display || "";
    const nodeLooksLargeEnough = node.offsetWidth >= 220 && node.offsetHeight >= 120;

    if (nodeLooksLargeEnough && (parentDisplay.includes("grid") || parentDisplay.includes("flex"))) {
      return node;
    }

    if (nodeLooksLargeEnough) {
      fallback = node;
    }

    node = parent;
  }

  return fallback ||
    heading.parentElement?.parentElement ||
    heading.parentElement ||
    null;
}

function initImportHistoryCollapse() {
  const historyPanel = findPanelByHeadingText("Import History");
  if (!historyPanel) return;

  const layoutParent = historyPanel.parentElement;
  if (!layoutParent) return;

  // v3.6.1.2: repair any prior runtime initialization and install one stable toggle.
  document.querySelectorAll(".history-rail-toggle, .history-panel-toggle").forEach((button) => button.remove());

  document.body.dataset.importHistoryCollapseInit = "1";

  historyPanel.classList.add("import-history-panel");
  layoutParent.classList.add("import-history-layout-parent");

  if (!layoutParent.dataset.originalGridTemplateColumns) {
    layoutParent.dataset.originalGridTemplateColumns = getComputedStyle(layoutParent).gridTemplateColumns || "";
  }

  if (!historyPanel.dataset.originalDisplay) {
    const display = getComputedStyle(historyPanel).display;
    historyPanel.dataset.originalDisplay = display && display !== "none" ? display : "block";
  }

  const railButton = document.createElement("button");
  railButton.type = "button";
  railButton.className = "history-rail-toggle";
  railButton.setAttribute("aria-controls", "import-history-panel");
  document.body.appendChild(railButton);

  historyPanel.id = historyPanel.id || "import-history-panel";

  const heading = Array.from(historyPanel.querySelectorAll("h1,h2,h3,h4,h5,.panel-title,.card-title,.section-title,strong,b"))
    .find((element) => String(element.textContent || "").trim().toLowerCase().startsWith("import history"));

  const headerButton = document.createElement("button");
  headerButton.type = "button";
  headerButton.className = "history-panel-toggle";
  headerButton.textContent = "Collapse";
  headerButton.title = "Collapse Import History";

  if (heading && heading.parentElement) {
    heading.parentElement.classList.add("history-heading-row");
    heading.parentElement.appendChild(headerButton);
  } else {
    historyPanel.insertBefore(headerButton, historyPanel.firstChild);
  }

  function setCollapsed(collapsed) {
    document.body.classList.toggle("import-history-collapsed", collapsed);
    document.body.classList.toggle("import-history-expanded", !collapsed);

    historyPanel.setAttribute("aria-hidden", collapsed ? "true" : "false");
    railButton.setAttribute("aria-expanded", collapsed ? "false" : "true");
    headerButton.setAttribute("aria-expanded", collapsed ? "false" : "true");

    if (collapsed) {
      historyPanel.style.setProperty("display", "none", "important");
      railButton.textContent = "Import History";
      railButton.title = "Show Import History";

      if (getComputedStyle(layoutParent).display === "grid") {
        layoutParent.style.gridTemplateColumns = "minmax(280px, 380px) minmax(0, 1fr)";
      }
    } else {
      historyPanel.style.removeProperty("display");
      historyPanel.style.display = historyPanel.dataset.originalDisplay || "block";
      railButton.textContent = "Hide History";
      railButton.title = "Hide Import History";

      if (layoutParent.dataset.originalGridTemplateColumns) {
        layoutParent.style.gridTemplateColumns = layoutParent.dataset.originalGridTemplateColumns;
      } else {
        layoutParent.style.removeProperty("grid-template-columns");
      }
    }
  }

  railButton.addEventListener("click", () => {
    const collapsed = document.body.classList.contains("import-history-collapsed");
    setCollapsed(!collapsed);
  });

  headerButton.addEventListener("click", () => setCollapsed(true));

  // Default requested behavior: wider Import Manager first, history on demand.
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

$AppJs = $Before + $HistoryJs + $After
$AppJs = $AppJs.Replace("v3.6.1.1", $AppVersion).Replace("v3.6.1.0", $AppVersion)
Write-TextFile -RelativePath $AppJsPath -Content $AppJs
Write-Ok "Updated Import History toggle behavior"

Write-Step "Adding status width and history toggle CSS fixes"
$StylePath = "app\static\style.css"
$Style = Read-TextFile $StylePath

if ($Style -notmatch 'v3\.6\.1\.2 Status Width and History Toggle Fixes') {
    $StyleAdd = @'

/* v3.6.1.2 Status Width and History Toggle Fixes */

/* Keep smart status cards inside the Status column. */
table:has(.smart-status-card) {
  table-layout: fixed !important;
  width: 100% !important;
}

table:has(.smart-status-card) th:last-child,
table:has(.smart-status-card) td:last-child,
.multi-status-cell {
  width: 148px !important;
  min-width: 148px !important;
  max-width: 148px !important;
  overflow: hidden !important;
  box-sizing: border-box !important;
}

.smart-status-card {
  width: 100% !important;
  min-width: 0 !important;
  max-width: 138px !important;
  padding: 6px 7px !important;
  box-sizing: border-box !important;
}

.smart-status-title {
  min-width: 0 !important;
  max-width: 100% !important;
  overflow: hidden !important;
  text-overflow: ellipsis !important;
  white-space: nowrap !important;
  font-size: 12px !important;
}

.smart-status-line {
  max-width: 100% !important;
  overflow: hidden !important;
  text-overflow: ellipsis !important;
  white-space: nowrap !important;
  font-size: 10px !important;
  line-height: 1.2 !important;
}

table:has(.smart-status-card) td:last-child > *:not(.smart-status-card) {
  display: block !important;
  max-width: 100% !important;
  overflow: hidden !important;
  text-overflow: ellipsis !important;
  white-space: nowrap !important;
}

/* Make table inputs respect their cell widths. */
table:has(.smart-status-card) input,
table:has(.smart-status-card) select,
table:has(.smart-status-card) textarea {
  max-width: 100% !important;
  box-sizing: border-box !important;
}

/* Keep the Import History toggle visible in both states. */
.history-rail-toggle,
body.import-history-expanded .history-rail-toggle,
body.import-history-collapsed .history-rail-toggle {
  display: inline-flex !important;
  align-items: center !important;
  justify-content: center !important;
  position: fixed !important;
  right: 18px !important;
  top: 112px !important;
  z-index: 120 !important;
}

body.import-history-expanded .history-rail-toggle {
  border-color: #ffcc66 !important;
  background: #33220f !important;
  color: #ffdf9c !important;
}

body.import-history-collapsed .history-rail-toggle {
  border-color: #2ab36a !important;
  background: #0f3a22 !important;
  color: #b8ffd0 !important;
}

/* When visible, the right panel must show its content and the collapse button. */
body.import-history-expanded .import-history-panel {
  display: block !important;
}

body.import-history-expanded .history-panel-toggle {
  display: inline-flex !important;
  align-items: center !important;
  justify-content: center !important;
}

/* Restore the requested hidden default state. */
body.import-history-collapsed .import-history-panel {
  display: none !important;
}

/* Slightly favor the Import Manager when the history panel is hidden. */
body.import-history-collapsed .import-history-layout-parent {
  column-gap: 18px !important;
}

/* end v3.6.1.2 Status Width and History Toggle Fixes */
'@
    $Style = $Style.TrimEnd() + "`r`n" + $StyleAdd.TrimStart("`r", "`n") + "`r`n"
    Write-Ok "Added v3.6.1.2 CSS"
} else {
    Write-Ok "v3.6.1.2 CSS already present"
}

$Style = $Style.Replace("v3.6.1.1", $AppVersion).Replace("v3.6.1.0", $AppVersion)
Write-TextFile -RelativePath $StylePath -Content $Style

Write-Step "Updating DEVELOPMENT.md"
$DevelopmentPath = Join-Path $ProjectRoot "DEVELOPMENT.md"
if (!(Test-Path $DevelopmentPath)) {
    Write-Utf8NoBom -Path $DevelopmentPath -Content "# NASDY Media Linker Development Notes`r`n"
}

$Development = [System.IO.File]::ReadAllText($DevelopmentPath)
if ($Development -notmatch 'v3\.6\.1\.2 Status Width and History Toggle Fixes') {
    $DevelopmentAdd = @'

## v3.6.1.2 Status Width and History Toggle Fixes

Polish release after v3.6.1.1.

Fixes:
- Smart status cards are constrained to the Status column and no longer grow off the right side of the Import Manager pane.
- Status card detail lines truncate with ellipses instead of forcing the table wider.
- Import History button remains visible after expanding so the user can hide the panel again.
- Import History expansion explicitly restores the panel display so it does not open as a blank right pane.
- Collapsed-by-default behavior is preserved.

'@
    $Development = $Development.TrimEnd() + "`r`n" + $DevelopmentAdd.TrimStart("`r", "`n")
    Write-Utf8NoBom -Path $DevelopmentPath -Content $Development
    Write-Ok "Updated DEVELOPMENT.md"
} else {
    Write-Ok "DEVELOPMENT.md already has v3.6.1.2 notes"
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
Write-Host "  3. Confirm status cards stay inside the Status column"
Write-Host "  4. Confirm Import History is collapsed by default"
Write-Host "  5. Click Import History and confirm the panel content appears"
Write-Host "  6. Click Hide History or Collapse and confirm it hides again"
Write-Host ""
Write-Host "Suggested commit:"
Write-Host '  git add app/config.py app/static/app.js app/static/style.css DEVELOPMENT.md'
Write-Host '  git commit -m "Fix status card width and import history toggle"'
Write-Host ""
