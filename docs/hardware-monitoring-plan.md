# Hardware Health Monitoring & Alerting Plan

## Context

Three homelab servers (pve, truenas, server04) have no hardware health monitoring beyond basic node_exporter metrics. PVE has previously shown SATA/HDD issues. Alertmanager is deployed on K8s but has zero receivers — alerts fire into the void. This plan adds SMART disk monitoring, IPMI sensor collection, ZFS pool health, alert routing to Home Assistant, and PrometheusRules for hardware failure detection.

## Scope

### Server Inventory (from recon 2026-02-21)

| Host | OS | IP | Disks | Controller | IPMI | Alloy (host-level) |
|------|----|----|-------|------------|------|---------------------|
| pve | Proxmox VE / Debian 13 | 192.168.11.13 | 2x SK hynix SC300B 256GB SSD (SATA) | Direct SATA | None | Systemd on pve (new) |
| truenas | TrueNAS SCALE / Debian 12 | 192.168.11.15 | 14 drives: 4x 6TB Seagate IronWolf HDD, 2x 1TB Samsung 870 EVO SSD, 3x 500GB Samsung 870 EVO SSD, 4x 2TB SanDisk Ultra 3D SSD, 1x 500GB Crucial MX500 SSD | LSI SAS2308 (IT mode) | iDRAC @ 192.168.10.185 | Systemd on truenas (new) |
| server04 | Ubuntu 22.04 | 192.168.11.17 | 4x 900GB Seagate ST900MM0006 SAS HDD + 1x Samsung 870 EVO SSD (SATA) | HP Smart Array Gen8 (RAID mode) | iLO (currently down) | Systemd on server04 (new, replaces Docker Alloy) |

### Key Findings from Recon

- **All 3 servers already have `smartmontools` installed and `smartmontools.service` running**
- **server04 HP Smart Array**: `smartctl --scan` only finds the SATA SSD (`/dev/sde`). The 4 SAS drives require `smartctl -d cciss,N /dev/sda` (N=0..3) — confirmed working, all report SMART Health: OK
- **truenas LSI SAS2308**: IT mode passthrough — all 14 drives visible via `smartctl --scan` as individual SCSI devices
- **pve**: Both SSDs report SMART PASSED. No current SATA errors in dmesg
- **server04 -> iDRAC routing**: Confirmed reachable via `192.168.11.1` gateway (routes between management VLAN 192.168.10.x and LAN 192.168.11.x)

### HA Notification Services Available

- `notify.mobile_app_mohit_s_oneplus` (Mohit's phone — primary)
- `notify.mobile_app_mohits_macbook_pro` (MacBook)
- `notify.notify` (broadcast to all)

**Out of scope**: K8s mini PCs (Talos — requires DaemonSet-based approach, not systemd), garage PC, VPS.

---

## Architecture Overview

All 3 bare-metal hosts run their own Alloy instance (systemd) alongside smartctl_exporter. This ensures host-level metrics come from the actual hardware, decouples monitoring from Docker health, and keeps the approach consistent across all hosts. Existing Komodo-managed Alloy instances on other Docker hosts (komodo LXC, seaweedfs VM, etc.) continue monitoring their own guest-level metrics separately — they are unaffected.

```
pve (192.168.11.13)          truenas (192.168.11.15)       server04 (192.168.11.17)
  smartctl_exporter             smartctl_exporter            smartctl_exporter
  (systemd, :9633)              (systemd, :9633)             (systemd, :9633)
  2 SSDs (direct SATA)          14 drives (SAS2308 IT)       4 SAS HDD (cciss,N) + 1 SSD
       |                              |                            |
       | scrape localhost              | scrape localhost            | scrape localhost
       v                              v                            v
  Alloy (systemd)             Alloy (systemd)              Alloy (systemd)
  host metrics + journal      host metrics + journal        host metrics + journal
  instance=pve                instance=truenas              + cAdvisor + Docker logs
       |                              |                     instance=server04
       |                              |                            |
       +----------+------------------+----------------------------+
                  |
                  v
         K8s Prometheus (remote-write)
                  |
                  v
           Alertmanager
                  |
           +------+------+
           |             |
      (primary)     (secondary)
           |             |
    HA webhook      Slack webhook
    homeassistant.   #homelab-alerts
    sharmamohit.com
           |
    notify.mobile_app_mohit_s_oneplus
           |
    Phone push notification

Note: komodo Alloy (LXC) and seaweedfs Alloy (VM) continue running the shared
Docker compose config unchanged — they monitor their own guest-level metrics.
server04's Komodo-managed Docker Alloy (server04-alloy stack) has been
REPLACED by the systemd Alloy and removed from stacks-server04.toml.
```

---

## Phase 1: Alertmanager Receiver + Home Assistant Webhook

**Goal**: Wire Alertmanager to actually notify you when alerts fire, with redundancy.

### 1A: Create HA webhook automation (via MCP)

Create an HA automation with a webhook trigger that:
1. Receives Alertmanager JSON payload
2. Extracts alert name, severity, instance, and description
3. Sends push notification to `notify.mobile_app_mohit_s_oneplus`
4. Uses critical notification priority for `severity=critical` alerts

The HA automation will be created via the `ha_config_set_automation` MCP tool.

**HA endpoint**: `homeassistant.sharmamohit.com` (192.168.10.191), reachable from K8s pods via LAN DNS.

### 1B: Configure Alertmanager receivers

**Modify**: `kubernetes/apps/argocd-apps/apps/kube-prometheus-stack.yaml`

Add under `alertmanager:` (sibling to `alertmanagerSpec:`):

```yaml
alertmanager:
  config:
    global:
      resolve_timeout: 5m
    route:
      receiver: homeassistant
      group_by: ['alertname', 'instance']
      group_wait: 3m        # wait for related alerts to coalesce (scrape interval is 120s)
      group_interval: 10m
      repeat_interval: 6h
      routes:
        # Watchdog: silence it (route to null receiver)
        # If using an external dead man's switch, replace "null" with a dedicated webhook receiver
        - receiver: "null"
          matchers:
            - alertname = "Watchdog"
        # Critical: HA with aggressive repeat, then continue to Slack
        - receiver: homeassistant
          matchers:
            - severity = "critical"
          repeat_interval: 1h
          continue: true
        # Warning: HA with standard repeat, then continue to Slack
        - receiver: homeassistant
          matchers:
            - severity = "warning"
          repeat_interval: 6h
          continue: true
        # Slack: catches critical + warning (after continue from above)
        - receiver: slack
          matchers:
            - severity =~ "critical|warning"
          repeat_interval: 6h
    receivers:
      - name: homeassistant
        webhook_configs:
          - url: 'https://homeassistant.sharmamohit.com:8123/api/webhook/alertmanager-infra-alerts'
            send_resolved: true
      - name: slack
        slack_configs:
          - api_url_file: '/etc/alertmanager/secrets/alertmanager-slack-webhook/slack-webhook-url'
            channel: '#homelab-alerts'
            send_resolved: true
            title: '{{ if eq .Status "firing" }}:fire:{{ else }}:white_check_mark:{{ end }} {{ .CommonLabels.alertname }}'
            text: '{{ range .Alerts }}*{{ .Labels.severity | toUpper }}* — {{ .Labels.instance }}\n{{ .Annotations.summary }}\n{{ end }}'
      - name: "null"          # silently drops alerts (used for Watchdog)
```

**Routing logic**:
- Watchdog (`severity: none`) → `null` receiver (silenced). Replace with a dead man's switch webhook if using one.
- Critical → HA (1h repeat) + `continue` → Slack (6h repeat). Both fire.
- Warning → HA (6h repeat) + `continue` → Slack (6h repeat). Both fire.
- Anything else (e.g., `severity: info`) → falls to default receiver (`homeassistant`).

**Slack setup required** (manual, one-time):
1. Go to api.slack.com/apps -> Create New App -> From scratch
2. Enable Incoming Webhooks -> Add to `#homelab-alerts` channel
3. Copy the webhook URL

**Secret handling**: The Slack webhook URL is stored in a SOPS-encrypted K8s Secret (`alertmanager-slack-secret.yaml` in `kubernetes/infrastructure/configs/`). The Prometheus Operator mounts it via `alertmanagerSpec.secrets` at `/etc/alertmanager/secrets/alertmanager-slack-webhook/`. The Alertmanager config references it via `api_url_file` instead of inline `api_url`, keeping sensitive data out of helm values.

### 1C: Deploy node health rules immediately

These work with existing node_exporter metrics (no new exporters needed).

**Note on `source` label**: All non-K8s Alloy instances (both Docker-managed and bare-metal systemd) use `source = "infra"` as an external label, identifying them as infrastructure hosts managed outside the K8s cluster. The bare-metal pve/truenas Alloy configs use the same label for consistency.

- `InfraHostDown`: `up{job="integrations/unix", source="infra"} == 0` for 5m — critical
- `FilesystemSpaceLow`: >85% full for 15m — warning
- `FilesystemSpaceCritical`: >95% full for 5m — critical
- `FilesystemWillFillIn24h`: linear prediction — warning
- `HighMemoryUsage`: >90% for 15m — warning
- `HighCpuLoad`: >90% sustained 30m — warning

### 1D: Watchdog / Dead Man's Switch (optional but recommended)

Add a `Watchdog` alert that always fires. If the watchdog STOPS firing, it means the monitoring pipeline is broken (Prometheus down, Alertmanager down, network partition).

```yaml
- alert: Watchdog
  expr: vector(1)
  labels:
    severity: none
  annotations:
    summary: "Alertmanager is alive"
```

The Watchdog is routed to a `null` receiver in the Alertmanager config (Phase 1B) so it doesn't spam HA or Slack. To get value from it, replace `null` with a dead man's switch service (e.g., Healthchecks.io, Dead Man's Snitch, or self-hosted) that alerts you when the heartbeat *stops* arriving.

---

## Phase 2: SMART Disk Monitoring

All 3 servers use the same approach: `smartctl_exporter` as a hardened systemd service on the host. This is consistent, reliable, and survives container rebuilds.

### Binary Installation

**Installed versions**: server04 has v0.14.0, pve and truenas have v0.13.0.

| Host | Binary path | Version | Notes |
|------|------------|---------|-------|
| server04 | `/opt/smartctl-exporter/smartctl_exporter` | v0.14.0 | Standard install to `/opt/` |
| pve | `/opt/smartctl-exporter/smartctl_exporter` | v0.13.0 | Standard install to `/opt/` |
| truenas | `/root/smartctl-exporter/smartctl_exporter` | v0.13.0 | `/opt/` is read-only, `/mnt/` has `noexec` — binary must live under `/root/` |

Download and install:

```bash
# Adjust version as needed
SMARTCTL_EXPORTER_VERSION="0.14.0"

wget -q "https://github.com/prometheus-community/smartctl_exporter/releases/download/v${SMARTCTL_EXPORTER_VERSION}/smartctl_exporter-${SMARTCTL_EXPORTER_VERSION}.linux-amd64.tar.gz" \
  -O /tmp/smartctl_exporter.tar.gz

# pve / server04:
mkdir -p /opt/smartctl-exporter
tar -xzf /tmp/smartctl_exporter.tar.gz -C /opt/smartctl-exporter/ --strip-components=1

# truenas (read-only root FS, noexec on /mnt):
mkdir -p /root/smartctl-exporter
tar -xzf /tmp/smartctl_exporter.tar.gz -C /root/smartctl-exporter/ --strip-components=1
```

### Systemd Service Template

```ini
[Unit]
Description=Prometheus SMART disk metrics exporter
Documentation=https://github.com/prometheus-community/smartctl_exporter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/smartctl-exporter/smartctl_exporter \
  --web.listen-address=127.0.0.1:9633 \
  --smartctl.interval=120s
Restart=on-failure
RestartSec=10
StartLimitIntervalSec=300
StartLimitBurst=5

# Hardening
NoNewPrivileges=true
ProtectHome=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
```

**Note**: Runs as root because `smartctl` needs raw device access. Systemd hardening limits attack surface. `NoNewPrivileges=true` prevents privilege escalation.

**TrueNAS exception**: The truenas systemd service must use `ProtectHome=false` (binary lives under `/root/`) and `ExecStart` path must point to `/root/smartctl-exporter/smartctl_exporter`.

### smartctl_exporter `--smartctl.device` flag syntax

The `--smartctl.device` flag uses a **semicolon** (`;`) as the separator between device path and device type (e.g., `"/dev/sda;cciss,0"`). The old `:::` separator does NOT work. When `--smartctl.device` flags are used, auto-scan is disabled — any device not listed is silently unmonitored.

**SMART health metric name**: v0.13.0 and v0.14.0 both use `smartctl_device_smart_status` (value `1` = healthy).

### 2A: server04 (HP Smart Array — needs explicit device flags)

**server04-specific ExecStart** (overrides template):

```ini
ExecStart=/opt/smartctl-exporter/smartctl_exporter \
  --web.listen-address=127.0.0.1:9633 \
  --smartctl.interval=120s \
  --smartctl.device="/dev/sda;cciss,0" \
  --smartctl.device="/dev/sdb;cciss,0" \
  --smartctl.device="/dev/sdc;cciss,0" \
  --smartctl.device="/dev/sdd;cciss,0" \
  --smartctl.device=/dev/sde
```

All 5 drives are explicitly listed. When `--smartctl.device` flags are used, auto-scan is disabled — any device not listed is silently unmonitored. The HP Smart Array presents each SAS drive as a separate block device (`/dev/sda`-`/dev/sdd`); the semicolon separator specifies the `cciss,0` device type for each. `/dev/sde` is the SATA SSD (auto-detected, no type needed).

**Listen address**: `127.0.0.1:9633` — Alloy runs on the same host as a systemd service.

**Alloy systemd service on server04**: Same approach as pve/truenas — install via Grafana APT repo (server04 is Ubuntu 22.04). server04's Alloy config is the most complete of the three because it also collects Docker container metrics (cAdvisor), Docker container logs, and IPMI data.

The `alloy` user must be added to the `docker` group for Docker socket access: `usermod -aG docker alloy`

**Migration**: The `server04-alloy` Komodo stack has been undeployed and removed from `docker/komodo-resources/stacks-server04.toml`. Systemd Alloy handles all monitoring on server04.

**Config**: `/etc/alloy/config.alloy` — extends the pve/truenas config with Docker + IPMI blocks:

```river
// ============================================================
// Host metrics (node_exporter)
// ============================================================
prometheus.exporter.unix "host" {
  procfs_path = "/proc"
  sysfs_path  = "/sys"
  rootfs_path = "/"
}

prometheus.scrape "host" {
  targets         = prometheus.exporter.unix.host.targets
  forward_to      = [prometheus.relabel.instance.receiver]
  scrape_interval = "60s"
  job_name        = "node"
}

// ============================================================
// SMART disk health (local smartctl_exporter)
// ============================================================
prometheus.scrape "smartctl" {
  targets         = [{"__address__" = "127.0.0.1:9633"}]
  forward_to      = [prometheus.relabel.instance.receiver]
  scrape_interval = "120s"
  job_name        = "smartctl"
}

// ============================================================
// Container metrics (cAdvisor) — server04 runs Docker containers
// ============================================================
prometheus.exporter.cadvisor "containers" {
  docker_host = "unix:///var/run/docker.sock"
}

prometheus.scrape "containers" {
  targets         = prometheus.exporter.cadvisor.containers.targets
  forward_to      = [prometheus.relabel.instance.receiver]
  scrape_interval = "60s"
  job_name        = "cadvisor"
}

// ============================================================
// Relabel: add instance label
// ============================================================
prometheus.relabel "instance" {
  forward_to = [prometheus.remote_write.prometheus.receiver]
  rule {
    action       = "replace"
    target_label = "instance"
    replacement  = "server04"
  }
}

// ============================================================
// Remote write: push metrics to K8s Prometheus
// ============================================================
prometheus.remote_write "prometheus" {
  // "infra" identifies non-K8s infrastructure hosts.
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
    replacement  = "server04"
  }
}

loki.source.docker "containers" {
  host       = "unix:///var/run/docker.sock"
  targets    = discovery.relabel.docker_logs.output
  forward_to = [loki.write.loki.receiver]
}

// ============================================================
// Host journal logs (syslog, kernel, hardware errors)
// ============================================================
loki.source.journal "host" {
  forward_to = [loki.process.journal.receiver]
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
      instance = "server04",
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
}
```

### 2B: pve (2 SSDs, direct SATA — Alloy systemd on host)

Uses the standard smartctl_exporter systemd template. `smartctl --scan` finds both SSDs.

**Listen address**: `127.0.0.1:9633` — Alloy runs on the same host as a systemd service. No LAN exposure needed.

**Alloy systemd service on pve**: Instead of scraping smartctl_exporter remotely from the komodo LXC, install Alloy directly on the pve host. This gives us actual bare-metal host metrics (CPU, memory, disk I/O) rather than LXC guest metrics, and eliminates the cross-host scrape dependency.

Install via Grafana APT repository (pve is Debian 13):

```bash
# Add Grafana APT repo
apt-get install -y apt-transport-https software-properties-common
mkdir -p /etc/apt/keyrings/
wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
  > /etc/apt/sources.list.d/grafana.list
apt-get update
apt-get install -y alloy
```

The .deb package creates `/etc/alloy/`, the systemd service, and a dedicated `alloy` user.

**Config**: `/etc/alloy/config.alloy` — River config matching the shared Alloy template, plus smartctl scrape:

```river
// ============================================================
// Host metrics (node_exporter)
// ============================================================
prometheus.exporter.unix "host" {
  procfs_path = "/proc"
  sysfs_path  = "/sys"
  rootfs_path = "/"
}

prometheus.scrape "host" {
  targets         = prometheus.exporter.unix.host.targets
  forward_to      = [prometheus.relabel.instance.receiver]
  scrape_interval = "60s"
  job_name        = "node"
}

// ============================================================
// SMART disk health (local smartctl_exporter)
// ============================================================
prometheus.scrape "smartctl" {
  targets         = [{"__address__" = "127.0.0.1:9633"}]
  forward_to      = [prometheus.relabel.instance.receiver]
  scrape_interval = "120s"
  job_name        = "smartctl"
}

// ============================================================
// Relabel: add instance label
// ============================================================
prometheus.relabel "instance" {
  forward_to = [prometheus.remote_write.prometheus.receiver]
  rule {
    action       = "replace"
    target_label = "instance"
    replacement  = "pve"
  }
}

// ============================================================
// Remote write: push metrics to K8s Prometheus
// ============================================================
prometheus.remote_write "prometheus" {
  // "infra" identifies non-K8s infrastructure hosts.
  // Bare-metal hosts use the same label for consistent alert expressions.
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
// Host journal logs (syslog, kernel, hardware errors)
// ============================================================
// Ships systemd journal to Loki — catches SATA errors, kernel panics,
// ECC memory errors, and other hardware events that appear in logs
// before they show up in SMART metrics.

loki.source.journal "host" {
  forward_to = [loki.process.journal.receiver]
  relabel_rules = loki.relabel.journal.rules
  labels = {
    job = "journal",
  }
}

loki.relabel "journal" {
  forward_to = []   // unused — rules extracted via .rules
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
      instance = "pve",
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
}
```

**Notes**:
- No Docker container log collection on pve — Alloy on the komodo LXC already handles that for Komodo-managed containers. The pve Alloy focuses on bare-metal host metrics, SMART data, and host journal logs.
- The `alloy` user must be added to the `systemd-journal` group: `usermod -aG systemd-journal alloy`
- truenas config is identical but with `instance = "truenas"` in the relabel/process stages.

**Environment file**: `/etc/alloy/env` (mode 0600, owned by root):
```
PROMETHEUS_URL=https://prometheus.sharmamohit.com/api/v1/write
LOKI_URL=https://loki.sharmamohit.com/loki/api/v1/push
BASIC_AUTH_USERNAME=<decrypted value>
BASIC_AUTH_PASSWORD=<decrypted value>
```

Credentials come from the same SOPS-encrypted values used by Docker Alloy instances. Decrypt once during manual setup, place in env file.

**Systemd override** for Alloy service (set env file path):
```ini
# /etc/systemd/system/alloy.service.d/override.conf
[Service]
EnvironmentFile=/etc/alloy/env
```

### 2C: truenas (14 drives, LSI SAS2308 IT mode — Alloy systemd on host)

Same approach as pve: smartctl_exporter + Alloy both as systemd services on the truenas host.

**Listen address**: `127.0.0.1:9633` — local scrape only.

**Alloy installation**: TrueNAS blocks APT package management ("Package management tools are disabled on TrueNAS appliances"), so Alloy is installed as a standalone binary downloaded from GitHub releases. Installed at `/root/alloy/alloy` (v1.6.1). A custom systemd unit at `/etc/systemd/system/alloy.service` runs it.

**Config**: Same River config structure as pve, but with `instance = "truenas"`. Config at `/etc/alloy/config.alloy`, env at `/etc/default/alloy` (mode 0600).

**TrueNAS filesystem constraints** (discovered during install):
- `/opt/` is **read-only** (root FS is immutable ZFS boot pool)
- `/mnt/` is mounted with **`noexec`** — binaries cannot execute from ZFS data pools
- `/root/` is writable and executable — both smartctl_exporter and Alloy binaries live under `/root/`
- `/etc/systemd/system/` is writable — custom systemd services work
- `ProtectHome=false` in both systemd services since binaries live under `/root/`
- TrueNAS OS upgrades may reset `/etc/systemd/system/` and `/root/`. The `SmartExporterDown` alert will fire if this happens. Reinstall from documented steps.

### Listen Address Summary

All smartctl_exporter instances bind to `127.0.0.1:9633` — Alloy always runs on the same host.

| Host | smartctl_exporter | Binary path | Alloy | Notes |
|------|------------------|-------------|-------|-------|
| pve | `127.0.0.1:9633` (systemd, v0.13.0) | `/opt/smartctl-exporter/` | Systemd (APT package) | 2 SSDs, auto-scan. Host metrics + SMART + journal |
| truenas | `127.0.0.1:9633` (systemd, v0.13.0) | `/root/smartctl-exporter/` | Systemd (manual binary, v1.6.1 at `/root/alloy/`) | 14 drives (LSI IT mode), auto-scan. `ProtectHome=false`. Host metrics + SMART + journal |
| server04 | `127.0.0.1:9633` (systemd, v0.14.0) | `/opt/smartctl-exporter/` | Systemd (APT package) | 5 drives (4 SAS via `";cciss,0"` + 1 SSD). Host metrics + SMART + cAdvisor + Docker logs + journal. Replaces `server04-alloy` Komodo stack |

---

## Phase 3: IPMI Monitoring — DROPPED

~~Deploy `ipmi_exporter` on server04.~~

**Status**: Dropped. server04's iLO is dead, and the only other BMC (truenas iDRAC at 192.168.10.185) is not worth the complexity of deploying a separate exporter for a single target. Can be revisited if iLO is repaired or more BMC targets are added.

---

## Phase 4: PrometheusRules for Hardware Health

**Modify**: `kubernetes/apps/argocd-apps/apps/kube-prometheus-stack.yaml`

Deploy AFTER Phase 2 exporters are confirmed working.

### SMART Disk Health

| Alert | Expression | For | Severity | Notes |
|-------|-----------|-----|----------|-------|
| SmartDiskUnhealthy | `smartctl_device_smart_status != 1` | 5m | critical | Most important alert (metric name is `smartctl_device_smart_status` in v0.13+) |
| SmartReallocatedSectorsGrowing | `increase(smartctl_device_attribute{attribute_name="Reallocated_Sector_Ct",attribute_value_type="raw"}[24h]) > 0` | 5m | warning | Uses `increase()` to avoid false alarms from pre-existing sectors |
| SmartPendingSectorsGrowing | `increase(smartctl_device_attribute{attribute_name="Current_Pending_Sector",attribute_value_type="raw"}[24h]) > 0` | 5m | warning | Uses `increase()` — same rationale |
| SmartDiskTemperatureHigh | `smartctl_device_temperature{temperature_type="current"} > 55` | 10m | warning | Must filter `temperature_type="current"` — `drive_trip` values are manufacturer shutdown thresholds, not actual temps |
| SmartDiskTemperatureCritical | `smartctl_device_temperature{temperature_type="current"} > 65` | 5m | critical | Same filter required |
| SmartNvmeMediaErrors | `increase(smartctl_device_media_errors[24h]) > 0` | 5m | warning | `increase()` for same reason |
| SmartNvmeCriticalWarning | `smartctl_device_critical_warning > 0` | 5m | critical | |
| SmartExporterDown | `up{job="smartctl"} == 0` | 5m | warning | A crashed exporter may itself indicate disk problems |

### Node Health (deployed in Phase 1C)

InfraHostDown, FilesystemSpace*, HighMemory, HighCPU, FilesystemWillFill — see Phase 1C.

---

## Phase 5: ZFS Pool Health on TrueNAS (stretch goal)

SMART monitors per-drive health, but a degraded ZFS pool won't trigger SMART alerts — a pool can be DEGRADED while all remaining drives report SMART PASSED. This is the most significant monitoring gap after SMART.

With Alloy running directly on truenas (Phase 2C), we have direct access to the host's ZFS data:

**Preferred approach**: Alloy's built-in `prometheus.exporter.unix` already collects ZFS metrics when running on the host (it reads `/proc/spl/kstat/zfs/`). The key metric is `node_zfs_zpool_state`. If the exporter doesn't expose pool state, add a scrape of the TrueNAS API (`localhost/api/v2.0/pool`) or a `zpool status` textfile collector.

**Alert rule**:
```yaml
- alert: ZfsPoolDegraded
  expr: node_zfs_zpool_state{state!="online"} == 1
  for: 5m
  labels:
    severity: critical
```

---

## Execution Order

```
Phase 1 ─── Alertmanager receivers + HA webhook + node health rules  ✅ DONE
             (foundation — works with existing metrics)
                 |
Phase 2 ──── smartctl_exporter (systemd) + Alloy (systemd) on all 3 hosts  ✅ DONE
             server04: also remove existing Docker Alloy (server04-alloy stack)
                 |
Phase 3 ──── DROPPED (server04 iLO dead, not worth single-target IPMI exporter)
                 |
Phase 4 ───── SMART PrometheusRules (after metrics confirmed)  ✅ DONE
                 |
Phase 5 ───── ZFS pool health via truenas Alloy  ✅ DONE
```

## Files Summary

### New files (GitOps)
| File | Purpose |
|------|---------|
| `kubernetes/infrastructure/configs/alertmanager-slack-secret.yaml` | SOPS-encrypted Slack webhook URL |

### Modified files (GitOps)
| File | Changes |
|------|---------|
| `kubernetes/apps/argocd-apps/apps/kube-prometheus-stack.yaml` | Alertmanager config (api_url_file + secrets mount) + PrometheusRules |
| `kubernetes/infrastructure/configs/kustomization.yaml` | Add alertmanager-slack-secret.yaml |
| `docker/komodo-resources/stacks-server04.toml` | `server04-alloy` stack removed (replaced by systemd) |

### Manual steps (not GitOps)
| Step | Host | Action |
|------|------|--------|
| 1 | pve | Install smartctl_exporter v0.13.0 binary + systemd service (listen: 127.0.0.1:9633) |
| 2 | pve | Install Alloy via Grafana APT repo + River config + env file with credentials |
| 3 | pve | Add alloy user to systemd-journal group: `usermod -aG systemd-journal alloy` |
| 4 | truenas | Install smartctl_exporter v0.13.0 binary + systemd service (listen: 127.0.0.1:9633) |
| 5 | truenas | Install Alloy via Grafana APT repo + River config + env file with credentials |
| 6 | truenas | Add alloy user to systemd-journal group: `usermod -aG systemd-journal alloy` |
| 7 | server04 | Install smartctl_exporter v0.13.0 binary + systemd service (listen: 127.0.0.1:9633, with cciss,N + /dev/sde flags) |
| 8 | server04 | Install Alloy via Grafana APT repo + River config + env file with credentials |
| 9 | server04 | Add alloy user to groups: `usermod -aG systemd-journal,docker alloy` |
| 10 | server04 | Undeploy `server04-alloy` Komodo stack — done, removed from stacks-server04.toml |
| 11 | Slack | Create incoming webhook app, copy webhook URL for Alertmanager config |
| 12 | HA | Create webhook automation for Alertmanager notifications |

**Note**: komodo and seaweedfs Alloy stacks continue using the shared compose config unchanged — no overrides needed for those hosts.

### Credential Rotation Procedure

The Prometheus/Loki basic auth credentials are stored in two places:
1. **Docker Alloy instances** (komodo, nvr, kasm, omni, seaweedfs, racknerd-aegis): SOPS-encrypted `.sops.env` in git (decrypted by Komodo pre_deploy)
2. **Systemd Alloy instances** (pve, truenas, server04): Plain-text `/etc/alloy/env` (mode 0600, manually placed)

If credentials need to be rotated:
1. Update the SOPS-encrypted `.sops.env` in the repo, commit, sync, and redeploy Docker Alloy stacks
2. SSH to pve, truenas, and server04, update `/etc/alloy/env` with new credentials
3. Restart Alloy on all three: `systemctl restart alloy`
4. Verify metrics are flowing in Grafana/Prometheus

## Verification

1. **Phase 1**: Trigger test alert -> confirm phone push notification arrives on HA AND message appears in `#homelab-alerts` Slack channel. Verify Watchdog alert does NOT reach HA or Slack.
2. **Phase 2 (metrics)**: `curl -s http://127.0.0.1:9633/metrics | grep smartctl_device_smart_status` on each host. On server04, verify 5 devices appear (4 cciss + 1 SSD `/dev/sde`)
3. **Phase 2 (logs)**: Query Loki for `{job="journal", instance="pve"}`, `{instance="truenas"}`, and `{instance="server04"}` — verify journal entries are flowing. On server04, also verify Docker container logs are still captured: `{container="/traefik", instance="server04"}`.
4. **Phase 4**: Check Alertmanager UI — no false positives, rules evaluating correctly

## Risks

| Risk | Mitigation |
|------|------------|
| smartctl_exporter/Alloy wiped by TrueNAS major upgrade | Both `SmartExporterDown` and Alloy health alerts fire. Reinstall from documented steps. Binary in `/opt/` and APT packages survive minor updates |
| Alloy on pve wiped by Proxmox major upgrade | Same alert-based detection. APT packages generally survive Proxmox upgrades since they use standard Debian packaging |
| Alert flood on initial deploy | `group_wait: 3m`, `repeat_interval: 6h` (warnings) / `1h` (critical) |
| HP Smart Array hides new drives | If drives are added/replaced, update `cciss,N` flags in systemd service and restart |
| HA down = no alerts | Slack as secondary receiver — all alerts go to both HA and Slack |
| Total monitoring failure (Prometheus/Alloy down) | Watchdog alert + dead man's switch service catches silent failures |
| ZFS pool degraded but SMART OK | Phase 5 adds ZFS pool state monitoring (stretch goal) |
| Alloy credentials on pve/truenas/server04 not SOPS-managed | Env file with mode 0600. Credentials are same as Docker Alloy instances. Rotation procedure documented in manual steps |
| server04 Docker Alloy removal is a migration | Deploy systemd Alloy first, verify metrics/logs flowing, then undeploy Docker Alloy. Brief gap possible during cutover |

## SRE Review Findings Addressed

| ID | Finding | Resolution |
|----|---------|------------|
| H1 | No dead man's switch | Added Phase 1D: Watchdog alert + null receiver routing |
| H2 | HA webhook single point of failure | Added Slack as secondary receiver in Phase 1B |
| H3 | Sector alerts `> 0` false alarms | Changed to `increase(...[24h]) > 0` |
| H5 | server04 SATA SSD unmonitored | Explicitly added `--smartctl.device=/dev/sde` (auto-scan disabled when flags used) |
| C1 | smartctl_exporter binds to all interfaces | Changed shared template to `127.0.0.1:9633` |
| M2 | `ipmi.sops.yml` not handled by decrypt | N/A — Phase 3 (IPMI) dropped |
| M4 | ZFS pool health unmonitored | Added Phase 5 |
| M5 | `group_wait` too short | Increased to `3m` |
| M6 | IPMI thresholds too generic | Added sensor-name-aware alerts |
| M7 | Fan RPM threshold arbitrary | Changed to `ipmi_fan_speed_state` BMC metric |
| L1 | No version pinning | Added pinned install script with version file |
| L2 | ExporterDown `for` too long | Reduced to `5m` |
| L3 | `repeat_interval` too long for critical | Split: `1h` critical, `6h` warning |
| M1 | Missing `NoNewPrivileges` | Added to systemd template |

## Architecture Review Findings Addressed

| ID | Finding | Resolution |
|----|---------|------------|
| A1 | Warnings never reach HA (routing bug) | Added explicit warning→HA route with `continue: true` |
| A2 | Watchdog spams phone | Routed to `null` receiver; documented DMS replacement |
| A3 | `source="docker"` label wrong for bare-metal | Renamed to `source="infra"` to accurately reflect infrastructure hosts |
| A4 | No journal shipping from pve/truenas | Added `loki.source.journal` to River config; `alloy` user added to `systemd-journal` group |
| A5 | smartctl_exporter shared template binds 0.0.0.0 | Changed to `127.0.0.1:9633` |
| A6 | server04 `/dev/sde` silently unmonitored | Explicitly listed in `--smartctl.device` flags |
| A7 | Credential rotation undocumented | Added rotation procedure to manual steps section |
| A8 | server04 Alloy inconsistently uses Docker while pve/truenas use systemd | Switched to systemd Alloy on server04 too. Removes alloy-override file, removes server04-alloy Komodo stack. All 3 hosts now use identical systemd approach |
