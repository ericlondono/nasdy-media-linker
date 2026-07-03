param(
  [string]$ProjectRoot = "C:\Projects\nasdy-media-linker",
  [string]$NasHost = "NASDY"
)

$ErrorActionPreference = "Stop"

function Write-Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Read-Text($path) { Get-Content -Raw -Encoding UTF8 $path }
function Write-Text($path, $text) { Set-Content -Path $path -Value $text -Encoding UTF8 -NoNewline }
function Replace-Required($path, $old, $new, $label) {
  $text = Read-Text $path
  if (-not $text.Contains($old)) { throw "Could not find expected block in $path for: $label" }
  Write-Text $path ($text.Replace($old, $new))
  Write-Host "Patched $label"
}

if (-not (Test-Path $ProjectRoot)) { throw "Project folder not found: $ProjectRoot" }
Set-Location $ProjectRoot

Write-Step "Backing up current files"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = Join-Path $ProjectRoot "backup-before-v347-$stamp"
New-Item -ItemType Directory -Force -Path $backup | Out-Null
$pathsToBackup = @(
  "app\config.py",
  "app\main.py",
  "app\services\qbittorrent.py",
  "app\services\queue.py",
  "app\services\linker.py",
  "app\templates\index.html",
  "app\static\app.js",
  "app\static\style.css"
)
foreach ($rel in $pathsToBackup) {
  $src = Join-Path $ProjectRoot $rel
  if (Test-Path $src) {
    $dst = Join-Path $backup $rel
    New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
    Copy-Item $src $dst -Force
  }
}
Write-Host "Backup created: $backup"

Write-Step "Bumping version and confirming lowercase media roots"
$configPath = Join-Path $ProjectRoot "app\config.py"
$config = Read-Text $configPath
$config = $config -replace 'APP_VERSION = "v[0-9.]+"', 'APP_VERSION = "v3.4.7"'
$config = $config -replace 'MOVIES_ROOT = Path\(os\.environ\.get\("MOVIES_ROOT", "[^"]+"\)\)', 'MOVIES_ROOT = Path(os.environ.get("MOVIES_ROOT", "/media/movies"))'
$config = $config -replace 'TV_ROOT = Path\(os\.environ\.get\("TV_ROOT", "[^"]+"\)\)', 'TV_ROOT = Path(os.environ.get("TV_ROOT", "/media/tv"))'
$config = $config -replace 'DATA_ROOT = Path\(os\.environ\.get\("DATA_ROOT", "[^"]+"\)\)', 'DATA_ROOT = Path(os.environ.get("DATA_ROOT", "/data"))'
Write-Text $configPath $config

Write-Step "Fixing imported/unmarked state logic"
$qbitPath = Join-Path $ProjectRoot "app\services\qbittorrent.py"
Replace-Required $qbitPath @'
def imported_from_db(db, candidates):
    keys = import_db_keys(db)
    for candidate in candidates:
        if not candidate:
            continue
        c = str(candidate)
        n = normalize_source_path(c)
        if c in keys or n in keys:
            return True
    return False
'@ @'
def get_import_entry(db, candidate):
    if not candidate:
        return None
    c = str(candidate)
    n = normalize_source_path(c)

    for key in (c, n):
        entry = (db or {}).get(key)
        if isinstance(entry, dict):
            return entry

    for key, entry in (db or {}).items():
        if not isinstance(entry, dict):
            continue
        key_norm = normalize_source_path(str(key))
        if key_norm == n:
            return entry
        for field in ("source", "source_key", "hash", "destination"):
            value = entry.get(field)
            if value and normalize_source_path(str(value)) == n:
                return entry
    return None


def unmarked_from_db(db, candidates):
    for candidate in candidates:
        entry = get_import_entry(db, candidate)
        if isinstance(entry, dict) and entry.get("unmarked") is True:
            return True
    return False


def imported_from_db(db, candidates):
    keys = import_db_keys(db)
    for candidate in candidates:
        if not candidate:
            continue
        entry = get_import_entry(db, candidate)
        if isinstance(entry, dict) and entry.get("unmarked") is True:
            return False
        c = str(candidate)
        n = normalize_source_path(c)
        if c in keys or n in keys:
            return True
    return False
'@ "qBittorrent DB import helpers"

Replace-Required $qbitPath @'
        imported = imported_from_db(db, import_candidates) or imported_from_history(
            name=name,
            title=title,
            year=year,
            source_path=str(source_path),
            history_keys=history_keys,
            media_type=media_type,
            season=season,
        )
'@ @'
        if unmarked_from_db(db, import_candidates):
            imported = False
        else:
            imported = imported_from_db(db, import_candidates) or imported_from_history(
                name=name,
                title=title,
                year=year,
                source_path=str(source_path),
                history_keys=history_keys,
                media_type=media_type,
                season=season,
            )
'@ "qBittorrent unmark override"

$queuePath = Join-Path $ProjectRoot "app\services\queue.py"
$queue = Read-Text $queuePath
$queue = $queue.Replace("from app.services.qbittorrent import qbit_completed_items, normalize_source_path, imported_from_db, imported_from_history, history_import_keys", "from app.services.qbittorrent import qbit_completed_items, normalize_source_path, imported_from_db, imported_from_history, history_import_keys, unmarked_from_db")
Write-Text $queuePath $queue
Replace-Required $queuePath @'
        imported = imported_from_db(db, {
            key,
            normalize_source_path(key),
            p.name,
        }) or imported_from_history(
            name=p.name,
            title=title,
            year=year,
            source_path=key,
            history_keys=history_keys,
            media_type=media_type,
            season=season,
        )
'@ @'
        import_candidates = {
            key,
            normalize_source_path(key),
            p.name,
        }

        if unmarked_from_db(db, import_candidates):
            imported = False
        else:
            imported = imported_from_db(db, import_candidates) or imported_from_history(
                name=p.name,
                title=title,
                year=year,
                source_path=key,
                history_keys=history_keys,
                media_type=media_type,
                season=season,
            )
'@ "folder queue unmark override"

Write-Step "Making Unmark persist through history-based detection"
$mainPath = Join-Path $ProjectRoot "app\main.py"
Replace-Required $mainPath @'
        db = load_import_db()
        before = len(db)
        db = remove_import_aliases(db, source_key, source)
        removed = before - len(db)
        save_import_db(db)

        log(f"Manual import unmark: removed {removed} import alias(es) source={source} source_key={source_key}")
        return JSONResponse({"ok": True, "removed": removed})
'@ @'
        db = load_import_db()
        before = len(db)
        db = remove_import_aliases(db, source_key, source)
        removed = before - len(db)

        tombstone = {
            "time": datetime.now().strftime("%Y-%m-%d %H:%M"),
            "status": "unmarked",
            "unmarked": True,
            "source": source,
            "source_key": source_key,
        }
        for key in import_alias_keys(source_key, source):
            db[key] = tombstone

        save_import_db(db)

        log(f"Manual import unmark: removed {removed} import alias(es), added unmark marker source={source} source_key={source_key}")
        return JSONResponse({"ok": True, "removed": removed, "unmarked": True})
'@ "manual unmark tombstone"

Write-Step "Adding permission normalization after hard-link creation"
$linkerPath = Join-Path $ProjectRoot "app\services\linker.py"
Replace-Required $linkerPath @'
def stat_device(path: Path):
    try:
        st = os.stat(path if path.exists() else path.parent)
        return st.st_dev
    except Exception:
        return None
'@ @'
def stat_device(path: Path):
    try:
        st = os.stat(path if path.exists() else path.parent)
        return st.st_dev
    except Exception:
        return None


def normalize_permissions(path: Path):
    """
    Keep files/folders Windows-SMB friendly.
    The container runs as nobody:users (99:100), so chmod is the important part here.
    chown is attempted only when allowed and ignored when the container is not root.
    """
    try:
        path = Path(path)
        targets = [path]
        if path.parent.exists():
            targets.append(path.parent)

        for target in targets:
            try:
                if target.is_dir():
                    os.chmod(target, 0o2775)
                elif target.exists():
                    os.chmod(target, 0o664)
            except Exception as perm_error:
                log(f"WARN permission normalization skipped for {target}: {perm_error}")
    except Exception as e:
        log(f"WARN permission normalization failed for {path}: {e}")
'@ "permission helper"

Replace-Required $linkerPath @'
        os.link(src_real, dst_real)
        created.append(str(dst_real))
        log(f"CREATED HARD LINK: {src_real} -> {dst_real}")
'@ @'
        os.link(src_real, dst_real)
        normalize_permissions(dst_real)
        created.append(str(dst_real))
        log(f"CREATED HARD LINK: {src_real} -> {dst_real}")
'@ "permission call after link"

Write-Step "Installing robust queue filter override"
$filterFixPath = Join-Path $ProjectRoot "app\static\filter-fix.js"
@'
// v3.4.7 robust queue/history filter state sync
(function () {
  function ready(fn) {
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", fn);
    else fn();
  }

  ready(() => {
    const queueTabs = Array.from(document.querySelectorAll(".queue-tab"));
    const queueCards = Array.from(document.querySelectorAll(".torrent-card"));
    const search = document.querySelector("#queueSearch");
    const empty = document.querySelector("#queueEmpty");
    let activeQueue = "ready";

    function imported(card) {
      return String(card.dataset.imported || "false").toLowerCase() === "true";
    }

    function showForQueue(card) {
      const isImported = imported(card);
      const filterOk =
        activeQueue === "all" ||
        (activeQueue === "ready" && !isImported) ||
        (activeQueue === "imported" && isImported);
      const term = (search?.value || "").trim().toLowerCase();
      const searchOk = !term || card.textContent.toLowerCase().includes(term);
      return filterOk && searchOk;
    }

    function applyQueue() {
      let visible = 0;
      queueCards.forEach(card => {
        const shouldShow = showForQueue(card);
        card.hidden = !shouldShow;
        card.style.display = shouldShow ? "" : "none";
        card.classList.toggle("hidden", !shouldShow);
        if (shouldShow) visible += 1;
      });
      if (empty) empty.classList.toggle("hidden", visible !== 0);
      document.dispatchEvent(new CustomEvent("queueFiltersChanged"));
    }

    queueTabs.forEach(tab => {
      tab.addEventListener("click", event => {
        event.preventDefault();
        event.stopImmediatePropagation();
        queueTabs.forEach(t => t.classList.remove("active"));
        tab.classList.add("active");
        activeQueue = tab.dataset.filter || "ready";
        applyQueue();
      }, true);
    });

    if (search) {
      search.addEventListener("input", () => applyQueue(), true);
    }

    // Force Ready as the initial tab every load.
    queueTabs.forEach(t => t.classList.remove("active"));
    const readyTab = queueTabs.find(t => t.dataset.filter === "ready") || queueTabs[0];
    if (readyTab) readyTab.classList.add("active");
    activeQueue = "ready";
    applyQueue();

    // Select the first true Ready item, not the first imported/grey item.
    const firstReady = queueCards.find(card => !imported(card));
    if (firstReady && typeof window.fillFromCard === "function") {
      window.fillFromCard(firstReady);
    }

    const historyTabs = Array.from(document.querySelectorAll(".history-tab"));
    const historyItems = Array.from(document.querySelectorAll(".history-item"));

    function applyHistory(filter) {
      historyItems.forEach(item => {
        const shouldShow = filter === "all" || (item.dataset.historyType || "success") === filter;
        item.hidden = !shouldShow;
        item.style.display = shouldShow ? "" : "none";
        item.classList.toggle("hidden", !shouldShow);
      });
    }

    historyTabs.forEach(tab => {
      tab.addEventListener("click", event => {
        event.preventDefault();
        event.stopImmediatePropagation();
        historyTabs.forEach(t => t.classList.remove("active"));
        tab.classList.add("active");
        applyHistory(tab.dataset.historyFilter || "success");
      }, true);
    });
    applyHistory("success");
  });
})();
'@ | Set-Content -Path $filterFixPath -Encoding UTF8

$appJsPath = Join-Path $ProjectRoot "app\static\app.js"
$appJs = Read-Text $appJsPath
if ($appJs -notmatch 'window\.fillFromCard') {
  $appJs = $appJs -replace 'function fillFromCard\(card\) \{', 'window.fillFromCard = function fillFromCard(card) {'
  Write-Text $appJsPath $appJs
  Write-Host "Exposed fillFromCard for filter-fix.js"
}

$indexPath = Join-Path $ProjectRoot "app\templates\index.html"
$index = Read-Text $indexPath
$index = $index.Replace('{{ item.state if item.state else "ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â" }}', '{{ item.state if item.state else "-" }}')
$index = $index -replace '<link rel="stylesheet" href="/static/style\.css\?v=\{\{ version \}\}-cards-final">', '<link rel="stylesheet" href="/static/style.css?v={{ version }}">'
if ($index -notmatch 'filter-fix\.js') {
  $index = $index.Replace('</body>', '  <script src="/static/filter-fix.js?v={{ version }}"></script>' + "`n" + '</body>')
}
Write-Text $indexPath $index

Write-Step "Removing accidental legacy uppercase TV folder if empty"
ssh root@$NasHost 'rmdir /mnt/user/NASDY/media/TV 2>/dev/null || true'

Write-Step "Building and deploying on NASDY"
$tarPath = Join-Path $env:TEMP "nasdy-media-linker-v347.tar"
if (Test-Path $tarPath) { Remove-Item $tarPath -Force }
$include = @("app", "Dockerfile", "requirements.txt") | Where-Object { Test-Path (Join-Path $ProjectRoot $_) }
if (-not $include.Contains("Dockerfile")) { throw "Dockerfile not found in $ProjectRoot" }
if (-not $include.Contains("requirements.txt")) { throw "requirements.txt not found in $ProjectRoot" }
& tar -cf $tarPath $include
if ($LASTEXITCODE -ne 0) { throw "tar failed creating $tarPath" }

scp $tarPath "root@${NasHost}:/tmp/nasdy-media-linker-v347.tar"
ssh root@$NasHost 'rm -rf /tmp/nasdy-media-linker-v347 && mkdir -p /tmp/nasdy-media-linker-v347 && tar -xf /tmp/nasdy-media-linker-v347.tar -C /tmp/nasdy-media-linker-v347 && cd /tmp/nasdy-media-linker-v347 && docker build -t nasdy-media-linker:latest . && mkdir -p /mnt/user/appdata/nasdy-media-organizer/data && chown -R 99:100 /mnt/user/appdata/nasdy-media-organizer && docker rm -f nasdy-media-organizer 2>/dev/null || true; docker run -d --name nasdy-media-organizer --restart unless-stopped -p 8088:8088 --user 99:100 -e DATA_ROOT=/data -e DOWNLOADS_ROOT=/downloads -e MOVIES_ROOT=/media/movies -e TV_ROOT=/media/tv -v /mnt:/host_mnt -v /mnt/user/NASDY/downloads:/downloads -v /mnt/user/NASDY/media:/media -v /mnt/user/appdata/nasdy-media-organizer/data:/data nasdy-media-linker:latest && docker ps --filter "name=nasdy-media-organizer" && docker logs nasdy-media-organizer --tail=80'

Write-Step "Done"
Write-Host "Open http://nasdy:8088 and press Ctrl+F5. You should see v3.4.7."
