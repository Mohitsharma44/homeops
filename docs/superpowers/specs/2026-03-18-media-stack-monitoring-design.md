# Media Stack Monitoring Design — LXC 400

**Date:** 2026-03-18
**Status:** Draft
**Node:** pve03 LXC 400 (192.168.11.40) — Debian 13, 4c/16GB/256GB, Radeon 760M

## Goal

Full observability for the media stack (Jellyfin + arr stack + Real-Debrid via Decypharr) running on LXC 400. Three layers: infrastructure metrics/logs, application metrics, and playback analytics. All data flows into the existing Prometheus → Thanos → Grafana / Loki pipeline, with alerts delivered to Slack (`#homelab-alerts`) via Grafana Alerting.

## Architecture Overview

```
LXC 400 (192.168.11.40) — host level (systemd)
├── Alloy (systemd service)
│   ├── prometheus.exporter.unix      → host CPU/mem/disk/network
│   ├── prometheus.scrape "cadvisor"  → cAdvisor container (127.0.0.1:8080)
│   ├── prometheus.scrape "scraparr"  → Scraparr container (127.0.0.1:7100)
│   ├── prometheus.scrape "jellyfin"  → Jellyfin /metrics (127.0.0.1:8096)
│   ├── textfile_directory            → /var/lib/alloy/textfile (RD expiry + FUSE)
│   ├── loki.source.docker            → container stdout/stderr logs
│   ├── loki.source.journal           → systemd journal (kernel, FUSE errors)
│   ├── prometheus.remote_write       → K8s Prometheus
│   └── loki.write                    → K8s Loki
├── RD expiry cron (daily 03:00)
│   └── writes /var/lib/alloy/textfile/rd_expiry.prom
├── FUSE mount check cron (every 5m)
│   └── writes /var/lib/alloy/textfile/rd_fuse.prom
└── /etc/alloy/config.alloy + /etc/alloy/env

Docker (media-stack compose template additions)
├── cAdvisor (:8080, localhost only)
├── Scraparr (:7100, localhost only)
├── Jellystat (:3000, LAN accessible) + PostgreSQL
└── (existing 12 media containers)

Data flow:
  Alloy → remote-write → Prometheus (K8s) → Thanos → Grafana
  Alloy → push logs   → Loki (K8s)                → Grafana
  Grafana alert rules  → Slack (#homelab-alerts)
  Jellystat            → own UI (:3000) for playback analytics
```

## Deployment Model

**Approach:** Ansible-managed everything. Extend the existing `proxmox/media-stack.yml` playbook. Alloy as a systemd service on the LXC host (matching the pve/truenas/server04 pattern). Monitoring containers (cAdvisor, Scraparr, Jellystat+PG) added to the Docker compose template.

**Why systemd Alloy:** Survives Docker restarts, provides clean host metrics from real procfs/sysfs (not bind mounts), consistent with the 3 other infrastructure hosts already using this pattern. The `alloy` user gets `systemd-journal` and `docker` group membership for journal and container log access.

**Idempotency:** All Ansible tasks use idempotent modules (`apt`, `template`, `cron`, `systemd`, `community.docker.docker_compose_v2`). Re-running the playbook produces no changes if the desired state already exists.

## Layer 1: Infrastructure (Alloy + cAdvisor)

### Alloy Systemd Service

Installed via Grafana APT repo (Debian 13, same as pve):

| File | Source | Purpose |
|------|--------|---------|
| `/etc/alloy/config.alloy` | `proxmox/templates/media-stack-alloy.config.j2` | River config |
| `/etc/alloy/env` | Ansible template, mode 0600 | Prometheus/Loki credentials |
| `/etc/systemd/system/alloy.service.d/override.conf` | Ansible template | EnvironmentFile path |
| `/var/lib/alloy/textfile/` | Ansible file task, owned by `alloy` | Textfile collector directory |

Ansible tasks (idempotent):
1. Add Grafana APT repo + GPG key
2. `apt install alloy`
3. Template config.alloy and env file
4. `usermod -aG systemd-journal,docker alloy`
5. Create `/var/lib/alloy/textfile/` directory
6. Deploy systemd override (EnvironmentFile + `MemoryMax=512M`)
7. Enable + start Alloy (handler restarts on config change)

### Alloy River Config

Extends the server04 pattern (host metrics + Docker logs + journal) with media-specific scrape targets:

```river
// ============================================================
// Host metrics (node_exporter)
// ============================================================
prometheus.exporter.unix "host" {
  procfs_path        = "/proc"
  sysfs_path         = "/sys"
  rootfs_path        = "/"
  textfile_directory = "/var/lib/alloy/textfile"
}

prometheus.scrape "host" {
  targets         = prometheus.exporter.unix.host.targets
  forward_to      = [prometheus.relabel.instance.receiver]
  scrape_interval = "60s"
  job_name        = "node"
}

// ============================================================
// cAdvisor (Docker container metrics)
// ============================================================
prometheus.scrape "cadvisor" {
  targets         = [{"__address__" = "127.0.0.1:8080"}]
  forward_to      = [prometheus.relabel.instance.receiver]
  scrape_interval = "60s"
  job_name        = "cadvisor"
}

// ============================================================
// Scraparr (arr application metrics)
// ============================================================
prometheus.scrape "scraparr" {
  targets         = [{"__address__" = "127.0.0.1:7100"}]
  forward_to      = [prometheus.relabel.instance.receiver]
  scrape_interval = "120s"
  job_name        = "scraparr"
}

// ============================================================
// Jellyfin Prometheus plugin
// ============================================================
prometheus.scrape "jellyfin" {
  targets         = [{"__address__" = "127.0.0.1:8096"}]
  metrics_path    = "/metrics"
  forward_to      = [prometheus.relabel.instance.receiver]
  scrape_interval = "60s"
  job_name        = "jellyfin"
}

// ============================================================
// Relabel: add instance label
// ============================================================
prometheus.relabel "instance" {
  forward_to = [prometheus.remote_write.prometheus.receiver]
  rule {
    action       = "replace"
    target_label = "instance"
    replacement  = "media-stack"
  }
}

// ============================================================
// Remote write: push metrics to K8s Prometheus
// ============================================================
prometheus.remote_write "prometheus" {
  external_labels = {
    source = "infra",
  }
  endpoint {
    url = sys.env("PROMETHEUS_URL")
    basic_auth {
      username = sys.env("BASIC_AUTH_USERNAME")
      password = sys.env("BASIC_AUTH_PASSWORD")
    }
  }
}

// ============================================================
// Docker container logs
// ============================================================
discovery.docker "containers" {
  host = "unix:///var/run/docker.sock"
}

discovery.relabel "docker_logs" {
  targets = discovery.docker.containers.targets
  rule {
    source_labels = ["__meta_docker_container_name"]
    target_label  = "container"
  }
  rule {
    source_labels = ["__meta_docker_image_name"]
    target_label  = "image"
  }
  rule {
    action       = "replace"
    target_label = "instance"
    replacement  = "media-stack"
  }
}

loki.source.docker "containers" {
  host       = "unix:///var/run/docker.sock"
  targets    = discovery.relabel.docker_logs.output
  forward_to = [loki.write.loki.receiver]
}

// ============================================================
// Host journal logs
// ============================================================
loki.source.journal "host" {
  forward_to    = [loki.process.journal.receiver]
  relabel_rules = loki.relabel.journal.rules
  labels = {
    job = "journal",
  }
}

loki.relabel "journal" {
  forward_to = []
  rule {
    source_labels = ["__journal__systemd_unit"]
    target_label  = "unit"
  }
  rule {
    source_labels = ["__journal_priority_keyword"]
    target_label  = "priority"
  }
}

loki.process "journal" {
  stage.static_labels {
    values = {
      instance = "media-stack",
    }
  }
  forward_to = [loki.write.loki.receiver]
}

// ============================================================
// Loki write: push logs to K8s Loki
// ============================================================
loki.write "loki" {
  endpoint {
    url       = sys.env("LOKI_URL")
    tenant_id = "homelab"
    basic_auth {
      username = sys.env("BASIC_AUTH_USERNAME")
      password = sys.env("BASIC_AUTH_PASSWORD")
    }
  }
  wal {
    max_segment_age = "1h"
  }
}
```

### Alloy Disk Safety

If Loki is unreachable, Alloy buffers logs in its WAL (Write-Ahead Log) at `/var/lib/alloy/data/`. On a 256GB LXC root disk shared with app configs and Docker images, unbounded WAL growth could fill the disk and crash everything.

**Protections (deployed via Ansible):**

1. **WAL segment age limit:** `max_segment_age = "1h"` in `loki.write` — Alloy drops WAL segments older than 1 hour if they can't be flushed. Limits WAL size to roughly 1 hour of log volume.

2. **Alloy systemd memory limit:** `MemoryMax=512M` in the systemd override — prevents Alloy from consuming excessive RAM if it's buffering aggressively.

3. **Alloy data directory cleanup:** The Alloy systemd override sets `StateDirectory=alloy` which maps to `/var/lib/alloy/`. If Alloy is restarted, stale WAL data is replayed and flushed (or aged out).

The combination ensures that even if Loki is down for hours, Alloy will buffer up to ~1 hour of logs, then drop older segments rather than filling the disk.

### Docker Daemon Log Rotation

The existing media-stack containers have **no log rotation configured** — neither per-container in the compose template nor at the Docker daemon level. With 15+ containers, unrotated JSON logs can fill the disk.

**Fix:** Configure Docker daemon-level defaults via `/etc/docker/daemon.json` (deployed by Ansible):

```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
```

This applies to **all containers** on the LXC as a default — no need to add `logging:` blocks to every service in the compose template. Per-container overrides in the compose file take precedence if needed.

**Ansible tasks:**
1. Template `/etc/docker/daemon.json` with log rotation defaults
2. Restart Docker daemon (handler, only when `daemon.json` changes)

**Note:** The monitoring containers (cAdvisor, Scraparr, Jellystat) in the compose template still have explicit `logging:` blocks as a defense-in-depth measure, but the daemon-level config is the primary safeguard for all 15+ containers.

### cAdvisor Container

Added to `media-stack-compose.yaml.j2`:

```yaml
cadvisor:
  image: gcr.io/cadvisor/cadvisor:v0.51.0
  container_name: cadvisor
  ports:
    - "127.0.0.1:8080:8080"
  volumes:
    - /:/rootfs:ro
    - /var/run:/var/run:ro
    - /sys:/sys:ro
    - /var/lib/docker/:/var/lib/docker:ro
  restart: unless-stopped
  logging:
    driver: json-file
    options:
      max-size: "10m"
      max-file: "3"
```

Port 8080 bound to localhost only — not LAN accessible. Alloy scrapes it from the host.

## Layer 2: Application Metrics (Scraparr + Jellyfin)

### Scraparr

Added to `media-stack-compose.yaml.j2`:

```yaml
scraparr:
  image: ghcr.io/thecfu/scraparr:latest
  container_name: scraparr
  ports:
    - "127.0.0.1:7100:7100"
  environment:
    - RADARR__URL=http://radarr:7878
    - RADARR__API_KEY=${RADARR_API_KEY}
    - SONARR__URL=http://sonarr:8989
    - SONARR__API_KEY=${SONARR_API_KEY}
    - PROWLARR__URL=http://prowlarr:9696
    - PROWLARR__API_KEY=${PROWLARR_API_KEY}
    - BAZARR__URL=http://bazarr:6767
    - BAZARR__API_KEY=${BAZARR_API_KEY}
  networks:
    - media-net
  restart: unless-stopped
  logging:
    driver: json-file
    options:
      max-size: "10m"
      max-file: "3"
```

Scraparr connects to arr apps via container names on `media-net`. Metrics port published to localhost for Alloy. API keys sourced from SOPS-encrypted `.env` file.

**Metrics exposed:** queue sizes, library counts, failed grabs, download rates, indexer stats per arr app.

### Jellyfin Prometheus Plugin

Enabled via Ansible task using the Jellyfin API (no manual UI interaction):

```yaml
- name: Install Jellyfin Prometheus plugin
  ansible.builtin.uri:
    url: "http://127.0.0.1:8096/Plugins/Installed/{{ jellyfin_prometheus_plugin_guid }}"
    method: POST
    headers:
      X-Emby-Token: "{{ vault_jellyfin_api_key }}"
    status_code: [200, 204]
  register: plugin_install

- name: Restart Jellyfin to load plugin
  community.docker.docker_compose_v2:
    project_src: /opt/media-stack
    services: [jellyfin]
    state: restarted
  when: plugin_install is changed
```

The exact plugin GUID will be verified during implementation. Idempotent — POST to an already-installed plugin returns 200 without changes.

**Metrics exposed:** active streams, transcoding sessions, server uptime, playback stats.

## Layer 3: Playback Analytics (Jellystat)

### Jellystat + PostgreSQL

Added to `media-stack-compose.yaml.j2`:

```yaml
jellystat-db:
  image: postgres:16-alpine
  container_name: jellystat-db
  environment:
    - POSTGRES_USER=jellystat
    - POSTGRES_PASSWORD=${JELLYSTAT_DB_PASSWORD}
    - POSTGRES_DB=jellystat
  volumes:
    - /opt/media-stack/config/jellystat-db:/var/lib/postgresql/data
  networks:
    - media-net
  restart: unless-stopped
  logging:
    driver: json-file
    options:
      max-size: "10m"
      max-file: "3"

jellystat:
  image: cyfershepard/jellystat:latest
  container_name: jellystat
  ports:
    - "3000:3000"
  environment:
    - POSTGRES_USER=jellystat
    - POSTGRES_PASSWORD=${JELLYSTAT_DB_PASSWORD}
    - POSTGRES_IP=jellystat-db
    - POSTGRES_PORT=5432
    - JWT_SECRET=${JELLYSTAT_JWT_SECRET}
    - TZ=America/New_York
  depends_on:
    - jellystat-db
  networks:
    - media-net
  restart: unless-stopped
  logging:
    driver: json-file
    options:
      max-size: "10m"
      max-file: "3"
```

- Port 3000 published to LAN — standalone UI at `http://192.168.11.40:3000`
- PostgreSQL data at `/opt/media-stack/config/jellystat-db/` — covered by Sanoid rpool snapshots
- First-time setup requires Jellystat web wizard to connect to Jellyfin (cannot be automated)

**What Jellystat provides (own UI, not Grafana):**
- Watch history per user
- Most-watched titles
- Playback duration trends
- Library growth over time

## Real-Debrid Health Monitoring

### RD Account Expiry Check

Daily cron job at 03:00, single RD API call per day. Deployed via Ansible.

**API endpoint:** `GET https://api.real-debrid.com/rest/1.0/user` with `Authorization: Bearer <token>`. Returns JSON with a `premium` field (integer, seconds remaining as premium). We use `premium` instead of `expiration` because the `expiration` field has a known timezone bug — RD sends local time formatted with a UTC `Z` suffix. The `premium` field is an unambiguous integer: `days_remaining = premium / 86400`.

**Rate limit:** 250 requests/minute (our once-daily call is well within this).

**Script** (`proxmox/templates/media-stack-rd-expiry-check.sh.j2`):

```bash
#!/bin/bash
set -euo pipefail
# Queries Real-Debrid /user API, calculates days until expiry,
# writes Prometheus textfile metric for Alloy to pick up.
# Runs once daily at 03:00 via cron. Single API call per run.
#
# Uses the "premium" field (seconds remaining) instead of "expiration"
# because the expiration field has a known timezone bug in the RD API.

TEXTFILE_DIR="/var/lib/alloy/textfile"
PROM_FILE="${TEXTFILE_DIR}/rd_expiry.prom"
TMPFILE="${PROM_FILE}.tmp"

write_failure_metric() {
  cat > "${TMPFILE}" <<EOF
# HELP rd_account_expiry_check_ok Whether the last RD API check succeeded (1=ok, 0=fail)
# TYPE rd_account_expiry_check_ok gauge
rd_account_expiry_check_ok 0
EOF
  mv "${TMPFILE}" "${PROM_FILE}"
}

# Timeout after 30s, retry once on transient failure
RESPONSE=$(curl -sf --max-time 30 --retry 1 --retry-delay 5 \
  -H "Authorization: Bearer {{ vault_rd_api_key }}" \
  "https://api.real-debrid.com/rest/1.0/user" 2>/dev/null) || {
  write_failure_metric
  exit 0
}

# Validate JSON and extract premium seconds remaining
PREMIUM=$(echo "$RESPONSE" | jq -r '.premium // empty' 2>/dev/null) || {
  write_failure_metric
  exit 0
}

# Guard against empty/non-numeric values
if ! [[ "$PREMIUM" =~ ^[0-9]+$ ]]; then
  write_failure_metric
  exit 0
fi

DAYS_REMAINING=$(( PREMIUM / 86400 ))

cat > "${TMPFILE}" <<EOF
# HELP rd_account_days_remaining Days until Real-Debrid account expires
# TYPE rd_account_days_remaining gauge
rd_account_days_remaining $DAYS_REMAINING
# HELP rd_account_expiry_check_ok Whether the last RD API check succeeded (1=ok, 0=fail)
# TYPE rd_account_expiry_check_ok gauge
rd_account_expiry_check_ok 1
EOF
mv "${TMPFILE}" "${PROM_FILE}"
```

**Robustness features:**
- `set -euo pipefail` — fail on unset variables and pipe errors
- Atomic write via temp file + `mv` — Alloy never reads a half-written `.prom` file
- `curl --max-time 30 --retry 1` — timeout and single retry on transient failure
- `jq` validates JSON and extracts `premium` with `// empty` fallback
- Regex guard on numeric value — non-numeric `premium` writes failure metric instead of crashing
- All error paths write `rd_account_expiry_check_ok 0` so the alert fires on script failure

Ansible tasks:
1. Install `jq` and `curl` (apt)
2. Template script to `/opt/media-stack/rd-expiry-check.sh` (mode 0700)
3. Deploy cron job via `ansible.builtin.cron` (daily at 03:00)

### FUSE Mount Health Check

Runs every 5 minutes. Purely local — no external API calls.

**Script** (`proxmox/templates/media-stack-fuse-check.sh.j2`):

```bash
#!/bin/bash
# Checks if /mnt/debrid FUSE mount is healthy.
# Runs every 5 minutes via cron.

TEXTFILE_DIR="/var/lib/alloy/textfile"

if mountpoint -q /mnt/debrid && ls /mnt/debrid/ >/dev/null 2>&1; then
  VALUE=1
else
  VALUE=0
fi

cat > "${TEXTFILE_DIR}/rd_fuse.prom" <<EOF
# HELP rd_fuse_mount_healthy Whether /mnt/debrid FUSE mount is accessible (1=ok, 0=fail)
# TYPE rd_fuse_mount_healthy gauge
rd_fuse_mount_healthy $VALUE
EOF
```

Ansible tasks:
1. Template script to `/opt/media-stack/fuse-check.sh` (mode 0700)
2. Deploy cron job via `ansible.builtin.cron` (every 5 minutes)

## Grafana Alert Rules

All rules in a new `Media Stack` folder under Grafana Alerting, deployed via `kube-prometheus-stack.yaml` provisioning (same pattern as existing Infra Node Health, SMART Health, ZFS Health folders).

Every alert annotation includes `runbook_url` pointing to `docs/runbooks/media-stack-alerts.md#<anchor>`.

**Note on `job_name` convention:** The existing `InfraHostDown` alert filters on `job="integrations/unix"`. This spec uses `job_name = "node"` for host metrics, which means `InfraHostDown` will NOT fire for the media-stack LXC. This is intentional — media-stack is an LXC (not bare metal infrastructure), and has its own `MediaContainerDown` alert for critical service availability. If LXC-level host-down detection is desired in the future, add a dedicated alert filtering on `instance="media-stack"`.

**Note on `MediaContainerDown`:** Uses `absent()` which fires a single alert when all container metrics vanish (e.g., if Alloy or cAdvisor itself goes down), not per-container alerts. This is acceptable — if the monitoring agent is down, a single "monitoring broken" alert is sufficient.

| Alert | Expression | For | Severity |
|-------|-----------|-----|----------|
| MediaContainerDown | `absent(container_last_seen{name=~"decypharr\|jellyfin\|radarr\|sonarr\|prowlarr", instance="media-stack"})` | 5m | critical |
| MediaContainerRestartLoop | `increase(container_restart_count{instance="media-stack"}[1h]) > 3` | 5m | warning |
| RdAccountExpiringSoon | `rd_account_days_remaining < 15` | 1h | warning |
| RdAccountExpiryCritical | `rd_account_days_remaining < 5` | 30m | critical |
| RdExpiryCheckFailed | `rd_account_expiry_check_ok == 0` | 6h | warning |
| RdFuseMountDown | `rd_fuse_mount_healthy == 0` | 10m | critical |
| JellyfinTranscodingErrors | LogQL: `count_over_time({container="jellyfin", instance="media-stack"} \|~ "transcode.*error\|ffmpeg.*error"[15m]) > 5` | 5m | warning |
| DecypharrRdApiErrors | LogQL: `count_over_time({container="decypharr", instance="media-stack"} \|~ "error\|rate.limit\|429"[15m]) > 10` | 5m | warning |
| MediaStackDiskUsage | `(1 - node_filesystem_avail_bytes{instance="media-stack",mountpoint="/"} / node_filesystem_size_bytes{instance="media-stack",mountpoint="/"}) > 0.85` | 15m | warning |

## Grafana Dashboard

Deployed via Grafana provisioning in `kube-prometheus-stack.yaml`. Dashboard UID: `media-stack-health`.

### Panels

1. **Container Health** — status map of all containers (up/down), restart counts, CPU/memory per container (cAdvisor)
2. **Arr Queue Status** — Radarr/Sonarr queue sizes, failed grabs, download rates (Scraparr)
3. **Jellyfin Streams** — active streams, transcoding sessions, direct play vs transcode ratio (Jellyfin /metrics)
4. **Real-Debrid Health** — account days remaining gauge, FUSE mount status, API error rate from logs (Prometheus + Loki)
5. **LXC Host Resources** — CPU, memory, disk I/O, network, filesystem usage (node_exporter)
6. **Logs Panel** — embedded Loki log viewer filtered to `instance="media-stack"` containers

## Runbook

Single document at `docs/runbooks/media-stack-alerts.md` covering all alerts. Each alert gets a section with consistent format:

```markdown
## AlertName
**Severity:** critical/warning | **For:** Xm

**Symptoms:** What the user observes

**Triage:**
1. Step-by-step commands
2. ...

**Resolution:** How to fix
```

Linked from every alert annotation via `runbook_url` with section anchors.

## Secrets Required

New secrets to add to `proxmox/group_vars/all/secrets.sops.yml`:

| Secret | Purpose | How to Obtain |
|--------|---------|---------------|
| `vault_prowlarr_api_key` | Scraparr → Prowlarr API access | Prowlarr UI: Settings > General > API Key |
| `vault_bazarr_api_key` | Scraparr → Bazarr API access | Bazarr UI: Settings > General > API Key |
| `vault_jellystat_db_password` | Jellystat PostgreSQL password | Generate: `openssl rand -hex 16` |
| `vault_jellystat_jwt_secret` | Jellystat JWT signing secret | Generate: `openssl rand -hex 32` |
| `vault_alloy_basic_auth_username` | Alloy → Prometheus/Loki auth | Same as existing Alloy instances |
| `vault_alloy_basic_auth_password` | Alloy → Prometheus/Loki auth | Same as existing Alloy instances |

**Already in vault:** `vault_rd_api_key`, `vault_radarr_api_key`, `vault_sonarr_api_key`, `vault_jellyfin_api_key`

## New/Modified Files

### New Files

| File | Purpose |
|------|---------|
| `proxmox/templates/media-stack-alloy.config.j2` | Alloy River config for media-stack LXC |
| `proxmox/templates/media-stack-alloy-env.j2` | Alloy credentials env file |
| `proxmox/templates/media-stack-rd-expiry-check.sh.j2` | RD expiry cron script |
| `proxmox/templates/media-stack-fuse-check.sh.j2` | FUSE mount health cron script |
| `proxmox/templates/media-stack-docker-daemon.json.j2` | Docker daemon log rotation config |
| `docs/runbooks/media-stack-alerts.md` | Alert runbook |

### Modified Files

| File | Changes |
|------|---------|
| `proxmox/templates/media-stack-compose.yaml.j2` | Add cAdvisor, Scraparr, Jellystat, Jellystat-DB |
| `proxmox/templates/media-stack-env.j2` | Add Prowlarr/Bazarr API keys, Jellystat secrets, Alloy credentials |
| `proxmox/media-stack.yml` | Add Play 4: monitoring setup (Alloy install, cron jobs, Jellyfin plugin, Docker daemon config) |
| `proxmox/group_vars/all/secrets.sops.yml` | Add new secrets (user-managed) |
| `kubernetes/apps/argocd-apps/apps/kube-prometheus-stack.yaml` | Add Media Stack alert folder + dashboard |

## Verification

1. **Alloy running:** `systemctl status alloy` on media-stack LXC
2. **Host metrics flowing:** Query `node_cpu_seconds_total{instance="media-stack"}` in Grafana
3. **Container metrics:** Query `container_cpu_usage_seconds_total{instance="media-stack"}` in Grafana
4. **Scraparr metrics:** Query `{job="scraparr"}` in Grafana — verify Radarr/Sonarr/Prowlarr/Bazarr stats appear
5. **Jellyfin metrics:** Query `{job="jellyfin"}` in Grafana
6. **Container logs:** LogQL `{instance="media-stack"}` — verify all container logs appear
7. **Journal logs:** LogQL `{job="journal", instance="media-stack"}` — verify systemd journal flowing
8. **RD expiry metric:** Query `rd_account_days_remaining` — verify reasonable value
9. **FUSE mount metric:** Query `rd_fuse_mount_healthy` — verify value is 1
10. **Jellystat UI:** Browse `http://192.168.11.40:3000` — complete setup wizard
11. **Alerts:** Verify all 9 rules appear in Grafana Alerting under Media Stack folder

## Risks

| Risk | Mitigation |
|------|------------|
| Alloy systemd wiped by LXC rebuild | Ansible playbook is idempotent — re-run restores everything |
| Scraparr/Jellystat images unavailable | Pin to known-good versions after initial validation |
| Jellyfin Prometheus plugin breaks on update | Plugin GUID may change — Ansible task will fail visibly, not silently |
| RD API changes /user endpoint | Cron script has error handling — `rd_account_expiry_check_ok` goes to 0, alerting on check failure |
| cAdvisor high CPU on small LXC | Monitor resource usage; can increase scrape interval from 60s to 120s if needed |
| Jellystat first-time wizard can't be automated | Documented as manual step; only needed once per fresh deploy |
| Port 3000 conflict (Jellystat vs Grafana) | Grafana runs in K8s (not on this LXC); no conflict |
