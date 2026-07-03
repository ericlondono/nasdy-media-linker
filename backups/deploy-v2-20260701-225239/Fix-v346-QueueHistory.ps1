# NASDY Media Linker v3.4.6 Queue/History UI Fix
# Run from PowerShell on your Windows machine.

$ErrorActionPreference = "Stop"
$ProjectRoot = "C:\Projects\nasdy-media-linker"

if (!(Test-Path $ProjectRoot)) {
  throw "Project folder not found: $ProjectRoot"
}

Set-Location $ProjectRoot

Write-Host "Creating safety backup..." -ForegroundColor Cyan
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = "backup-before-v346-$stamp"
New-Item -ItemType Directory -Path $backup -Force | Out-Null

$filesToBackup = @(
  "app\config.py",
  "app\main.py",
  "app\templates\index.html",
  "app\static\style.css",
  "app\services\queue.py",
  "app\services\qbittorrent.py"
)

foreach ($f in $filesToBackup) {
  if (Test-Path $f) {
    Copy-Item $f (Join-Path $backup (Split-Path $f -Leaf)) -Force
  }
}

Write-Host "Writing v3.4.6 patcher..." -ForegroundColor Cyan
$patcher = Join-Path $ProjectRoot "_v346_queue_history_patch.py"

@'
from pathlib import Path
import re

ROOT = Path(r"C:\Projects\nasdy-media-linker")


def read_text(path: Path) -> str:
    raw = path.read_bytes()
    for enc in ("utf-8-sig", "utf-8", "cp1252", "latin-1"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", errors="replace")


def write_text(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")


def clean_known_mojibake(text: str) -> str:
    replacements = {
        "ðŸ“º": "TV",
        "ðŸŽ¬": "Movie",
        "âš ï¸": "Error",
        "âœ“": "",
        "â†’": "->",
        "Ã¢Â†Â’": "->",
        "Ã¢â€ â€™": "->",
        "Ã¢â‚¬â„¢": "'",
        "â€™": "'",
        "â€œ": '"',
        "â€�": '"',
        "â€”": "-",
        "â€“": "-",
    }
    for bad, good in replacements.items():
        text = text.replace(bad, good)
    return text


# --- config.py: version and lowercase media roots ---
config_path = ROOT / "app" / "config.py"
config = clean_known_mojibake(read_text(config_path))
config = re.sub(r'APP_VERSION\s*=\s*["\'][^"\']+["\']', 'APP_VERSION = "v3.4.6"', config)
config = re.sub(
    r'MOVIES_ROOT\s*=\s*Path\(os\.environ\.get\("MOVIES_ROOT",\s*"[^"]+"\)\)',
    'MOVIES_ROOT = Path(os.environ.get("MOVIES_ROOT", "/media/movies"))',
    config,
)
config = re.sub(
    r'TV_ROOT\s*=\s*Path\(os\.environ\.get\("TV_ROOT",\s*"[^"]+"\)\)',
    'TV_ROOT = Path(os.environ.get("TV_ROOT", "/media/tv"))',
    config,
)
config = re.sub(
    r'DATA_ROOT\s*=\s*Path\(os\.environ\.get\("DATA_ROOT",\s*"[^"]+"\)\)',
    'DATA_ROOT = Path(os.environ.get("DATA_ROOT", "/data"))',
    config,
)
write_text(config_path, config)


# --- main.py: make sure history counters exist and are passed to Jinja ---
main_path = ROOT / "app" / "main.py"
main = clean_known_mojibake(read_text(main_path))

history_func = '''def history_counts(history):
    success = sum(
        1 for h in history
        if h.get("status") == "success" and h.get("type") != "error"
    )
    error = sum(
        1 for h in history
        if h.get("status") == "error" or h.get("type") == "error"
    )
    return {
        "success_count": {"value": success},
        "error_count": {"value": error},
        "history_total_count": {"value": success + error},
    }
'''

if "def history_counts(history):" in main:
    main = re.sub(
        r'def history_counts\(history\):\n(?:    .*\n)+',
        history_func,
        main,
        count=1,
    )
else:
    anchor = 'templates = Jinja2Templates(directory="app/templates")\n'
    if anchor in main:
        main = main.replace(anchor, anchor + "\n\n" + history_func + "\n", 1)
    else:
        main = history_func + "\n" + main

if "counts = history_counts(history)" not in main:
    main = main.replace(
        "    history = read_history()\n",
        "    history = read_history()\n    counts = history_counts(history)\n",
        1,
    )

if "**counts" not in main:
    main = main.replace(
        '        "history": history,\n',
        '        "history": history,\n        **counts,\n',
        1,
    )

write_text(main_path, main)


# --- index.html: clean history rendering, add counters, robust filters ---
index_path = ROOT / "app" / "templates" / "index.html"
html = clean_known_mojibake(read_text(index_path))

# Clean visible button/label text that commonly got mojibaked.
html = re.sub(r'<span>.*?TV Show</span>', '<span>TV Show</span>', html)
html = re.sub(r'<span>.*?Movie</span>', '<span>Movie</span>', html)
html = re.sub(r'>[^<]*Mark Imported<', '>Mark Imported<', html)
html = html.replace("→", "->")

# Version static assets so Ctrl+F5 is less often needed.
html = re.sub(
    r'href="/static/style\.css(?:\?v=\{\{ version \}\})?"',
    'href="/static/style.css?v={{ version }}"',
    html,
)
html = re.sub(
    r'src="/static/app\.js(?:\?v=\{\{ version \}\})?"',
    'src="/static/app.js?v={{ version }}"',
    html,
)

history_tabs = '''<div class="history-tabs" role="tablist" aria-label="Import history filters">
          <button class="history-tab active" type="button" data-history-filter="success">
            Success <span>{{ success_count.value }}</span>
          </button>
          <button class="history-tab" type="button" data-history-filter="error">
            Errors <span>{{ error_count.value }}</span>
          </button>
          <button class="history-tab" type="button" data-history-filter="all">
            All <span>{{ history_total_count.value }}</span>
          </button>
        </div>'''

html = re.sub(
    r'<div class="history-tabs"[^>]*>.*?</div>\s*\n\s*<div class="history"',
    history_tabs + '\n\n        <div class="history"',
    html,
    count=1,
    flags=re.S,
)

history_block = '''<div class="history" id="historyList">
          {% if history %}
            {% for item in history %}
              {% set htype = 'error' if item.status == 'error' or item.type == 'error' else 'success' %}
              <div class="history-item {% if htype == 'error' %}bad{% else %}success{% endif %}" data-history-type="{{ htype }}">
                <strong>
                  {% if htype == 'error' %}Error{% elif item.type == 'tv' %}TV{% elif item.type == 'movie' %}Movie{% else %}Import{% endif %}
                  - {{ item.title }}
                </strong>
                <span>{{ item.time }}</span>
                {% if htype == 'error' %}
                  <small>{{ item.error }}</small>
                {% else %}
                  <small>{{ item.count }} link(s) -> {{ item.destination }}</small>
                {% endif %}
              </div>
            {% endfor %}
          {% else %}
            <p>No hard links created yet.</p>
          {% endif %}
        </div>'''

html = re.sub(
    r'<div class="history"[^>]*>\s*\{% if history %\}.*?\{% else %\}\s*<p>No hard links created yet\.</p>\s*\{% endif %\}\s*</div>',
    history_block,
    html,
    count=1,
    flags=re.S,
)

filter_override = r'''
<script>
// v3.4.6 queue/history filter override
(function () {
  function run() {
    const queueTabs = Array.from(document.querySelectorAll(".queue-tab"));
    const queueCards = Array.from(document.querySelectorAll(".torrent-card"));
    const search = document.querySelector("#queueSearch");
    const empty = document.querySelector("#queueEmpty");
    let activeQueue = (document.querySelector(".queue-tab.active")?.dataset.filter) || "ready";

    function queueVisible(card) {
      const imported = card.dataset.imported === "true";
      const filterOk =
        activeQueue === "all" ||
        (activeQueue === "ready" && !imported) ||
        (activeQueue === "imported" && imported);
      const term = (search?.value || "").trim().toLowerCase();
      const searchOk = !term || card.textContent.toLowerCase().includes(term);
      return filterOk && searchOk;
    }

    function applyQueue() {
      let visibleCount = 0;
      queueCards.forEach(card => {
        const show = queueVisible(card);
        card.hidden = !show;
        card.style.display = show ? "" : "none";
        card.classList.toggle("hidden", !show);
        if (show) visibleCount += 1;
      });
      if (empty) empty.classList.toggle("hidden", visibleCount !== 0);
      document.dispatchEvent(new CustomEvent("queueFiltersChanged"));
    }

    queueTabs.forEach(tab => {
      tab.addEventListener("click", () => {
        queueTabs.forEach(t => t.classList.remove("active"));
        tab.classList.add("active");
        activeQueue = tab.dataset.filter || "ready";
        applyQueue();
      }, true);
    });
    if (search) search.addEventListener("input", applyQueue, true);
    applyQueue();

    const historyTabs = Array.from(document.querySelectorAll(".history-tab"));
    const historyItems = Array.from(document.querySelectorAll(".history-item"));

    function applyHistory(filter) {
      historyItems.forEach(item => {
        const show = filter === "all" || (item.dataset.historyType || "success") === filter;
        item.hidden = !show;
        item.style.display = show ? "" : "none";
        item.classList.toggle("hidden", !show);
      });
    }

    historyTabs.forEach(tab => {
      tab.addEventListener("click", () => {
        historyTabs.forEach(t => t.classList.remove("active"));
        tab.classList.add("active");
        applyHistory(tab.dataset.historyFilter || "success");
      }, true);
    });
    applyHistory((document.querySelector(".history-tab.active")?.dataset.historyFilter) || "success");
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", run);
  else run();
})();
</script>
'''

if "v3.4.6 queue/history filter override" not in html:
    html = html.replace("</body>", filter_override + "\n</body>", 1)

write_text(index_path, html)


# --- CSS: history counter pills and hard hide fallback ---
css_path = ROOT / "app" / "static" / "style.css"
css = clean_known_mojibake(read_text(css_path))
if "v3.4.6 queue/history filtering and counters" not in css:
    css += r'''

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
'''
write_text(css_path, css)


# --- Python queue services: use ASCII labels instead of emoji icons ---
for rel in ("app/services/queue.py", "app/services/qbittorrent.py"):
    path = ROOT / rel
    if path.exists():
        txt = clean_known_mojibake(read_text(path))
        txt = re.sub(
            r'"icon":\s*"[^"]*"\s*if\s*media_type\s*==\s*"tv"\s*else\s*"[^"]*"',
            '"icon": "TV" if media_type == "tv" else "Movie"',
            txt,
        )
        write_text(path, txt)

print("v3.4.6 source patch complete.")
'@ | Set-Content -Path $patcher -Encoding UTF8

Write-Host "Applying source patch..." -ForegroundColor Cyan
python $patcher

Write-Host "Checking Python syntax..." -ForegroundColor Cyan
python -m py_compile app\config.py app\main.py app\services\queue.py app\services\qbittorrent.py

Write-Host "Copying build to NASDY..." -ForegroundColor Cyan
ssh root@NASDY "mkdir -p /mnt/user/appdata/nasdy-media-organizer/build /mnt/user/appdata/nasdy-media-organizer/data && chown -R 99:100 /mnt/user/appdata/nasdy-media-organizer"
scp -r .\app .\Dockerfile .\requirements.txt root@NASDY:/mnt/user/appdata/nasdy-media-organizer/build/

Write-Host "Building and restarting container on NASDY..." -ForegroundColor Cyan
ssh root@NASDY "set -e; cd /mnt/user/appdata/nasdy-media-organizer/build; docker build -t nasdy-media-linker:latest .; docker rm -f nasdy-media-organizer 2>/dev/null || true; docker run -d --name nasdy-media-organizer --restart unless-stopped -p 8088:8088 --user 99:100 -e DATA_ROOT=/data -e DOWNLOADS_ROOT=/downloads -e MOVIES_ROOT=/media/movies -e TV_ROOT=/media/tv -v /mnt:/host_mnt -v /mnt/user/NASDY/downloads:/downloads -v /mnt/user/NASDY/media:/media -v /mnt/user/appdata/nasdy-media-organizer/data:/data nasdy-media-linker:latest; docker ps --filter name=nasdy-media-organizer; docker logs nasdy-media-organizer --tail=80"

Write-Host "Testing app health..." -ForegroundColor Cyan
ssh root@NASDY "curl -sS http://127.0.0.1:8088/health || curl -sS http://127.0.0.1:8088/"

Write-Host ""
Write-Host "v3.4.6 queue/history cleanup deployed." -ForegroundColor Green
Write-Host "Backup saved to: $backup" -ForegroundColor Cyan
Write-Host "Open http://nasdy:8088 and press Ctrl+F5 once." -ForegroundColor Yellow
