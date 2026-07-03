# NASDY Media Linker v3.6.0.1 - Compact Multi-Item Import Manager UI
# Run this from C:\Projects\nasdy-media-linker
#
# This script backs up your local UI files, applies the compact no-horizontal-scroll
# Multi-Item Import Manager layout, syncs the project to the NAS, rebuilds the
# Docker image on unRAID, restarts the container, and verifies /health.

param(
    [string]$NasHost = "NASDY",
    [string]$NasUser = "root",
    [string]$RemoteProjectPath = "/mnt/user/appdata/nasdy-media-organizer",
    [string]$ContainerName = "nasdy-media-organizer",
    [string]$ImageName = "nasdy-media-linker:latest",
    [int]$Port = 8088,
    [switch]$SkipDeploy
)

$ErrorActionPreference = "Stop"

function Write-Step($Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Good($Message) {
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Warn($Message) {
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Fail($Message) {
    Write-Host "[FAIL] $Message" -ForegroundColor Red
    exit 1
}

function Write-Utf8File {
    param(
        [Parameter(Mandatory=$true)][string]$RelativePath,
        [Parameter(Mandatory=$true)][string]$Content
    )

    $TargetPath = Join-Path $ProjectRoot $RelativePath
    New-Item -ItemType Directory -Force -Path (Split-Path $TargetPath -Parent) | Out-Null
    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($TargetPath, $Content, $Utf8NoBom)
    Write-Good "Wrote $RelativePath"
}

$ProjectRoot = (Get-Location).Path

Write-Step "Checking project folder"

if (!(Test-Path "$ProjectRoot\app")) {
    Fail "This does not look like the NASDY Media Linker project folder. Missing .\app"
}
if (!(Test-Path "$ProjectRoot\Dockerfile")) {
    Fail "Missing Dockerfile. Run this from C:\Projects\nasdy-media-linker"
}
if (!(Test-Path "$ProjectRoot\requirements.txt")) {
    Fail "Missing requirements.txt. Run this from C:\Projects\nasdy-media-linker"
}
if (!(Test-Path "$ProjectRoot\app\config.py")) {
    Fail "Missing app\config.py"
}

Write-Good "Project detected: $ProjectRoot"

Write-Step "Creating local backup"

$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$BackupRoot = Join-Path $ProjectRoot "backups"
$BackupPath = Join-Path $BackupRoot "v3.6.0.1-compact-multi-ui-$Stamp"
New-Item -ItemType Directory -Force -Path $BackupPath | Out-Null

$FilesToBackup = @(
    "app\config.py",
    "app\static\app.js",
    "app\static\style.css"
)

foreach ($RelativePath in $FilesToBackup) {
    $SourcePath = Join-Path $ProjectRoot $RelativePath
    if (Test-Path $SourcePath) {
        $BackupFile = Join-Path $BackupPath $RelativePath
        New-Item -ItemType Directory -Force -Path (Split-Path $BackupFile -Parent) | Out-Null
        Copy-Item $SourcePath $BackupFile -Force
    }
}

Write-Good "Backup created: $BackupPath"

Write-Step "Applying v3.6.0.1 compact UI patch"

Write-Utf8File -RelativePath "app\config.py" -Content @'
import os
from pathlib import Path

APP_NAME = "NASDY Media Linker"
APP_VERSION = "v3.6.0.1"

DOWNLOADS_ROOT = Path(os.environ.get("DOWNLOADS_ROOT", "/downloads"))
MOVIES_ROOT = Path(os.environ.get("MOVIES_ROOT", "/media/movies"))
TV_ROOT = Path(os.environ.get("TV_ROOT", "/media/tv"))
DATA_ROOT = Path(os.environ.get("DATA_ROOT", "/data"))

HOST_DOWNLOADS_ROOT = os.environ.get("HOST_DOWNLOADS_ROOT", "/mnt/user/NASDY/downloads")
HOST_MEDIA_ROOT = os.environ.get("HOST_MEDIA_ROOT", "/mnt/user/NASDY/media")
HOST_MNT_ROOT = Path(os.environ.get("HOST_MNT_ROOT", "/host_mnt"))

VIDEO_EXTENSIONS = {".mkv", ".mp4", ".avi", ".mov", ".m4v", ".wmv"}

IGNORE_NAMES = {
    "audiobooks", "books", "print", "movies", "tv shows", "tv", "music",
    "media organizer", "lost+found", "media linker"
}

QUALITY_WORDS = [
    "2160p","1080p","720p","480p","webrip","web-rip","web-dl","webdl","bluray","blu-ray","brrip",
    "hdrip","dvdrip","uhd","truehd","remux","x264","x265","h264","h265","hevc","av1","flac","aac",
    "truehd","atmos","dts","dts-hd","ma","hdr","hdr10","dv","dolby","vision","proper","repack",
    "extended","unrated","directors","director","cut","amzn","amazon","nf","netflix","hulu","max",
    "lama","trolluhd","playweb","ddp","dd5","5.1","7.1","10bit","8bit","yts","rarbg", "eac3", "siqma"
]

DATA_ROOT.mkdir(parents=True, exist_ok=True)

HISTORY_FILE = DATA_ROOT / "history.jsonl"
IMPORT_DB_FILE = DATA_ROOT / "imports.json"
SETTINGS_FILE = DATA_ROOT / "settings.json"
LOG_FILE = DATA_ROOT / "media-linker.log"
'@

Write-Utf8File -RelativePath "app\static\app.js" -Content @'
const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => Array.from(document.querySelectorAll(selector));

let previewTimer = null;
let multiPreviewTimer = null;
let activeQueueFilter = "recommended";
let activeHistoryFilter = "success";
let multiImportState = { enabled: false, mode: "single", items: [] };

function setMediaType(type) {
  const radio = document.querySelector(`input[name="media_type"][value="${type}"]`);
  if (radio) radio.checked = true;
  updateSeasonVisibility();
}

function getMediaType() {
  const checked = document.querySelector('input[name="media_type"]:checked');
  return checked ? checked.value : "tv";
}

function getImportButton() {
  return document.querySelector('form[action="/organize"] button[type="submit"]');
}

function setImportButton(text, disabled = false) {
  const btn = getImportButton();
  if (!btn) return;
  btn.textContent = text;
  btn.disabled = disabled;
  btn.classList.toggle("disabled", disabled);
}

function setDuplicatePolicy(value = "skip") {
  const field = $("#duplicatePolicy");
  if (field) field.value = value;
}

function setManualButtons(imported = false) {
  const markBtn = $("#markImportedBtn");
  const unmarkBtn = $("#unmarkImportedBtn");
  if (markBtn) markBtn.classList.toggle("hidden", imported || multiImportState.enabled);
  if (unmarkBtn) unmarkBtn.classList.toggle("hidden", !imported);
}

function setActionMessage(message, isError = false) {
  const warning = $("#warning");
  if (!warning) return;
  warning.textContent = message || "";
  warning.classList.toggle("bad-text", !!isError);
}

function selectedPayload() {
  return {
    source: $("#source")?.value || "",
    source_key: $("#sourceKey")?.value || "",
    media_type: getMediaType(),
    title: $("#title")?.value || "",
    year: $("#year")?.value || "",
    imdb_id: $("#imdb_id")?.value || "",
    season: $("#season")?.value || "01",
  };
}

function updateSeasonVisibility() {
  const seasonWrap = $("#seasonWrap");
  if (!seasonWrap) return;
  seasonWrap.style.display = getMediaType() === "movie" ? "none" : "block";
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function asArray(value) {
  return Array.isArray(value) ? value : [];
}

function schedulePreview() {
  clearTimeout(previewTimer);
  previewTimer = setTimeout(previewSelected, 350);
}

function setSingleImportFieldsVisible(visible = true) {
  const single = $("#singleImportFields");
  if (single) single.classList.toggle("hidden", !visible);
}

function resetMultiImportUI() {
  multiImportState = { enabled: false, mode: "single", items: [] };
  clearTimeout(multiPreviewTimer);
  const hidden = $("#multiItems");
  if (hidden) hidden.value = "";
  const manager = $("#multiImportManager");
  if (manager) {
    manager.classList.add("hidden");
    manager.innerHTML = "";
  }
  setSingleImportFieldsVisible(true);
}

function fillFromCard(card) {
  if (!card) return;

  $$(".folder").forEach(el => el.classList.remove("active"));
  card.classList.add("active");

  resetMultiImportUI();

  $("#source").value = card.dataset.source || "";
  $("#sourceKey").value = card.dataset.sourceKey || card.dataset.source || "";
  $("#title").value = card.dataset.title || "";
  $("#year").value = card.dataset.year || "";
  $("#season").value = card.dataset.season || "01";
  const imdbInput = $("#imdb_id");
  if (imdbInput) imdbInput.value = "";
  setDuplicatePolicy("skip");
  setActionMessage("");
  setManualButtons(card.dataset.imported === "true");

  setMediaType(card.dataset.type || "tv");
  setImportButton("Checking...", true);

  const metadata = $("#metadata");
  if (metadata) {
    metadata.classList.remove("hidden");
    metadata.innerHTML = `
      <div class="advisor-panel checking">
        <h3>Smart Import Advisor</h3>
        <p>Checking your library, incoming files, and duplicate risk...</p>
      </div>
    `;
  }

  const preview = $("#preview");
  if (preview) preview.innerHTML = '<div class="empty-preview">Checking import plan...</div>';

  schedulePreview();
}

function renderMiniFacts(advisor) {
  const chips = [
    ["Incoming", advisor.incoming_summary],
    ["Existing", advisor.existing_summary],
    ["Missing", advisor.missing_summary],
    ["Duplicates", advisor.duplicate_summary],
  ].filter(pair => pair[1]);

  if (!chips.length) return "";

  return `
    <div class="advisor-chip-row">
      ${chips.map(([label, value]) => `
        <span class="advisor-mini-chip">
          <strong>${escapeHtml(label)}</strong>
          ${escapeHtml(value)}
        </span>
      `).join("")}
    </div>
  `;
}

function renderAdvisorFacts(advisor) {
  const facts = asArray(advisor.facts);
  if (!facts.length) return "";
  return `
    <div class="advisor-facts">
      ${facts.map(fact => `<p>${escapeHtml(fact)}</p>`).join("")}
    </div>
  `;
}

function renderAdvisorWarnings(advisor) {
  const warnings = asArray(advisor.warnings).concat(asArray(advisor.errors));
  if (!warnings.length) return "";
  return `
    <div class="advisor-warnings">
      ${warnings.map(warning => `<p>${escapeHtml(warning)}</p>`).join("")}
    </div>
  `;
}

function multiStatusClass(level) {
  if (level === "error") return "error";
  if (level === "duplicate") return "duplicate";
  if (level === "warning") return "attention";
  if (level === "skipped") return "imported";
  return "recommended";
}

function renderMultiAdvisor(data) {
  const metadata = $("#metadata");
  if (!metadata) return;
  metadata.classList.remove("hidden");

  const multi = data.multi_import || {};
  if (multi.enabled) multiImportState.enabled = true;
  const advisor = data.advisor || {};
  const summary = multi.summary || {};
  const level = advisor.level || (summary.errors || summary.warnings ? "attention" : "recommended");
  const label = advisor.label || "Multi-Item";
  const importAllowed = multi.import_allowed !== false;

  setDuplicatePolicy("skip_existing");
  setImportButton(multi.action_button || advisor.action_button || "Create Selected Hard Links", !importAllowed);
  setManualButtons(false);

  metadata.innerHTML = `
    <div class="advisor-panel ${escapeHtml(level)}">
      <div class="advisor-heading-row">
        <h3>Smart Import Advisor</h3>
        <span class="status-chip advisor-chip ${escapeHtml(level)}">${escapeHtml(label)}</span>
      </div>
      <p class="advisor-headline">${escapeHtml(advisor.headline || multi.title || "Multi-Item Import Manager")}</p>
      <div class="advisor-chip-row">
        <span class="advisor-mini-chip"><strong>Total rows</strong>${escapeHtml(summary.total ?? 0)}</span>
        <span class="advisor-mini-chip"><strong>Selected</strong>${escapeHtml(summary.enabled ?? 0)}</span>
        <span class="advisor-mini-chip"><strong>Ready</strong>${escapeHtml(summary.ready ?? 0)}</span>
        <span class="advisor-mini-chip"><strong>Warnings</strong>${escapeHtml((summary.warnings ?? 0) + (summary.errors ?? 0))}</span>
      </div>
      ${renderAdvisorFacts(advisor)}
      ${renderAdvisorWarnings(advisor)}
      <p><strong>Recommendation:</strong> ${escapeHtml(advisor.recommendation || multi.recommendation || "Review each row before importing.")}</p>
      <p><strong>Destination:</strong><br>Multiple destinations</p>
    </div>
  `;
}

function compactPath(value) {
  const text = String(value || "").replaceAll("\\", "/");
  if (!text) return "";
  const parts = text.split("/").filter(Boolean);
  if (parts.length <= 2) return text;
  return `.../${parts.slice(-2).join("/")}`;
}

function titleCaseLoose(value) {
  const small = new Set(["of", "the", "a", "an", "and", "or", "in", "on", "at", "to", "for", "with", "by", "from"]);
  return String(value || "")
    .replace(/[._]+/g, " ")
    .replace(/[-]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .split(" ")
    .filter(Boolean)
    .map((word, index) => {
      const lower = word.toLowerCase();
      if (index !== 0 && small.has(lower)) return lower;
      if (/^[A-Z0-9]{2,}$/.test(word)) return word;
      return lower.charAt(0).toUpperCase() + lower.slice(1);
    })
    .join(" ");
}

function compactDetectedLabel(row) {
  const mediaType = row.media_type || "movie";
  const detected = String(row.detected || row.source || "").replaceAll("\\", "/").split("/").filter(Boolean).pop() || "Detected item";

  if (mediaType === "tv") {
    return titleCaseLoose(detected) || `Season ${row.season || ""}`.trim();
  }

  const year = String(row.year || "").trim();
  if (row.title) {
    return year ? `${row.title} (${year})` : row.title;
  }

  const yearMatch = detected.match(/^(.*?)(19\d{2}|20\d{2})/);
  if (yearMatch) {
    const name = titleCaseLoose(yearMatch[1]);
    return name ? `${name} (${yearMatch[2]})` : titleCaseLoose(detected);
  }

  return titleCaseLoose(detected);
}

function shortDestination(value) {
  const text = String(value || "").replaceAll("\\", "/");
  if (!text) return "";
  const parts = text.split("/").filter(Boolean);
  if (parts.length <= 3) return text;
  return `.../${parts.slice(-3).join("/")}`;
}

function renderMultiImportManager(multi) {
  const manager = $("#multiImportManager");
  if (!manager || !multi || !multi.enabled) return;

  multiImportState = {
    ...multi,
    items: asArray(multi.items),
  };

  setSingleImportFieldsVisible(false);
  manager.classList.remove("hidden");

  const hasTvRows = multiImportState.items.some(row => row.media_type === "tv");
  const seasonHeader = hasTvRows ? '<th class="multi-season-cell">Season</th>' : '';
  const tableClass = hasTvRows ? "has-season" : "movie-only";

  const rows = multiImportState.items.map(row => {
    const isTv = row.media_type === "tv";
    const statusClass = multiStatusClass(row.status_level || row.match_level);
    const checked = row.enabled === false ? "" : "checked";
    const seasonInput = hasTvRows
      ? (isTv
        ? `<td class="multi-season-cell"><input class="multi-field multi-season" value="${escapeHtml(row.season || "01")}" autocomplete="off"></td>`
        : `<td class="multi-season-cell"><span class="muted-dash">-</span></td>`)
      : "";
    const destination = row.destination || "";
    const detectedLabel = compactDetectedLabel(row);
    const sourceHint = compactPath(row.source || "");
    const fileCount = Number(row.file_count || 0);

    return `
      <tr
        data-row-id="${escapeHtml(row.row_id)}"
        data-media-type="${escapeHtml(row.media_type || "movie")}" 
        data-source="${escapeHtml(row.source || "")}" 
        data-source-key="${escapeHtml(row.source_key || row.source || "")}" 
        data-detected="${escapeHtml(row.detected || "")}" 
        data-tmdb-id="${escapeHtml(row.tmdb_id || "")}" 
        data-poster="${escapeHtml(row.poster || "")}" 
        data-match-status="${escapeHtml(row.match_status || "")}" 
        data-match-level="${escapeHtml(row.match_level || "")}" 
        data-match-score="${escapeHtml(row.match_score || "")}" 
      >
        <td class="multi-check-cell">
          <input class="multi-enabled" type="checkbox" ${checked} aria-label="Import ${escapeHtml(row.title || row.detected || "row")}">
        </td>
        <td class="multi-folder-cell" title="${escapeHtml(row.source || row.detected || "")}">
          <strong class="multi-folder-name">${escapeHtml(detectedLabel)}</strong>
          <small class="multi-folder-meta">
            <span class="multi-file-count">${escapeHtml(fileCount)} file${fileCount === 1 ? "" : "s"}</span>
            ${sourceHint ? `<span class="multi-source-hint">${escapeHtml(sourceHint)}</span>` : ""}
          </small>
        </td>
        <td class="multi-title-cell"><input class="multi-field multi-title" value="${escapeHtml(row.title || "")}" autocomplete="off"></td>
        <td class="multi-year-cell"><input class="multi-field multi-year" value="${escapeHtml(row.year || "")}" autocomplete="off" maxlength="4"></td>
        ${seasonInput}
        <td class="multi-imdb-cell"><input class="multi-field multi-imdb" value="${escapeHtml(row.imdb_id || "")}" placeholder="tt..." autocomplete="off"></td>
        <td class="multi-status-cell">
          <span class="status-chip advisor-chip ${statusClass} multi-status" data-row-id="${escapeHtml(row.row_id)}">${escapeHtml(row.status_label || row.match_status || "Ready")}</span>
          <small class="multi-destination" data-row-id="${escapeHtml(row.row_id)}" title="${escapeHtml(destination)}">${escapeHtml(shortDestination(destination))}</small>
        </td>
      </tr>
    `;
  }).join("");

  manager.innerHTML = `
    <section class="multi-manager-card">
      <div class="multi-manager-head">
        <div>
          <h3>${escapeHtml(multi.title || "Multi-Item Import Manager")}</h3>
          <p>${escapeHtml(multi.recommendation || "Each detected item can be edited and imported independently.")}</p>
        </div>
        <span class="status-chip advisor-chip recommended">v3.6.0.1</span>
      </div>
      <div class="multi-table-wrap">
        <table class="multi-import-table ${tableClass}" id="multiImportTable">
          <thead>
            <tr>
              <th class="multi-check-cell">Import</th>
              <th class="multi-folder-cell">Folder</th>
              <th class="multi-title-cell">Title / Show</th>
              <th class="multi-year-cell">Year</th>
              ${seasonHeader}
              <th class="multi-imdb-cell">IMDb</th>
              <th class="multi-status-cell">Status</th>
            </tr>
          </thead>
          <tbody>${rows}</tbody>
        </table>
      </div>
      <p class="multi-help">Unchecked rows are skipped. Hover over a folder or destination to see the full path.</p>
    </section>
  `;

  updateMultiItemsHidden();
}

function collectMultiRows() {
  const tableRows = $$("#multiImportTable tbody tr");
  return tableRows.map(row => {
    const mediaType = row.dataset.mediaType || "movie";
    return {
      row_id: row.dataset.rowId || "",
      enabled: !!row.querySelector(".multi-enabled")?.checked,
      media_type: mediaType,
      source: row.dataset.source || "",
      source_key: row.dataset.sourceKey || row.dataset.source || "",
      detected: row.dataset.detected || "",
      title: row.querySelector(".multi-title")?.value || "",
      year: row.querySelector(".multi-year")?.value || "",
      imdb_id: row.querySelector(".multi-imdb")?.value || "",
      season: mediaType === "tv" ? (row.querySelector(".multi-season")?.value || "01") : "",
      tmdb_id: row.dataset.tmdbId || "",
      poster: row.dataset.poster || "",
      match_status: row.dataset.matchStatus || "",
      match_level: row.dataset.matchLevel || "",
      match_score: row.dataset.matchScore || "",
    };
  });
}

function updateMultiItemsHidden() {
  const hidden = $("#multiItems");
  if (!hidden) return;
  if (!multiImportState.enabled) {
    hidden.value = "";
    return;
  }
  hidden.value = JSON.stringify(collectMultiRows());
}

function scheduleMultiPreview() {
  if (!multiImportState.enabled) return;
  updateMultiItemsHidden();
  clearTimeout(multiPreviewTimer);
  multiPreviewTimer = setTimeout(previewMultiRows, 450);
}

function syncMultiComputed(multi) {
  if (!multi || !multi.enabled) return;

  multiImportState = {
    ...multiImportState,
    ...multi,
    items: asArray(multi.items),
  };

  for (const row of multiImportState.items) {
    const tr = document.querySelector(`#multiImportTable tbody tr[data-row-id="${CSS.escape(row.row_id)}"]`);
    if (!tr) continue;

    const destination = tr.querySelector(".multi-destination");
    if (destination) destination.textContent = shortDestination(row.destination || "");
      destination.title = row.destination || "";

    const fileCount = tr.querySelector(".multi-file-count");
    if (fileCount) {
      const count = Number(row.file_count || 0);
      fileCount.textContent = `${count} file${count === 1 ? "" : "s"}`;
    }

    const status = tr.querySelector(".multi-status");
    if (status) {
      status.textContent = row.status_label || row.match_status || "Ready";
      status.className = `status-chip advisor-chip ${multiStatusClass(row.status_level || row.match_level)} multi-status`;
    }
  }

  updateMultiItemsHidden();
}

async function previewMultiRows() {
  if (!multiImportState.enabled) return;
  const payload = {
    mode: multiImportState.mode || "custom",
    items: collectMultiRows(),
  };

  try {
    const data = await postJson("/api/multi-preview", payload);
    if (!data.ok) {
      setImportButton("Review Rows Before Import", true);
      setActionMessage(data.error || "Multi-row preview failed.", true);
      return;
    }

    renderMultiAdvisor(data);
    syncMultiComputed(data.multi_import || {});
    renderMultiFilePreview(data);
    renderDiagnostics(data);
    setActionMessage("");
  } catch (error) {
    setImportButton("Review Rows Before Import", true);
    setActionMessage(`Multi-row preview failed: ${error}`, true);
  }
}

function renderImportAdvisor(data) {
  const metadata = $("#metadata");
  if (!metadata) return;
  metadata.classList.remove("hidden");

  if (!data.ok) {
    resetMultiImportUI();
    setImportButton("Import Unavailable", true);
    metadata.innerHTML = `
      <div class="advisor-panel attention">
        <h3>Smart Import Advisor</h3>
        <p class="bad-text">${escapeHtml(data.error || "Preview failed")}</p>
      </div>
    `;
    return;
  }

  if (data.multi_import && data.multi_import.enabled) {
    renderMultiAdvisor(data);
    renderMultiImportManager(data.multi_import);
    return;
  }

  resetMultiImportUI();

  if (data.imported) {
    const importType = data.imported.import_type || "linked";
    const heading = importType === "manual" ? "Manually Marked Imported" : "Previously Hard Linked";
    const verb = importType === "manual" ? "Marked" : "Linked";

    setImportButton("Already Imported", true);
    setManualButtons(true);

    metadata.innerHTML = `
      <div class="advisor-panel imported">
        <div class="advisor-heading-row">
          <h3>${escapeHtml(heading)}</h3>
          <span class="status-chip advisor-chip imported">Imported</span>
        </div>
        <p>This item is already recorded in Media Linker import tracking.</p>
        <p><strong>Destination:</strong><br>${escapeHtml(data.imported.destination || "")}</p>
        <p><strong>${escapeHtml(verb)}:</strong> ${escapeHtml(data.imported.time || "")}</p>
        <p><strong>Import Type:</strong> ${escapeHtml(importType)}</p>
        <p><strong>Recommendation:</strong> No action needed.</p>
      </div>
    `;
    return;
  }

  setManualButtons(false);

  const advisor = data.advisor || {};
  const level = advisor.level || "recommended";
  const label = advisor.label || "Recommended";
  const importAllowed = advisor.import_allowed !== false;
  const actionButton = advisor.action_button || "Create Hard Links";
  setDuplicatePolicy(advisor.import_policy || "skip");

  setImportButton(actionButton, !importAllowed);

  const poster = data.metadata && data.metadata.poster
    ? `<img src="${escapeHtml(data.metadata.poster)}" alt="">`
    : "";

  const destination = advisor.destination || data.destination || "";
  const recommendation = advisor.recommendation || "Review the dry run preview before importing.";

  metadata.innerHTML = `
    ${poster}
    <div class="advisor-panel ${escapeHtml(level)}">
      <div class="advisor-heading-row">
        <h3>Smart Import Advisor</h3>
        <span class="status-chip advisor-chip ${escapeHtml(level)}">${escapeHtml(label)}</span>
      </div>
      <p class="advisor-headline">${escapeHtml(advisor.headline || "Import analysis ready")}</p>
      ${renderMiniFacts(advisor)}
      ${renderAdvisorFacts(advisor)}
      ${renderAdvisorWarnings(advisor)}
      <p><strong>Recommendation:</strong> ${escapeHtml(recommendation)}</p>
      <p><strong>Destination:</strong><br>${escapeHtml(destination)}</p>
    </div>
  `;
}

function renderMultiFilePreview(data) {
  const preview = $("#preview");
  if (!preview) return;

  const rows = (data.items || []).map(item => {
    const duplicate = item.exists || item.duplicate_episode || item.status === "duplicate";
    const statusHtml = duplicate
      ? '<span class="exists">Duplicate / Skip</span>'
      : '<span class="good-text">Ready</span>';

    const displayTitle = item.row_year
      ? `${item.row_title} (${item.row_year})`
      : item.row_title;

    return `
      <tr class="${duplicate ? "preview-duplicate" : "preview-ready"}">
        <td>${escapeHtml(displayTitle || item.row_id || "")}</td>
        <td>${escapeHtml(item.src)}</td>
        <td>${escapeHtml(item.dst || item.new_name)}</td>
        <td>${statusHtml}</td>
      </tr>
    `;
  }).join("");

  preview.innerHTML = `
    <div class="destination"><strong>Destination:</strong><br>Multiple destinations</div>
    <table class="preview-table">
      <thead><tr><th>Import row</th><th>Original</th><th>New destination</th><th>Status</th></tr></thead>
      <tbody>${rows || '<tr><td colspan="4">No selected files to preview.</td></tr>'}</tbody>
    </table>
  `;
}

function renderPreview(data) {
  const preview = $("#preview");
  if (!preview) return;

  if (!data.ok) {
    setImportButton("Import Unavailable", true);
    preview.innerHTML = `<div class="empty-preview bad-text">${escapeHtml(data.error || "Preview failed")}</div>`;
    return;
  }

  if (data.multi_import && data.multi_import.enabled) {
    renderMultiFilePreview(data);
    return;
  }

  const rows = (data.items || []).map(item => {
    const duplicate = item.exists || item.duplicate_episode || item.status === "duplicate";
    const statusHtml = duplicate
      ? '<span class="exists">Duplicate / Skip</span>'
      : '<span class="good-text">Ready</span>';

    return `
      <tr class="${duplicate ? "preview-duplicate" : "preview-ready"}">
        <td>${escapeHtml(item.src)}</td>
        <td>${escapeHtml(item.new_name || item.dst)}</td>
        <td>${statusHtml}</td>
      </tr>
    `;
  }).join("");

  preview.innerHTML = `
    <div class="destination"><strong>Destination:</strong><br>${escapeHtml(data.destination || "")}</div>
    <table class="preview-table">
      <thead><tr><th>Original</th><th>New filename</th><th>Status</th></tr></thead>
      <tbody>${rows}</tbody>
    </table>
  `;
}

function renderDiagnostics(data) {
  const diag = $("#diagnostics");
  if (!diag) return;
  diag.textContent = JSON.stringify(data.diagnostics || [], null, 2);
}

async function previewSelected() {
  const payload = selectedPayload();
  if (!payload.source) return;

  try {
    const response = await fetch("/api/preview", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload)
    });

    const data = await response.json();
    renderImportAdvisor(data);
    renderPreview(data);
    renderDiagnostics(data);
  } catch (error) {
    setImportButton("Import Unavailable", true);
    setActionMessage(`Preview failed: ${error}`, true);
  }
}

async function postJson(url, payload) {
  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload)
  });
  return await response.json();
}

async function markSelectedImported() {
  const payload = selectedPayload();
  if (!payload.source) {
    setActionMessage("Select a queue item first.", true);
    return;
  }
  const btn = $("#markImportedBtn");
  if (btn) { btn.disabled = true; btn.textContent = "Marking..."; }

  const data = await postJson("/api/imports/mark", payload);
  if (!data.ok) {
    setActionMessage(data.error || "Could not mark this item imported.", true);
    if (btn) { btn.disabled = false; btn.textContent = "Mark Imported"; }
    return;
  }
  window.location.reload();
}

async function unmarkSelectedImported() {
  const payload = selectedPayload();
  if (!payload.source) {
    setActionMessage("Select a queue item first.", true);
    return;
  }
  const btn = $("#unmarkImportedBtn");
  if (btn) { btn.disabled = true; btn.textContent = "Unmarking..."; }

  const data = await postJson("/api/imports/unmark", payload);
  if (!data.ok) {
    setActionMessage(data.error || "Could not unmark this item.", true);
    if (btn) { btn.disabled = false; btn.textContent = "Unmark Imported"; }
    return;
  }
  window.location.reload();
}

function selectedQueueItems() {
  return $$(".queue-select:checked").map(box => ({
    source: box.dataset.source || "",
    source_key: box.dataset.sourceKey || box.dataset.source || "",
    media_type: box.dataset.type || "tv",
    title: box.dataset.title || "",
    year: box.dataset.year || "",
    imdb_id: "",
    season: box.dataset.season || "01",
  }));
}

function matchesQueueFilter(card, filter) {
  const imported = card.dataset.imported === "true";
  const level = card.dataset.advisorLevel || (imported ? "imported" : "recommended");

  if (filter === "all") return true;
  if (filter === "ready") return !imported;
  if (filter === "imported") return imported || level === "imported";
  if (filter === "recommended") return !imported && level === "recommended";
  if (filter === "attention") return !imported && level === "attention";
  if (filter === "duplicate") return !imported && level === "duplicate";
  return true;
}

function cardShouldShow(card) {
  const filterOk = matchesQueueFilter(card, activeQueueFilter);
  const term = ($("#queueSearch")?.value || "").trim().toLowerCase();
  const searchOk = !term || card.textContent.toLowerCase().includes(term);
  return filterOk && searchOk;
}

function setQueueFilter(filter) {
  activeQueueFilter = filter;
  $$(".queue-tab").forEach(tab => {
    tab.classList.toggle("active", (tab.dataset.filter || "") === filter);
  });
  applyQueueFilters();
}

function chooseInitialQueueFilter() {
  const cards = $$(".torrent-card");
  const filters = ["recommended", "attention", "duplicate", "imported", "all"];
  const firstFilterWithItems = filters.find(filter => cards.some(card => matchesQueueFilter(card, filter))) || "all";
  setQueueFilter(firstFilterWithItems);
}

function applyQueueFilters() {
  const cards = $$(".torrent-card");
  let visibleCount = 0;

  cards.forEach(card => {
    const show = cardShouldShow(card);
    card.hidden = !show;
    if (show) {
      card.style.removeProperty("display");
    } else {
      card.style.setProperty("display", "none", "important");
    }
    card.classList.toggle("hidden", !show);
    if (!show) {
      const box = card.querySelector(".queue-select");
      if (box) box.checked = false;
    } else {
      visibleCount += 1;
    }
  });

  const empty = $("#queueEmpty");
  if (empty) empty.classList.toggle("hidden", visibleCount !== 0);
  updateBulkControls();
}

function visibleQueueCheckboxes() {
  return $$(".torrent-card")
    .filter(card => cardShouldShow(card) && card.dataset.imported !== "true")
    .map(card => card.querySelector(".queue-select"))
    .filter(Boolean);
}

function updateBulkControls() {
  const selected = selectedQueueItems();
  const count = selected.length;
  const countEl = $("#selectedCount");
  const bulkBtn = $("#bulkMarkImportedBtn");
  const clearBtn = $("#clearSelectionBtn");
  const selectAll = $("#selectAllReady");
  const visible = visibleQueueCheckboxes();
  const checkedVisible = visible.filter(box => box.checked);

  if (countEl) countEl.textContent = `${count} selected`;
  if (bulkBtn) bulkBtn.disabled = count === 0;
  if (clearBtn) clearBtn.disabled = count === 0;

  if (selectAll) {
    selectAll.checked = visible.length > 0 && checkedVisible.length === visible.length;
    selectAll.indeterminate = checkedVisible.length > 0 && checkedVisible.length < visible.length;
    selectAll.disabled = visible.length === 0;
  }

  $$(".torrent-card").forEach(card => {
    const box = card.querySelector(".queue-select");
    card.classList.toggle("selected", !!box && box.checked);
  });
}

function clearQueueSelection() {
  $$(".queue-select").forEach(box => { box.checked = false; });
  updateBulkControls();
}

async function bulkMarkSelectedImported() {
  const items = selectedQueueItems();
  if (!items.length) {
    setActionMessage("Select one or more visible items first.", true);
    return;
  }
  const btn = $("#bulkMarkImportedBtn");
  if (btn) { btn.disabled = true; btn.textContent = "Marking..."; }

  const data = await postJson("/api/imports/mark-bulk", { items });
  if (!data.ok) {
    setActionMessage(data.error || "Could not mark selected items imported.", true);
    if (btn) { btn.disabled = false; btn.textContent = "Mark Selected Imported"; }
    updateBulkControls();
    return;
  }
  window.location.reload();
}

function applyHistoryFilter() {
  $$(".history-item").forEach(item => {
    const show = activeHistoryFilter === "all" || (item.dataset.historyType || "success") === activeHistoryFilter;
    item.hidden = !show;
    item.style.display = show ? "" : "none";
    item.classList.toggle("hidden", !show);
  });
}

document.addEventListener("DOMContentLoaded", () => {
  $$(".folder").forEach(card => {
    card.addEventListener("click", event => {
      if (event.target && event.target.classList && event.target.classList.contains("queue-select")) {
        event.stopPropagation();
        updateBulkControls();
        return;
      }
      fillFromCard(card);
    });
  });

  $$(".queue-select").forEach(box => {
    box.addEventListener("click", event => event.stopPropagation());
    box.addEventListener("change", updateBulkControls);
  });

  $$(".queue-tab").forEach(tab => {
    tab.addEventListener("click", event => {
      event.preventDefault();
      setQueueFilter(tab.dataset.filter || "recommended");
    });
  });

  const search = $("#queueSearch");
  if (search) search.addEventListener("input", applyQueueFilters);

  const selectAllReady = $("#selectAllReady");
  if (selectAllReady) {
    selectAllReady.addEventListener("change", () => {
      visibleQueueCheckboxes().forEach(box => { box.checked = selectAllReady.checked; });
      updateBulkControls();
    });
  }

  const clearSelectionBtn = $("#clearSelectionBtn");
  if (clearSelectionBtn) clearSelectionBtn.addEventListener("click", clearQueueSelection);

  const bulkMarkBtn = $("#bulkMarkImportedBtn");
  if (bulkMarkBtn) bulkMarkBtn.addEventListener("click", bulkMarkSelectedImported);

  $$(('input[name="media_type"]')).forEach(radio => {
    radio.addEventListener("change", () => {
      updateSeasonVisibility();
      schedulePreview();
    });
  });

  ["#title", "#year", "#season", "#imdb_id"].forEach(selector => {
    const el = $(selector);
    if (el) el.addEventListener("input", schedulePreview);
  });

  const manager = $("#multiImportManager");
  if (manager) {
    manager.addEventListener("input", event => {
      if (event.target && event.target.classList && event.target.classList.contains("multi-field")) {
        scheduleMultiPreview();
      }
    });
    manager.addEventListener("change", event => {
      if (event.target && event.target.classList && (event.target.classList.contains("multi-field") || event.target.classList.contains("multi-enabled"))) {
        scheduleMultiPreview();
      }
    });
  }

  const previewBtn = $("#previewBtn");
  if (previewBtn) previewBtn.style.display = "none";

  const markBtn = $("#markImportedBtn");
  if (markBtn) markBtn.addEventListener("click", markSelectedImported);

  const unmarkBtn = $("#unmarkImportedBtn");
  if (unmarkBtn) unmarkBtn.addEventListener("click", unmarkSelectedImported);

  $$(".history-tab").forEach(tab => {
    tab.addEventListener("click", event => {
      event.preventDefault();
      $$(".history-tab").forEach(t => t.classList.remove("active"));
      tab.classList.add("active");
      activeHistoryFilter = tab.dataset.historyFilter || "success";
      applyHistoryFilter();
    });
  });

  chooseInitialQueueFilter();
  applyHistoryFilter();

  const first =
    document.querySelector('.torrent-card[data-imported="false"][data-advisor-level="recommended"]') ||
    document.querySelector('.torrent-card[data-imported="false"][data-advisor-level="attention"]') ||
    document.querySelector('.torrent-card[data-imported="false"][data-advisor-level="duplicate"]') ||
    document.querySelector(".torrent-card") ||
    document.querySelector(".folder");
  if (first) fillFromCard(first);

  updateSeasonVisibility();
});
'@

Write-Utf8File -RelativePath "app\static\style.css" -Content @'
* { box-sizing: border-box; }
body {
  margin: 0;
  background: radial-gradient(circle at top left, #172033, #0f1117 38%);
  color: #f5f7fb;
  font-family: system-ui, -apple-system, Segoe UI, Roboto, Arial, sans-serif;
}
.shell { max-width: 1540px; margin: 0 auto; padding: 34px 22px; }
.shell.narrow { max-width: 900px; }
.hero { display: flex; justify-content: space-between; gap: 18px; align-items: flex-start; margin-bottom: 22px; }
h1 { margin: 0 0 8px; font-size: 42px; letter-spacing: -1px; }
h2 { margin-top: 0; }
h3 { margin-top: 22px; }
p { color: #b8bfcc; }
.section-subtitle { margin: -6px 0 0; font-size: 13px; }
.hero-actions { display: flex; gap: 8px; flex-wrap: wrap; justify-content: flex-end; }
.badge, .pill, .navlink {
  background: #1f6feb;
  padding: 8px 12px;
  border-radius: 999px;
  font-weight: 800;
  color: white;
  text-decoration: none;
}
.pill { background: #2a2f3b; color: #c8cfdb; }
.pill.good { background: #12351e; color: #85f0a3; border: 1px solid #2dbd6e; }
.navlink { background: #2a2f3b; }
.layout { display: grid; grid-template-columns: 0.95fr 1.25fr 0.8fr; gap: 18px; }
.card {
  background: rgba(25, 28, 36, 0.96);
  border: 1px solid #313644;
  border-radius: 18px;
  padding: 20px;
  min-width: 0;
  box-shadow: 0 18px 50px rgba(0,0,0,.24);
}
.card-head { display: flex; justify-content: space-between; align-items: flex-start; gap: 12px; }
.card-head span { color: #aeb6c5; font-weight: 800; white-space: nowrap; }
.search { margin: 0 0 12px; }
.queue-tabs {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 8px;
  margin: 14px 0 12px;
}
.queue-tab {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 6px;
  padding: 9px 10px;
  border: 1px solid #343a49;
  background: #10141d;
  color: #cfd6e3;
  border-radius: 12px;
  font-weight: 900;
  cursor: pointer;
}
.queue-tab span {
  background: #242a37;
  color: #aeb6c5;
  border-radius: 999px;
  padding: 2px 7px;
  font-size: 12px;
}
.queue-tab.active {
  border-color: #2dbd6e;
  background: #12351e;
  color: #85f0a3;
}
.queue-tab.active span {
  background: #0d2514;
  color: #85f0a3;
}
.queue-empty {
  margin-top: 12px;
  padding: 14px;
  border: 1px dashed #3d4351;
  border-radius: 12px;
  color: #aeb6c5;
  text-align: center;
}
.folder-list { display: grid; gap: 12px; max-height: 68vh; overflow: auto; padding-right: 4px; }
.folder {
  text-align: left;
  padding: 0;
  border: 1px solid #343a49;
  background: #11141b;
  color: #f5f7fb;
  border-radius: 16px;
  cursor: pointer;
  overflow: hidden;
}
.folder:hover, .folder.active {
  border-color: #2dbd6e;
  background: linear-gradient(135deg, #142018, #11141b 72%);
}
.folder.imported { opacity: .62; }
.torrent-card { display: block; padding: 15px; position: relative; }
.torrent-card::before {
  content: "";
  position: absolute;
  inset: 0 auto 0 0;
  width: 4px;
  background: #2dbd6e;
  opacity: .9;
}
.torrent-card.imported::before { background: #6e8cff; }
.torrent-topline {
  display: grid;
  grid-template-columns: 34px minmax(0, 1fr) 44px;
  gap: 10px;
  align-items: start;
  margin-bottom: 8px;
}
.torrent-icon {
  width: 30px;
  height: 30px;
  display: grid;
  place-items: center;
  border-radius: 10px;
  background: #202634;
  font-size: 16px;
  line-height: 1;
}
.torrent-heading {
  display: flex;
  align-items: flex-start;
  justify-content: flex-start;
  gap: 8px;
  min-width: 0;
  padding-right: 0;
}
.folder-title {
  display: block;
  font-weight: 950;
  line-height: 1.18;
  overflow-wrap: anywhere;
  min-width: 0;
}
.year-pill {
  flex: 0 0 auto;
  background: #0c1119;
  border: 1px solid #2b303d;
  border-radius: 999px;
  color: #aeb6c5;
  font-size: 11px;
  font-weight: 900;
  padding: 3px 7px;
}
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
.torrent-status-row {
  display: flex;
  gap: 7px;
  flex-wrap: wrap;
  align-items: center;
  margin-left: 44px;
  margin-right: 44px;
  margin-bottom: 10px;
}
.mini-pill {
  background: #151a24;
  border: 1px solid #2b303d;
  border-radius: 999px;
  color: #b7c0d1;
  font-size: 11px;
  font-weight: 850;
  padding: 4px 8px;
}
.metric-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 8px;
  margin-left: 44px;
  margin-right: 44px;
}
.metric {
  background: #0c1119;
  border: 1px solid #2b303d;
  border-radius: 11px;
  padding: 8px;
  min-width: 0;
}
.metric.wide { grid-column: 1 / -1; }
.metric-label {
  display: block;
  color: #778399;
  font-size: 10px;
  font-weight: 900;
  text-transform: uppercase;
  letter-spacing: .04em;
  margin-bottom: 3px;
}
.metric-value {
  display: block;
  color: #dce6f7;
  font-size: 12px;
  font-weight: 950;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.status-chip {
  border-radius: 999px;
  padding: 4px 9px;
  font-size: 11px;
  font-weight: 950;
  border: 1px solid transparent;
  text-transform: uppercase;
  letter-spacing: .02em;
}
.status-chip.ready { background: #12351e; color: #85f0a3; border-color: #2dbd6e; }
.status-chip.imported { background: #1b2b4a; color: #9db3ff; border-color: #375dae; }
.folder-meta { display: block; color: #aeb6c5; font-size: 13px; }
label { display: block; margin-top: 14px; margin-bottom: 7px; font-weight: 750; }
input {
  width: 100%;
  padding: 12px;
  border-radius: 11px;
  border: 1px solid #3d4351;
  background: #0f1218;
  color: white;
  font-size: 15px;
}
.grid { display: grid; grid-template-columns: 1fr 1fr; gap: 14px; }
.segmented { display: flex; gap: 10px; }
.segmented label { flex: 1; margin: 0; cursor: pointer; }
.segmented input { display: none; }
.segmented span { display: block; text-align: center; padding: 12px; border: 1px solid #3d4351; border-radius: 11px; background: #0f1218; font-weight: 850; }
.segmented input:checked + span { border-color: #2dbd6e; background: #15351f; }
.checkline { display: flex; align-items: center; gap: 10px; color: #cfd6e3; }
.checkline input { width: auto; }
.actions { display: flex; gap: 10px; margin-top: 18px; }
button { padding: 12px 16px; border: 0; border-radius: 11px; background: #2dbd6e; color: white; font-weight: 850; cursor: pointer; }
button.secondary { background: #1f6feb; }
.preview-box { min-height: 260px; background: #0b0d12; border: 1px solid #303644; border-radius: 13px; padding: 0; overflow: auto; }
.empty-preview { padding: 14px; color: #aeb6c5; }
.preview-table { width: 100%; border-collapse: collapse; font-size: 13px; }
.preview-table th, .preview-table td { text-align: left; vertical-align: top; border-bottom: 1px solid #262b36; padding: 10px; }
.preview-table th { color: #9db3d9; background: #111620; position: sticky; top: 0; }
.preview-table td { overflow-wrap: anywhere; }
.destination { padding: 12px 14px; border-bottom: 1px solid #303644; color: #cfd6e3; }
.exists { color: #ffcc66; font-weight: 900; }
.warning { color: #ffcc66; font-weight: 800; }
.metadata, .imported-box { display: flex; gap: 14px; margin: 18px 0; padding: 14px; border: 1px solid #313644; border-radius: 14px; background: #11141b; }
.imported-box { display:block; border-color:#ffcc66; }
.metadata img { width: 92px; border-radius: 8px; object-fit: cover; }
.metadata h3 { margin: 0 0 6px; }
.metadata p { margin: 0 0 8px; }
.hidden { display: none !important; }
.history { display: grid; gap: 10px; max-height: 72vh; overflow: auto; }
.history-item { padding: 12px; background: #11141b; border: 1px solid #343a49; border-radius: 12px; }
.history-item strong, .history-item span, .history-item small { display: block; }
.history-item span { color: #aeb6c5; font-size: 12px; margin-top: 3px; }
.history-item small { color: #b8bfcc; margin-top: 5px; overflow-wrap: anywhere; }
.history-item.bad, .alert.error { border-color: #d85050; }
.alert { padding: 13px 16px; border-radius: 12px; margin-bottom: 14px; background:#11141b; border:1px solid #343a49; }
.diag-box { white-space: pre-wrap; background:#0b0d12; border:1px solid #303644; border-radius:13px; padding:15px; overflow:auto; max-height:420px; }
.good-text { color:#85f0a3; font-weight:800; }
.bad-text { color:#ff7373; font-weight:800; }
@media (max-width: 1150px) { .layout { grid-template-columns: 1fr; } }

.history-tabs {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 8px;
  margin: 12px 0;
}

.history-tab {
  padding: 9px 10px;
  border: 1px solid #343a49;
  background: #10141d;
  color: #cfd6e3;
  border-radius: 12px;
  font-weight: 900;
  cursor: pointer;
}

.history-tab.active {
  border-color: #2dbd6e;
  background: #12351e;
  color: #85f0a3;
}

.history-item.success {
  border-color: #2dbd6e;
}


.history-tabs {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 8px;
  margin: 12px 0;
}

.history-tab {
  padding: 9px 10px;
  border: 1px solid #343a49;
  background: #10141d;
  color: #cfd6e3;
  border-radius: 12px;
  font-weight: 900;
  cursor: pointer;
}

.history-tab.active {
  border-color: #2dbd6e;
  background: #12351e;
  color: #85f0a3;
}

.history-item.success {
  border-color: #2dbd6e;
}


button.disabled,
button:disabled {
  opacity: 0.55;
  cursor: not-allowed;
}

.bulk-toolbar {
  display: grid;
  grid-template-columns: auto 1fr auto auto;
  gap: 8px;
  align-items: center;
  margin: 0 0 12px;
  padding: 10px;
  border: 1px solid #343a49;
  background: #0f131c;
  border-radius: 13px;
}
.bulk-select-all {
  display: flex;
  align-items: center;
  gap: 8px;
  margin: 0;
  color: #cfd6e3;
  font-size: 12px;
  font-weight: 900;
  white-space: nowrap;
}
.bulk-select-all input { width: auto; }
.selected-count {
  color: #aeb6c5;
  font-size: 12px;
  font-weight: 850;
}
button.small {
  padding: 8px 10px;
  border-radius: 9px;
  font-size: 12px;
}
button.ghost {
  background: #2a2f3b;
  color: #c8cfdb;
}
.select-box-wrap {
  position: absolute;
  top: 12px;
  right: 12px;
  z-index: 3;
  width: 24px;
  height: 24px;
  display: grid;
  place-items: center;
  background: #0c1119;
  border: 1px solid #343a49;
  border-radius: 8px;
}
.queue-select {
  width: 16px;
  height: 16px;
  margin: 0;
  cursor: pointer;
}
.torrent-card.selected {
  border-color: #6e8cff;
  background: linear-gradient(135deg, #171f3a, #11141b 72%);
}
.torrent-card.selected::before { background: #6e8cff; }
.torrent-card.imported .select-box-wrap {
  opacity: .35;
  pointer-events: none;
}
@media (max-width: 720px) {
  .bulk-toolbar { grid-template-columns: 1fr; }
}




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

/* v3.4.6 queue/history filtering and counters */
.hidden { display: none !important; }
.history-tab {
  display: flex !important;
  justify-content: space-between !important;
  align-items: center !important;
  gap: 8px !important;
}
.history-tab span {
  background: #242a37;
  color: #aeb6c5;
  border-radius: 999px;
  padding: 2px 7px;
  font-size: 12px;
  font-weight: 900;
}
.history-tab.active span {
  background: #0d2514;
  color: #85f0a3;
}
.history-item strong {
  overflow-wrap: anywhere;
}
/* end v3.4.6 queue/history filtering and counters */

/* v3.4.7.1 force queue tab visibility */
.queue-tabs:has(.queue-tab[data-filter="ready"].active) ~ .folder-list .torrent-card[data-imported="true"] {
  display: none !important;
}

.queue-tabs:has(.queue-tab[data-filter="imported"].active) ~ .folder-list .torrent-card[data-imported="false"] {
  display: none !important;
}
/* end v3.4.7.1 */

/* v3.4.7.2 queue filters are controlled by app/static/app.js */




/* v3.5.0 Smart Import Advisor */
.advisor {
  display: block !important;
  border-left: 5px solid #2dbd6e;
}

.advisor-green {
  border-color: #2dbd6e !important;
  background: linear-gradient(135deg, #102318, #11141b 72%) !important;
}

.advisor-yellow {
  border-color: #ffcc66 !important;
  background: linear-gradient(135deg, #2a2212, #11141b 72%) !important;
}

.advisor-red {
  border-color: #ff7373 !important;
  background: linear-gradient(135deg, #2a1414, #11141b 72%) !important;
}

.advisor-blue {
  border-color: #6e8cff !important;
  background: linear-gradient(135deg, #171f3a, #11141b 72%) !important;
}

.advisor-kicker {
  display: inline-block;
  margin: 0 0 8px;
  padding: 4px 9px;
  border-radius: 999px;
  background: #0c1119;
  border: 1px solid #343a49;
  color: #cfd6e3;
  font-size: 11px;
  font-weight: 950;
  text-transform: uppercase;
  letter-spacing: .04em;
}

.advisor-details {
  margin: 10px 0 12px;
  padding-left: 22px;
  color: #cfd6e3;
}

.advisor-details li {
  margin: 4px 0;
  color: #cfd6e3;
}
/* end v3.5.0 */

/* v3.5.0 Smart Import Advisor */
.smart-queue-tabs {
  grid-template-columns: repeat(5, minmax(0, 1fr)) !important;
}
.advisor-tab {
  font-size: 12px;
  padding: 9px 8px;
}
.torrent-card.advisor-recommended::before { background: #2dbd6e !important; }
.torrent-card.advisor-attention::before { background: #ffcc66 !important; }
.torrent-card.advisor-duplicate::before { background: #d85050 !important; }
.torrent-card.advisor-imported::before { background: #6e8cff !important; }

.status-chip.advisor-chip.recommended {
  background: #12351e;
  color: #85f0a3;
  border-color: #2dbd6e;
}
.status-chip.advisor-chip.attention {
  background: #3a2c0b;
  color: #ffdd88;
  border-color: #ffcc66;
}
.status-chip.advisor-chip.duplicate {
  background: #3a1010;
  color: #ff9b9b;
  border-color: #d85050;
}
.status-chip.advisor-chip.imported {
  background: #1b2b4a;
  color: #9db3ff;
  border-color: #375dae;
}
.advisor-reason {
  max-width: 100%;
  white-space: normal !important;
  overflow-wrap: anywhere;
}
.advisor-panel {
  width: 100%;
}
.advisor-panel h3 {
  margin: 0;
}
.advisor-heading-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  margin-bottom: 8px;
}
.advisor-headline {
  color: #f5f7fb;
  font-size: 17px;
  font-weight: 900;
  margin: 0 0 10px !important;
}
.advisor-chip-row {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 8px;
  margin: 12px 0;
}
.advisor-mini-chip {
  display: block;
  background: #0c1119;
  border: 1px solid #2b303d;
  border-radius: 11px;
  padding: 9px;
  color: #dce6f7;
  font-weight: 850;
}
.advisor-mini-chip strong {
  display: block;
  color: #778399;
  font-size: 10px;
  font-weight: 950;
  text-transform: uppercase;
  letter-spacing: .04em;
  margin-bottom: 3px;
}
.advisor-facts,
.advisor-warnings {
  margin: 10px 0;
  padding: 10px;
  border-radius: 12px;
  background: #0c1119;
  border: 1px solid #2b303d;
}
.advisor-facts p,
.advisor-warnings p {
  margin: 0 0 6px !important;
}
.advisor-facts p:last-child,
.advisor-warnings p:last-child {
  margin-bottom: 0 !important;
}
.advisor-warnings {
  border-color: #ffcc66;
}
.preview-table tr.preview-duplicate td {
  background: rgba(216, 80, 80, 0.08);
}
.preview-table tr.preview-ready td {
  background: rgba(45, 189, 110, 0.05);
}
button.danger {
  background: #8b2f2f;
}
@media (max-width: 720px) {
  .smart-queue-tabs {
    grid-template-columns: 1fr 1fr !important;
  }
  .advisor-chip-row {
    grid-template-columns: 1fr;
  }
}
/* end v3.5.0 Smart Import Advisor */

/* v3.5.0.1 queue filter button polish */
.queue-tabs.smart-queue-tabs {
  display: grid !important;
  grid-template-columns: repeat(2, minmax(0, 1fr)) !important;
  gap: 9px !important;
  margin: 14px 0 12px !important;
}

.smart-queue-tabs .advisor-tab {
  min-width: 0 !important;
  width: 100% !important;
  display: flex !important;
  align-items: center !important;
  justify-content: space-between !important;
  gap: 8px !important;
  padding: 10px 11px !important;
  border-radius: 13px !important;
  font-size: 13px !important;
  line-height: 1.15 !important;
  letter-spacing: 0 !important;
  white-space: nowrap !important;
  overflow: hidden !important;
  text-overflow: ellipsis !important;
}

.smart-queue-tabs .advisor-tab.all {
  grid-column: 1 / -1 !important;
}

.smart-queue-tabs .advisor-tab span {
  flex: 0 0 auto !important;
  display: inline-flex !important;
  align-items: center !important;
  justify-content: center !important;
  min-width: 26px !important;
  padding: 2px 7px !important;
  margin-left: 4px !important;
  border-radius: 999px !important;
  font-size: 11px !important;
  font-weight: 950 !important;
  background: #242a37 !important;
  color: #cfd6e3 !important;
}

.smart-queue-tabs .advisor-tab.recommended.active {
  border-color: #2dbd6e !important;
  background: #12351e !important;
  color: #85f0a3 !important;
}
.smart-queue-tabs .advisor-tab.recommended.active span {
  background: #0d2514 !important;
  color: #85f0a3 !important;
}

.smart-queue-tabs .advisor-tab.attention.active {
  border-color: #ffcc66 !important;
  background: #3a2c0b !important;
  color: #ffdd88 !important;
}
.smart-queue-tabs .advisor-tab.attention.active span {
  background: #211906 !important;
  color: #ffdd88 !important;
}

.smart-queue-tabs .advisor-tab.duplicate.active {
  border-color: #d85050 !important;
  background: #3a1010 !important;
  color: #ff9b9b !important;
}
.smart-queue-tabs .advisor-tab.duplicate.active span {
  background: #230909 !important;
  color: #ff9b9b !important;
}

.smart-queue-tabs .advisor-tab.imported.active {
  border-color: #375dae !important;
  background: #1b2b4a !important;
  color: #9db3ff !important;
}
.smart-queue-tabs .advisor-tab.imported.active span {
  background: #111d35 !important;
  color: #9db3ff !important;
}

.smart-queue-tabs .advisor-tab.all.active {
  border-color: #6e8cff !important;
  background: #1f2740 !important;
  color: #cbd6ff !important;
}
.smart-queue-tabs .advisor-tab.all.active span {
  background: #151b2e !important;
  color: #cbd6ff !important;
}

@media (max-width: 720px) {
  .queue-tabs.smart-queue-tabs {
    grid-template-columns: 1fr !important;
  }
  .smart-queue-tabs .advisor-tab.all {
    grid-column: 1 !important;
  }
}
/* end v3.5.0.1 queue filter button polish */

/* v3.5.0.2 queue filter visibility fix */
#queueList .folder.torrent-card.hidden,
#queueList .torrent-card.folder.hidden,
#queueList .folder.torrent-card[hidden],
#queueList .torrent-card.folder[hidden],
.folder-list .folder.torrent-card.hidden,
.folder-list .torrent-card.folder.hidden,
.folder-list .folder.torrent-card[hidden],
.folder-list .torrent-card.folder[hidden] {
  display: none !important;
}
/* end v3.5.0.2 queue filter visibility fix */

/* v3.6.0.1 Multi-Item Import Manager compact layout */
@media (min-width: 1151px) {
  .layout {
    grid-template-columns: 0.78fr 1.62fr 0.72fr;
  }
}
.multi-import-manager {
  margin: 16px 0 10px;
}
.multi-manager-card {
  border: 1px solid #343a49;
  background: #10141d;
  border-radius: 16px;
  padding: 14px;
}
.multi-manager-head {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  gap: 12px;
  margin-bottom: 12px;
}
.multi-manager-head h3 {
  margin: 0 0 5px;
}
.multi-manager-head p,
.multi-help {
  margin: 0;
  color: #aeb6c5;
  font-size: 13px;
}
.multi-help {
  margin-top: 10px;
}
.multi-table-wrap {
  overflow: visible;
  border: 1px solid #2b303d;
  border-radius: 13px;
  background: #0b0d12;
}
.multi-import-table {
  width: 100%;
  min-width: 0;
  table-layout: fixed;
  border-collapse: collapse;
  font-size: 12px;
}
.multi-import-table th,
.multi-import-table td {
  text-align: left;
  vertical-align: top;
  border-bottom: 1px solid #262b36;
  padding: 9px 8px;
  min-width: 0;
}
.multi-import-table th {
  color: #9db3d9;
  background: #111620;
  position: sticky;
  top: 0;
  z-index: 2;
}
.multi-import-table tr:last-child td {
  border-bottom: 0;
}
.multi-check-cell {
  width: 48px;
  text-align: center !important;
}
.multi-folder-cell {
  width: 21%;
}
.multi-title-cell {
  width: auto;
}
.multi-year-cell {
  width: 70px;
}
.multi-season-cell {
  width: 70px;
}
.multi-imdb-cell {
  width: 116px;
}
.multi-status-cell {
  width: 128px;
}
.multi-import-table.movie-only .multi-folder-cell {
  width: 23%;
}
.multi-import-table.movie-only .multi-title-cell {
  width: auto;
}
.multi-import-table.movie-only .multi-imdb-cell {
  width: 118px;
}
.multi-import-table.movie-only .multi-status-cell {
  width: 130px;
}
.multi-folder-name {
  display: block;
  color: #f5f7fb;
  font-size: 13px;
  line-height: 1.2;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.multi-folder-meta,
.multi-import-table small {
  display: block;
  margin-top: 4px;
  color: #7f8aa0;
  line-height: 1.25;
  min-width: 0;
}
.multi-file-count {
  display: inline-block;
  margin-right: 7px;
  white-space: nowrap;
}
.multi-source-hint {
  display: block;
  max-width: 100%;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.multi-import-table input {
  width: 100%;
  min-width: 0;
  padding: 8px;
  border-radius: 9px;
  font-size: 13px;
}
.multi-import-table .multi-year,
.multi-import-table .multi-season {
  text-align: center;
}
.multi-enabled {
  width: 17px !important;
  min-width: 17px !important;
  height: 17px;
  padding: 0 !important;
  margin: 3px auto 0 !important;
  accent-color: #2dbd6e;
}
.multi-status {
  display: inline-flex;
  max-width: 100%;
  white-space: nowrap;
}
.multi-destination {
  display: block;
  margin-top: 6px !important;
  max-width: 100%;
  color: #8d98ad;
  font-size: 11px;
  font-weight: 750;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.muted-dash {
  display: inline-block;
  color: #778399;
  padding: 9px 0;
}
.status-chip.advisor-chip.error {
  background: #3a1010;
  color: #ff9b9b;
  border-color: #d85050;
}
.status-chip.advisor-chip.skipped {
  background: #242a37;
  color: #aeb6c5;
  border-color: #343a49;
}
@media (max-width: 1250px) {
  .multi-manager-card {
    padding: 12px;
  }
  .multi-import-table thead {
    display: none;
  }
  .multi-import-table,
  .multi-import-table tbody,
  .multi-import-table tr,
  .multi-import-table td {
    display: block;
    width: 100% !important;
  }
  .multi-import-table tr {
    display: grid;
    grid-template-columns: 34px minmax(0, 1fr);
    gap: 8px 10px;
    padding: 12px;
    border-bottom: 1px solid #262b36;
  }
  .multi-import-table tr:last-child {
    border-bottom: 0;
  }
  .multi-import-table td {
    border-bottom: 0;
    padding: 0;
  }
  .multi-check-cell {
    grid-column: 1;
    grid-row: 1 / span 4;
    padding-top: 2px !important;
  }
  .multi-folder-cell,
  .multi-title-cell,
  .multi-year-cell,
  .multi-season-cell,
  .multi-imdb-cell,
  .multi-status-cell {
    grid-column: 2;
  }
  .multi-title-cell::before,
  .multi-year-cell::before,
  .multi-season-cell::before,
  .multi-imdb-cell::before,
  .multi-status-cell::before {
    display: block;
    margin: 2px 0 4px;
    color: #778399;
    font-size: 10px;
    font-weight: 950;
    text-transform: uppercase;
    letter-spacing: .04em;
  }
  .multi-title-cell::before { content: "Title / Show"; }
  .multi-year-cell::before { content: "Year"; }
  .multi-season-cell::before { content: "Season"; }
  .multi-imdb-cell::before { content: "IMDb"; }
  .multi-status-cell::before { content: "Status"; }
  .multi-folder-name {
    white-space: normal;
    overflow-wrap: anywhere;
  }
  .multi-source-hint,
  .multi-destination {
    white-space: normal;
    overflow-wrap: anywhere;
  }
}
@media (max-width: 720px) {
  .multi-manager-head {
    display: block;
  }
}
/* end v3.6.0.1 Multi-Item Import Manager compact layout */
'@

Write-Step "Cleaning local Python cache files"

Get-ChildItem "$ProjectRoot\app" -Recurse -Directory -Filter "__pycache__" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem "$ProjectRoot\app" -Recurse -File -Filter "*.pyc" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

Write-Good "Python cache files cleaned"

if ($SkipDeploy) {
    Write-Good "Patch applied locally. Deployment skipped because -SkipDeploy was used."
    exit 0
}

Write-Step "Checking SSH connection to $NasUser@$NasHost"

ssh "$NasUser@$NasHost" "echo SSH_OK" | Out-Null
if ($LASTEXITCODE -ne 0) {
    Fail "SSH connection failed."
}
Write-Good "SSH connection OK"

Write-Step "Preparing remote project folder"

ssh "$NasUser@$NasHost" "mkdir -p '$RemoteProjectPath' '$RemoteProjectPath/backups'"
if ($LASTEXITCODE -ne 0) {
    Fail "Could not create remote project folder."
}

Write-Step "Creating remote backup"

$RemoteBackupPath = "$RemoteProjectPath/backups/v3.6.0.1-compact-multi-ui-$Stamp"
ssh "$NasUser@$NasHost" "mkdir -p '$RemoteBackupPath'; if [ -d '$RemoteProjectPath/app' ]; then cp -a '$RemoteProjectPath/app' '$RemoteBackupPath/app'; fi; if [ -f '$RemoteProjectPath/Dockerfile' ]; then cp -a '$RemoteProjectPath/Dockerfile' '$RemoteBackupPath/Dockerfile'; fi; if [ -f '$RemoteProjectPath/requirements.txt' ]; then cp -a '$RemoteProjectPath/requirements.txt' '$RemoteBackupPath/requirements.txt'; fi"
if ($LASTEXITCODE -ne 0) {
    Fail "Remote backup failed."
}
Write-Good "Remote backup created: $RemoteBackupPath"

Write-Step "Syncing local files to NAS"

scp -r "$ProjectRoot\app" "$ProjectRoot\Dockerfile" "$ProjectRoot\requirements.txt" "${NasUser}@${NasHost}:$RemoteProjectPath/"
if ($LASTEXITCODE -ne 0) {
    Fail "SCP sync failed."
}
Write-Good "Files synced to NAS"

Write-Step "Skipping remote host version check"
Write-Good "Version will be verified from /health after the container starts"
Write-Step "Building Docker image on NAS"

ssh "$NasUser@$NasHost" "cd '$RemoteProjectPath' && docker build --no-cache -t '$ImageName' ."
if ($LASTEXITCODE -ne 0) {
    Fail "Docker build failed."
}
Write-Good "Docker image built: $ImageName"

Write-Step "Restarting container"

$RunCommand = @"
docker stop '$ContainerName' || true
docker rm '$ContainerName' || true
docker run -d \
  --name '$ContainerName' \
  --restart unless-stopped \
  -p ${Port}:${Port} \
  -v /mnt/user/NASDY/downloads:/downloads \
  -v /mnt/user/NASDY/media:/media \
  -v /mnt/user/appdata/nasdy-media-organizer/data:/app/data \
  '$ImageName'
"@

ssh "$NasUser@$NasHost" $RunCommand
if ($LASTEXITCODE -ne 0) {
    Fail "Container restart failed."
}
Write-Good "Container restarted"

Write-Step "Waiting for app to come online"

$Healthy = $false
$RunningVersion = ""
for ($i = 1; $i -le 20; $i++) {
    Start-Sleep -Seconds 2
    try {
        $Health = Invoke-RestMethod -Uri "http://$NasHost`:$Port/health" -TimeoutSec 4
        if ($Health.ok -eq $true) {
            $Healthy = $true
            $RunningVersion = $Health.version
            break
        }
    } catch {
        Write-Host "Waiting... attempt $i/20"
    }
}

if (!$Healthy) {
    Write-Warn "The container started, but /health did not respond yet."
    Write-Host ""
    Write-Host "Recent logs:" -ForegroundColor Yellow
    ssh "$NasUser@$NasHost" "docker logs '$ContainerName' --tail=80"
    exit 1
}

Write-Good "App is online"
Write-Good "Running version: $RunningVersion"

if ($RunningVersion -ne "v3.6.0.1") {
    Write-Warn "Expected v3.6.0.1, but /health returned $RunningVersion"
} else {
    Write-Good "Version verified"
}

Write-Step "Recent container logs"
ssh "$NasUser@$NasHost" "docker logs '$ContainerName' --tail=40"

Write-Host ""
Write-Host "Deployment successful." -ForegroundColor Green
Write-Host "Open: http://$NasHost`:$Port" -ForegroundColor Green

