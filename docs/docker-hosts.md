# Docker Hosts

Operational reference for all 6 Docker hosts managed by Komodo. For GitOps workflow and stack management, see [docker/README.md](/docker/README.md).

## Host Summary

| Host | IP | OS | SSH | Periphery Compose | Role |
|------|----|----|-----|-------------------|------|
| **komodo** | 192.168.11.200 | Ubuntu 24.04 LTS | `root@komodo` | systemd service | Komodo Core (self-managed) + systemd Periphery |
| **nvr** | 192.168.11.89 | Debian 12 (bookworm) | `root@nvr` | `/root/komodo-periphery/compose.yaml` | Frigate NVR |
| **kasm** | 192.168.11.34 | Ubuntu 24.04 LTS | `root@kasm` | `/root/komodo-periphery/compose.yaml` | KASM Workspaces + Newt |
| **omni** | 192.168.11.30 | Ubuntu 22.04 LTS | `root@omni` | `/root/komodo-periphery/compose.yaml` | Siderolabs Omni |
| **server04** | 192.168.11.17 | Ubuntu 22.04 LTS | `mohitsharma44@server04` | `/home/mohitsharma44/komodo-periphery/compose.yaml` | App server + build server |
| **seaweedfs** | 192.168.11.133 | Ubuntu 25.10 | `mohitsharma44@seaweedfs` | `/home/mohitsharma44/komodo-periphery/compose.yaml` | SeaweedFS object storage |

## Network Topology

```
                    ┌─────────────────────┐
                    │  192.168.11.1       │
                    │  Gateway / DNS      │
                    └─────────┬───────────┘
                              │
        ┌─────────────────────┼─────────────────────────────────────┐
        │                     │           192.168.11.0/24           │
        │                     │                                     │
   ┌────┴────┐  ┌─────────┐  │  ┌──────────┐  ┌──────────────────┐│
   │ komodo  │  │  nvr    │  │  │  kasm    │  │  K8s cluster     ││
   │ .200    │  │  .89    │  │  │  .34     │  │  (minipcs)       ││
   │ Core+   │  │ Frigate │  │  │ KASM     │  │  MetalLB:        ││
   │ sysd    │  │ Coral   │  │  │ Newt     │  │  .88-.98         ││
   │ Periph  │  │ Alloy   │  │  │ Alloy    │  │  Ingress: .90    ││
   │ Alloy   │  │         │  │  │          │  │                  ││
   └─────────┘  └─────────┘  │  └──────────┘  └──────────────────┘│
        │                     │                                     │
   ┌────┴────┐  ┌──────────┐ │  ┌────────────┐                    │
   │  omni   │  │server04  │ │  │ seaweedfs  │                    │
   │  .30    │  │  .17     │ │  │  .133      │                    │
   │ Talos   │  │ Traefik  │ │  │ S3 object  │                    │
   │ Mgmt    │  │ Vault-   │ │  │ storage    │                    │
   │ Alloy   │  │ warden   │ │  │ Alloy      │                    │
   └─────────┘  │ Alloy    │ │  └────────────┘                    │
                └──────────┘ │                                     │
                             └─────────────────────────────────────┘
```

## Per-Host Details

### komodo (192.168.11.200)

**Platform**: Proxmox LXC container (ID 200) — unprivileged, nesting enabled

Runs Komodo Core (the control plane) as a self-managed stack, alongside systemd Periphery. Core manages all other hosts via their Periphery agents.

| Service | Container/Service | Notes |
|---------|-------------------|-------|
| Komodo Core | `core-core-1` | API on port 9120, UI via Traefik on server04, managed via `komodo-core` stack |
| FerretDB | `core-ferretdb-1` | MongoDB-compatible database for Core |
| PostgreSQL | `core-postgres-1` | Backend for FerretDB |
| Periphery | systemd service | Port 8120 (TLS), config at `/etc/komodo/periphery.config.toml` |
| Alloy | via Komodo stack | Host/container metrics and logs |

**Compose**: Managed by Komodo stack `komodo-core`
**Data**: `/etc/komodo/` (stacks, ssl certs, backups)
**Backups**: Daily at 01:00 to `/etc/komodo/backups/`

**LXC Workaround**: A systemd service (`mask-apparmor.service`) mounts an empty tmpfs over `/sys/kernel/security` to hide AppArmor from Docker, which otherwise fails in unprivileged LXC. See the PVE LXC 200 notes for details.

---

### nvr (192.168.11.89)

**Platform**: Proxmox LXC container — Debian 12

Dedicated NVR host running Frigate with hardware acceleration.

| Service | Container | Notes |
|---------|-----------|-------|
| Frigate | `frigate` | Coral TPU (`/dev/apex_0`), Intel GPU (`/dev/dri/renderD128`), privileged |
| Periphery | `komodo-periphery-periphery-1` | Standard periphery |
| Alloy | via Komodo stack | Host/container metrics and logs |

**Frigate config**: Compose at `/root/frigate/docker-compose.yaml` (now managed via Komodo)
**Media**: `/media/frigate`
**Ports**: 8971 (UI), 5000, 8554 (RTSP), 8555 (WebRTC)

**Hardware note**: Frigate is pinned to this host due to Coral TPU and Intel GPU dependencies.

---

### kasm (192.168.11.34)

**Platform**: Bare metal / VM — Ubuntu 24.04

Remote desktop environment. KASM Workspaces is installer-managed (10 containers) and NOT managed by Komodo. Only the Newt tunnel agent is Komodo-managed.

| Service | Container | Notes |
|---------|-----------|-------|
| KASM Workspaces | 10 containers (`kasm_*`) | Installer-managed, do NOT touch via Komodo |
| Newt | `newt` | Pangolin tunnel to `pangolin.proxy.sharmamohit.com` |
| Periphery | `komodo-periphery-periphery-1` | Standard periphery |
| Alloy | via Komodo stack | Host/container metrics and logs |

**KASM compose**: `/opt/kasm/1.17.0/docker/docker-compose.yaml` (installer-owned)

**Warning**: KASM manages its own compose file via its installer. Do not manage it through Komodo — KASM updates will overwrite any external changes.

---

### omni (192.168.11.30)

**Platform**: Proxmox LXC container — Ubuntu 22.04

Runs Siderolabs Omni for managing Talos Linux Kubernetes clusters.

| Service | Container | Notes |
|---------|-----------|-------|
| Omni | `omni` | Host network, `NET_ADMIN`, `/dev/net/tun` access |
| Periphery | `komodo-periphery-periphery-1` | Standard periphery |
| Alloy | via Komodo stack | Host/container metrics and logs |

**Original compose**: `/opt/omni/compose.yaml` (now managed via Komodo)
**Network**: Uses host network mode — required for Talos machine discovery

---

### server04 (192.168.11.17)

**Platform**: Bare metal / VM — Ubuntu 22.04
**SSH user**: `mohitsharma44` (sudo available)

Primary application server and Docker build server for custom images.

| Service | Container | Notes |
|---------|-----------|-------|
| Traefik | `traefik` | Reverse proxy, `traefik_proxy` external network |
| Vaultwarden | `vaultwarden` | `bitwarden.sharmamohit.com` |
| Periphery | `komodo-periphery-periphery-1` | Also serves as Komodo build server |
| Alloy | via Komodo stack | Host/container metrics and logs |

**Traefik network**: Services that need reverse proxying must join the `traefik_proxy` external Docker network and use Traefik labels for routing.

**Periphery quirk**: Requires explicit `dns: ["192.168.11.1"]` in the periphery compose — Docker's embedded DNS doesn't forward correctly on this host.

---

### seaweedfs (192.168.11.133)

**Platform**: TrueNAS VM — Ubuntu 25.10
**SSH user**: `mohitsharma44` (sudo available)

Distributed object storage providing S3-compatible API for the observability stack (Thanos, Loki, Tempo) and general-purpose storage.

| Service | Container | Notes |
|---------|-----------|-------|
| SeaweedFS Master | `seaweedfs-master-1` | Port 9333 |
| SeaweedFS Volume | `seaweedfs-volume-1` | Port 8080 |
| SeaweedFS Filer | `seaweedfs-filer-1` | Port 8888 |
| SeaweedFS S3 | `seaweedfs-s3-1` | Port 8333 (`seaweedfs.sharmamohit.com:8333`) |
| SeaweedFS WebDAV | `seaweedfs-webdav-1` | Port 7333 |
| Periphery | `komodo-periphery-periphery-1` | Standard periphery |
| Alloy | via Komodo stack | Host/container metrics and logs |

**Data**: `/mnt/seaweedfs/` (master, volume, filer data)
**S3 credentials**: Stored in `s3.sops.json` (SOPS-encrypted)
**S3 buckets**: `thanos-metrics`, `loki-chunks`, `loki-ruler`, `tempo-traces`

## Periphery Compose Locations

Quick reference for restarting periphery agents:

```bash
# komodo (systemd Periphery)
ssh root@komodo "systemctl restart periphery"

# nvr, kasm, omni (root users)
ssh root@nvr  "cd /root/komodo-periphery && docker compose up -d --force-recreate"
ssh root@kasm "cd /root/komodo-periphery && docker compose up -d --force-recreate"
ssh root@omni "cd /root/komodo-periphery && docker compose up -d --force-recreate"

# server04, seaweedfs (non-root users)
ssh mohitsharma44@server04   "cd ~/komodo-periphery && docker compose up -d --force-recreate"
ssh mohitsharma44@seaweedfs  "cd ~/komodo-periphery && docker compose up -d --force-recreate"
```

## Maintenance

### Pulling Updated Periphery Image on All Hosts

```bash
# After building: km execute run-build periphery-custom
for host in root@nvr root@kasm root@omni; do
  ssh $host "docker pull mohitsharma44/komodo-periphery-sops:latest" &
done
for host in mohitsharma44@seaweedfs mohitsharma44@server04; do
  ssh $host "docker pull mohitsharma44/komodo-periphery-sops:latest" &
done
wait

# komodo uses systemd Periphery -- update separately:
# ssh root@komodo "curl -sSL https://raw.githubusercontent.com/moghtech/komodo/main/scripts/setup-periphery.py | python3 - --version=<new-version>"
# ssh root@komodo "systemctl restart periphery"
```

Then restart each periphery using the commands in the section above.

### Checking Periphery Health

```bash
km list servers -a
```

Or directly via each host's health endpoint:
```bash
for host in komodo nvr kasm omni server04 seaweedfs; do
  echo -n "$host: "
  curl -sk https://$host.sharmamohit.com:8120/health 2>/dev/null || echo "unreachable"
done
```
