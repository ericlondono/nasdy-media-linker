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
