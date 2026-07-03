const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => Array.from(document.querySelectorAll(selector));

let previewTimer = null;
let activeQueueFilter = "ready";
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
  setActionMessage("");
  setManualButtons(card.dataset.imported === "true");

  setMediaType(card.dataset.type || "tv");
  setImportButton("Checking...", true);

  const metadata = $("#metadata");
  if (metadata) {
    metadata.classList.remove("hidden");
    metadata.innerHTML = `
      <div>
        <h3>Import Advisor</h3>
        <p>Checking your library and building an import plan...</p>
      </div>
    `;
  }

  const preview = $("#preview");
  if (preview) preview.innerHTML = '<div class="empty-preview">Checking import plan...</div>';

  schedulePreview();
}

function renderImportAdvisor(data) {
  const metadata = $("#metadata");
  if (!metadata) return;
  metadata.classList.remove("hidden");

  if (data.imported) {
    const importType = data.imported.import_type || "linked";
    const heading = importType === "manual" ? "Manually Marked Imported" : "Previously Hard Linked";
    const verb = importType === "manual" ? "Marked" : "Linked";

    setImportButton("Already Imported", true);
    setManualButtons(true);

    metadata.innerHTML = `
      <div>
        <h3>${escapeHtml(heading)}</h3>
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

  const match = data.library_match;
  const mediaType = getMediaType();

  if (!match) {
    setImportButton(mediaType === "movie" ? "Create New Movie" : "Create New TV Folder", false);
    metadata.innerHTML = `
      <div>
        <h3>New Library Folder</h3>
        <p>No existing library match was found.</p>
        <p><strong>Recommendation:</strong> Create a new destination folder.</p>
        <p><strong>Destination:</strong><br>${escapeHtml(data.destination || "")}</p>
      </div>
    `;
    return;
  }

  if (match.kind === "movie") {
    setImportButton("Import into Existing Movie", false);
    metadata.innerHTML = `
      <div>
        <h3>Existing Movie Found</h3>
        <p><strong>${escapeHtml(match.title)}</strong></p>
        <p>Media Linker found an existing movie folder in your library.</p>
        <p><strong>Videos already there:</strong> ${escapeHtml(match.video_count)}</p>
        <p><strong>Confidence:</strong> ${escapeHtml(match.confidence)} / Score ${escapeHtml(match.score)}</p>
        <p><strong>Recommendation:</strong> Import into the existing movie folder.</p>
        <p><strong>Path:</strong><br>${escapeHtml(match.path)}</p>
      </div>
    `;
    return;
  }

  const episodes = Array.isArray(match.existing_episodes) && match.existing_episodes.length
    ? match.existing_episodes.map(e => String(e).padStart(2, "0")).join(", ")
    : "None detected";

  setImportButton(`Import into Season ${match.season}`, false);
  metadata.innerHTML = `
    <div>
      <h3>Existing Show Found</h3>
      <p><strong>${escapeHtml(match.title)}</strong></p>
      <p>Media Linker found this show in your TV library.</p>
      <p><strong>Season ${escapeHtml(match.season)}:</strong> ${match.season_exists ? "Exists" : "Not found yet"}</p>
      <p><strong>Episodes already there:</strong> ${escapeHtml(episodes)}</p>
      <p><strong>Confidence:</strong> ${escapeHtml(match.confidence)} / Score ${escapeHtml(match.score)}</p>
      <p><strong>Recommendation:</strong> Import into the existing show/season folder.</p>
      <p><strong>Path:</strong><br>${escapeHtml(match.season_path || match.path)}</p>
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

  const rows = (data.items || []).map(item => `
    <tr>
      <td>${escapeHtml(item.src)}</td>
      <td>${escapeHtml(item.new_name || item.dst)}</td>
      <td>${item.exists ? '<span class="exists">Exists</span>' : '<span class="good-text">Ready</span>'}</td>
    </tr>
  `).join("");

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

  const response = await fetch("/api/preview", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload)
  });

  const data = await response.json();
  renderImportAdvisor(data);
  renderPreview(data);
  renderDiagnostics(data);
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

function cardShouldShow(card) {
  const imported = card.dataset.imported === "true";
  const filterOk =
    activeQueueFilter === "all" ||
    (activeQueueFilter === "ready" && !imported) ||
    (activeQueueFilter === "imported" && imported);

  const term = ($("#queueSearch")?.value || "").trim().toLowerCase();
  const searchOk = !term || card.textContent.toLowerCase().includes(term);
  return filterOk && searchOk;
}

function applyQueueFilters() {
  const cards = $$(".torrent-card");
  let visibleCount = 0;

  cards.forEach(card => {
    const show = cardShouldShow(card);
    card.hidden = !show;
    card.style.display = show ? "" : "none";
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
    setActionMessage("Select one or more Ready items first.", true);
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
      $$(".queue-tab").forEach(t => t.classList.remove("active"));
      tab.classList.add("active");
      activeQueueFilter = tab.dataset.filter || "ready";
      applyQueueFilters();
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

  applyQueueFilters();
  applyHistoryFilter();

  const first = document.querySelector('.torrent-card[data-imported="false"]') || document.querySelector(".torrent-card") || document.querySelector(".folder");
  if (first) fillFromCard(first);

  updateSeasonVisibility();
});
