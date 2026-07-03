const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => Array.from(document.querySelectorAll(selector));

let previewTimer = null;
let activeQueueFilter = "recommended";
let activeHistoryFilter = "success";

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
  if (markBtn) markBtn.classList.toggle("hidden", imported);
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

function fillFromCard(card) {
  if (!card) return;

  $$(".folder").forEach(el => el.classList.remove("active"));
  card.classList.add("active");

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

function renderImportAdvisor(data) {
  const metadata = $("#metadata");
  if (!metadata) return;
  metadata.classList.remove("hidden");

  if (!data.ok) {
    setImportButton("Import Unavailable", true);
    metadata.innerHTML = `
      <div class="advisor-panel attention">
        <h3>Smart Import Advisor</h3>
        <p class="bad-text">${escapeHtml(data.error || "Preview failed")}</p>
      </div>
    `;
    return;
  }

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

function renderPreview(data) {
  const preview = $("#preview");
  if (!preview) return;

  if (!data.ok) {
    setImportButton("Import Unavailable", true);
    preview.innerHTML = `<div class="empty-preview bad-text">${escapeHtml(data.error || "Preview failed")}</div>`;
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

  $$('input[name="media_type"]').forEach(radio => {
    radio.addEventListener("change", () => {
      updateSeasonVisibility();
      schedulePreview();
    });
  });

  ["#title", "#year", "#season", "#imdb_id"].forEach(selector => {
    const el = $(selector);
    if (el) el.addEventListener("input", schedulePreview);
  });

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