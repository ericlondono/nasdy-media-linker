const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => Array.from(document.querySelectorAll(sel));

function selectedType() {
  return $("input[name='media_type']:checked").value;
}

function setType(type) {
  const el = document.querySelector(`input[name='media_type'][value='${type}']`);
  if (el) el.checked = true;
  $("#seasonWrap").style.display = selectedType() === "tv" ? "block" : "none";
}

function fillFromItem(btn) {
  $$(".folder").forEach(b => b.classList.remove("active"));
  btn.classList.add("active");
  $("#source").value = btn.dataset.source;
  $("#sourceKey").value = btn.dataset.sourceKey || btn.dataset.source;
  $("#title").value = btn.dataset.title || "";
  $("#year").value = btn.dataset.year || "";
  $("#season").value = btn.dataset.season || "01";
  setType(btn.dataset.type || "tv");
  preview();
}

function esc(s) {
  return String(s || "").replace(/[&<>"']/g, ch => ({
    "&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&#39;"
  }[ch]));
}

function renderMetadata(meta) {
  const box = $("#metadata");
  if (!meta) {
    box.classList.add("hidden");
    box.innerHTML = "";
    return;
  }
  box.classList.remove("hidden");
  box.innerHTML = `
    ${meta.poster ? `<img src="${esc(meta.poster)}" alt="">` : ""}
    <div>
      <h3>${esc(meta.title)} ${meta.year ? `(${esc(meta.year)})` : ""}</h3>
      ${meta.score ? `<p>TMDb score: ${esc(meta.score)}</p>` : ""}
      ${meta.overview ? `<p>${esc(meta.overview)}</p>` : ""}
      <button type="button" class="secondary" id="useMeta">Use TMDb title/year</button>
    </div>
  `;
  const btn = $("#useMeta");
  if (btn) {
    btn.addEventListener("click", () => {
      if (meta.title) $("#title").value = meta.title;
      if (meta.year) $("#year").value = meta.year;
      preview();
    });
  }
}

function renderImported(imported) {
  const box = $("#importedBox");
  if (!imported) {
    box.classList.add("hidden");
    box.innerHTML = "";
    return;
  }
  box.classList.remove("hidden");
  box.innerHTML = `<strong>Already linked</strong><br>${esc(imported.time)}<br>${esc(imported.destination || "")}`;
}

function renderPreview(data) {
  let html = `<div class="destination"><strong>Destination:</strong><br>${esc(data.destination)}</div>`;
  html += `<table class="preview-table">
    <thead><tr><th>Original</th><th>New filename</th><th>Status</th></tr></thead><tbody>`;
  data.items.forEach(item => {
    html += `<tr>
      <td>${esc(item.src)}</td>
      <td>${esc(item.new_name)}</td>
      <td>${item.exists ? '<span class="exists">Already exists</span>' : 'Ready'}</td>
    </tr>`;
  });
  html += `</tbody></table>`;
  $("#preview").innerHTML = html;
}

async function preview() {
  if (!$("#source").value) {
    $("#preview").textContent = "Select a queue item to begin.";
    return;
  }
  const payload = {
    source: $("#source").value,
    source_key: $("#sourceKey").value,
    title: $("#title").value,
    year: $("#year").value,
    season: $("#season").value,
    media_type: selectedType()
  };
  const res = await fetch("/api/preview", {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify(payload)
  });
  const data = await res.json();
  if (!data.ok) {
    $("#preview").textContent = data.error;
    renderMetadata(null);
    renderImported(null);
    return;
  }
  renderMetadata(data.metadata);
  renderImported(data.imported);
  $("#warning").textContent = data.same_device ? "" : "Warning: hard links may fail because source and destination may not be on the same filesystem.";
  renderPreview(data);
}

function filterQueue() {
  const q = $("#queueSearch").value.toLowerCase();
  $$(".folder").forEach(btn => {
    btn.style.display = btn.textContent.toLowerCase().includes(q) ? "" : "none";
  });
}

document.addEventListener("DOMContentLoaded", () => {
  $$(".folder").forEach(btn => btn.addEventListener("click", () => fillFromItem(btn)));
  $$("input[name='media_type']").forEach(r => r.addEventListener("change", () => { setType(selectedType()); preview(); }));
  ["#title", "#year", "#season"].forEach(sel => $(sel).addEventListener("input", preview));
  $("#previewBtn").addEventListener("click", preview);
  $("#queueSearch").addEventListener("input", filterQueue);
  const first = $(".folder");
  if (first) fillFromItem(first);
});
