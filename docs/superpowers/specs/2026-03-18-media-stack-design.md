# Media Stack Design — pve03

**Date:** 2026-03-18
**Status:** Approved
**Node:** pve03 (192.168.11.12) — AMD Ryzen 5 8500G, 30GB RAM, 1TB NVMe

## Goal

Self-hosted media server as an alternative to commercial streaming platforms (Netflix, Hulu, Amazon Prime, Hotstar, etc.). Multi-user, multi-device (phones, laptops, tablets, LG/Samsung TVs). Content sourced primarily from Real-Debrid with optional local downloads for permanent storage.

## Architecture Overview

```
+---------------------------------------------------------------+
| pve03 (192.168.11.12)                                         |
|                                                               |
|  +----------------------------------------------------------+ |
|  | LXC 400: media-stack (192.168.11.40)                     | |
|  | Debian 13 (Trixie), privileged, nesting+fuse             | |
|  | 4 cores, 16GB RAM, 2GB swap, 64GB root disk              | |
|  | GPU: /dev/dri (Radeon 760M VAAPI)                        | |
|  | Privileged mode: required for FUSE mount propagation     | |
|  |   and clean GPU passthrough without AppArmor issues      | |
|  |                                                          | |
|  | Docker Compose — all services on media-net network        | |
|  |                                                          | |
|  |  +-----------+ +--------+ +--------+ +--------------+    | |
|  |  | Prowlarr  |>| Radarr |>|        |>| Jellyfin     |    | |
|  |  | (indexer) | |(movies)| |Decypharr| | (playback)   |    | |
|  |  |           |>| Sonarr |>|(RD +   | | GPU: VAAPI   |    | |
|  |  |           | | (tv)   | |symlink)| | 8GB tmpfs    |    | |
|  |  +-----------+ +--------+ +--------+ +--------------+    | |
|  |  +-----------+ +--------+ +----------+ +----------+      | |
|  |  | Jellyseerr| | Bazarr | | SuggestArr | | Tunarr  |      | |
|  |  | (requests)| | (subs) | | (auto-req) | |(live TV)|      | |
|  |  +-----------+ +--------+ +----------+ +----------+      | |
|  |  +-----------+                                            | |
|  |  | Profilarr |                                            | |
|  |  | (profiles)|                                            | |
|  |  +-----------+                                            | |
|  |                                                          | |
|  |  Storage:                                                | |
|  |   /opt/media-stack/config/ -> app configs (rpool)        | |
|  |   /mnt/debrid/             -> Decypharr FUSE mount       | |
|  |   /mnt/local-media/        -> NFS from r720xd            | |
|  +----------------------------------------------------------+ |
|                                                               |
|  NFS: r720xd:/mnt/pool0/media -> /mnt/local-media            |
+---------------------------------------------------------------+
```

## Components

### Core Services

| Service | Port | Image | Role |
|---------|------|-------|------|
| Decypharr | 8282 | `cy01/blackhole:latest` | Real-Debrid bridge. Mocks qBittorrent API for arrs. Built-in WebDAV + rclone replaces Zurg. Mounts RD to `/mnt/debrid/`, creates symlinks. |
| Jellyfin | 8096 | `jellyfin/jellyfin:latest` | Media server. VAAPI hardware transcoding via Radeon 760M. 8GB tmpfs for transcoding cache. Serves debrid symlinks + local NFS media. |
| Prowlarr | 9696 | `linuxserver/prowlarr:latest` | Indexer aggregator. Torrentio (custom YAML), 1337x, YTS, EZTV, TorrentGalaxy (built-in). |
| Radarr | 7878 | `linuxserver/radarr:latest` | Movie automation. Two root folders: `/mnt/debrid/decypharr_symlinks/movies` (default) and `/mnt/local-media/movies` (permanent). |
| Sonarr | 8989 | `linuxserver/sonarr:latest` | TV automation. Two root folders: `/mnt/debrid/decypharr_symlinks/tv` (default) and `/mnt/local-media/tv` (permanent). |
| Bazarr | 6767 | `linuxserver/bazarr:latest` | Subtitle management. OpenSubtitles provider. English + Hindi languages. |
| Jellyseerr | 5055 | `fallenbagel/jellyseerr:latest` | User-facing request UI. TMDB-powered discovery. Netflix-like browsing. Users request on phone, watch on TV. |
| SuggestArr | 5000 | `ciuse99/suggestarr:latest` | Automatically requests trending content to Jellyseerr based on watch history. Keeps library growing. |
| Tunarr | 8000 | `jasongdove/tunarr:latest` | Creates live TV channels from library content (e.g., "Comedy" channel playing random comedies). |
| Profilarr | 6868 | `ghcr.io/dictionarry-hub/profilarr:latest` | Quality profile management for Radarr/Sonarr. Syncs TRaSH Guides and custom profiles across arr instances from a centralized UI. |

### Indexers (Prowlarr)

| Indexer | Type | Install |
|---------|------|---------|
| Torrentio | Custom (debrid-aware) | Download `torrentio.yml` from [dreulavelle/Prowlarr-Indexers](https://github.com/dreulavelle/Prowlarr-Indexers), place in `<prowlarr-config>/Definitions/Custom/`, restart Prowlarr. Configure RD API key in indexer settings. |
| 1337x | Public tracker | Built-in |
| YTS | Public tracker | Built-in |
| EZTV | Public tracker | Built-in |
| TorrentGalaxy | Public tracker | Built-in |

Torrentio is the primary indexer — searches multiple sources and filters for Real-Debrid cached content. Public trackers serve as fallback; Decypharr rejects uncached torrents automatically.

## Data Flow

### Request to Playback (Debrid)

```
User browses Jellyseerr (or SuggestArr auto-triggers)
    |
    v
Request sent to Radarr/Sonarr
    |
    v
Radarr/Sonarr queries Prowlarr -> searches indexers (Torrentio etc.)
    |
    v
Torrent sent to Decypharr (via qBittorrent API)
    |
    v
Decypharr checks Real-Debrid cache -> adds torrent to RD
    |
    v
Decypharr mounts via WebDAV -> /mnt/debrid/decypharr/realdebrid/__all__/
    |
    v
Decypharr creates symlink -> /mnt/debrid/decypharr_symlinks/{movies,tv}/
    |
    v
Radarr/Sonarr imports, renames per naming convention
    |
    v
Jellyfin library scan picks up new content
    |
    v
Bazarr fetches subtitles (EN + HI)
    |
    v
User plays on any device (TV app, phone, browser)
```

### Local Download (Optional)

For permanently keeping a title independent of Real-Debrid:

1. In Radarr/Sonarr, the title has a second root folder configured: `/mnt/local-media/{movies,tv}`
2. Use Radarr/Sonarr's "Move to Root Folder" feature to reassign the title to the local NFS path
3. This performs an actual data copy (not a filesystem move) from the debrid WebDAV mount to NFS storage, since they are different filesystems
4. Once copied, the title is served from local NFS — no Real-Debrid dependency
5. The debrid symlink can be cleaned up manually or left (Decypharr handles stale symlinks gracefully)

### User Workflow

- **Requesting**: Phone/laptop via Jellyseerr web UI. Not available on TV (no native app), but TV isn't the right UX for searching anyway.
- **Watching**: Jellyfin native app on LG, Samsung, Android TV, Fire TV, Apple TV, Roku. Jellyfin app on iOS/Android. Web browser on laptop.
- **Auto-discovery**: SuggestArr monitors watch history and auto-requests similar trending content.

## LXC Configuration

| Setting | Value |
|---------|-------|
| ID | 400 |
| Hostname | `media-stack` |
| OS | Debian 13 (Trixie) — verify template availability: `pveam available --section system \| grep debian-13`. Fallback to Debian 12 if unavailable. |
| IP | 192.168.11.40/24 (static, gateway 192.168.11.1) |
| Cores | 4 |
| RAM | 16GB |
| Swap | 2GB |
| Root disk | 64GB on local-zfs |
| Type | Privileged (required for FUSE mount propagation and clean GPU/device passthrough without AppArmor issues) |
| Features | `nesting=1,fuse=1` |
| GPU | `/dev/dri` passthrough (Radeon 760M VAAPI) |
| SSH | Root key injected during LXC creation (pve03's root pubkey) |
| DNS | 192.168.11.1, 9.9.9.9 |

### LXC Config Additions (for GPU + FUSE)

```
# GPU passthrough
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
# FUSE
lxc.cgroup2.devices.allow: c 10:229 rwm
lxc.mount.entry: /dev/fuse dev/fuse none bind,optional,create=file
```

### Mount Points

```
/opt/media-stack/config/     -> App configs (local rpool, 64GB disk)
/mnt/debrid/                 -> Decypharr FUSE mount (runtime, no disk usage)
/mnt/local-media/            -> NFS: r720xd:/mnt/pool0/media
/dev/dri/                    -> GPU device passthrough
```

## Storage Strategy

| What | Size | Location |
|------|------|----------|
| App configs + databases | ~10-15GB | pve03 rpool (local-zfs, inside 64GB root disk) |
| Docker images | ~15-20GB | pve03 rpool |
| Decypharr FUSE mount | Virtual (no disk) | pve03 RAM/cache |
| Jellyfin transcoding cache | 8GB tmpfs | pve03 RAM |
| Jellyfin metadata/artwork | ~5-10GB (grows) | pve03 rpool |
| Locally downloaded media | Variable | r720xd pool0/media via NFS |

### RAM Budget

| Consumer | Allocation |
|----------|-----------|
| pve03 ZFS ARC | 4GB (from pve03.yml) |
| LXC RAM | 16GB |
| PVE overhead | ~2GB |
| Remaining headroom | ~8GB |
| **Total** | **30GB** |

Within the 16GB LXC: 8GB tmpfs for transcoding + ~6-8GB for all containers + OS. Monitor memory pressure after deployment; reduce tmpfs to 4GB if needed.

### NFS Setup

**r720xd side** (via existing Ansible `nfs_exports`):
```yaml
nfs_exports:
  - path: /mnt/pool0/media
    network: 192.168.11.0/24
    options: rw,sync,no_subtree_check,no_root_squash
```

Requires creating `pool0/media` dataset on r720xd:
```bash
zfs create pool0/media
chown 1100:1100 /mnt/pool0/media   # match media user PUID/PGID
```

**pve03 LXC side** (`/etc/fstab`):
```
192.168.11.15:/mnt/pool0/media /mnt/local-media nfs rw,soft,intr 0 0
```

### User/Group ID Mapping

All containers use a consistent `media` user:
- **PUID**: 1100
- **PGID**: 1100

Created inside the LXC: `groupadd -g 1100 media && useradd -u 1100 -g 1100 -s /usr/sbin/nologin media`

The NFS dataset on r720xd must have matching ownership (`chown 1100:1100`). Since NFS is exported with `no_root_squash` and the LXC is privileged, UID 1100 maps directly.

### Backup Strategy

- **LXC root disk** (configs, databases): Covered by existing Sanoid config in `pve03.yml` — `rpool` recursive snapshots include `rpool/data/subvol-400-disk-0`
- **NFS media dataset** (`pool0/media` on r720xd): Add to `sanoid_datasets` in `host_vars/r720xd.yml` with `data_retention` template

## Quality Profiles

Managed by **Profilarr**, which syncs TRaSH Guides profiles and custom formats to Radarr/Sonarr:

- **Strategy**: 4K preferred, 1080p fallback
- **Profilarr** connects to the Dictionarry database for community-maintained quality profiles and custom formats
- **Radarr/Sonarr quality profiles**: Synced from Profilarr — grab highest available quality up to 4K/2160p
- **Jellyfin transcoding**: VAAPI handles HDR-to-SDR tone mapping for clients that don't support HDR. Automatic quality downgrade for remote/mobile clients.

## Docker Compose Structure

### Source of Truth

The Ansible Jinja2 template (`proxmox/templates/media-stack-compose.yaml.j2`) is the authoritative source. It renders to `/opt/media-stack/compose.yaml` on the LXC. No Komodo integration — Ansible manages deployment and updates directly.

To update the stack after config changes: `ansible-playbook proxmox/media-stack.yml`

### Runtime Layout (on LXC)

```
/opt/media-stack/
+-- config/
|   +-- jellyfin/
|   +-- radarr/
|   +-- sonarr/
|   +-- prowlarr/
|   +-- bazarr/
|   +-- jellyseerr/
|   +-- decypharr/
|   +-- suggestarr/
|   +-- tunarr/
|   +-- profilarr/
+-- compose.yaml          # Rendered from Jinja2 template
+-- .env                  # Rendered from SOPS-encrypted vars
```

### Secrets (SOPS + age)

| Secret | Used By | Notes |
|--------|---------|-------|
| `RD_API_KEY` | Decypharr | Real-Debrid API key |
| `OPENSUB_USERNAME` | Bazarr | OpenSubtitles account |
| `OPENSUB_PASSWORD` | Bazarr | OpenSubtitles account |
| `JELLYFIN_API_KEY` | SuggestArr, Tunarr | See bootstrap sequence below |

Encrypted with age key `age1y6dnshya496nf3072zudw3vd33723v02g3tfvpt563zng0xd9ghqwzj5xk`, matching K8s and Docker secret management pattern.

### Bootstrap Sequence

`JELLYFIN_API_KEY` cannot be known until Jellyfin is running. Deployment order:

1. **Initial deploy**: Run `docker compose up -d` with all services. SuggestArr and Tunarr will start but fail to connect to Jellyfin (expected).
2. **Configure Jellyfin**: Access web UI at `192.168.11.40:8096`, complete setup wizard, create admin user, generate API key from Dashboard > API Keys.
3. **Store API key**: Add `JELLYFIN_API_KEY` to SOPS-encrypted secrets, re-run Ansible to redeploy `.env`.
4. **Restart dependents**: `docker compose restart suggestarr tunarr` — they now connect to Jellyfin.

### Docker Compose Conventions

- All containers use `PUID=1100`/`PGID=1100` (media user)
- Single shared network: `media-net` (bridge, all services communicate by container name)
- `/mnt/debrid` mapped with `:rshared` propagation flag for FUSE mount visibility
- Restart policy: `unless-stopped`
- Decypharr: `cap_add: [SYS_ADMIN]`, `devices: [/dev/fuse]`, privileged for FUSE
- Jellyfin: `devices: [/dev/dri:/dev/dri]`, `tmpfs: /config/transcodes:size=8G`

### Decypharr Config (`decypharr-config.json.j2`)

Key settings rendered by Ansible:
- `debrid.provider`: `realdebrid`
- `debrid.api_key`: from SOPS vault
- `webdav.enabled`: `true`
- `webdav.port`: `8282`
- `mount.path`: `/mnt/debrid`
- `symlinks.path`: `/mnt/debrid/decypharr_symlinks`
- `symlinks.categories`: `movies`, `tv`

## IaC Strategy

### Approach

Separate Ansible playbook (`proxmox/media-stack.yml`), not mixed into existing `proxmox/site.yml`. Ansible manages both initial deployment and ongoing updates (image pulls, config changes, redeployment).

### New/Modified Files

```
proxmox/
+-- media-stack.yml                    # New playbook
+-- host_vars/pve03.yml               # Add media_stack LXC vars
+-- host_vars/r720xd.yml              # Add NFS export + sanoid dataset for pool0/media
+-- inventory/hosts.yml               # Add media-stack LXC entry
+-- templates/
|   +-- media-stack-compose.yaml.j2    # Docker compose (source of truth)
|   +-- decypharr-config.json.j2       # Decypharr config
+-- group_vars/all/
    +-- secrets.sops.yml               # Add RD API key, OpenSubtitles creds
```

### Inventory

Add the LXC to `proxmox/inventory/hosts.yml`:
```yaml
all:
  hosts:
    r720xd:
      ansible_host: 192.168.11.15
      ansible_user: root
      ansible_python_interpreter: /usr/bin/python3
    pve03:
      ansible_host: 192.168.11.12
      ansible_user: root
      ansible_python_interpreter: /usr/bin/python3
    media-stack:
      ansible_host: 192.168.11.40
      ansible_user: root
      ansible_python_interpreter: /usr/bin/python3
```

Play 1 creates the LXC with static IP 192.168.11.40 and injects pve03's root SSH public key. Play 2 then connects via SSH to the LXC directly.

### Playbook Flow

```
media-stack.yml

  Play 1: Target pve03 (hypervisor)
    - Download Debian 13 LXC template if not present
    - Create LXC 400 via community.general.proxmox module
      - Privileged, nesting, fuse
      - 4 cores, 16GB RAM, 2GB swap, 64GB disk
      - Static IP: 192.168.11.40/24, gateway 192.168.11.1
      - Inject SSH pubkey for root access
    - Configure LXC conf (GPU + FUSE device passthrough)
    - Start LXC
    - Wait for SSH to become available on 192.168.11.40

  Play 2: Target media-stack LXC (192.168.11.40 via SSH)
    - Install Docker CE + docker compose plugin (official Docker apt repo)
    - Create media user/group (UID/GID 1100)
    - Install NFS client (nfs-common), create /mnt/local-media, configure /etc/fstab
    - Create directory structure (/opt/media-stack/config/{jellyfin,radarr,...})
    - Deploy SOPS-decrypted .env file
    - Deploy rendered compose.yaml from Jinja2 template
    - Deploy rendered decypharr-config.json
    - docker compose up -d

  Play 3: Target r720xd (NFS export)
    - Create pool0/media ZFS dataset (idempotent)
    - Set ownership to 1100:1100
    - NFS export handled by existing site.yml nfs_exports mechanism
```

### r720xd Changes

Add to `host_vars/r720xd.yml`:
```yaml
nfs_exports:
  - path: /mnt/pool0/nvr           # existing
    network: 192.168.11.0/24
    options: rw,sync,no_subtree_check,no_root_squash
  - path: /mnt/pool0/media         # new
    network: 192.168.11.0/24
    options: rw,sync,no_subtree_check,no_root_squash

sanoid_datasets:
  # ... existing datasets ...
  - name: "pool0/media"
    template: data_retention
    recursive: no
```

## Networking

### Internal (Docker)

All services on `media-net` bridge network, communicate by container name.

### External Access

During initial deployment, services are accessible directly at `192.168.11.40:<port>` from the local network. Subdomain-based ingress is deferred to a follow-up task.

| Service | Direct Access | Future Subdomain | Audience |
|---------|--------------|-------------------|----------|
| Jellyfin | `192.168.11.40:8096` | `jellyfin.sharmamohit.com` | All users |
| Jellyseerr | `192.168.11.40:5055` | `requests.sharmamohit.com` | All users |
| Radarr | `192.168.11.40:7878` | `radarr.sharmamohit.com` | Admin only |
| Sonarr | `192.168.11.40:8989` | `sonarr.sharmamohit.com` | Admin only |
| Prowlarr | `192.168.11.40:9696` | `prowlarr.sharmamohit.com` | Admin only |
| Bazarr | `192.168.11.40:6767` | `bazarr.sharmamohit.com` | Admin only |
| Decypharr | `192.168.11.40:8282` | `decypharr.sharmamohit.com` | Admin only |
| Profilarr | `192.168.11.40:6868` | `profilarr.sharmamohit.com` | Admin only |

## Anti-Abuse: Real-Debrid Ban Prevention

Real-Debrid permanently bans accounts that perform excessive file reads. Critical settings:

- **Jellyfin**: Disable video preview thumbnails, intro detection, chapter thumbnail generation, audio loudness analysis
- **rclone (Decypharr built-in)**: `--vfs-read-ahead 256M` for buffering
- **No VPN**: RD discourages VPN use (shared IPs trigger bans)

## Out of Scope (Deferred)

- Remote access / VPN / ingress configuration
- Jellyfin-Enhanced CSS theming
- Zilean / MediaFusion indexers
- Jellyfin plugins (provider-stuff, home-sections, editors-choice) — can be added later
