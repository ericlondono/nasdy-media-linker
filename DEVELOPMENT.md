# NASDY Media Linker Development Notes

## Current Stable Versions

```text
App version:       v3.6.3.0
Deploy version:    Deploy v3.0.1
Development guide: v3.6.3.1
```

## Current Release Target

```text
Current app stable:          v3.6.3.0
Next app test candidate:      v3.6.3.0
Current deploy stable:       Deploy v3.0.1
Next app release target:     v3.6.3.0 Hardlink Reconciliation
Next infrastructure target:  None unless a deploy bug is found
```

## Core Workflow Rules

- Eric does not manually edit code files.
- All code changes should be delivered as runnable PowerShell upgrade scripts or generated full replacement files.
- Upgrade scripts should create backups before changing files.
- Docker Desktop is not used locally.
- Docker images are built directly on the unRAID NAS over SSH.
- Deployment uses `root@NASDY`.
- Normal deploys should use one command from the project root: `.\Deploy.ps1`.
- Prefer boring, repeatable deployment over clever one-off fixes.
- Avoid manual instructions like "open this file and change this line."

## Local Project Path

```text
C:\Projects\nasdy-media-linker
```

## NAS Paths

```text
Remote app path:
/mnt/user/appdata/nasdy-media-organizer

Downloads:
/mnt/user/NASDY/downloads

Media:
/mnt/user/NASDY/media

App data:
/mnt/user/appdata/nasdy-media-organizer/data

Required host mount:
/mnt:/host_mnt
```

## Docker

```text
Container:
nasdy-media-organizer

Image:
nasdy-media-linker:latest

Port:
8088
```

## Required Docker Run Mounts

```bash
-v /mnt/user/NASDY/downloads:/downloads
-v /mnt/user/NASDY/media:/media
-v /mnt/user/appdata/nasdy-media-organizer/data:/app/data
-v /mnt:/host_mnt
```

## Current Deployment Source of Truth

Normal deployment command:

```powershell
cd C:\Projects\nasdy-media-linker
powershell -ExecutionPolicy Bypass -File .\Deploy.ps1
```

Deploy v3.0.1 is the stable deployment foundation.

Confirmed behavior:

- SSH key authentication works for `root@NASDY`.
- The expected private key path is `%USERPROFILE%\.ssh\nasdy_ed25519`.
- Deployments should not prompt for the NAS password after SSH key setup is complete.
- Password-based SSH is still preserved as a fallback and should not be removed unless intentionally changed later.
- Docker images are built directly on the unRAID NAS over SSH.
- Docker Desktop is not used locally.
- Deployment always includes `/mnt:/host_mnt`.
- Deployment verifies `/host_mnt` inside the running container.
- Deployment verifies `http://127.0.0.1:8088/health`.
- Deploy v3.0.1 uses LF-safe script handling to prevent Windows CRLF shell failures.
- The deployment output should end with the clean Deploy v3.0.1 success banner.

Expected final deploy banner:

```text
====================================
 NASDY Deploy v3.0.1 Complete
====================================
[OK] SSH authentication path selected
[OK] Source synced
[OK] Docker built and container restarted
[OK] /host_mnt verified
[OK] /health verified
```

## Deploy v3.0.1 Architecture

Deployment is split into three files:

```text
Setup-NASDY-SSHKey.ps1  - Windows helper for creating/testing SSH key auth
Deploy.ps1              - Windows/PowerShell deployment orchestrator
.deploy.sh              - NAS/Linux Docker deployment script
```

This prevents PowerShell from trying to interpret Bash/Linux commands like `seq`, `docker`, or `curl`.

Deploy v3.0.1 responsibilities:

1. Back up the local project.
2. Clean local `__pycache__`, `.pyc`, and `.pyo` files.
3. Package source files only.
4. Exclude `.git`, `backups`, cache folders, logs, and generated files.
5. Use SSH-key auth automatically when available.
6. Fall back to password SSH if key auth is not ready.
7. Send the source package to NASDY over SSH.
8. Extract to `/mnt/user/appdata/nasdy-media-organizer`.
9. Build Docker image on the NAS.
10. Restart the `nasdy-media-organizer` container.
11. Always include `/mnt:/host_mnt`.
12. Verify `/host_mnt` exists inside the container.
13. Verify `/health`.
14. Print a clean success summary.

## SSH Key Authentication

Deploy v3 uses a Windows SSH key:

```text
%USERPROFILE%\.ssh\nasdy_ed25519
```

The matching public key is installed on NASDY at:

```text
/root/.ssh/authorized_keys
```

Setup command:

```powershell
cd C:\Projects\nasdy-media-linker
powershell -ExecutionPolicy Bypass -File .\Setup-NASDY-SSHKey.ps1
```

Important rules:

- Do not commit private key files to Git.
- Do not hard-code private key contents into project files.
- `Deploy.ps1` should reference only the private key path.
- Do not remove password-based SSH until key-based SSH has been tested.
- Password SSH is currently preserved as a fallback.

## Known Completed Infrastructure

- One-command deploy with `Deploy.ps1`.
- Passwordless SSH key auth from Windows to NASDY.
- Automatic local backup before deployment.
- Automatic Python cache cleanup before packaging.
- Source-only deployment package creation.
- Deployment package excludes `.git`, backups, logs, cache folders, and generated files.
- Source sync to `/mnt/user/appdata/nasdy-media-organizer`.
- NAS-side Docker image build.
- Automatic container restart for `nasdy-media-organizer`.
- Required Docker mounts verified, including `/mnt:/host_mnt`.
- `/health` verification confirmed.
- CRLF-safe Deploy v3.0.1 flow confirmed.
- Docker Desktop is not required locally.

## Release Process

1. Create a new Git branch.
2. Create an upgrade script for the version.
3. Backup project automatically.
4. Apply file changes automatically.
5. Clean Python cache files.
6. Build Docker image on NAS over SSH with `.\Deploy.ps1`.
7. Restart container through Deploy v3.0.1.
8. Verify `/health`.
9. Confirm UI behavior.
10. Commit and tag the release.

Recommended Deploy v3.0.1 milestone commands:

```powershell
git add .
git commit -m "Deploy v3.0.1 - stable SSH key deployment"
git tag deploy-v3.0.1
```

## Coding Preferences

- Prefer full replacement files or automated patch scripts.
- Avoid manual instructions like "open this file and change this line."
- Keep UI clean, readable, compact, and dark-theme friendly.
- Avoid breaking working import behavior while polishing UI.
- Preserve multi-movie collection behavior.
- Preserve individual editable movie rows.
- Preserve TMDb / IMDb auto matching.
- Preserve hard-link engine behavior.
- Avoid visible emoji in UI status labels because some browser/static-file combinations rendered emoji as mojibake.
- Prefer CSS dots/icons for status indicators.

## UI Naming

Use:

```text
Import Manager
```

Do not use:

```text
Movie Collection Import Manager
```

## Architecture Overview

NASDY Media Linker is a local utility app for reviewing completed downloads, correcting movie/show metadata, and creating hard links into the media library.

High-level flow:

```text
qBittorrent downloads
        |
        v
NASDY Media Linker queue
        |
        v
Import Manager review
        |
        v
TMDb / IMDb match
        |
        v
Hard link into media library
        |
        v
Jellyfin scans final library path
```

## Design Philosophy

The goal of NASDY Media Linker is to automate repetitive work while keeping the user in control of decisions.

Automation should eliminate unnecessary clicks and typing, but should never silently make destructive decisions.

Examples:

- Automatically detect Movie vs TV.
- Automatically detect IMDb/TMDb IDs.
- Automatically detect upgrades.
- Automatically detect duplicates.
- Allow the user to override any automatic decision.
- Prefer review over guessing when confidence is low.
- Keep imports non-destructive unless the user explicitly chooses otherwise.
- Make deployment boring, repeatable, and easy to verify.

## Known Good Behavior as of v3.6.2.2

- Multi-movie collections are detected.
- Each movie gets its own editable row.
- Direct folders of movie files are split into one Import Manager row per movie.
- TMDb automatically finds IMDb IDs.
- Individual IMDb/TMDb fields are available per split movie row.
- Mixed movie/TV packs can route movies and TV episodes separately.
- TV seasons and legacy episode patterns such as `5x01` are parsed.
- Manual downloads scan can discover files/folders not represented by qBittorrent.
- Active/incomplete qBittorrent downloads are hidden from manual scan.
- Manual scan items that match completed qBittorrent torrents adopt qBittorrent state metadata.
- The hard-link engine works.
- `/mnt:/host_mnt` is required and verified for host path resolution.

## Smart Status States

Status card states:

```text
Ready
Auto matched
New item
Destination available
```

```text
Needs Review
Multiple metadata matches found or confidence is low
```

```text
Duplicate
Already exists in library
```

```text
Upgrade
Existing quality is lower than incoming quality
```

```text
Blocked
Missing data or destination unavailable
```

Implementation note:

- Do not rely on Unicode emoji for these labels.
- Use CSS dots or plain labels for reliable rendering.

## Project Milestones

### Deploy v3.0.1 - Stable SSH Key Deployment

Status: Complete.

This milestone established the permanent deployment foundation for NASDY Media Linker:

- `Setup-NASDY-SSHKey.ps1` creates/validates the Windows SSH deploy key.
- `Deploy.ps1` performs the normal full deployment.
- `.deploy.sh` performs the NAS/Linux Docker deployment work.
- SSH key authentication is preferred automatically.
- Password SSH fallback remains available if key auth is not ready.
- Remote deployment is LF-safe and no longer fails from Windows CRLF endings.
- The verified successful deployment showed:
  - Docker image built successfully.
  - Container restarted successfully.
  - `/host_mnt` verified successfully.
  - `/health` verified successfully.
  - App returned version `v3.6.2.2`.

## App Release Notes

### v3.6.1.0 App Smart Status

Changes:

- Renamed Import Manager headings to the generic `Import Manager`.
- Added `app/services/quality.py` for filename-based incoming vs existing quality scoring.
- Added structured `status_card` data to multi-import rows.
- Rendered smart status cards in the Import Manager table:
  - Ready
  - Needs Review
  - Duplicate
  - Upgrade
  - Blocked
- Kept upgrade detection non-destructive.

Testing expectations:

- Existing same/similar item should show Duplicate or Needs Review.
- Existing lower-quality item with higher-quality incoming file should show Upgrade.
- Missing metadata or failed planning should show Blocked.
- Clean new matched item should show Ready.

### v3.6.1.1 Status Icons and Collapsed Import History

Changes:

- Replaced visible Unicode emoji status icons with CSS status dots.
- Kept backend status states the same: ready, needs_review, duplicate, upgrade, blocked.
- Collapsed Import History by default so the Import Manager can use more horizontal space.
- Added an `Import History` rail button to expand the history panel.
- Added a `Collapse` button inside Import History to return to the wider Import Manager layout.

Reason:

Some static-file/browser combinations rendered emoji as mojibake. CSS dots are more reliable, cleaner, and easier to theme.

### v3.6.1.2 Status Width and History Toggle Fixes

Fixes:

- Smart status cards are constrained to the Status column and no longer grow off the right side of the Import Manager pane.
- Status card detail lines truncate with ellipses instead of forcing the table wider.
- Import History button remains visible after expanding so the user can hide the panel again.
- Import History expansion explicitly restores the panel display so it does not open as a blank right pane.
- Collapsed-by-default behavior is preserved.

### v3.6.1.3 Emergency Import History Recovery

Problem:

- The Import History collapse script used heading/ancestor detection.
- On the live layout it could hide the wrong parent container.
- The app appeared as a blank page with only the floating Import History button visible.

Fix:

- Removed the unsafe runtime Import History collapse script.
- Hid the floating Import History controls.
- Forced the Import History panel/layout classes visible again.
- Preserved the smart status-card UI and status-width fixes.

Next:

- Rebuild Import History collapse using explicit template markup/classes instead of DOM guessing.

### v3.6.1.4 Mixed Media Routing

Changes:

- Multi-import rows can now change media type after metadata resolution.
- Pasted IMDb IDs, TMDb URLs, or TMDb numeric IDs are resolved during multi-preview even when automatic search is otherwise off.
- Automatic TMDb matching searches both movie and TV endpoints, then routes the row based on the best metadata match.
- Filesystem episode patterns can route a row to TV even without TMDb.
- TV source folders with multiple seasons now plan each file into its detected season folder instead of forcing everything into Season 01.
- Browser row state now preserves backend media-type changes so final import uses the corrected movie/TV route.

Expected behavior:

- Movie rows import under `/media/movies`.
- TV rows import under `/media/tv`.
- Mixed collections such as Stargate packs can import movies and TV shows from the same source folder.

### v3.6.1.5 TV Season and Episode Title Fix

Problem:

- TV shows routed correctly to `/media/tv`, but some S02 files were still renamed into `Season 01` / `S01Exx`.
- Season values like `S02` could fail numeric conversion and fall back to `01`.
- Episode titles such as `Duet` were also dropped from the output filename.

Changes:

- Added robust TV season normalization for `S02E04`, `S02`, `Season 2`, and `2`.
- Detected each TV file's season from the filename before using the row fallback season.
- Preserved episode titles from source filenames when available.

Example output:

```text
/media/tv/Stargate Atlantis (2004)/Season 02/Stargate Atlantis (2004) - S02E04 - Duet.mkv
```

### v3.6.1.6 Movie Pack Routing Fix

Problem:

- A mixed pack can contain a folder such as `Stargate - The Movies`.
- Because the selected queue item is TV-heavy, rows with no TMDb match and no TV episode pattern could remain marked as TV.
- `build_plan(media_type="tv")` then named movie files as `Season 01 / S01E01`, `S01E02`, etc.

Changes:

- Added movie filename signal detection in `multi_import.py`.
- If a row has no SxxEyy/1x01 TV pattern but has movie-like filename/year signals, it routes as Movie.
- Added direct movie-file collection planning in `linker.py`.
- A folder containing direct movie files such as `Stargate (1994).mkv`, `Stargate Continuum (2008).mkv`, and `Stargate The Ark of Truth (2008).mkv` now plans each file under `/media/movies/<Movie Title (Year)>/`.
- TV episode folders still route as TV because SxxEyy patterns win first.

Expected Stargate result:

- Stargate movie files route to `/media/movies`.
- Stargate Atlantis / SG-1 / Universe episode files route to `/media/tv`.

### v3.6.1.7 TV Branch Movie Pack Guard

Problem:

- v3.6.1.6 added direct movie-file collection planning in the Movie branch.
- Mixed packs could still pass `media_type="tv"` into `build_plan()` for a movie folder such as `Stargate - The Movies`.
- Because the TV branch ran first, those movie files were still converted into `Season 01 / S01E01`, `S01E02`, etc.

Change:

- Added an early guard inside `build_plan()`.
- If a row arrives as TV but the source is clearly a direct folder of movie files, the linker routes it through the movie collection planner before the TV branch runs.

Expected result:

- `Stargate - The Movies` routes to `/media/movies`.
- `Stargate Atlantis`, `SG-1`, `Universe`, and other episode folders still route to `/media/tv`.

### v3.6.1.8 Split Direct Movie Rows

Problem:

- `Stargate - The Movies` was routing to `/media/movies`, but it still appeared as one grouped Import Manager row.
- One grouped row means one IMDb/TMDb field would apply to all three movies.
- The preview could route the files correctly, but the metadata editor could not assign a different ID per movie.

Changes:

- Direct folders of movie files are now split into one Import Manager row per file.
- Each split movie row points directly at its own video file source.
- `build_plan()` now supports a single video file as the source.
- Filename parsing removes year parentheses correctly, preventing destinations like `Stargate ((1994))`.
- TV episode folders are not split because SxxEyy / 1x01 patterns exclude them from movie splitting.

Expected result:

- `Stargate (1994)` gets its own row and IMDb/TMDb field.
- `Stargate Continuum (2008)` gets its own row and IMDb/TMDb field.
- `Stargate The Ark of Truth (2008)` gets its own row and IMDb/TMDb field.
- TV shows such as Atlantis, SG-1, Universe, and Origins remain grouped by show/season rows.

### v3.6.2.0 Manual Downloads Scan

Problem:

- The queue was primarily driven by qBittorrent completed torrents.
- Manually copied files/folders in `/downloads` could be invisible when qBittorrent was enabled.
- Bare files such as `/downloads/Twisters (2024).mkv` were also not guaranteed to become queue items.

Change:

- Added a manual scan source for the root downloads folder.
- When qBittorrent is enabled, the queue shows completed qBittorrent items plus manual files/folders not already represented by qBittorrent.
- When qBittorrent errors, the app falls back to Manual Scan.
- When qBittorrent is disabled, Manual Scan is the queue source.

Manual Scan supports:

- `/downloads/Movie Folder/movie.mkv`
- `/downloads/Movie.mkv`
- `/downloads/TV Show/Season 01/S01E01.mkv`
- `/downloads/Mixed Collection/...`

Manual scan items use:

- `source_kind = manual_folder` for folders.
- `source_kind = manual_file` for bare video files.
- No qBittorrent hash.
- No qBittorrent ratio/state dependency.

Design note:

- This makes NASDY Media Linker a true downloads import manager instead of only a qBittorrent completed-torrent importer.

### v3.6.2.1 Active qBittorrent Guard

Problem:

- Manual Scan made manually copied files/folders visible, but it also saw files that qBittorrent was still actively downloading.
- Those incomplete files should not be importable yet.

Behavior:

- If qBittorrent knows about a torrent and `progress < 1`, Manual Scan hides the matching file/folder.
- If qBittorrent knows about a torrent and it is complete, qBittorrent Completed shows it normally.
- If no qBittorrent torrent matches the file/folder, Manual Scan shows it.

Queue source examples:

- `qBittorrent + Manual Scan (2 manual, 1 active hidden)`
- `qBittorrent`
- `Manual Scan`

Design note:

- Manual Scan should make NASDY Media Linker flexible, not unsafe.
- Incomplete qBittorrent downloads remain hidden until qBittorrent reports them complete.

### v3.6.2.1 Legacy TV Season Parser Fix

Problem:

- Complete-series TV packs such as `Reno 911! Complete` could pollute the show title with pack descriptors.
- Legacy episode names such as `5x01` exposed the episode number but not the season number to the planner, causing files to fall back to `Season 01` / `S01E01`.
- Some Import Manager TV rows could inherit a default season before checking stronger filename signals.

Change:

- Added explicit support for legacy TV patterns such as `5x01`, `05x01`, and `5 x 01` in season and episode parsing.
- Cleaned TV show titles by removing pack descriptors such as `Complete`, `Collection`, `Pack`, season labels, and release words while preserving punctuation from filenames when useful.
- Preferred filename/folder season evidence before defaulting to Season 01.
- Updated the Import Manager version badge to match the backend app version.

Expected Reno 911 result:

- `Reno 911! Complete` imports under `/media/tv/Reno 911!/`.
- `Reno 911 Season 5` and filenames like `Reno 911! - 5x01 - Title.avi` import under `Season 05` as `S05E01`.

### v3.6.2.2 qBittorrent State Annotation

Problem:

- Active qBittorrent downloads were correctly hidden from Manual Scan.
- After completion, some items could still appear through Manual Scan rather than `qbit_completed_items()`.
- Those rows showed `state = manual scan` even though qBittorrent still knew about the torrent.

Behavior:

- If Manual Scan finds a file/folder that matches a completed qBittorrent torrent, the row now adopts qBittorrent metadata:
  - `state`
  - `hash`
  - `ratio`
  - `tracker`
  - `category`
  - `tags`
- Active/incomplete qBittorrent downloads are still hidden.
- Manual files with no qBittorrent match still show as manual.

Expected state examples:

- `uploading`
- `stalledUP`
- `queuedUP`
- `completed`
- `manual scan` only when no qBittorrent torrent matches.

### v3.6.3.0 Hardlink Reconciliation

Problem:

- Queue items could reappear as not imported after deploys or source-key changes.
- Existing protection depended mostly on `imports.json` aliases and history records.
- If tracking aliases were missing or changed, the user had to manually mark already-imported seeding media again.

Changes:

- Added inode/device based hardlink reconciliation.
- NML now scans source video files in `/downloads` and looks for matching hard links under the media library.
- If every source video already has a matching hard link in `/media`, the queue row is automatically marked Imported.
- This comparison uses actual file identity, not title-only matching, so a different release, better resolution, or better audio remains visible for review as a duplicate/upgrade candidate.
- Preview now reports `Already Hard Linked in Library` for auto-reconciled items.

Expected behavior:

- Previously hard-linked torrents remain in the Imported tab after future deploys.
- Manual re-marking should no longer be needed for media that is still truly hard-linked.
- New upgraded files are not hidden unless they are the exact same hard-linked file already present in `/media`.

## Infrastructure Release Notes

### Deploy v3.0.1 Cleanup Release

Infrastructure polish after Deploy v3 SSH-key setup.

Changes:

- Replaced the previous stdin pipe with raw LF-safe SSH script execution.
- Normalized `.deploy.sh` to Unix LF line endings before packaging.
- Converted `.deploy.sh` to LF again on the NAS before execution as a safety net.
- Kept SSH-key authentication through `%USERPROFILE%\.ssh\nasdy_ed25519`.
- Kept password SSH fallback if key-only authentication is not ready.
- Kept Docker build on NASDY, container restart, `/mnt:/host_mnt`, `/host_mnt` verification, and `/health` verification.
- Added a clean Deploy v3.0.1 completion banner.

## Future Chat Startup

At the start of a new ChatGPT conversation, upload this file first.

Then say:

```text
Please use DEVELOPMENT.md as the source of truth for our NASDY Media Linker workflow.
```

## Reminder

For longer coding/debugging sessions:

- Start a new Git branch.
- Start a new ChatGPT conversation when the current one gets too long.

