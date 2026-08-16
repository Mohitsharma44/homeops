# Docker Hosts

Operational reference for all 7 Docker hosts managed by Komodo. For GitOps workflow and stack management, see [docker/README.md](/docker/README.md).

All Peripheries run v2.1.2 in **outbound mode** (Periphery dials Core, PKI keypair auth). Core is at `http://192.168.11.200:9120` for LAN hosts and `http://komodo.private.sharmamohit.com:9120` (Pangolin private resource) for the VPS.

## Host Summary

| Host | IP | OS | SSH | Periphery Compose | Role |
|------|----|----|-----|-------------------|------|
| **komodo** | 192.168.11.200 | Ubuntu 24.04 LTS | `root@komodo` | systemd service | Komodo Core (self-managed) + systemd Periphery |
| **nvr** | 192.168.11.89 | Debian 12 (bookworm) | `root@nvr` | `/root/komodo-periphery/compose.yaml` | Frigate NVR |
| **kasm** | 192.168.11.34 | Ubuntu 24.04 LTS | `root@kasm` | `/root/komodo-periphery/compose.yaml` | KASM Workspaces + Newt |
| **omni** | 192.168.11.30 | Ubuntu 22.04 LTS | `root@omni` | `/root/komodo-periphery/compose.yaml` | Siderolabs Omni |
| **server04** | 192.168.11.17 | Ubuntu 22.04 LTS | `mohitsharma44@server04` | `/home/mohitsharma44/komodo-periphery/compose.yaml` | App server + build server |
| **storage** | 192.168.11.244 | UGOS (vendor OS, squashfs + overlay) | `mohitsharma44@192.168.11.244` | `/volume2/komodo/periphery/compose.yaml` | Object store + backup verification |
| **racknerd-aegis** | <VPS_PUBLIC_IP> | Ubuntu 22.04 LTS | `<vps-user>@hs` | Komodo-managed stack `aegis-periphery` | VPS gateway (Pangolin/Traefik/identity) |

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
   │  omni   │  │server04  │ │  │  storage   │                    │
   │  .30    │  │  .17     │ │  │  .244      │                    │
   │ Talos   │  │ Traefik  │ │  │ Garage S3  │                    │
   │ Mgmt    │  │ Vault-   │ │  │ backup-    │                    │
   │ Alloy   │  │ warden   │ │  │ verifier   │                    │
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
| Periphery | systemd service | v2.1.2, outbound mode. Config at `/etc/komodo/periphery.config.toml` (`core_address = http://192.168.11.200:9120`, `connect_as = komodo`). Port 8120 still bound but unused. |
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
| Vaultwarden Backup | `vaultwarden-backup` | Daily SQLite backup sidecar (02:00 UTC) |
| Periphery | `komodo-periphery-periphery-1` | Also serves as Komodo build server |
| Alloy | systemd service | Host metrics + SMART + cAdvisor + Docker logs + journal. Config at `/etc/alloy/config.alloy` |
| smartctl_exporter | systemd service | SMART disk health on `127.0.0.1:9633` (5 drives: 4 SAS via cciss + 1 SSD) |

**Traefik network**: Services that need reverse proxying must join the `traefik_proxy` external Docker network and use Traefik labels for routing.

**Vaultwarden backups**: An Alpine sidecar runs `sqlite3 .backup` daily at 02:00 UTC, storing copies locally at `/opt/backups/vaultwarden/` (pruned at 180 days) and pushing them off-host over SFTP to the storage host's `backup-landing` share. The `backup-verifier` stack there integrity-checks each file and promotes it into `backup-archive`, which no sender identity can reach. See `docker/stacks/server04/vaultwarden/backup.sh` and `docker/stacks/storage/backup-verifier/`.

**Periphery quirk**: Requires explicit `dns: ["192.168.11.1"]` in the periphery compose — Docker's embedded DNS doesn't forward correctly on this host.

---

### storage (192.168.11.244)

**Platform**: UGREEN DXP6800 Pro running UGOS — a vendor OS on squashfs + overlay
**SSH user**: `mohitsharma44` (passwordless sudo)

The storage host. It runs storage *providers* only; storage consumers live elsewhere and
reach it over the network. Everything lives on `/volume2`, never `/etc`, because `/` is a
firmware-replaceable overlay.

**Never install system packages or hand-patch UGOS**, and **never drive `mdadm` directly**
— `storage_serv` keeps its own pool state. Shares are created and deleted in the UGOS UI
only; a shell `rm` desyncs UGOS's own share records.

| Service | Container | Notes |
|---------|-----------|-------|
| Garage | `garage` | S3 on 3900, admin on 3903, RPC on 3901 (`objects.sharmamohit.com:3900`) |
| Snapshotter | `garage-snapshotter` | Triggers metadata snapshots on wall clock, exports freshness on 9102 |
| Backup verifier | `backup-verifier` | Integrity-checks landed backups, promotes them, exports metrics on 9101 |
| Periphery | `periphery-periphery-1` | `PERIPHERY_ROOT_DIRECTORY=/volume2/komodo/etc-komodo` |

**Storage**: `/volume1` = md1, RAID6, 4x 6TB IronWolf. `/volume2` = md2, RAID1 SSD.
The boot device (`nvme0n1`) is in no array.

**Object store data**: `/volume1/object-store/{meta,data}`; snapshots on the *other*
array at `/volume2/object-store-snapshots`, so a metadata copy does not share a failure
domain with the metadata it protects.

**Config**: `docker/stacks/storage/garage/garage.toml` holds no secrets — Garage reads
`GARAGE_RPC_SECRET`, `GARAGE_ADMIN_TOKEN` and `GARAGE_METRICS_TOKEN` from the environment.

**S3 buckets**: `thanos-metrics`, `loki-chunks`, `loki-ruler`, `tempo-traces`, with one
scoped key per consumer (`loki`, `tempo`, `thanos`), none holding `owner`.

**Region gotcha**: Garage validates the SigV4 region. Consumers must send `region: garage`;
`us-east-1` fails authentication and looks like a credentials problem.

---

### racknerd-aegis (<VPS_PUBLIC_IP>)

**Platform**: VPS (Ubuntu 22.04)
**SSH**: via `ssh hs` alias (account configured locally)

Public gateway. Runs Pangolin (reverse tunnel control plane) + Gerbil (WireGuard) + public-facing Traefik with CrowdSec, plus identity stack (LLDAP + PocketID) and the Komodo agent that manages it all.

| Service | Container | Notes |
|---------|-----------|-------|
| aegis-traefik | `aegis-traefik` | Public reverse proxy, CrowdSec bouncer plugin, Route53 ACME |
| aegis-crowdsec | `aegis-crowdsec` | IDS/IPS reading Traefik access logs |
| pangolin | `pangolin` | Reverse tunnel control plane, port 3001 (API) |
| gerbil | `gerbil` | WireGuard manager, NAT hole punch |
| pangolin-traefik | `pangolin-traefik` | Inner Traefik, `network_mode: service:gerbil` |
| pangolin-newt | `pangolin-newt` | Newt agent — VPS-side site for `racknerd-aegis` |
| pangolin-client-obs | `pangolin-client-obs` | Machine Client, network_mode: host. Provides Pangolin DNS proxy + WireGuard routes to private resources (k8s-prometheus, k8s-loki, komodo.private) |
| pocketid | `pocketid` | OIDC provider, `pocketid.proxy.sharmamohit.com` |
| lldap | `lldap` | LDAP directory (identity-internal network only) |
| periphery | `periphery` | v2.1.2, outbound mode. Dials Core via `komodo.private.sharmamohit.com:9120`. Isolated on `newt-periphery` Docker network. Managed by Komodo as the `aegis-periphery` stack. |
| racknerd-aegis-alloy | `racknerd-aegis-alloy-alloy-1` | Host/container metrics + CrowdSec scrape, pushes via Pangolin tunnel |

**Outbound periphery DNS**: The `aegis-periphery` container is on the isolated `newt-periphery` bridge network (no host networking). It resolves `*.private.sharmamohit.com` via Docker's embedded DNS → host systemd-resolved → split DNS rule → Pangolin DNS proxy at `100.96.128.1`. The split-DNS rule is installed by the `pangolin-dns.service` systemd unit (`/usr/local/bin/pangolin-dns-setup.sh`, oneshot, runs after `docker.service`), which derives the DNS proxy IP dynamically from the routed subnet on the `pangolin` interface.

**Networks (4-way isolation)**: `traefik-public` (internet-facing) / `pangolin-internal` (Pangolin control + PocketID) / `identity-internal` (LLDAP + PocketID bridge) / `newt-periphery` (Periphery + Newt, no exposed ports). Plus host networking for the Machine Client and Alloy. A compromised public container cannot reach Periphery or LLDAP. See [docs/architecture.md](architecture.md) L3 for the full matrix.

## Periphery Compose Locations

Quick reference for restarting periphery agents:

```bash
# komodo (systemd Periphery)
ssh root@komodo "systemctl restart periphery"

# nvr, kasm, omni (root users)
ssh root@nvr  "cd /root/komodo-periphery && docker compose up -d --force-recreate"
ssh root@kasm "cd /root/komodo-periphery && docker compose up -d --force-recreate"
ssh root@omni "cd /root/komodo-periphery && docker compose up -d --force-recreate"

# server04, storage (non-root users)
ssh mohitsharma44@server04       "cd ~/komodo-periphery && docker compose up -d --force-recreate"
ssh mohitsharma44@192.168.11.244 "cd /volume2/komodo/periphery && sudo docker compose up -d --force-recreate"
```

## Maintenance

### Pulling Updated Periphery Image on All Hosts

```bash
# After building: km execute run-build periphery-custom
for host in root@nvr root@kasm root@omni; do
  ssh $host "docker pull mohitsharma44/komodo-periphery-sops:latest" &
done
for host in mohitsharma44@server04 mohitsharma44@192.168.11.244; do
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
for host in komodo nvr kasm omni server04 storage; do
  echo -n "$host: "
  curl -sk https://$host.sharmamohit.com:8120/health 2>/dev/null || echo "unreachable"
done
```
