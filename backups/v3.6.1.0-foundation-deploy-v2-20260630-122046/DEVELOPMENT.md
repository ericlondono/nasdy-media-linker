# NASDY Media Linker Development Notes

## Core Workflow Rules

- Eric does not manually edit code files.
- All code changes should be delivered as runnable PowerShell upgrade scripts.
- Upgrade scripts should create backups before changing files.
- Docker Desktop is not used locally.
- Docker images are built directly on the unRAID NAS over SSH.
- Deployment uses root@NASDY.
- Future deploys should use one command: .\Deploy.ps1.

## Paths

Local project:
C:\Projects\nasdy-media-linker

Remote app path:
/mnt/user/appdata/nasdy-media-organizer

Downloads:
/mnt/user/NASDY/downloads

Media:
/mnt/user/NASDY/media

App data:
/mnt/user/appdata/nasdy-media-organizer/data

Required mount:
/mnt:/host_mnt

## Docker

Container:
nasdy-media-organizer

Image:
nasdy-media-linker:latest

Port:
8088

## v3.6.1.0 Goals

1. Create permanent Deploy.ps1.
2. Bake /mnt:/host_mnt into every deployment.
3. Rename Movie Collection Import Manager to Import Manager.
4. Add smart import status cards.

## Workflow Reminder

At the start of a new ChatGPT conversation, upload this file first.
