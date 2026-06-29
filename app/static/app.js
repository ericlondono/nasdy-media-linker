function $(selector) {
  return document.querySelector(selector);
}

function selectedCard() {
  return document.querySelector(".folder.active");
}

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
}

async function previewSelected() {
  const payload = {
    source: $("#source").value,
    source_key: $("#sourceKey").value,
    media_type: getMediaType(),
    title: $("#title").value,
    year: $("#year").value,
    season: $("#season").value,
  };

  const response = await fetch("/api/preview", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload)
  });

  const data = await response.json();

  if (data.library_match) {
    const metadata = $("#metadata");
    metadata.classList.remove("hidden");

    let html = `<h3>? Existing Library Match</h3>`;

    if (data.library_match.kind === "movie") {
      html += `
        <p><strong>Movie Folder:</strong> ${data.library_match.title}</p>
        <p><strong>Videos:</strong> ${data.library_match.video_count}</p>
        <p><strong>Confidence:</strong> ${data.library_match.confidence}</p>
      `;
    } else {
      html += `
        <p><strong>Show:</strong> ${data.library_match.title}</p>
        <p><strong>Season:</strong> ${data.library_match.season}</p>
        <p><strong>Season Exists:</strong> ${data.library_match.season_exists}</p>
        <p><strong>Episodes:</strong> ${data.library_match.existing_episodes.join(", ")}</p>
      `;
    }

    metadata.innerHTML = html;
  }
}

document.addEventListener("DOMContentLoaded", () => {

  document.querySelectorAll(".folder").forEach(card => {
    card.addEventListener("click", () => fillFromCard(card));
  });

  document.querySelectorAll('input[name="media_type"]').forEach(radio => {
    radio.addEventListener("change", updateSeasonVisibility);
  });

  $("#previewBtn").addEventListener("click", previewSelected);

  const first = document.querySelector('.torrent-card[data-imported="false"]')
      || document.querySelector(".torrent-card");

  if (first) fillFromCard(first);

  updateSeasonVisibility();
});
