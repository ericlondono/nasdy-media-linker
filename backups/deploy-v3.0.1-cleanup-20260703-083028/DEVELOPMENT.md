# NASDY Media Linker Development Notes

## Core Workflow Rules

- Eric does not manually edit code files.
- All code changes should be delivered as runnable PowerShell upgrade scripts or generated full replacement files.
- Upgrade scripts should create backups before changing files.
- Docker Desktop is not used locally.
- Docker images are built directly on the unRAID NAS over SSH.
- Deployment uses `root@NASDY`.
- Future deploys should use one command: `.\Deploy.ps1`.

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

## Deployment Flow

Normal deployment command:

```powershell
.\Deploy.ps1
```

The deploy script should:

1. Back up the local project.
2. Clean local `__pycache__` and `.pyc` files.
3. Package source files only.
4. Exclude `.git`, `backups`, cache folders, logs, and generated files.
5. Send the package to NASDY over SSH.
6. Extract to `/mnt/user/appdata/nasdy-media-organizer`.
7. Build Docker image on the NAS.
8. Restart the `nasdy-media-organizer` container.
9. Always include `/mnt:/host_mnt`.
10. Verify `/host_mnt` exists inside the container.
11. Verify `/health`.
12. Print a success summary.

## Release Process

1. Create a new Git branch.
2. Create an upgrade script for the version.
3. Backup project automatically.
4. Apply file changes automatically.
5. Clean Python cache files.
6. Build Docker image on NAS over SSH.
7. Restart container.
8. Verify `/health`.
9. Confirm UI behavior.
10. Commit and tag the release.

## Current Release Target

```text
v3.6.1.0
```

## v3.6.1.0 Goals

1. Create permanent `Deploy.ps1`.
2. Bake `/mnt:/host_mnt` into every deployment.
3. Rename `Movie Collection Import Manager` to `Import Manager`.
4. Add smart import status cards.

## Smart Status Goals

Statuses should become decision cards:

```text
ðŸŸ¢ Ready
Auto matched
New movie
Destination available
```

```text
ðŸŸ¡ Needs Review
Multiple TMDb matches found
```

```text
ðŸ”´ Duplicate
Already exists in library
```

```text
ðŸ”µ Upgrade
Existing quality is lower than incoming quality
```

```text
âš« Blocked
Missing data or destination unavailable
```

## UI Naming

Use:

```text
Import Manager
```

Do not use:

```text
Movie Collection Import Manager
```

## Coding Preferences

- Prefer full replacement files or automated patch scripts.
- Avoid manual instructions like â€œopen this file and change this line.â€
- Keep UI clean, readable, compact, and dark-theme friendly.
- Avoid breaking working import behavior while polishing UI.
- Preserve multi-movie collection behavior.
- Preserve individual editable movie rows.
- Preserve TMDb / IMDb auto matching.
- Preserve hard-link engine behavior.

## Architecture Overview

NASDY Media Linker is a local utility app for reviewing completed downloads, correcting movie/show metadata, and creating hard links into the media library.

High-level flow:

```text
qBittorrent downloads
        â†“
NASDY Media Linker queue
        â†“
Import Manager review
        â†“
TMDb / IMDb match
        â†“
Hard link into media library
        â†“
Jellyfin scans final library path
```

## Known Good Behavior as of v3.6.0.1

- Multi-movie collections are detected.
- Each movie gets its own editable row.
- TMDb automatically finds IMDb IDs.
- The UI is clean and readable.
- The hard-link engine works.
- `/mnt:/host_mnt` is required for host path resolution.

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

## Deploy v2 Architecture

Deployment is split into two files:

```text
Deploy.ps1   - Windows/PowerShell orchestrator
.deploy.sh   - NAS/Linux Docker deployment script
```

This prevents PowerShell from trying to interpret Bash/Linux commands like `seq`, `docker`, or `curl`.

Standard deployment command:

```powershell
cd C:\Projects\nasdy-media-linker
powershell -ExecutionPolicy Bypass -File .\Deploy.ps1
```

Deploy v2 must always:
- Build Docker image on NAS over SSH.
- Restart container `nasdy-media-organizer`.
- Use image `nasdy-media-linker:latest`.
- Expose port `8088`.
- Mount `/mnt:/host_mnt`.
- Verify `/host_mnt` exists inside the container.
- Verify `http://127.0.0.1:8088/health`.
## v3.6.1.0 App Smart Status

This release is application-only. It intentionally does not change the Deploy v2 foundation.

Changes:
- Renames Import Manager headings to the generic `Import Manager`.
- Adds `app/services/quality.py` for filename-based incoming vs existing quality scoring.
- Adds structured `status_card` data to multi-import rows.
- Renders smart status cards in the Import Manager table:
  - ðŸŸ¢ Ready
  - ðŸŸ¡ Needs Review
  - ðŸ”´ Duplicate
  - ðŸ”µ Upgrade
  - âš« Blocked
- Keeps upgrade detection non-destructive. It identifies upgrade candidates but does not replace existing library files automatically.

Testing expectations:
- Existing same/similar item should show Duplicate or Needs Review.
- Existing lower-quality item with higher-quality incoming file should show Upgrade.
- Missing metadata or failed planning should show Blocked.
- Clean new matched item should show Ready.
## v3.6.1.1 Status Icons and Collapsed Import History

Polish release after the first Smart Status deployment.

Changes:
- Replaces visible Unicode emoji status icons with CSS status dots.
- Keeps backend status states the same: ready, needs_review, duplicate, upgrade, blocked.
- Collapses Import History by default so the Import Manager can use more horizontal space.
- Adds an `Import History` rail button to expand the history panel.
- Adds a `Collapse` button inside Import History to return to the wider Import Manager layout.

Reason:
Some static-file/browser combinations rendered emoji as mojibake. CSS dots are more reliable, cleaner, and easier to theme.
## v3.6.1.2 Status Width and History Toggle Fixes

Polish release after v3.6.1.1.

Fixes:
- Smart status cards are constrained to the Status column and no longer grow off the right side of the Import Manager pane.
- Status card detail lines truncate with ellipses instead of forcing the table wider.
- Import History button remains visible after expanding so the user can hide the panel again.
- Import History expansion explicitly restores the panel display so it does not open as a blank right pane.
- Collapsed-by-default behavior is preserved.
## v3.6.1.3 Emergency Import History Recovery

Recovery release after v3.6.1.2.

Problem:
- The Import History collapse script used heading/ancestor detection.
- On the live layout it could hide the wrong parent container.
- The app appeared as a blank page with only the floating Import History button visible.

Fix:
- Removes the unsafe runtime Import History collapse script.
- Hides the floating Import History controls.
- Forces the Import History panel/layout classes visible again.
- Preserves the smart status-card UI and status-width fixes.

Next:
- Rebuild Import History collapse using explicit template markup/classes instead of DOM guessing.
## v3.6.1.4 Mixed Media Routing

This release fixes mixed folders that contain both movies and TV shows.

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
## v3.6.1.5 TV Season and Episode Title Fix

Fix after mixed media routing.

Problem:
- TV shows routed correctly to `/media/tv`, but some S02 files were still renamed into `Season 01` / `S01Exx`.
- The cause was season normalization: values like `S02` could fail numeric conversion and fall back to `01`.
- Episode titles such as `Duet` were also dropped from the output filename.

Changes:
- Adds robust TV season normalization for `S02E04`, `S02`, `Season 2`, and `2`.
- Detects each TV file's season from the filename before using the row fallback season.
- Preserves episode titles from source filenames when available.
- Example output:
  `/media/tv/Stargate Atlantis (2004)/Season 02/Stargate Atlantis (2004) - S02E04 - Duet.mkv`
## v3.6.1.6 Movie Pack Routing Fix

Fix after mixed media routing.

Problem:
- A mixed pack can contain a folder such as `Stargate - The Movies`.
- Because the selected queue item is TV-heavy, rows with no TMDb match and no TV episode pattern could remain marked as TV.
- `build_plan(media_type="tv")` then named movie files as `Season 01 / S01E01`, `S01E02`, etc.

Changes:
- Adds movie filename signal detection in `multi_import.py`.
- If a row has no SxxEyy/1x01 TV pattern but has movie-like filename/year signals, it routes as Movie.
- Adds direct movie-file collection planning in `linker.py`.
- A folder containing direct movie files such as `Stargate (1994).mkv`, `Stargate Continuum (2008).mkv`, and `Stargate The Ark of Truth (2008).mkv` now plans each file under `/media/movies/<Movie Title (Year)>/`.
- TV episode folders still route as TV because SxxEyy patterns win first.

Expected Stargate result:
- Stargate movie files route to `/media/movies`.
- Stargate Atlantis / SG-1 / Universe episode files route to `/media/tv`.
## v3.6.1.7 TV Branch Movie Pack Guard

Fix after v3.6.1.6.

Problem:
- v3.6.1.6 added direct movie-file collection planning in the Movie branch.
- However, mixed packs can still pass `media_type="tv"` into `build_plan()` for a movie folder such as `Stargate - The Movies`.
- Because the TV branch ran first, those movie files were still converted into `Season 01 / S01E01`, `S01E02`, etc.

Change:
- Adds an early guard inside `build_plan()`.
- If a row arrives as TV but the source is clearly a direct folder of movie files, the linker routes it through the movie collection planner before the TV branch runs.

Expected result:
- `Stargate - The Movies` routes to `/media/movies`.
- `Stargate Atlantis`, `SG-1`, `Universe`, and other episode folders still route to `/media/tv`.
## v3.6.1.8 Split Direct Movie Rows

Fix after movie-pack routing.

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

## Future Infrastructure Goals

### Deploy v3 (Planned)

The current `Deploy.ps1` works correctly, but it still requires multiple SSH/SCP operations. When using password authentication, that can cause several password prompts.

The long-term deployment goal is:

- One deployment command:

```powershell
.\Deploy.ps1
```

- Zero manual file copying.
- One SSH session when practical.
- Zero password prompts using SSH key authentication.
- Automatic project backup.
- Automatic source sync.
- Exclude `__pycache__`, `.pyc`, backups, logs, `.git`, and other generated files.
- Build the Docker image directly on the NAS.
- Restart the `nasdy-media-organizer` container.
- Always mount:

```text
/mnt:/host_mnt
```

- Verify `/host_mnt` exists inside the running container.
- Verify the `/health` endpoint.
- Display a clean deployment summary including:
  - Build time
  - Deploy time
  - Health status
  - Container status
  - Image name
  - Container name
  - Active port
  - Required mounts

### SSH Authentication Goal

Future deployments should use SSH key authentication instead of repeated password prompts.

Desired workflow:

1. Configure an SSH key pair on the Windows development workstation.
2. Install the public key on the NAS under:

```text
/root/.ssh/authorized_keys
```

3. Update `Deploy.ps1` to use the key for SSH/SCP commands:

```powershell
ssh -i "$env:USERPROFILE\.ssh\nasdy_ed25519" root@NASDY
scp -i "$env:USERPROFILE\.ssh\nasdy_ed25519"
```

After setup, deployments should require zero password prompts.

The planned Windows setup command is expected to be similar to:

```powershell
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\nasdy_ed25519"
type "$env:USERPROFILE\.ssh\nasdy_ed25519.pub" | ssh root@NASDY "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"
ssh -i "$env:USERPROFILE\.ssh\nasdy_ed25519" root@NASDY "echo SSH key works"
```

Important:
- Do not remove password-based SSH until key-based SSH has been tested.
- Do not hard-code private key contents into any project file.
- Never commit private key files to Git.
- `Deploy.ps1` should reference the private key path only.

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
## v3.6.2.0 Manual Downloads Scan

Problem:
- The queue was primarily driven by qBittorrent completed torrents.
- Manually copied files/folders in `/downloads` could be invisible when qBittorrent was enabled.
- Bare files such as `/downloads/Twisters (2024).mkv` were also not guaranteed to become queue items.

Change:
- Adds a manual scan source for the root downloads folder.
- When qBittorrent is enabled, the queue now shows completed qBittorrent items plus manual files/folders not already represented by qBittorrent.
- When qBittorrent errors, the app falls back to Manual Scan.
- When qBittorrent is disabled, Manual Scan is the queue source.

Manual Scan supports:
- `/downloads/Movie Folder/movie.mkv`
- `/downloads/Movie.mkv`
- `/downloads/TV Show/Season 01/S01E01.mkv`
- `/downloads/Mixed Collection/...`

Manual scan items use:
- `source_kind = manual_folder` for folders
- `source_kind = manual_file` for bare video files
- no qBittorrent hash
- no qBittorrent ratio/state dependency

Design note:
- This makes NASDY Media Linker a true downloads import manager instead of only a qBittorrent completed-torrent importer.
## v3.6.2.1 Active qBittorrent Guard

Fix after Manual Downloads Scan.

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
## v3.6.2.1 Legacy TV Season Parser Fix

Problem:
- Complete-series TV packs such as `Reno 911! Complete` could pollute the show title with pack descriptors.
- Legacy episode names such as `5x01` exposed the episode number but not the season number to the planner, causing files to fall back to `Season 01` / `S01E01`.
- Some Import Manager TV rows could inherit a default season before checking stronger filename signals.

Change:
- Adds explicit support for legacy TV patterns such as `5x01`, `05x01`, and `5 x 01` in season and episode parsing.
- Cleans TV show titles by removing pack descriptors such as `Complete`, `Collection`, `Pack`, season labels, and release words while preserving punctuation from filenames when useful.
- Prefers filename/folder season evidence before defaulting to Season 01.
- Updates the Import Manager version badge to match the backend app version.

Expected Reno 911 result:
- `Reno 911! Complete` imports under `/media/tv/Reno 911!/`.
- `Reno 911 Season 5` and filenames like `Reno 911! - 5x01 - Title.avi` import under `Season 05` as `S05E01`.
## v3.6.2.2 qBittorrent State Annotation

Fix after v3.6.2.1.

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
