const $ = (selector) => document.querySelector(selector);

let previewTimer = null;

function setMediaType(type) {
  const radio = document.querySelector(`input[name="media_type"][value="${type}"]`);
  if (radio) radio.checked = true;
  updateSeasonVisibility();
}

function getMediaType() {
  const checked = document.querySelector('input[name="media_type"]:checked');
  return checked ? checked.value : "tv";
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

  document.querySelectorAll(".folder").forEach(el => el.classList.remove("active"));
  card.classList.add("active");

  $("#source").value = card.dataset.source || "";
  $("#sourceKey").value = card.dataset.sourceKey || card.dataset.source || "";
  $("#title").value = card.dataset.title || "";
  $("#year").value = card.dataset.year || "";
  $("#season").value = card.dataset.season || "01";

  setMediaType(card.dataset.type || "tv");

  $("#metadata").innerHTML = `
    <div>
      <h3>Import Advisor</h3>
      <p>Checking your library and building an import plan...</p>
    </div>
  `;

  $("#preview").innerHTML = '<div class="empty-preview">Checking import plan...</div>';

  schedulePreview();
}

function renderImportAdvisor(data) {
  const metadata = $("#metadata");
  if (!metadata) return;

  if (data.imported) {
    metadata.innerHTML = `
      <div>
        <h3>?? Already Linked</h3>
        <p>This item is already in Media Linker import history.</p>
        <p><strong>Destination:</strong><br>${escapeHtml(data.imported.destination || "")}</p>
        <p><strong>Linked:</strong> ${escapeHtml(data.imported.time || "")}</p>
        <p><strong>Recommendation:</strong> No action needed.</p>
      </div>
    `;
    return;
  }

  const match = data.library_match;

  if (!match) {
    metadata.innerHTML = `
      <div>
        <h3>?? New Library Folder</h3>
        <p>No existing library match was found.</p>
        <p><strong>Recommendation:</strong> Media Linker will create a new folder using the title, year, and season shown below.</p>
        <p><strong>Destination:</strong><br>${escapeHtml(data.destination || "")}</p>
      </div>
    `;
    return;
  }

  if (match.kind === "movie") {
    metadata.innerHTML = `
      <div>
        <h3>?? Existing Movie Found</h3>
        <p><strong>${escapeHtml(match.title)}</strong></p>
        <p>Media Linker found an existing movie folder in your library.</p>
        <p><strong>Videos already there:</strong> ${escapeHtml(match.video_count)}</p>
        <p><strong>Confidence:</strong> ${escapeHtml(match.confidence)} · Score ${escapeHtml(match.score)}</p>
        <p><strong>Recommendation:</strong> Import into the existing movie folder.</p>
        <p><strong>Path:</strong><br>${escapeHtml(match.path)}</p>
      </div>
    `;
    return;
  }

  const episodes = Array.isArray(match.existing_episodes) && match.existing_episodes.length
    ? match.existing_episodes.map(e => String(e).padStart(2, "0")).join(", ")
    : "None detected";

  metadata.innerHTML = `
    <div>
      <h3>?? Existing Show Found</h3>
      <p><strong>${escapeHtml(match.title)}</strong></p>
      <p>Media Linker found this show in your TV library.</p>
      <p><strong>Season ${escapeHtml(match.season)}:</strong> ${match.season_exists ? "Exists" : "Not found yet"}</p>
      <p><strong>Episodes already there:</strong> ${escapeHtml(episodes)}</p>
      <p><strong>Confidence:</strong> ${escapeHtml(match.confidence)} · Score ${escapeHtml(match.score)}</p>
      <p><strong>Recommendation:</strong> Import into the existing show/season folder.</p>
      <p><strong>Path:</strong><br>${escapeHtml(match.season_path || match.path)}</p>
    </div>
  `;
}

function renderPreview(data) {
  const preview = $("#preview");
  if (!preview) return;

  if (!data.ok) {
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
      <thead>
        <tr>
          <th>Original</th>
          <th>New filename</th>
          <th>Status</th>
        </tr>
      </thead>
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
  const payload = {
    source: $("#source")?.value || "",
    source_key: $("#sourceKey")?.value || "",
    media_type: getMediaType(),
    title: $("#title")?.value || "",
    year: $("#year")?.value || "",
    season: $("#season")?.value || "01",
  };

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

document.addEventListener("DOMContentLoaded", () => {
  document.querySelectorAll(".folder").forEach(card => {
    card.addEventListener("click", () => fillFromCard(card));
  });

  document.querySelectorAll('input[name="media_type"]').forEach(radio => {
    radio.addEventListener("change", () => {
      updateSeasonVisibility();
      schedulePreview();
    });
  });

  ["#title", "#year", "#season"].forEach(selector => {
    const el = $(selector);
    if (el) el.addEventListener("input", schedulePreview);
  });

  const previewBtn = $("#previewBtn");
  if (previewBtn) previewBtn.style.display = "none";

  const importButton = document.querySelector('form[action="/organize"] button[type="submit"]');
  if (importButton) importButton.textContent = "?? Import";

  const first = document.querySelector('.torrent-card[data-imported="false"]')
    || document.querySelector(".torrent-card")
    || document.querySelector(".folder");

  if (first) fillFromCard(first);

  updateSeasonVisibility();
});
