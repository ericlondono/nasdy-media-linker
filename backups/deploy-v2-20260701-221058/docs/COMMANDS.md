# Commands

## Windows PowerShell: commit and push v3.0

```powershell
cd C:\Projects\nasdy-media-linker

git status
git add .
git commit -m "Media Linker v3.0 - structured app and hard-link resolver"
git push
```

## unRAID terminal: update and reinstall

```bash
cd /mnt/user/appdata/nasdy-media-organizer
git pull
chmod +x install-unraid.sh
./install-unraid.sh
```

## unRAID terminal: quick logs

```bash
docker logs nasdy-media-organizer --tail=100
```

## unRAID terminal: verify mounted paths

```bash
docker exec -it nasdy-media-organizer sh
ls -la /host_mnt/cache/NASDY
ls -la /host_mnt/user/NASDY
```
