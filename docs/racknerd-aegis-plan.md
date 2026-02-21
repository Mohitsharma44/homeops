# Plan: Pangolin Sites + Machine Clients for racknerd-aegis VPS Management

## Context

The homeops Komodo setup manages Docker containers across 6 homelab hosts. A VPS at RackNerd (23.94.73.98) runs Pangolin (reverse tunnel gateway), CrowdSec, Traefik, LLDAP, and PocketID — currently deployed manually via `deploy.sh` (rsync).

**Goals:**
1. Manage VPS containers through Komodo without exposing Periphery or Komodo Core to the internet
2. Allow Alloy on VPS to push metrics/logs to K8s Prometheus/Loki
3. Use Pangolin's existing tunnel infrastructure (no separate WireGuard tunnel)

**Approach:** Pangolin Sites (Newt for private resources) + Local Sites (for same-host public services) + Machine Clients. Pangolin acts as control plane for peer discovery; data flows peer-to-peer via WireGuard NAT hole punching (with Gerbil relay fallback). No new networking paradigm — reuses existing Pangolin/Gerbil infrastructure.

**Branch**: `feat/racknerd-aegis`

---

## POC Results (Phase 0 — completed)

All core hypotheses validated. Key findings that correct the original plan:

| # | Original Assumption | POC Finding |
|---|---------------------|-------------|
| 1 | Machine Client image: `fosrl/pangolin:latest` with `up` CLI | **`fosrl/pangolin-cli:latest`** with env vars `CLIENT_ID`, `CLIENT_SECRET`, `PANGOLIN_ENDPOINT` |
| 2 | Machine Client docker run as-is | Needs **`-v /etc/resolv.conf:/etc/resolv.conf`** for DNS override to work on host |
| 3 | Private resources just work after creation | Machine Clients need **explicit access grants** in Pangolin UI Access Policy tab |
| 4 | Periphery address `https://...` through tunnel | Private resources are **HTTP-only** (no TLS from Pangolin). Periphery has its own TLS so `https://` still works — that's Periphery's cert, not Pangolin's |
| 5 | NAT hole punch both directions | Homelab → VPS **relays** (VPS Newt self-loop reports Docker bridge IP). Accepted — relay goes through Gerbil on same VPS, negligible overhead |
| 6 | Aliases like `*.proxy.sharmamohit.com` | **Conflicts with public wildcard DNS** — causes misleading 404. Use `*.private.sharmamohit.com` for private resource aliases |

### Additional requirements discovered

- **DNS failsafe**: pangolin-cli backs up resolv.conf to `/etc/resolv.conf.olm.backup`. If container crashes without cleanup, ALL host DNS breaks. Production needs a systemd watchdog timer or similar to restore the backup if `100.96.128.1` becomes unreachable.
- **Access policy setup**: Each Machine Client must be explicitly granted access to its target private resources in Pangolin UI.
- **server04 netplan cleanup** (separate task): stale DNS servers in `/etc/netplan/01-netcfg.yaml` — says `.2/.31/.32` but actual resolv.conf uses `.1`.

### POC Success Criteria Scorecard

| Test | Result |
|------|--------|
| Local site resource via container name | **Pass** (auth disabled for public resource) |
| VPS Newt connects to own Pangolin | **Pass** |
| Newt private resource via Docker DNS | **Pass** |
| Homelab Machine Client connects | **Pass** |
| Homelab curl → VPS private nginx | **Pass** (needed resolv.conf mount) |
| VPS Machine Client connects | **Pass** |
| VPS curl → Homelab nginx | **Pass** |
| Tunnels are peer-to-peer | **Partial** — VPS→homelab direct (8.6ms), homelab→VPS relayed (26ms). Accepted. |

---

## Architecture

```
┌── K8s Cluster (192.168.11.19/21/22) ──────────┐
│  Newt Site (Helm chart)                        │
│  ├─ Connects to pangolin.proxy.sharmamohit.com │
│  └─ Private resources:                         │
│     - Prometheus (prometheus.monitoring.svc:9090)│
│     - Loki (loki.monitoring.svc:3100)           │
│     - (future: public resources for exposing    │
│       K8s services to internet via Pangolin)    │
└────────────────────────────────────────────────┘
         ↕ WireGuard (peer-to-peer via NAT hole punch)

┌── VPS (23.94.73.98) ──────────────────────────┐
│  Pangolin + Gerbil + Traefik (existing)        │
│                                                 │
│  Local Site (public VPS services)               │
│  └─ Containers on shared Docker network with    │
│     Gerbil — routed by container name           │
│     e.g. http://pocketid:8080                   │
│                                                 │
│  Newt Site (connects to own Pangolin)           │
│  └─ Private resources only:                     │
│     - Periphery (periphery:8120 via Docker DNS) │
│     Newt + Periphery share isolated network     │
│                                                 │
│  Machine Client (network_mode:host)             │
│  └─ Gets routes to K8s private resources        │
│     → Alloy pushes to Prometheus/Loki           │
└─────────────────────────────────────────────────┘
         ↕ WireGuard (homelab→VPS relays via Gerbil, VPS→homelab hole punches)

┌── Komodo (192.168.11.200) ─────────────────────┐
│  Machine Client (network_mode:host)             │
│  └─ Gets routes to VPS private resources        │
│     → Komodo reaches Periphery on VPS           │
└─────────────────────────────────────────────────┘
```

**Data flow:**
- Pangolin = control plane only (peer discovery, credential validation, access policy)
- Data flows: Machine Client ↔ Newt Site (peer-to-peer WireGuard when hole punch succeeds)
- Fallback: Gerbil relays on UDP 21820 (when hole punch fails — e.g., homelab→VPS due to self-loop)

**DNS for private resources:**
- Machine Client runs a local DNS proxy at `100.96.128.1:53`
- Intercepts private resource aliases → returns tunnel IPs
- Forwards all other DNS queries to upstream (original system resolver)
- Requires `-v /etc/resolv.conf:/etc/resolv.conf` to actually override host DNS

## Docker Network Segmentation (VPS)

```
Networks:
  traefik-public (external)    — Outer Traefik, CrowdSec, Gerbil (public-facing)
  pangolin-internal (external) — Pangolin core, Gerbil, pangolin-traefik,
                                  and containers exposed via Local site
  identity-internal (bridge)   — PocketID ↔ LLDAP internal comms
  newt-periphery (bridge)      — Newt ↔ Periphery only (isolated private resource)

Container → Network assignments:
  aegis-traefik     → traefik-public
  aegis-crowdsec    → traefik-public
  gerbil            → traefik-public, pangolin-internal
  pangolin          → pangolin-internal
  pangolin-traefik  → network_mode: service:gerbil (inherits gerbil's networks)
  pocketid          → pangolin-internal (Local site: http://pocketid:8080),
                       identity-internal (talks to LLDAP)
  lldap             → identity-internal ONLY (NOT on pangolin — LDAP isolated)
  newt              → newt-periphery (reaches Periphery for private resource)
  periphery         → newt-periphery ONLY (NOT on pangolin — isolated)
  alloy             → network_mode: host (Machine Client WireGuard routes)
```

**Security principle:** Only containers that need WAN/LAN access touch the Pangolin
network. Databases, admin tools, and internal services stay on isolated bridge
networks. A compromise of a public-facing app cannot pivot to Periphery or LLDAP.

---

## ~~Phase 1: Periphery Deployment on VPS (manual)~~ DONE

> Completed Feb 19, 2026. Age key deployed, `newt-periphery` network created,
> Periphery running (network-isolated, no published ports). Also fixed VPS
> `/etc/resolv.conf` — symlinked to `systemd-resolved` stub (was corrupted from
> POC Machine Client). `systemd-resolved` is active on VPS with upstream DNS
> `8.8.8.8`/`8.8.4.4` from interface config.

### 1a. Deploy age key

```bash
ssh hs "mkdir -p /etc/sops/age"
scp -P 2244 ~/.sops/key.txt root@23.94.73.98:/etc/sops/age/keys.txt
ssh hs "chmod 600 /etc/sops/age/keys.txt && chown root:root /etc/sops/age/keys.txt"
```

### 1b. Create isolated network for Newt ↔ Periphery

```bash
ssh hs "docker network create newt-periphery"
```

### 1c. Deploy Periphery container (NO port publishing — network-isolated)

**`/root/komodo-periphery/compose.yaml`** on VPS:
```yaml
# Bootstrap Periphery for initial Komodo connectivity.
# After Phase 5 migration, the aegis-periphery Komodo stack takes over.
services:
  periphery:
    image: mohitsharma44/komodo-periphery-sops:latest
    # Custom build — "latest" is controlled by our build pipeline (periphery-custom).
    # Upstream base: ghcr.io/moghtech/komodo-periphery
    container_name: periphery
    restart: unless-stopped
    labels:
      com.homeops.role: "komodo-periphery"
      com.homeops.network: "newt-periphery only (isolated)"
      com.homeops.managed-by: "bootstrap — replaced by aegis-periphery Komodo stack"
    # NO ports: section — Periphery is NOT exposed to host network or internet.
    # Only reachable via Docker DNS from containers on newt-periphery network (i.e., Newt).
    networks:
      - newt-periphery
    volumes:
      # Docker socket requires read-write — Periphery manages the full container
      # lifecycle: create/start/stop/remove, pull images, create networks.
      - /var/run/docker.sock:/var/run/docker.sock
      - /etc/sops/age:/etc/sops/age:ro
    environment:
      SOPS_AGE_KEY_FILE: /etc/sops/age/keys.txt

networks:
  newt-periphery:
    external: true
```

```bash
ssh hs "mkdir -p /root/komodo-periphery && cd /root/komodo-periphery && docker compose pull && docker compose up -d"
```

**Security:** No `ports:` mapping means Periphery is NEVER reachable from the host
network or internet. No iptables rules needed. Only containers on the `newt-periphery`
Docker network can reach it (i.e., Newt). Defense-in-depth via Docker network
isolation — simpler and more reliable than DOCKER-USER iptables chains.

### 1d. Verify

```bash
# From VPS host — should FAIL (not published to host)
ssh hs "curl -sk --connect-timeout 5 https://localhost:8120/health"

# From internet — should FAIL
curl -sk --connect-timeout 5 https://23.94.73.98:8120/health

# From within the newt-periphery network — should work
ssh hs "docker run --rm --network newt-periphery curlimages/curl -sk https://periphery:8120/health"
```

---

## Phase 2: Pangolin Sites + Machine Clients Setup (manual, in Pangolin UI)

### 2a. VPS Newt site (for Periphery private resource)

1. Pangolin UI → Sites → Create Site
2. Name: `racknerd-aegis`, Type: **Newt**
3. Save credentials (`NEWT_ID`, `NEWT_SECRET`)

4. Deploy Newt on VPS on the `newt-periphery` network (same network as Periphery).

   **`/root/pangolin-newt/compose.yaml`** on VPS:
   ```yaml
   # Bootstrap Newt for initial tunnel connectivity.
   # After Phase 5 migration, the aegis-newt Komodo stack takes over.
   services:
     newt:
       image: fosrl/newt:1.9.0
       container_name: pangolin-newt
       restart: unless-stopped
       labels:
         com.homeops.role: "pangolin-newt-tunnel"
         com.homeops.network: "newt-periphery (reaches Periphery by Docker DNS)"
         com.homeops.managed-by: "bootstrap — replaced by aegis-newt Komodo stack"
       networks:
         - newt-periphery
       env_file: .env

   networks:
     newt-periphery:
       external: true
   ```

   Create `.env` on VPS (plaintext, manual bootstrap — not in repo):
   ```
   PANGOLIN_ENDPOINT=https://pangolin.proxy.sharmamohit.com
   NEWT_ID=<racknerd-aegis-newt-id>
   NEWT_SECRET=<racknerd-aegis-newt-secret>
   ```

   ```bash
   ssh hs "mkdir -p /root/pangolin-newt"
   # Copy .env to VPS with credentials from Pangolin UI
   ssh hs "cd /root/pangolin-newt && docker compose pull && docker compose up -d"
   ```

5. **Verify:** Pangolin UI — `racknerd-aegis` site shows "Connected"

6. Define private resource:
   - Site: `racknerd-aegis`
   - Type: **Private**
   - Destination: `periphery:8120` (Docker DNS — both on `newt-periphery` network)
   - Name: `vps-periphery`
   - Alias: `periphery.private.sharmamohit.com` (avoid `*.proxy.sharmamohit.com` — conflicts with public wildcard)

### 2b. K8s Newt site (for Alloy metrics — future)

1. Pangolin UI → Sites → Create Site
2. Name: `homelab-k8s`, Type: **Newt**
3. Deploy via ArgoCD (consistent with existing GitOps pattern):
   - Create SOPS-encrypted secret with Newt `endpoint`, `id`, `secret` values
   - Create ArgoCD Application pointing to `fossorial/newt` Helm chart
   - ArgoCD auto-syncs; Flux decrypts the secret in-cluster

4. Define K8s private resources on `homelab-k8s` site:
   - **Prometheus**: destination `prometheus.monitoring.svc.cluster.local:9090`
   - **Loki**: destination `loki.monitoring.svc.cluster.local:3100`

### ~~2c. Create Machine Clients~~ DONE (komodo-mgmt — Feb 19)

> **Completed:** Komodo Machine Client deployed on LXC 200. Required adding TUN device
> to Proxmox LXC config (`lxc.cgroup2.devices.allow: c 10:200 rwm` +
> `lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file` in
> `/etc/pve/lxc/200.conf` on PVE host, then stop+start LXC).
> Tunnel connected via relay (holepunch fails for LXC — expected). RTT ~13-27ms.
> Periphery reachable at `periphery.private.sharmamohit.com:8120` (resolves to 100.96.128.8).
>
> **OLM backup gotcha:** The OLM DNS Manager creates `/etc/resolv.conf.olm.backup`
> **inside** the container (not on the host), because only `/etc/resolv.conf` is
> bind-mounted. Do NOT try to bind-mount the backup file — OLM's startup cleanup
> tries to `rm` it and fails on bind mounts ("device or resource busy"), causing
> it to skip DNS override entirely. Instead, keep a host-side backup at
> `/etc/resolv.conf.pre-pangolin` for the watchdog to use.

Machine Clients are managed via Komodo GitOps (compose files in repo, deployed as stacks).
During bootstrap (before Komodo manages VPS), deploy manually using compose files at
temporary host paths. After Phase 5 migration, Komodo stacks take over.

1. **Komodo Machine Client** — for Komodo to reach VPS Periphery
   - Pangolin UI → Clients → Create → Machine
   - Name: `komodo-mgmt`
   - **Grant access** to `vps-periphery` private resource in Access Policy tab

   **Bootstrap** — deploy on Komodo (192.168.11.200):
   ```yaml
   # /root/pangolin-client/compose.yaml
   # Bootstrap — replaced by komodo-pangolin-client Komodo stack after Phase 5.
   services:
     pangolin-cli:
       image: fosrl/pangolin-cli:0.3.3
       container_name: pangolin-cli
       restart: unless-stopped
       labels:
         com.homeops.role: "pangolin-machine-client"
         com.homeops.target: "vps-periphery private resource"
         com.homeops.critical: "redeploying severs VPS management tunnel"
       network_mode: host
       cap_add:
         - NET_ADMIN
       devices:
         - /dev/net/tun:/dev/net/tun
       volumes:
         - /etc/resolv.conf:/etc/resolv.conf
       env_file: .env
   ```

   Create `.env` on komodo (plaintext, manual bootstrap — not in repo):
   ```
   PANGOLIN_ENDPOINT=https://pangolin.proxy.sharmamohit.com
   CLIENT_ID=<komodo-mgmt-client-id>
   CLIENT_SECRET=<komodo-mgmt-client-secret>
   ```

   ```bash
   ssh root@komodo "mkdir -p /root/pangolin-client"
   # Copy .env to komodo with credentials from Pangolin UI
   ssh root@komodo "cd /root/pangolin-client && docker compose pull && docker compose up -d"
   ```

   **Production** — Komodo stack `komodo-pangolin-client` (Phase 4, compose at
   `docker/stacks/komodo/pangolin-client/compose.yaml`, SOPS-encrypted `.sops.env`).

2. **VPS Machine Client** — for Alloy to reach Prometheus/Loki (future, after K8s Newt site)
   - Pangolin UI → Clients → Create → Machine
   - Name: `racknerd-aegis-obs`
   - **Grant access** to Prometheus and Loki private resources

   **Bootstrap** — deploy on VPS:
   ```yaml
   # /root/pangolin-obs-client/compose.yaml
   # Bootstrap — replaced by aegis-obs-client Komodo stack after Phase 5.
   services:
     pangolin-cli:
       image: fosrl/pangolin-cli:0.3.3
       container_name: pangolin-obs-client
       restart: unless-stopped
       labels:
         com.homeops.role: "pangolin-machine-client"
         com.homeops.target: "K8s Prometheus + Loki private resources"
       network_mode: host
       cap_add:
         - NET_ADMIN
       devices:
         - /dev/net/tun:/dev/net/tun
       volumes:
         - /etc/resolv.conf:/etc/resolv.conf
       env_file: .env
   ```

   Create `.env` on VPS (plaintext, manual bootstrap — not in repo):
   ```
   PANGOLIN_ENDPOINT=https://pangolin.proxy.sharmamohit.com
   CLIENT_ID=<vps-obs-client-id>
   CLIENT_SECRET=<vps-obs-client-secret>
   ```

   ```bash
   ssh hs "mkdir -p /root/pangolin-obs-client"
   # Copy .env to VPS with credentials from Pangolin UI
   ssh hs "cd /root/pangolin-obs-client && docker compose pull && docker compose up -d"
   ```

   **Production** — Komodo stack `aegis-obs-client` (Phase 4, compose at
   `docker/stacks/racknerd-aegis/pangolin-obs-client/compose.yaml`, SOPS-encrypted `.sops.env`).

### 2d. DNS failsafe (required for any host running pangolin-cli with resolv.conf mount)

The pangolin-cli container overrides `/etc/resolv.conf` to point to its DNS proxy
(`100.96.128.1`). If the container crashes without cleanup, ALL host DNS breaks.

**Recovery logic (4-tier fallback):**
1. Is `100.96.128.1` reachable? → do nothing (pangolin-cli is healthy)
2. Does `/etc/resolv.conf.pre-pangolin` exist? → restore it (host-side backup,
   created manually before first pangolin-cli start — OLM's own backup at
   `/etc/resolv.conf.olm.backup` lives inside the container and is lost on crash)
3. Is `systemd-resolved` active? → symlink to stub + flush caches
4. Last resort → hardcoded fallback DNS for the host

**Per-host fallback DNS:**
| Host | Fallback DNS | Reason |
|------|-------------|--------|
| komodo (192.168.11.200) | `192.168.11.1` | Homelab gateway/DNS |
| racknerd-aegis (23.94.73.98) | `8.8.8.8`, `8.8.4.4` | VPS provider DNS (from `/etc/network/interfaces`) |

> **VPS note:** `systemd-resolved` is active on racknerd-aegis with
> `/etc/resolv.conf` symlinked to `/run/systemd/resolve/stub-resolv.conf`.
> The resolved stub at `127.0.0.53` forwards to upstream `8.8.8.8`/`8.8.4.4`
> from the `eth0` interface config. `resolvectl revert` should recover DNS
> in most cases. The hardcoded fallback is a last resort.

Deploy a systemd watchdog on each host running pangolin-cli:

```bash
# /etc/systemd/system/pangolin-dns-watchdog.service
[Unit]
Description=Restore DNS if Pangolin CLI DNS proxy is unreachable

[Service]
Type=oneshot
# FALLBACK_DNS is host-specific: "192.168.11.1" for homelab, "8.8.8.8" for VPS
Environment=FALLBACK_DNS=8.8.8.8
ExecStart=/bin/bash -c '\
  # Step 1: Is pangolin-cli DNS proxy healthy? \
  if dig +short +timeout=2 @100.96.128.1 example.com >/dev/null 2>&1; then \
    exit 0; \
  fi; \
  echo "pangolin-dns-watchdog: DNS proxy unreachable, recovering..."; \
  # Step 2: Host-side backup exists? Restore it. \
  # Note: OLM backup at /etc/resolv.conf.olm.backup lives INSIDE the container \
  # (only /etc/resolv.conf is bind-mounted) and is lost on crash. \
  # /etc/resolv.conf.pre-pangolin is our host-side backup created before first start. \
  if [ -f /etc/resolv.conf.pre-pangolin ]; then \
    cp /etc/resolv.conf.pre-pangolin /etc/resolv.conf; \
    echo "pangolin-dns-watchdog: restored from /etc/resolv.conf.pre-pangolin"; \
    exit 0; \
  fi; \
  # Step 3: Try systemd-resolved (if active, symlink to stub restores DNS) \
  if systemctl is-active --quiet systemd-resolved; then \
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf; \
    resolvectl flush-caches 2>/dev/null; \
    echo "pangolin-dns-watchdog: restored via systemd-resolved stub"; \
    exit 0; \
  fi; \
  # Step 4: Last resort — hardcoded fallback DNS \
  echo "nameserver ${FALLBACK_DNS}" > /etc/resolv.conf; \
  echo "pangolin-dns-watchdog: wrote hardcoded fallback DNS ${FALLBACK_DNS}"; \
'

# /etc/systemd/system/pangolin-dns-watchdog.timer
[Unit]
Description=Check Pangolin DNS every 30s

[Timer]
OnBootSec=60
OnUnitActiveSec=30

[Install]
WantedBy=timers.target
```

**Deployment:**
```bash
# On each host running pangolin-cli, adjust FALLBACK_DNS:
#   komodo:         Environment=FALLBACK_DNS=192.168.11.1
#   racknerd-aegis: Environment=FALLBACK_DNS=8.8.8.8
systemctl daemon-reload
systemctl enable --now pangolin-dns-watchdog.timer
```

### ~~2e. Verify connectivity~~ DONE (Feb 19)

> **Completed:** `km list servers -a` shows all 7 servers `ok` including racknerd-aegis.
> `km container -a` shows all 9 VPS containers (aegis-traefik, aegis-crowdsec,
> gerbil, pangolin, pangolin-traefik, pocketid, lldap, pangolin-newt, periphery).
>
> **Docker DNS gotcha:** Komodo Core (bridge network) couldn't resolve
> `periphery.private.sharmamohit.com` because Docker caches host DNS at daemon startup.
> Bind-mounting `/etc/resolv.conf` broke internal DNS (Core couldn't find `ferretdb:27017`).
> Fix: `dns: [100.96.128.1]` directive in Core's compose — tells Docker's embedded DNS
> to forward external queries to Pangolin proxy while preserving container name resolution.
> PRs: #33 (bind-mount, broken), #34 (dns directive, correct).

### ~~2f. Update Komodo server address~~ DONE (Feb 19)

> **Completed:** Server added declaratively via `docker/komodo-resources/servers.toml`
> (PR #32). Address: `https://periphery.private.sharmamohit.com:8120`.
> Synced via `km execute sync`.

---

## Phase 3: Prepare VPS runtime data (manual, before migration)

### 3a. Pre-create external Docker networks

```bash
ssh hs "
docker network create traefik-public 2>/dev/null || true
docker network create pangolin-internal 2>/dev/null || true
docker network create newt-periphery 2>/dev/null || true
"
```

### 3b. Prepare target directories for runtime data

Create the directory structure now. **Data copy happens in Phase 5 AFTER services
are stopped** (prevents SQLite corruption from copying `pangolin.db` while running).

```bash
ssh hs "
mkdir -p /opt/aegis/gateway/letsencrypt
mkdir -p /opt/aegis/pangolin/config/{db,letsencrypt,traefik/logs}
mkdir -p /opt/aegis/crowdsec/{config,data}
chmod 700 /opt/aegis/gateway/letsencrypt /opt/aegis/pangolin/config/db /opt/aegis/pangolin/config
"
```

**Runtime data layout** (on VPS, NOT in repo):
```
/opt/aegis/
├── gateway/letsencrypt/acme.json    (chmod 600 — contains TLS private keys)
├── pangolin/config/
│   ├── config.yml, key              (chmod 600 — Pangolin signing key)
│   ├── db/pangolin.db               (chmod 600 — site credentials, routing)
│   ├── letsencrypt/acme.json        (chmod 600)
│   └── traefik/logs/
└── crowdsec/{config/, data/}
```

---

## Phase 4: Repo changes (code — single commit on `feat/racknerd-aegis` branch)

### 4a. Add server to `docker/komodo-resources/servers.toml`

```toml
[[server]]
name = "racknerd-aegis"
description = "RackNerd VPS — Pangolin gateway, CrowdSec, identity providers"
tags = ["vps", "gateway"]
[server.config]
address = "https://periphery.private.sharmamohit.com:8120"
region = "VPS"
enabled = true
```

> **Note:** The server address uses the Pangolin private resource alias for Periphery.
> Komodo's Machine Client provides the WireGuard route. DNS resolves via the
> pangolin-cli DNS proxy at `100.96.128.1`.

### 4b. Create `docker/komodo-resources/stacks-racknerd-aegis.toml`

```toml
[[stack]]
name = "aegis-gateway"
description = "Main Traefik reverse proxy + CrowdSec IDS/IPS"
tags = ["infrastructure", "racknerd-aegis"]
[stack.config]
server_id = "racknerd-aegis"
file_paths = ["docker/stacks/racknerd-aegis/aegis-gateway/compose.yaml"]
repo = "mohitsharma44/homeops"
branch = "main"
[stack.config.pre_deploy]
path = "docker/stacks/racknerd-aegis/aegis-gateway"
command = "sops-decrypt.sh"

[[stack]]
name = "aegis-pangolin"
description = "Pangolin reverse tunnel server + Gerbil WireGuard + inner Traefik"
tags = ["networking", "racknerd-aegis"]
[stack.config]
server_id = "racknerd-aegis"
file_paths = ["docker/stacks/racknerd-aegis/pangolin/compose.yaml"]
repo = "mohitsharma44/homeops"
branch = "main"
[stack.config.pre_deploy]
path = "docker/stacks/racknerd-aegis/pangolin"
command = "sops-decrypt.sh"

[[stack]]
name = "aegis-identity"
description = "LLDAP directory + PocketID OIDC provider"
tags = ["security", "racknerd-aegis"]
[stack.config]
server_id = "racknerd-aegis"
file_paths = ["docker/stacks/racknerd-aegis/identity/compose.yaml"]
repo = "mohitsharma44/homeops"
branch = "main"
[stack.config.pre_deploy]
path = "docker/stacks/racknerd-aegis/identity"
command = "sops-decrypt.sh"

[[stack]]
name = "aegis-periphery"
description = "Komodo Periphery agent (SOPS+age) — isolated on newt-periphery network"
tags = ["infrastructure", "racknerd-aegis"]
[stack.config]
server_id = "racknerd-aegis"
file_paths = ["docker/stacks/racknerd-aegis/periphery/compose.yaml"]
repo = "mohitsharma44/homeops"
branch = "main"

[[stack]]
name = "aegis-newt"
description = "Newt agent — connects to Pangolin for private resource tunneling"
tags = ["networking", "racknerd-aegis"]
[stack.config]
server_id = "racknerd-aegis"
file_paths = ["docker/stacks/racknerd-aegis/newt/compose.yaml"]
repo = "mohitsharma44/homeops"
branch = "main"
[stack.config.pre_deploy]
path = "docker/stacks/racknerd-aegis/newt"
command = "sops-decrypt.sh"

[[stack]]
name = "racknerd-aegis-alloy"
description = "Grafana Alloy monitoring agent for racknerd-aegis VPS"
tags = ["monitoring", "racknerd-aegis"]
[stack.config]
server_id = "racknerd-aegis"
file_paths = ["docker/stacks/shared/alloy/compose.yaml"]
repo = "mohitsharma44/homeops"
branch = "main"
environment = """
HOSTNAME=racknerd-aegis
"""
[stack.config.pre_deploy]
path = "docker/stacks/shared/alloy"
command = "sops-decrypt.sh"

[[stack]]
name = "aegis-obs-client"
description = "Pangolin Machine Client — WireGuard route to K8s Prometheus/Loki (future)"
tags = ["networking", "racknerd-aegis"]
[stack.config]
server_id = "racknerd-aegis"
file_paths = ["docker/stacks/racknerd-aegis/pangolin-obs-client/compose.yaml"]
repo = "mohitsharma44/homeops"
branch = "main"
[stack.config.pre_deploy]
path = "docker/stacks/racknerd-aegis/pangolin-obs-client"
command = "sops-decrypt.sh"
```

Add to `docker/komodo-resources/stacks-komodo.toml`:

```toml
[[stack]]
name = "komodo-pangolin-client"
description = "Pangolin Machine Client — WireGuard route to VPS Periphery"
tags = ["networking", "komodo"]
[stack.config]
server_id = "komodo"
file_paths = ["docker/stacks/komodo/pangolin-client/compose.yaml"]
repo = "mohitsharma44/homeops"
branch = "main"
[stack.config.pre_deploy]
path = "docker/stacks/komodo/pangolin-client"
command = "sops-decrypt.sh"
```

### 4c. Update `docker/komodo-resources/procedures.toml`

Modify `deploy-all-stacks`:
- **Exclude** `komodo-core`, `komodo-pangolin-client`, `aegis-pangolin`, `aegis-newt`,
  `aegis-periphery`, `aegis-obs-client` from batch deploy (redeploying these severs
  management tunnels — circular dependency).
- Add separate `deploy-vps-infra` procedure with explicit ordering:
  1. `aegis-gateway` (Traefik + CrowdSec)
  2. `aegis-pangolin` (Pangolin + Gerbil)
  3. `aegis-newt` (Newt tunnel)
  4. `aegis-periphery` (Periphery — depends on Newt network)
- Keep existing stages for homelab + remaining VPS stacks.

### 4d. Create compose files (multi-network segmentation)

**Directory structure:**
```
docker/stacks/komodo/
└── pangolin-client/
    ├── compose.yaml              # Machine Client → VPS Periphery
    └── .sops.env                 # CLIENT_ID, CLIENT_SECRET

docker/stacks/racknerd-aegis/
├── aegis-gateway/
│   ├── compose.yaml              # aegis-traefik + aegis-crowdsec
│   ├── .sops.env                 # AWS creds, CrowdSec bouncer key
│   └── config/
│       ├── dynamic/
│       │   └── pangolin.yml      # TCP passthrough + HTTP forward rules
│       └── crowdsec/
│           └── acquis.d/
│               ├── traefik.yaml          # Main Traefik log acquisition
│               └── pangolin-traefik.yaml # Pangolin Traefik log acquisition
├── pangolin/
│   ├── compose.yaml              # pangolin + gerbil + pangolin-traefik
│   └── .sops.env                 # CROWDSEC_BOUNCER_KEY only
├── identity/
│   ├── compose.yaml              # lldap + pocketid
│   └── .sops.env                 # LDAP admin creds, JWT secret, PocketID key
├── periphery/
│   └── compose.yaml              # Komodo Periphery (SOPS+age), newt-periphery network only
├── newt/
│   ├── compose.yaml              # Newt agent, newt-periphery network
│   └── .sops.env                 # NEWT_ID, NEWT_SECRET
└── pangolin-obs-client/
    ├── compose.yaml              # Machine Client → K8s Prometheus/Loki
    └── .sops.env                 # CLIENT_ID, CLIENT_SECRET
```

**Key networking:**
- `gerbil`: traefik-public + pangolin-internal
- `pangolin-traefik`: `network_mode: service:gerbil` (inherits Gerbil's networks, must be in same compose)
- `pocketid`: pangolin-internal + identity-internal
- `lldap`: identity-internal ONLY (isolated)
- `periphery`: newt-periphery ONLY (no ports published, fully isolated)
- `newt`: newt-periphery (reaches Periphery by Docker DNS container name)

**Pinned image versions:**

| Image | Tag | Used in |
|-------|-----|---------|
| `traefik` | `v3.6.8` | aegis-gateway, pangolin (inner traefik) |
| `crowdsecurity/crowdsec` | `v1.7.6` | aegis-gateway |
| `fosrl/pangolin` | `1.15.4` | pangolin |
| `fosrl/gerbil` | `1.3.0` | pangolin |
| `fosrl/newt` | `1.9.0` | newt |
| `ghcr.io/pocket-id/pocket-id` | `v2.2.0` | identity |
| `lldap/lldap` | `v0.6.2` | identity |
| `fosrl/pangolin-cli` | `0.3.3` | komodo-pangolin-client, aegis-obs-client |
| `mohitsharma44/komodo-periphery-sops` | `latest` | periphery (custom build) |

**Key compose adaptations from existing VPS files:**
1. Bind mounts → absolute paths (`/opt/aegis/...`) instead of relative
2. Secrets → `env_file: .env` (decrypted from `.sops.env` by pre_deploy hook)
3. Docker networks → `external: true` (pre-created in Phase 3a)
4. All services have `restart: unless-stopped` and descriptive `labels:`
5. Docker socket mounted read-write (Periphery needs full container lifecycle access)

### 4e. Create SOPS-encrypted secrets

**`docker/stacks/racknerd-aegis/aegis-gateway/.sops.env`**:
```
AWS_ACCESS_KEY_ID=<value>
AWS_SECRET_ACCESS_KEY=<value>
CROWDSEC_BOUNCER_KEY=<value>
```

**`docker/stacks/racknerd-aegis/pangolin/.sops.env`**:
```
CROWDSEC_BOUNCER_KEY=<value>
```

**`docker/stacks/racknerd-aegis/identity/.sops.env`**:
```
LDAP_BASE_DN=<value>
LLDAP_ADMIN_PASSWORD=<value>
LLDAP_JWT_SECRET=<value>
POCKETID_ADMIN_EMAIL=<value>
POCKETID_ENCRYPTION_KEY=<value>
```

**`docker/stacks/racknerd-aegis/newt/.sops.env`**:
```
NEWT_ID=<value>
NEWT_SECRET=<value>
```

**`docker/stacks/komodo/pangolin-client/.sops.env`**:
```
PANGOLIN_ENDPOINT=https://pangolin.proxy.sharmamohit.com
CLIENT_ID=<value>
CLIENT_SECRET=<value>
```

**`docker/stacks/racknerd-aegis/pangolin-obs-client/.sops.env`**:
```
PANGOLIN_ENDPOINT=https://pangolin.proxy.sharmamohit.com
CLIENT_ID=<value>
CLIENT_SECRET=<value>
```

Encrypt all: `sops -e -i <file>` (the `.sops.yaml` rule already matches `docker/stacks/.*\.sops\.env$`)

### 4f. Update documentation

- `docker/CLAUDE.md` — add racknerd-aegis host, update stack count (13→21), add Pangolin connectivity + network segmentation gotchas
- `docker/README.md` — mirror host/stack additions
- `docs/docker-hosts.md` — add racknerd-aegis section (Pangolin tunnel instead of WireGuard)
- `CLAUDE.md` — add Pangolin management tunnel info to Network section

---

## Phase 5: Migration (manual, after PR merge)

### 5a. Pre-migration validation

```bash
# Verify rollback path works BEFORE starting (old compose paths still valid)
ssh hs "cd /root/devel/aegis-gateway && docker compose config --quiet"
ssh hs "cd /root/devel/aegis-gateway/pangolin && docker compose config --quiet"

# Sync new stacks to Komodo
km execute sync 'mohitsharma44/homeops'
km list servers -a  # Verify racknerd-aegis appears

# Replace bootstrap Machine Client on komodo with Komodo-managed stack
km execute deploy-stack komodo-pangolin-client
ssh root@komodo "curl -sk https://periphery.private.sharmamohit.com:8120/health"
# Clean up bootstrap compose
ssh root@komodo "rm -rf /root/pangolin-client"
```

### 5b. Staged teardown + data copy + deploy

Staged approach minimizes CrowdSec protection gap. Schedule during low-traffic hours.

```bash
# Stage 1: Stop identity services first (lowest impact)
ssh hs "cd /root/devel/aegis-gateway/pangolin/identity && docker compose down"

# Stage 2: Stop Pangolin (tunnel services drop — expected)
ssh hs "cd /root/devel/aegis-gateway/pangolin && docker compose down"

# Stage 3: Copy runtime data NOW (services stopped — safe for SQLite)
ssh hs "
cp -a /root/devel/aegis-gateway/letsencrypt/acme.json /opt/aegis/gateway/letsencrypt/
cp -a /root/devel/aegis-gateway/pangolin/config/db/pangolin.db /opt/aegis/pangolin/config/db/
cp -a /root/devel/aegis-gateway/pangolin/config/key /opt/aegis/pangolin/config/
cp -a /root/devel/aegis-gateway/pangolin/config/config.yml /opt/aegis/pangolin/config/
cp -a /root/devel/aegis-gateway/pangolin/config/letsencrypt/acme.json /opt/aegis/pangolin/config/letsencrypt/
cp -a /root/devel/aegis-gateway/pangolin/config/traefik/logs/* /opt/aegis/pangolin/config/traefik/logs/ 2>/dev/null || true
chmod 600 /opt/aegis/gateway/letsencrypt/acme.json
chmod 600 /opt/aegis/pangolin/config/db/pangolin.db
chmod 600 /opt/aegis/pangolin/config/key
chmod 600 /opt/aegis/pangolin/config/letsencrypt/acme.json
"

# Stage 4: Stop outer Traefik last (CrowdSec gap starts here)
ssh hs "cd /root/devel/aegis-gateway && docker compose down"

# Stage 5: Deploy new VPS stacks in order
km execute deploy-stack aegis-gateway           # CrowdSec protection restored
km execute deploy-stack aegis-pangolin
km execute deploy-stack aegis-newt
km execute deploy-stack aegis-periphery
km execute deploy-stack aegis-identity
km execute deploy-stack racknerd-aegis-alloy
# Future: km execute deploy-stack aegis-obs-client  # After K8s Newt site is set up

# Stage 6: Clean up bootstrap compose files (now replaced by Komodo stacks)
ssh hs "rm -rf /root/komodo-periphery /root/pangolin-newt /root/pangolin-obs-client"
```

### 5c. Verify

```bash
km list stacks -a
ssh hs "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
curl -I https://pangolin.proxy.sharmamohit.com
curl -I https://pocketid.proxy.sharmamohit.com
# Grafana: up{instance="racknerd-aegis"}
```

### Rollback

**Test rollback path BEFORE migration (Step 5a).** If migration fails:

```bash
ssh hs "docker stop \$(docker ps -q)"
ssh hs "
cd /root/devel/aegis-gateway && docker compose up -d
cd /root/devel/aegis-gateway/pangolin && docker compose up -d
cd /root/devel/aegis-gateway/pangolin/identity && docker compose up -d
"
```

### Emergency Recovery (out-of-band)

If the Pangolin tunnel is down and Komodo cannot reach Periphery:

```bash
# SSH is the permanent emergency backdoor (port 2244)
ssh hs "docker ps -a"                     # Inspect container state
ssh hs "docker logs pangolin-newt"        # Check Newt tunnel
ssh hs "docker restart gerbil"            # Restart WireGuard manager
ssh hs "docker restart pangolin-newt"     # Restart tunnel
# If all else fails, manually docker compose up from /opt/aegis paths
```

> SSH access on port 2244 must always remain functional. It is independent of all
> Pangolin/Docker infrastructure.

---

## Execution Order

1. ~~**Phase 0** — POC (completed, all tests passed)~~
2. ~~**Phase 1** — Periphery on VPS (completed Feb 19)~~
3. **Phase 2** — Pangolin Sites + Machine Clients (manual, Pangolin UI)
   - ~~2a. VPS Newt site (completed Feb 19)~~
   - ~~2c. Komodo Machine Client (completed Feb 19 — LXC TUN fix + OLM backup discovery)~~
   - 2d. DNS failsafe watchdog (next)
   - ~~2e. Verify connectivity (completed Feb 19 — Docker DNS fix PRs #33/#34)~~
   - ~~2f. Update Komodo server address (completed Feb 19 — PR #32)~~
4. **Phase 3** — Runtime data preparation (manual on VPS)
5. **Phase 4** — Repo changes (code, commit, PR)
6. **Phase 5** — Migration (manual, after merge)

---

## Files Summary

### New files (in homeops repo)
| File | Description |
|------|-------------|
| `docker/komodo-resources/stacks-racknerd-aegis.toml` | 7 stack definitions (5 VPS services + alloy + obs client) |
| `docker/stacks/komodo/pangolin-client/compose.yaml` | Machine Client → VPS Periphery |
| `docker/stacks/komodo/pangolin-client/.sops.env` | Machine Client credentials |
| `docker/stacks/racknerd-aegis/aegis-gateway/compose.yaml` | Main Traefik + CrowdSec |
| `docker/stacks/racknerd-aegis/aegis-gateway/.sops.env` | AWS creds, bouncer key |
| `docker/stacks/racknerd-aegis/aegis-gateway/config/dynamic/pangolin.yml` | TCP passthrough routing |
| `docker/stacks/racknerd-aegis/aegis-gateway/config/crowdsec/acquis.d/traefik.yaml` | CrowdSec log config |
| `docker/stacks/racknerd-aegis/aegis-gateway/config/crowdsec/acquis.d/pangolin-traefik.yaml` | CrowdSec log config |
| `docker/stacks/racknerd-aegis/pangolin/compose.yaml` | Pangolin + Gerbil + inner Traefik |
| `docker/stacks/racknerd-aegis/pangolin/.sops.env` | CrowdSec bouncer key |
| `docker/stacks/racknerd-aegis/identity/compose.yaml` | LLDAP + PocketID |
| `docker/stacks/racknerd-aegis/identity/.sops.env` | LDAP/PocketID secrets |
| `docker/stacks/racknerd-aegis/periphery/compose.yaml` | Periphery (network-isolated) |
| `docker/stacks/racknerd-aegis/newt/compose.yaml` | Newt tunnel agent |
| `docker/stacks/racknerd-aegis/newt/.sops.env` | Newt credentials |
| `docker/stacks/racknerd-aegis/pangolin-obs-client/compose.yaml` | Machine Client → K8s Prometheus/Loki |
| `docker/stacks/racknerd-aegis/pangolin-obs-client/.sops.env` | Machine Client credentials |

### Modified files (in homeops repo)
| File | Change |
|------|--------|
| `docker/komodo-resources/servers.toml` | Add racknerd-aegis |
| `docker/komodo-resources/stacks-komodo.toml` | Add komodo-pangolin-client stack |
| `docker/komodo-resources/procedures.toml` | Add VPS stages, exclude tunnel + client stacks from batch deploy |
| `docker/CLAUDE.md` | Add VPS host info, update stack count (13→21), add gotchas |
| `docker/README.md` | Add VPS to all relevant sections |
| `docs/docker-hosts.md` | Add racknerd-aegis section |
| `CLAUDE.md` | Add Pangolin management tunnel info to Network section |

### Files on hosts (bootstrap + system files only — NOT in repo)
| Host | File | Description |
|------|------|-------------|
| komodo | `/root/pangolin-client/` | Bootstrap Machine Client (replaced by `komodo-pangolin-client` stack in Phase 5a, then deleted) |
| komodo | pangolin-dns-watchdog.{service,timer} | DNS failsafe systemd units |
| racknerd-aegis | `/root/komodo-periphery/` | Bootstrap Periphery (replaced by `aegis-periphery` stack, deleted in Phase 5b Stage 6) |
| racknerd-aegis | `/root/pangolin-newt/` | Bootstrap Newt (replaced by `aegis-newt` stack, deleted in Phase 5b Stage 6) |
| racknerd-aegis | `/root/pangolin-obs-client/` | Bootstrap obs client (replaced by `aegis-obs-client` stack, deleted in Phase 5b Stage 6) |
| racknerd-aegis | pangolin-dns-watchdog.{service,timer} | DNS failsafe systemd units |
| racknerd-aegis | `/etc/sops/age/keys.txt` | Age private key (600 perms) |
| racknerd-aegis | `/opt/aegis/` | All runtime data (certs, DBs, keys, logs) |

> **Bootstrap files are temporary.** After Phase 5 migration, Komodo stacks replace all
> bootstrap compose files, which are then deleted.

---

## Alloy Observability Path

VPS Alloy currently pushes metrics/logs to K8s via existing HTTPS ingress endpoints
(`prometheus.sharmamohit.com`, `loki.sharmamohit.com`) with basic auth. This already works
and does NOT depend on the Pangolin tunnel.

**Recommendation:** Keep the HTTPS ingress path initially. The Pangolin tunnel path
(VPS Machine Client → K8s Newt Site) can be optimized later if ingress overhead is a
concern. This means Alloy remains functional even if the Pangolin tunnel is down.

---

## Security Notes

### Accepted Risks (documented)

| Risk | Rationale |
|------|-----------|
| Docker socket access for Periphery | Architecturally required by Komodo. Mitigated by network isolation (newt-periphery only). |
| `NET_ADMIN` + host networking for Machine Clients | Required for WireGuard tunnel creation. Pin images to specific versions. |
| Pangolin self-loop circular dependency | If Pangolin crashes, Komodo can't reach Periphery to redeploy it. Mitigated by SSH emergency recovery (port 2244). |
| PocketID bridges pangolin-internal and identity-internal | Required for OIDC + LDAP integration. Keep PocketID updated. |
| Komodo Core + FerretDB host networking on LXC | Required so Core reads host resolv.conf for Pangolin DNS. FerretDB published on localhost only. Mitigated by future LXC→VM migration. |
| Single age key across homelab + VPS | Simplifies operations. VPS compromise could decrypt all secrets. |
| resolv.conf override by pangolin-cli | If container crashes, host DNS breaks. Mitigated by DNS watchdog timer. |
| Homelab→VPS tunnel relays via Gerbil | VPS Newt self-loop causes Docker bridge IP reporting. Relay overhead negligible (same host). |

### Future Security Improvements

- **Migrate komodo LXC 200 → VM**: Komodo runs in an unprivileged Proxmox LXC (CT 200)
  which shares the host kernel. Multiple services now run with elevated privileges
  (`pangolin-cli` with NET_ADMIN + /dev/net/tun, Periphery with Docker socket, Core with
  `network_mode: host`). A VM provides hypervisor-enforced isolation — a compromised
  container faces the KVM boundary before reaching Proxmox, vs just kernel namespaces
  in LXC. Use Ubuntu 24.04 cloud template (VM ID 9001), same IP 192.168.11.200, migrate
  Docker volumes. This also eliminates the AppArmor workaround (`mask-apparmor.service`)
  and LXC TUN device config hacks.
- **Separate age key for VPS**: Create per-environment key pairs with `path_regex` in `.sops.yaml`
- **Image digest pinning**: All images are pinned to release tags (see Phase 4d version table). For stronger guarantees, pin to SHA256 digests instead of tags
- **Decrypted secret cleanup**: Modify `sops-decrypt.sh` to `chmod 600` output files and add post-deploy cleanup
- **Komodo ↔ Periphery TLS verification**: Verify Komodo validates Periphery's TLS certificate through the tunnel
