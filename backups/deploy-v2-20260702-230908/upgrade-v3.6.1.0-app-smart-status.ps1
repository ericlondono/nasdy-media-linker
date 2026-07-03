param(
    [switch]$SkipDeploy
)

$ErrorActionPreference = "Stop"

$Version = "v3.6.1.0-app-smart-status"
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
Write-Host "Application-only release"
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
    Fail "Deploy.ps1 is missing. Run the v3.6.1.0 Deploy v2 foundation upgrade first."
}
if (!(Test-Path ".\.deploy.sh")) {
    Fail ".deploy.sh is missing. Run the v3.6.1.0 Deploy v2 foundation upgrade first."
}

Write-Ok "Project detected: $ProjectRoot"

Write-Step "Creating local backup"
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$BackupRoot = Join-Path $ProjectRoot "backups"
$BackupPath = Join-Path $BackupRoot "$Version-$Stamp"
New-Item -ItemType Directory -Force -Path $BackupPath | Out-Null

$FilesToBackup = @(
    "app\config.py",
    "app\services\multi_import.py",
    "app\services\quality.py",
    "app\static\app.js",
    "app\static\style.css",
    "app\templates\index.html",
    "DEVELOPMENT.md"
)

foreach ($RelativePath in $FilesToBackup) {
    Backup-File -RelativePath $RelativePath -BackupPath $BackupPath
}

Write-Ok "Backup created: $BackupPath"

Write-Step "Updating app version"
$ConfigPath = Join-Path $ProjectRoot "app\config.py"
$Config = Read-TextFile "app\config.py"
$Config = [regex]::Replace($Config, 'APP_VERSION\s*=\s*["''][^"''\r\n]+["'']', 'APP_VERSION = "v3.6.1.0"')
Write-Utf8NoBom -Path $ConfigPath -Content $Config
Write-Ok "Set APP_VERSION to v3.6.1.0"

Write-Step "Renaming Import Manager titles"
$RenameTargets = Get-ChildItem -Path (Join-Path $ProjectRoot "app") -Recurse -File |
    Where-Object { $_.Extension -in @(".py", ".js", ".html", ".css") }

foreach ($File in $RenameTargets) {
    $Text = [System.IO.File]::ReadAllText($File.FullName)
    $Updated = $Text.
        Replace("Movie Collection Import Manager", "Import Manager").
        Replace("TV Season Pack Import Manager", "Import Manager").
        Replace("Multi-Item Import Manager", "Import Manager")

    if ($Updated -ne $Text) {
        Write-Utf8NoBom -Path $File.FullName -Content $Updated
        Write-Ok "Renamed titles in $($File.FullName.Replace($ProjectRoot + '\', ''))"
    }
}

Write-Step "Writing quality detection service"
$QualityPy = @'
import re
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional

from app.services.utils import find_videos


MISSING = {
    "score": 0,
    "summary": "Unknown quality",
    "tags": [],
    "resolution": "",
    "source": "",
    "codec": "",
    "hdr": "",
    "audio": "",
    "confidence": "low",
}


RESOLUTION_RULES = [
    (re.compile(r"\b(4320p|8k)\b", re.I), "8K", 700),
    (re.compile(r"\b(2160p|4k|uhd)\b", re.I), "2160p", 520),
    (re.compile(r"\b1080p\b", re.I), "1080p", 340),
    (re.compile(r"\b720p\b", re.I), "720p", 220),
    (re.compile(r"\b(576p|480p|dvdrip)\b", re.I), "480p", 120),
]

SOURCE_RULES = [
    (re.compile(r"\b(remux|bdremux)\b", re.I), "Remux", 95),
    (re.compile(r"\b(bluray|blu-ray|bdrip|brrip)\b", re.I), "BluRay", 75),
    (re.compile(r"\b(web[- ._]?dl|webdl)\b", re.I), "WEB-DL", 62),
    (re.compile(r"\bwebrip\b", re.I), "WEBRip", 50),
    (re.compile(r"\bhdtv\b", re.I), "HDTV", 38),
    (re.compile(r"\b(hdrip|dvdrip)\b", re.I), "Rip", 28),
]

CODEC_RULES = [
    (re.compile(r"\b(av1)\b", re.I), "AV1", 42),
    (re.compile(r"\b(hevc|h[ ._]?265|x265)\b", re.I), "HEVC", 36),
    (re.compile(r"\b(h[ ._]?264|x264)\b", re.I), "H.264", 22),
]

HDR_RULES = [
    (re.compile(r"\b(dolby[ ._]?vision|dv)\b", re.I), "Dolby Vision", 40),
    (re.compile(r"\b(hdr10\+|hdr10|hdr)\b", re.I), "HDR", 30),
]

AUDIO_RULES = [
    (re.compile(r"\batmos\b", re.I), "Atmos", 28),
    (re.compile(r"\btruehd\b", re.I), "TrueHD", 26),
    (re.compile(r"\bdts[- ._]?hd\b", re.I), "DTS-HD", 22),
    (re.compile(r"\bdts\b", re.I), "DTS", 16),
    (re.compile(r"\bddp|eac3\b", re.I), "DD+", 12),
    (re.compile(r"\bac3\b", re.I), "AC3", 8),
]

CHANNEL_RULES = [
    (re.compile(r"\b7[ ._]1\b", re.I), "7.1", 12),
    (re.compile(r"\b5[ ._]1\b", re.I), "5.1", 8),
]


def _normalize_texts(texts: Iterable[Any]) -> str:
    return " ".join(str(t or "") for t in texts if str(t or "").strip()).replace("_", " ").replace(".", " ")


def _first_match(text: str, rules):
    for pattern, label, score in rules:
        if pattern.search(text):
            return label, score
    return "", 0


def _all_matches(text: str, rules):
    out = []
    seen = set()
    score = 0
    for pattern, label, points in rules:
        if pattern.search(text) and label not in seen:
            seen.add(label)
            out.append(label)
            score += points
    return out, score


def analyze_quality_from_texts(texts: Iterable[Any]) -> Dict[str, Any]:
    text = _normalize_texts(texts)
    if not text.strip():
        return dict(MISSING)

    resolution, resolution_score = _first_match(text, RESOLUTION_RULES)
    source, source_score = _first_match(text, SOURCE_RULES)
    codec, codec_score = _first_match(text, CODEC_RULES)
    hdr_tags, hdr_score = _all_matches(text, HDR_RULES)
    audio_tags, audio_score = _all_matches(text, AUDIO_RULES)
    channel_tags, channel_score = _all_matches(text, CHANNEL_RULES)

    tags: List[str] = []
    for value in [resolution, source, codec] + hdr_tags + audio_tags + channel_tags:
        if value and value not in tags:
            tags.append(value)

    score = resolution_score + source_score + codec_score + hdr_score + audio_score + channel_score

    if not tags:
        return dict(MISSING)

    signal_count = sum(1 for value in [resolution, source, codec] if value) + len(hdr_tags) + len(audio_tags) + len(channel_tags)
    confidence = "high" if signal_count >= 3 else ("medium" if signal_count >= 2 else "low")

    return {
        "score": int(score),
        "summary": " ".join(tags) if tags else "Unknown quality",
        "tags": tags,
        "resolution": resolution,
        "source": source,
        "codec": codec,
        "hdr": ", ".join(hdr_tags),
        "audio": ", ".join(audio_tags + channel_tags),
        "confidence": confidence,
    }


def quality_for_planned_items(source: Any, planned_items: Optional[List[Dict[str, Any]]] = None) -> Dict[str, Any]:
    texts: List[str] = [Path(str(source or "")).name]
    for item in planned_items or []:
        try:
            src = Path(str(item.get("src") or ""))
            texts.append(src.name)
            if src.parent:
                texts.append(src.parent.name)
        except Exception:
            pass

    quality = analyze_quality_from_texts(texts)
    quality["path"] = str(source or "")
    return quality


def quality_for_library_match(library_match: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    if not library_match:
        return dict(MISSING)

    path = library_match.get("season_path") or library_match.get("path") or ""
    texts: List[str] = [
        library_match.get("title", ""),
        Path(str(path or "")).name,
    ]

    try:
        p = Path(str(path or ""))
        if p.exists():
            if p.is_file():
                texts.append(p.name)
            else:
                videos = find_videos(p)
                texts.extend(str(v.name) for v in videos[:20])
    except Exception:
        pass

    quality = analyze_quality_from_texts(texts)
    quality["path"] = str(path or "")
    return quality


def compare_quality(incoming: Dict[str, Any], existing: Dict[str, Any], library_match: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    incoming_score = int((incoming or {}).get("score") or 0)
    existing_score = int((existing or {}).get("score") or 0)

    if not library_match:
        return {
            "level": "new",
            "label": "New import",
            "recommendation": "No existing library item was found.",
            "score_delta": incoming_score,
        }

    if not incoming_score or not existing_score:
        return {
            "level": "unknown",
            "label": "Quality review",
            "recommendation": "Existing or incoming quality could not be detected from filename signals.",
            "score_delta": incoming_score - existing_score,
        }

    delta = incoming_score - existing_score

    if delta >= 80:
        return {
            "level": "upgrade",
            "label": "Upgrade candidate",
            "recommendation": "Incoming quality appears higher than the existing library item. This release remains non-destructive.",
            "score_delta": delta,
        }

    if delta <= -80:
        return {
            "level": "downgrade",
            "label": "Lower quality",
            "recommendation": "Incoming quality appears lower than the existing library item.",
            "score_delta": delta,
        }

    return {
        "level": "similar",
        "label": "Similar quality",
        "recommendation": "Incoming and existing quality appear similar based on filename signals.",
        "score_delta": delta,
    }


def quality_advice_for_import(source: Any, planned_items: Optional[List[Dict[str, Any]]] = None, library_match: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    incoming = quality_for_planned_items(source, planned_items)
    existing = quality_for_library_match(library_match)
    comparison = compare_quality(incoming, existing, library_match)

    return {
        "incoming": incoming,
        "existing": existing,
        "comparison": comparison,
        "summary": f"Incoming: {incoming.get('summary', 'Unknown quality')} | Existing: {existing.get('summary', 'Unknown quality') if library_match else 'Not found'}",
    }
'@

Write-TextFile -RelativePath "app\services\quality.py" -Content $QualityPy

Write-Step "Patching multi_import.py smart status engine"
$MultiPath = "app\services\multi_import.py"
$Multi = Read-TextFile $MultiPath

if ($Multi -notmatch 'from app\.services\.quality import quality_advice_for_import') {
    if ($Multi -match 'from app\.services\.tmdb import tmdb_search_with_imdb') {
        $Multi = $Multi.Replace(
            "from app.services.tmdb import tmdb_search_with_imdb",
            "from app.services.tmdb import tmdb_search_with_imdb`nfrom app.services.quality import quality_advice_for_import"
        )
        Write-Ok "Added quality service import"
    } else {
        Fail "Could not find TMDb import in app\services\multi_import.py. Not safe to patch."
    }
}

if ($Multi -notmatch 'quality_advice_for_import\(row\.get\("source"') {
    $OldCall = @'
        row_status = _status_from_plan(row, planned_items, library_match, error)
        row.update(row_status)
        row["destination"] = destination
'@

    $NewCall = @'
        quality = quality_advice_for_import(row.get("source", ""), planned_items, library_match)
        row_status = _status_from_plan(row, planned_items, library_match, quality=quality, error=error)
        row.update(row_status)
        row["quality"] = quality
        row["destination"] = destination
'@

    if ($Multi.Contains($OldCall)) {
        $Multi = $Multi.Replace($OldCall, $NewCall)
        Write-Ok "Connected quality analysis to multi-row preview"
    } else {
        # Some later builds may already use keyword args or have the advisor-pack shape.
        if ($Multi -notmatch 'row\["quality"\]\s*=\s*quality') {
            Fail "Could not safely connect quality analysis in multi_import.py. Expected v3.6.0.1 preview call shape was not found."
        }
    }
}

if ($Multi -notmatch 'def _legacy_status_from_plan\(') {
    if ($Multi -match 'def _status_from_plan\(') {
        $Multi = [regex]::Replace($Multi, 'def _status_from_plan\(', 'def _legacy_status_from_plan(', 1)
        Write-Ok "Preserved previous status function as _legacy_status_from_plan"
    } else {
        Fail "Could not find _status_from_plan in app\services\multi_import.py"
    }
}

if ($Multi -notmatch 'def _smart_import_status_card\(') {
    $SmartStatusPy = @'

def _quality_summary(quality_part: Optional[Dict[str, Any]]) -> str:
    quality_part = quality_part or {}
    summary = str(quality_part.get("summary") or "").strip()
    if summary and summary.lower() != "unknown quality":
        return summary
    tags = quality_part.get("tags") or []
    if tags:
        return " ".join(str(tag) for tag in tags if str(tag).strip())
    return ""


def _confidence_percent(row: Dict[str, Any]) -> Optional[int]:
    for key in ("match_confidence", "match_score"):
        value = row.get(key)
        if value in ("", None):
            continue
        try:
            number = int(float(value))
            if number > 100:
                # Older local TMDb scores can exceed 100. Clamp for display.
                number = 100
            if number < 0:
                number = 0
            return number
        except Exception:
            continue
    return None


def _status_card(state: str, icon: str, label: str, lines: List[str]) -> Dict[str, Any]:
    clean_lines = []
    for line in lines or []:
        text = str(line or "").strip()
        if text and text not in clean_lines:
            clean_lines.append(text)

    return {
        "state": state,
        "icon": icon,
        "label": label,
        "lines": clean_lines,
    }


def _match_line(row: Dict[str, Any]) -> str:
    confidence = _confidence_percent(row)
    if row.get("imdb_id"):
        return f"Auto matched ({confidence}%)" if confidence is not None else "Auto matched"
    if row.get("match_status"):
        return str(row.get("match_status"))
    return "Metadata pending"


def _smart_import_status_card(
    row: Dict[str, Any],
    result: Dict[str, Any],
    planned_items: List[Dict[str, Any]],
    library_match: Optional[Dict[str, Any]],
    quality: Optional[Dict[str, Any]] = None,
    error: str = "",
) -> Dict[str, Any]:
    quality = quality or {}
    comparison = quality.get("comparison") or {}
    incoming = quality.get("incoming") or {}
    existing = quality.get("existing") or {}

    label = str((result or {}).get("status_label") or row.get("match_status") or "").strip()
    level = str((result or {}).get("status_level") or row.get("match_level") or "").strip().lower()
    comparison_level = str(comparison.get("level") or "").strip().lower()
    confidence = _confidence_percent(row)

    incoming_summary = _quality_summary(incoming)
    existing_summary = _quality_summary(existing)

    destination_existing = []
    for item in planned_items or []:
        try:
            if Path(item.get("dst", "")).exists():
                destination_existing.append(item)
        except Exception:
            pass

    if error or level == "error":
        return _status_card(
            "blocked",
            "⚫",
            "Blocked",
            [
                str(error or label or "Import plan failed"),
                "Manual review required",
            ],
        )

    if not row.get("enabled", True):
        return _status_card(
            "blocked",
            "⚫",
            "Skipped",
            [
                "Row unchecked",
                "Will not import",
            ],
        )

    if comparison_level == "upgrade" or "upgrade" in label.lower():
        return _status_card(
            "upgrade",
            "🔵",
            "Upgrade",
            [
                f"Existing: {existing_summary}" if existing_summary else "Existing item found",
                f"Incoming: {incoming_summary}" if incoming_summary else "Incoming quality appears higher",
                "Non-destructive review",
            ],
        )

    if level == "duplicate" or "duplicate" in label.lower() or (
        planned_items and len(destination_existing) == len(planned_items)
    ):
        return _status_card(
            "duplicate",
            "🔴",
            "Duplicate",
            [
                "Already exists in library",
                f"Existing: {existing_summary}" if existing_summary else "",
                f"Incoming: {incoming_summary}" if incoming_summary else "",
            ],
        )

    alternatives = row.get("alternatives") or []
    needs_review_lines = []

    if alternatives:
        needs_review_lines.append(f"{len(alternatives) + 1} TMDb matches found")

    if confidence is not None and confidence < 90:
        needs_review_lines.append(f"Match confidence {confidence}%")

    if comparison_level in {"downgrade", "unknown", "similar"} and library_match:
        if comparison_level == "downgrade":
            needs_review_lines.append("Incoming may be lower quality")
        elif comparison_level == "unknown":
            needs_review_lines.append("Quality could not be confirmed")
        else:
            needs_review_lines.append("Existing library item found")

    if level in {"warning", "attention"}:
        needs_review_lines.append(label or "Review recommended")

    if not row.get("imdb_id"):
        needs_review_lines.append("IMDb ID missing")

    if needs_review_lines:
        return _status_card(
            "needs_review",
            "🟡",
            "Needs Review",
            needs_review_lines,
        )

    media_type = row.get("media_type") or "movie"
    return _status_card(
        "ready",
        "🟢",
        "Ready",
        [
            _match_line(row),
            "New movie" if media_type == "movie" else "New TV item",
            "Destination available",
        ],
    )


def _status_from_plan(
    row: Dict[str, Any],
    planned_items: List[Dict[str, Any]],
    library_match: Optional[Dict[str, Any]],
    quality: Optional[Dict[str, Any]] = None,
    error: str = "",
) -> Dict[str, Any]:
    try:
        result = _legacy_status_from_plan(row, planned_items, library_match, quality=quality, error=error)
    except TypeError:
        result = _legacy_status_from_plan(row, planned_items, library_match, error)

    result = dict(result or {})
    card = _smart_import_status_card(
        row=row,
        result=result,
        planned_items=planned_items,
        library_match=library_match,
        quality=quality or {},
        error=error,
    )

    result["status_card"] = card
    result["status_state"] = card.get("state")
    result["status_icon"] = card.get("icon")
    result["status_lines"] = card.get("lines", [])
    return result

'@

    if ($Multi.Contains("def preview_multi_rows(")) {
        $Multi = $Multi.Replace("def preview_multi_rows(", $SmartStatusPy + "def preview_multi_rows(")
        Write-Ok "Inserted smart status wrapper"
    } else {
        Fail "Could not find preview_multi_rows in app\services\multi_import.py"
    }
}

Write-TextFile -RelativePath $MultiPath -Content $Multi

Write-Step "Patching app.js smart status cards"
$AppJsPath = "app\static\app.js"
$AppJs = Read-TextFile $AppJsPath

if ($AppJs -notmatch 'function renderSmartImportStatus\(') {
    $SmartStatusJs = @'

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
      icon: "⚫",
      label: "Blocked",
      lines: [row.error || statusLabel || "Import plan failed", "Manual review required"],
    };
  }

  if (row.enabled === false) {
    return {
      state: "blocked",
      icon: "⚫",
      label: "Skipped",
      lines: ["Row unchecked", "Will not import"],
    };
  }

  if (comparisonLevel === "upgrade" || statusLabel.toLowerCase().includes("upgrade")) {
    return {
      state: "upgrade",
      icon: "🔵",
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
      icon: "🔴",
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
      icon: "🟡",
      label: "Needs Review",
      lines: reviewLines,
    };
  }

  return {
    state: "ready",
    icon: "🟢",
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
  const icon = card.icon || "⚫";
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

'@

    if ($AppJs.Contains("function schedulePreview()")) {
        $AppJs = $AppJs.Replace("function schedulePreview()", $SmartStatusJs + "function schedulePreview()")
        Write-Ok "Inserted smart status JavaScript helpers"
    } else {
        Fail "Could not find schedulePreview in app\static\app.js"
    }
}

$InitialStatusOld = '<span class="status-chip advisor-chip ${statusClass} multi-status" data-row-id="${escapeHtml(row.row_id)}">${escapeHtml(row.status_label || row.match_status || "Ready")}</span>'
$InitialStatusNew = '${renderSmartImportStatus(row)}'

if ($AppJs.Contains($InitialStatusOld)) {
    $AppJs = $AppJs.Replace($InitialStatusOld, $InitialStatusNew)
    Write-Ok "Updated initial table status renderer"
} elseif ($AppJs -notmatch 'renderSmartImportStatus\(row\)') {
    Fail "Could not find the initial multi-status table renderer in app.js"
}

$StatusBlockPattern = '(?s)const status = tr\.querySelector\("\.multi-status"\);\s*if \(status\) \{\s*status\.textContent = row\.status_label \|\| row\.match_status \|\| "Ready";\s*status\.className = `status-chip advisor-chip \$\{multiStatusClass\(row\.status_level \|\| row\.match_level\)\} multi-status`;\s*\}'
$StatusBlockReplacement = @'
const status = tr.querySelector(".multi-status");
    if (status) {
      status.outerHTML = renderSmartImportStatus(row);
    }
'@

$UpdatedAppJs = [regex]::Replace($AppJs, $StatusBlockPattern, $StatusBlockReplacement)
if ($UpdatedAppJs -ne $AppJs) {
    $AppJs = $UpdatedAppJs
    Write-Ok "Updated live preview status renderer"
} elseif ($AppJs -notmatch 'status\.outerHTML = renderSmartImportStatus\(row\)') {
    Fail "Could not find the live multi-status update block in app.js"
}

$AppJs = $AppJs.Replace('v3.6.0.1', 'v3.6.1.0').Replace('v3.6.1</span>', 'v3.6.1.0</span>')

Write-TextFile -RelativePath $AppJsPath -Content $AppJs

Write-Step "Appending smart status CSS"
$StylePath = "app\static\style.css"
$Style = Read-TextFile $StylePath

if ($Style -notmatch 'v3\.6\.1\.0 Smart Status Cards') {
    $StyleAdd = @'

/* v3.6.1.0 Smart Status Cards */
.smart-status-card {
  display: inline-block;
  min-width: 168px;
  max-width: 230px;
  padding: 8px 9px;
  border-radius: 12px;
  border: 1px solid #343a49;
  background: #0c1119;
  line-height: 1.25;
  text-align: left;
  white-space: normal;
  box-shadow: inset 0 1px 0 rgba(255,255,255,.035);
}

.smart-status-title {
  display: flex;
  align-items: center;
  gap: 6px;
  margin-bottom: 4px;
  color: #f5f7fb;
  font-weight: 950;
  white-space: nowrap;
}

.smart-status-icon {
  font-size: 15px;
  line-height: 1;
}

.smart-status-line {
  color: #b8c2d4;
  font-size: 11px;
  font-weight: 700;
  overflow-wrap: anywhere;
}

.smart-status-ready {
  border-color: #2dbd6e;
  background: linear-gradient(135deg, #102318, #0c1119 74%);
}

.smart-status-ready .smart-status-line {
  color: #a5f0bd;
}

.smart-status-needs_review {
  border-color: #ffcc66;
  background: linear-gradient(135deg, #2a2212, #0c1119 74%);
}

.smart-status-needs_review .smart-status-line {
  color: #ffdd99;
}

.smart-status-duplicate {
  border-color: #d85050;
  background: linear-gradient(135deg, #2a1414, #0c1119 74%);
}

.smart-status-duplicate .smart-status-line {
  color: #ffaaa7;
}

.smart-status-upgrade {
  border-color: #5b7cff;
  background: linear-gradient(135deg, #141d3a, #0c1119 74%);
}

.smart-status-upgrade .smart-status-line {
  color: #aebdff;
}

.smart-status-blocked {
  border-color: #7c8494;
  background: linear-gradient(135deg, #1b1f28, #0c1119 74%);
}

.smart-status-blocked .smart-status-line {
  color: #c5ccd8;
}

.multi-status-cell {
  vertical-align: top;
}

.multi-status-cell .multi-badge-row {
  margin-top: 6px;
}

@media (max-width: 720px) {
  .smart-status-card {
    min-width: 145px;
    max-width: none;
  }
}
/* end v3.6.1.0 Smart Status Cards */
'@
    $Style = $Style.TrimEnd() + "`r`n" + $StyleAdd.TrimStart("`r", "`n") + "`r`n"
    Write-Ok "Added smart status CSS"
} else {
    Write-Ok "Smart status CSS already present"
}

Write-TextFile -RelativePath $StylePath -Content $Style

Write-Step "Updating DEVELOPMENT.md"
$DevelopmentPath = Join-Path $ProjectRoot "DEVELOPMENT.md"
if (!(Test-Path $DevelopmentPath)) {
    Write-Utf8NoBom -Path $DevelopmentPath -Content "# NASDY Media Linker Development Notes`r`n"
}

$Development = [System.IO.File]::ReadAllText($DevelopmentPath)
if ($Development -notmatch 'v3\.6\.1\.0 App Smart Status') {
    $DevelopmentAdd = @'

## v3.6.1.0 App Smart Status

This release is application-only. It intentionally does not change the Deploy v2 foundation.

Changes:
- Renames Import Manager headings to the generic `Import Manager`.
- Adds `app/services/quality.py` for filename-based incoming vs existing quality scoring.
- Adds structured `status_card` data to multi-import rows.
- Renders smart status cards in the Import Manager table:
  - 🟢 Ready
  - 🟡 Needs Review
  - 🔴 Duplicate
  - 🔵 Upgrade
  - ⚫ Blocked
- Keeps upgrade detection non-destructive. It identifies upgrade candidates but does not replace existing library files automatically.

Testing expectations:
- Existing same/similar item should show Duplicate or Needs Review.
- Existing lower-quality item with higher-quality incoming file should show Upgrade.
- Missing metadata or failed planning should show Blocked.
- Clean new matched item should show Ready.

'@
    $Development = $Development.TrimEnd() + "`r`n" + $DevelopmentAdd.TrimStart("`r", "`n")
    Write-Utf8NoBom -Path $DevelopmentPath -Content $Development
    Write-Ok "Updated DEVELOPMENT.md"
} else {
    Write-Ok "DEVELOPMENT.md already has v3.6.1.0 notes"
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
Write-Host "  2. Open a movie collection"
Write-Host "  3. Confirm heading says Import Manager"
Write-Host "  4. Confirm Status column shows smart cards"
Write-Host ""
Write-Host "Suggested commit:"
Write-Host '  git add app/config.py app/services/multi_import.py app/services/quality.py app/static/app.js app/static/style.css DEVELOPMENT.md'
Write-Host '  git commit -m "Add smart Import Manager status cards"'
Write-Host ""
