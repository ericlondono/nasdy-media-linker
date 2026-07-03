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


function numberOrNull(value) {
  if (value === null || value === undefined || value === "") return null;
  const number = Number(value);
  if (!Number.isFinite(number)) return null;
  return Math.max(0, Math.min(100, Math.round(number)));
}

function qualitySummary(part) {
  if (!part) return "";
  const summary = String(part.summary || "").trim();
  if (summary && summary.toLowerCase() !== "unknown quality") return summary;
  if (Array.isArray(part.tags) && part.tags.length) return part.tags.join(" ");
  return "";
}

function smartStatusCardFromRow(row) {
  row = row || {};
  if (row.status_card && row.status_card.state) {
    return row.status_card;
  }

  const quality = row.quality || {};
  const comparison = quality.comparison || {};
  const incoming = quality.incoming || {};
  const existing = quality.existing || {};
  const comparisonLevel = String(comparison.level || "").toLowerCase();
  const statusLevel = String(row.status_level || row.match_level || "").toLowerCase();
  const statusLabel = String(row.status_label || row.match_status || "").trim();
  const confidence = numberOrNull(row.match_confidence || row.match_score);
  const incomingSummary = qualitySummary(incoming);
  const existingSummary = qualitySummary(existing);

  const matchLine = row.imdb_id
    ? (confidence !== null ? `Auto matched (${confidence}%)` : "Auto matched")
    : (statusLabel || "Metadata pending");

  if (statusLevel === "error" || row.error) {
    return {
      state: "blocked",
      icon: "âš«",
      label: "Blocked",
      lines: [row.error || statusLabel || "Import plan failed", "Manual review required"],
    };
  }

  if (row.enabled === false) {
    return {
      state: "blocked",
      icon: "âš«",
      label: "Skipped",
      lines: ["Row unchecked", "Will not import"],
    };
  }

  if (comparisonLevel === "upgrade" || statusLabel.toLowerCase().includes("upgrade")) {
    return {
      state: "upgrade",
      icon: "ðŸ”µ",
      label: "Upgrade",
      lines: [
        existingSummary ? `Existing: ${existingSummary}` : "Existing item found",
        incomingSummary ? `Incoming: ${incomingSummary}` : "Incoming quality appears higher",
        "Non-destructive review",
      ],
    };
  }

  if (statusLevel === "duplicate" || statusLabel.toLowerCase().includes("duplicate")) {
    return {
      state: "duplicate",
      icon: "ðŸ”´",
      label: "Duplicate",
      lines: [
        "Already exists in library",
        existingSummary ? `Existing: ${existingSummary}` : "",
        incomingSummary ? `Incoming: ${incomingSummary}` : "",
      ].filter(Boolean),
    };
  }

  const reviewLines = [];
  if (Array.isArray(row.alternatives) && row.alternatives.length) {
    reviewLines.push(`${row.alternatives.length + 1} TMDb matches found`);
  }
  if (confidence !== null && confidence < 90) {
    reviewLines.push(`Match confidence ${confidence}%`);
  }
  if (comparisonLevel === "downgrade") {
    reviewLines.push("Incoming may be lower quality");
  } else if (comparisonLevel === "unknown") {
    reviewLines.push("Quality could not be confirmed");
  } else if (comparisonLevel === "similar") {
    reviewLines.push("Existing library item found");
  }
  if (statusLevel === "warning" || statusLevel === "attention") {
    reviewLines.push(statusLabel || "Review recommended");
  }
  if (!row.imdb_id) {
    reviewLines.push("IMDb ID missing");
  }

  if (reviewLines.length) {
    return {
      state: "needs_review",
      icon: "ðŸŸ¡",
      label: "Needs Review",
      lines: reviewLines,
    };
  }

  return {
    state: "ready",
    icon: "ðŸŸ¢",
    label: "Ready",
    lines: [
      matchLine,
      row.media_type === "tv" ? "New TV item" : "New movie",
      "Destination available",
    ],
  };
}

function renderSmartImportStatus(row) {
  const card = smartStatusCardFromRow(row);
  const state = card.state || "blocked";
  const icon = card.icon || "âš«";
  const label = card.label || "Blocked";
  const lines = Array.isArray(card.lines) ? card.lines.filter(Boolean) : [];

  return `
    <div class="smart-status-card smart-status-${escapeHtml(state)} multi-status" data-row-id="${escapeHtml(row?.row_id || "")}">
      <div class="smart-status-title">
        <span class="smart-status-icon">${escapeHtml(icon)}</span>
        <span>${escapeHtml(label)}</span>
      </div>
      ${lines.map(line => `<div class="smart-status-line">${escapeHtml(line)}</div>`).join("")}
    </div>
  `;
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
      <p class="advisor-headline">${escapeHtml(advisor.headline || multi.title || "Import Manager")}</p>
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
          ${renderSmartImportStatus(row)}
          <small class="multi-destination" data-row-id="${escapeHtml(row.row_id)}" title="${escapeHtml(destination)}">${escapeHtml(shortDestination(destination))}</small>
        </td>
      </tr>
    `;
  }).join("");

  manager.innerHTML = `
    <section class="multi-manager-card">
      <div class="multi-manager-head">
        <div>
          <h3>${escapeHtml(multi.title || "Import Manager")}</h3>
          <p>${escapeHtml(multi.recommendation || "Each detected item can be edited and imported independently.")}</p>
        </div>
        <span class="status-chip advisor-chip recommended">v3.6.1.0</span>
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
      status.outerHTML = renderSmartImportStatus(row);
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