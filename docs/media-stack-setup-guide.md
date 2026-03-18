# Media Stack Setup Guide

**LXC 400** on pve03 (192.168.11.40) | Debian 13 | 4c/16GB/256GB | GPU: Radeon 760M

## Architecture

```
                           ┌─────────────┐
                           │  Jellyseerr  │ :5055  (user requests)
                           └──────┬───────┘
                                  │ request
                    ┌─────────────┴─────────────┐
                    │                           │
              ┌─────▼─────┐              ┌──────▼─────┐
              │   Radarr   │ :7878       │   Sonarr   │ :8989
              │  (movies)  │              │    (tv)    │
              └─────┬──────┘              └──────┬─────┘
                    │ search                     │
              ┌─────▼────────────────────────────▼─────┐
              │              Prowlarr                   │ :9696
              │  Torrentio (via Tweakio:3185)           │
              │  1337x (via FlareSolverr:8191)          │
              │  YTS, EZTV, TorrentGalaxy               │
              └─────────────────┬───────────────────────┘
                                │ torrent
                          ┌─────▼──────┐
                          │  Decypharr  │ :8282
                          │  (RD bridge)│
                          └──┬──────┬──┘
                  rclone FUSE│      │symlinks
                    mount    │      │
              ┌──────────────▼┐  ┌──▼──────────────┐
              │  /mnt/debrid   │  │  /mnt/symlinks   │
              │  (RD content)  │  │  (radarr/, tv-   │
              │                │  │   sonarr/)        │
              └───────┬────────┘  └────────┬─────────┘
                      │ symlinks point to  │ Jellyfin reads
                      └────────────────────┘
                                │
                          ┌─────▼──────┐
                          │  Jellyfin   │ :8096
                          │  VAAPI GPU  │
                          └─────────────┘
                                │
              ┌─────────┬───────┼────────┬──────────┐
              │         │       │        │          │
           Bazarr   SuggestArr Tunarr Profilarr   NFS
           :6767     :5000    :8000   :6868    /mnt/local-media
           (subs)   (auto-req)(live TV)(profiles)(r720xd)
```

## Critical Gotchas

These broke the stack and took hours to fix. Read before touching anything.

1. **Decypharr config path**: `/app/config.json` (file mount, NOT directory). Volume: `config.json:/app/config.json`
2. **Separate mount paths**: `/mnt/debrid` (FUSE) and `/mnt/symlinks` (download output) MUST be different. FUSE overwrites everything at its mount point.
3. **Mount propagation**: `mount --make-rshared /` must run before Docker. Handled by `make-rshared.service` systemd unit.
4. **All debrid containers**: need `/mnt/debrid:/mnt/debrid:rshared` volume flag.
5. **Decypharr beta schema**: uses `"provider"` field (not just `"name"`), `"mount"` as top-level struct.
6. **Decypharr download client auth**: username = arr host URL (`http://radarr:7878`), password = arr API key.
7. **Torrentio**: needs Tweakio proxy (`varthe/tweakio`) due to infoHash API change.
8. **FlareSolverr**: tag-based routing in Prowlarr for Cloudflare-protected indexers.
9. **GPU encoding**: HEVC 10-bit and AV1 NOT supported on Radeon 760M. Disable both in Jellyfin transcoding.
10. **Real-Debrid ban risk**: disable trickplay, chapter images, intro detection in Jellyfin. Immediately.
11. **Tunarr URL**: use IP (`http://192.168.11.40:8096`) not hostname for Jellyfin connection.
12. **Library updates**: use Radarr/Sonarr Connect > Jellyfin webhook (On File Import). Don't rely on manual scans.

## Deploy from Scratch

### Prerequisites

SOPS secrets in `proxmox/group_vars/all/secrets.sops.yml`:
```yaml
vault_rd_api_key: "..."
vault_pve03_api_password: "..."
vault_opensub_username: "..."
vault_opensub_password: "..."
vault_radarr_api_key: "..."      # get from Radarr UI after first deploy
vault_sonarr_api_key: "..."      # get from Sonarr UI after first deploy
vault_jellyfin_api_key: "..."    # get from Jellyfin UI after first deploy
```

### Run

```bash
# NFS export on r720xd (if not already done)
cd proxmox && ansible-playbook site.yml --limit r720xd

# Full stack deployment
ansible-playbook media-stack.yml
```

Three plays: r720xd NFS setup -> pve03 LXC creation -> media-stack Docker deployment.

## Post-Deploy UI Config (in order)

### 1. Jellyfin (:8096)
- Setup wizard: create admin user
- **IMMEDIATELY DISABLE**: Dashboard > Scheduled Tasks: chapter images, trickplay, intro detection
- Transcoding: VAAPI, device `/dev/dri/renderD128`, disable HEVC + AV1 encoding
- Libraries: `/mnt/symlinks/radarr` (Movies), `/mnt/symlinks/tv-sonarr` (TV), `/mnt/local-media/movies`, `/mnt/local-media/tv`
- Generate API key: Dashboard > API Keys -> add to SOPS secrets

### 2. Decypharr (:8282)
Auto-configured from `config.json`. If broken, check Settings tabs:
- Debrid: Real-Debrid + API key
- Rclone: enable mount, path `/mnt/debrid`, PUID/PGID 1100, VFS read ahead 256M
- QBittorrent: download folder `/mnt/symlinks`

### 3. Prowlarr (:9696)
- Auth: create admin user
- Indexer Proxies: add FlareSolverr (`http://flaresolverr:8191`), set tag `flaresolverr`
- Indexers: add Generic Torznab "Torrentio" (`http://tweakio:3185`), add 1337x (tag: flaresolverr), YTS, EZTV, TorrentGalaxy
- Apps: add Radarr (`http://radarr:7878`) + Sonarr (`http://sonarr:8989`) with API keys, sync indexers

### 4. Radarr (:7878)
- Root folders: `/mnt/symlinks/radarr` + `/mnt/local-media/movies`
- Download client: qBittorrent, host `decypharr`, port `8282`, username `http://radarr:7878`, password = Radarr API key
- Connect: add Emby/Jellyfin, host `jellyfin`, port `8096`, API key. Triggers: On File Import, On File Upgrade

### 5. Sonarr (:8989)
Same as Radarr but: root folders `/mnt/symlinks/tv-sonarr` + `/mnt/local-media/tv`, username `http://sonarr:8989`, password = Sonarr API key

### 6. Bazarr (:6767)
Languages: EN + HI. Providers: OpenSubtitles. Connect Radarr (`http://radarr:7878`) + Sonarr (`http://sonarr:8989`)

### 7. Jellyseerr (:5055)
Connect Jellyfin (`http://jellyfin:8096`), add Radarr + Sonarr with API keys

### 8. Profilarr (:6868)
Database: `https://github.com/Dictionarry-Hub/database`. Add Radarr + Sonarr, sync method "On Pull". Profile: 2160p Balanced

### 9. SuggestArr (:5000)
Jellyfin (`http://jellyfin:8096` + API key), Jellyseerr (`http://jellyseerr:5055`). Optional: OpenAI with `gpt-4o-mini`

### 10. Tunarr (:8000)
Add Jellyfin source: `http://192.168.11.40:8096` (use IP!). Create channels. In Jellyfin Live TV: M3U `http://tunarr:8000/api/channels.m3u`, XMLTV `http://tunarr:8000/api/xmltv.xml`

## Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| FFmpeg 254 | HEVC 10-bit encoding on unsupported GPU | Disable HEVC + AV1 encoding in Jellyfin |
| "No debrid clients" | Decypharr config not loaded | Check `docker logs decypharr` for `debrids=0`. Fix config.json format |
| Symlinks empty | Decypharr stable (v1.1.6) bug | Use beta tag (`cy01/blackhole:beta`) |
| Jellyfin can't follow symlinks | Mount propagation broken | `mount --make-rshared /`, restart Docker, ensure `:rshared` on volumes |
| Slow scrubbing | VFS cache too small | Increase `vfs_cache_max_size` in Decypharr config |
| Duplicate shows | Stale Jellyfin DB entries | Remove library, re-add with correct path |
| Tunarr 400 error | Using hostname for Jellyfin URL | Use IP `http://192.168.11.40:8096` |
| Indexer Cloudflare block | FlareSolverr not tagged | Add `flaresolverr` tag to indexer AND proxy |

## Maintenance

```bash
# Update containers
ssh root@192.168.11.40 "cd /opt/media-stack && docker compose pull && docker compose up -d"

# Or via Ansible
ansible-playbook proxmox/media-stack.yml --limit media-stack

# Check backups (Sanoid snapshots on rpool)
ssh root@192.168.11.12 "zfs list -t snapshot | grep subvol-400"

# Renew RD key
sops proxmox/group_vars/all/secrets.sops.yml  # edit vault_rd_api_key
ansible-playbook proxmox/media-stack.yml --limit media-stack

# Verify mount propagation persists
ssh root@192.168.11.40 "systemctl is-enabled make-rshared"
```

## Monitoring

### Jellystat (Playback Analytics)

Standalone UI at `http://192.168.11.40:3000` — Jellyfin playback history, user stats, library analytics. Backed by a dedicated PostgreSQL container.

### Grafana Dashboard

Dashboard UID: `media-stack-health` — container health, *arr queue depth, RD account expiry, FUSE mount status, transcode activity.

### Alloy (Metrics + Logs Agent)

```bash
# Check status
ssh root@192.168.11.40 "systemctl status alloy"

# Restart after config changes
ssh root@192.168.11.40 "systemctl restart alloy"
```

### Cron Jobs

| Script | Schedule | Purpose |
|--------|----------|---------|
| `/opt/media-stack/rd-expiry-check.sh` | Daily 03:00 | Check RD account expiry days |
| `/opt/media-stack/fuse-check.sh` | Every 5 min | Validate rclone FUSE mount at `/mnt/debrid` |

Textfile metrics written to `/var/lib/alloy/textfile/` and scraped by Alloy.

### Alerts

9 alert rules in the **Media Stack** Grafana Alerting folder. Runbook: `docs/runbooks/media-stack-alerts.md`

## URLs

| Service | URL | Audience |
|---------|-----|----------|
| Jellyfin | http://192.168.11.40:8096 | Everyone |
| Jellyseerr | http://192.168.11.40:5055 | Everyone |
| Radarr | http://192.168.11.40:7878 | Admin |
| Sonarr | http://192.168.11.40:8989 | Admin |
| Prowlarr | http://192.168.11.40:9696 | Admin |
| Bazarr | http://192.168.11.40:6767 | Admin |
| Decypharr | http://192.168.11.40:8282 | Admin |
| Profilarr | http://192.168.11.40:6868 | Admin |
| SuggestArr | http://192.168.11.40:5000 | Admin |
| Tunarr | http://192.168.11.40:8000 | Admin |
