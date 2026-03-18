# Media Stack Monitoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Full observability for the media stack on LXC 400 — infrastructure metrics/logs, application metrics, playback analytics, and alerting.

**Architecture:** Systemd Alloy on the LXC host for metrics collection + log shipping. cAdvisor, Scraparr, and Jellystat as Docker containers in the existing compose template. Grafana alert rules and dashboard deployed via kube-prometheus-stack.yaml. Single runbook for all alerts.

**Tech Stack:** Grafana Alloy (River config), cAdvisor, Scraparr, Jellystat+PostgreSQL, Prometheus/Loki/Grafana (existing K8s stack), Ansible (IaC)

**Spec:** `docs/superpowers/specs/2026-03-18-media-stack-monitoring-design.md`

---

## File Map

### New Files

| File | Responsibility |
|------|----------------|
| `proxmox/templates/media-stack-alloy.config.j2` | Alloy River config — host metrics, cAdvisor/Scraparr/Jellyfin scrapes, Docker logs, journal logs, textfile collector |
| `proxmox/templates/media-stack-alloy-env.j2` | Alloy credentials (Prometheus/Loki endpoints + basic auth) |
| `proxmox/templates/media-stack-alloy-override.conf.j2` | Alloy systemd override (EnvironmentFile + MemoryMax) |
| `proxmox/templates/media-stack-docker-daemon.json.j2` | Docker daemon log rotation defaults |
| `proxmox/templates/media-stack-rd-expiry-check.sh.j2` | RD account expiry cron script |
| `proxmox/templates/media-stack-fuse-check.sh.j2` | FUSE mount health cron script |
| `docs/runbooks/media-stack-alerts.md` | Alert runbook for all Media Stack alerts |

### Modified Files

| File | What Changes |
|------|-------------|
| `proxmox/templates/media-stack-compose.yaml.j2` | Add cAdvisor, Scraparr, Jellystat, Jellystat-DB services |
| `proxmox/templates/media-stack-env.j2` | Add Prowlarr/Bazarr API keys, Jellystat secrets |
| `proxmox/media-stack.yml` | Add Play 4 (monitoring: Docker daemon config, Alloy, cron jobs, Jellyfin plugin) |
| `kubernetes/apps/argocd-apps/apps/kube-prometheus-stack.yaml` | Add Media Stack alert folder with 9 rules + dashboard JSON |

---

## Pre-Implementation: Secrets

Before running any tasks, the user must add these secrets to `proxmox/group_vars/all/secrets.sops.yml`:

| Secret | How to Obtain |
|--------|---------------|
| `vault_prowlarr_api_key` | Prowlarr UI → Settings → General → API Key |
| `vault_bazarr_api_key` | Bazarr UI → Settings → General → API Key |
| `vault_jellystat_db_password` | Generate: `openssl rand -hex 16` |
| `vault_jellystat_jwt_secret` | Generate: `openssl rand -hex 32` |
| `vault_alloy_basic_auth_username` | Same value as existing Alloy instances (from Docker `.sops.env`) |
| `vault_alloy_basic_auth_password` | Same value as existing Alloy instances (from Docker `.sops.env`) |

Already in vault: `vault_rd_api_key`, `vault_radarr_api_key`, `vault_sonarr_api_key`, `vault_jellyfin_api_key`

---

### Task 1: Docker Daemon Log Rotation

**Files:**
- Create: `proxmox/templates/media-stack-docker-daemon.json.j2`
- Modify: `proxmox/media-stack.yml` (Play 3, add tasks before Docker start)

This must go before any new containers are deployed so all containers get log rotation from the start.

- [ ] **Step 1: Create Docker daemon config template**

Create `proxmox/templates/media-stack-docker-daemon.json.j2`:

```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
```

- [ ] **Step 2: Add daemon.json deployment to Play 3**

In `proxmox/media-stack.yml`, add these tasks in Play 3 after the "Enable and start Docker" task but before the "Deploy configs" section:

```yaml
    # ── Docker daemon log rotation ─────────────────────
    - name: Deploy Docker daemon config (log rotation)
      ansible.builtin.template:
        src: media-stack-docker-daemon.json.j2
        dest: /etc/docker/daemon.json
        owner: root
        group: root
        mode: "0644"
      notify: restart docker

    - name: Ensure Docker is running with latest config
      ansible.builtin.meta: flush_handlers
```

Also add a handler to the `handlers:` section:

```yaml
    - name: restart docker
      ansible.builtin.systemd:
        name: docker
        state: restarted
```

- [ ] **Step 3: Verify**

1. Validate the JSON template is valid: `python3 -c "import json; json.load(open('proxmox/templates/media-stack-docker-daemon.json.j2'))"`
2. Verify playbook syntax: `ansible-playbook proxmox/media-stack.yml --syntax-check`
3. Confirm the new tasks appear in the right position in Play 3 (after Docker start, before deploy configs)
4. Confirm the `restart docker` handler is in Play 3's `handlers:` block (not Play 4's)

- [ ] **Step 4: Commit**

```bash
git add proxmox/templates/media-stack-docker-daemon.json.j2 proxmox/media-stack.yml
git commit -m "feat(monitoring): add Docker daemon log rotation for media-stack LXC"
```

---

### Task 2: Add Monitoring Containers to Compose Template

**Files:**
- Modify: `proxmox/templates/media-stack-compose.yaml.j2`
- Modify: `proxmox/templates/media-stack-env.j2`
- Modify: `proxmox/media-stack.yml` (add jellystat-db config directory)

- [ ] **Step 1: Add new env vars to media-stack-env.j2**

Append to `proxmox/templates/media-stack-env.j2`:

```
# Scraparr — arr application metrics
RADARR_API_KEY={{ vault_radarr_api_key }}
SONARR_API_KEY={{ vault_sonarr_api_key }}
PROWLARR_API_KEY={{ vault_prowlarr_api_key }}
BAZARR_API_KEY={{ vault_bazarr_api_key }}
# Jellystat — playback analytics
JELLYSTAT_DB_PASSWORD={{ vault_jellystat_db_password }}
JELLYSTAT_JWT_SECRET={{ vault_jellystat_jwt_secret }}
```

- [ ] **Step 2: Add monitoring containers to compose template**

Append to the `services:` section of `proxmox/templates/media-stack-compose.yaml.j2`:

```yaml
  # ── Monitoring: cAdvisor (container metrics) ────────
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

  # ── Monitoring: Scraparr (arr app metrics) ──────────
  # Note: ${VAR} syntax is resolved by Docker Compose from the .env file.
  # Do NOT use env_file here — it would leak unrelated secrets into this container.
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
    depends_on:
      - radarr
      - sonarr
      - prowlarr
      - bazarr
    restart: unless-stopped
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  # ── Analytics: Jellystat PostgreSQL ─────────────────
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

  # ── Analytics: Jellystat (playback analytics UI) ────
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
      - TZ=America/Vancouver
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

- [ ] **Step 3: Add jellystat-db config directory to media-stack.yml**

In `proxmox/media-stack.yml` Play 3, add `jellystat-db` to the directory creation loop:

```yaml
      loop:
        - jellyfin
        - radarr
        - sonarr
        - prowlarr
        - bazarr
        - jellyseerr
        - decypharr
        - suggestarr
        - tunarr
        - profilarr
        - jellystat-db   # <-- add this
```

- [ ] **Step 4: Verify**

1. Validate compose template renders valid YAML (no Jinja2 syntax errors): `python3 -c "import yaml; print('OK')"` after checking for balanced braces and correct indentation
2. Confirm no `env_file` directive on scraparr service (only `environment` with `${VAR}` substitution)
3. Confirm all 4 new services have `logging:` blocks with `max-size: "10m"` and `max-file: "3"`
4. Confirm `jellystat-db` is in the directory creation loop in media-stack.yml
5. Confirm cAdvisor and Scraparr ports are bound to `127.0.0.1` (not `0.0.0.0`)
6. Confirm Jellystat port 3000 is NOT bound to `127.0.0.1` (needs LAN access for standalone UI)
7. Verify playbook syntax: `ansible-playbook proxmox/media-stack.yml --syntax-check`

- [ ] **Step 5: Commit**

```bash
git add proxmox/templates/media-stack-compose.yaml.j2 proxmox/templates/media-stack-env.j2 proxmox/media-stack.yml
git commit -m "feat(monitoring): add cAdvisor, Scraparr, Jellystat to media-stack compose"
```

---

### Task 3: Alloy Systemd Service + Config Templates

**Files:**
- Create: `proxmox/templates/media-stack-alloy.config.j2`
- Create: `proxmox/templates/media-stack-alloy-env.j2`
- Create: `proxmox/templates/media-stack-alloy-override.conf.j2`

- [ ] **Step 1: Create Alloy River config template**

Create `proxmox/templates/media-stack-alloy.config.j2` with the full River config from the spec. This is the complete config — copy it verbatim from the spec's "Alloy River Config" section. Key scrape targets:
- `prometheus.exporter.unix "host"` with `textfile_directory = "/var/lib/alloy/textfile"`
- `prometheus.scrape "cadvisor"` → `127.0.0.1:8080`, interval 60s
- `prometheus.scrape "scraparr"` → `127.0.0.1:7100`, interval 120s
- `prometheus.scrape "jellyfin"` → `127.0.0.1:8096`, `/metrics`, interval 60s
- `prometheus.relabel "instance"` → `replacement = "media-stack"`
- `prometheus.remote_write` with `source = "infra"` external label
- `loki.source.docker` for container logs
- `loki.source.journal` for systemd journal
- `loki.write` with `wal { max_segment_age = "1h" }` — **critical disk safety**: without this, Alloy buffers unbounded logs if Loki is down and can fill the 256GB root disk

- [ ] **Step 2: Create Alloy env template**

Create `proxmox/templates/media-stack-alloy-env.j2`:

```
PROMETHEUS_URL=https://prometheus.sharmamohit.com/api/v1/write
LOKI_URL=https://loki.sharmamohit.com/loki/api/v1/push
BASIC_AUTH_USERNAME={{ vault_alloy_basic_auth_username }}
BASIC_AUTH_PASSWORD={{ vault_alloy_basic_auth_password }}
```

- [ ] **Step 3: Create Alloy systemd override template**

Create `proxmox/templates/media-stack-alloy-override.conf.j2`:

```ini
[Service]
EnvironmentFile=/etc/alloy/env
MemoryMax=512M
```

- [ ] **Step 4: Verify**

1. Verify the River config contains all required blocks by grepping for key patterns:
   - `grep 'textfile_directory' proxmox/templates/media-stack-alloy.config.j2` → must find `/var/lib/alloy/textfile`
   - `grep 'max_segment_age' proxmox/templates/media-stack-alloy.config.j2` → must find `1h` (disk safety)
   - `grep 'MemoryMax' proxmox/templates/media-stack-alloy-override.conf.j2` → must find `512M`
   - `grep '127.0.0.1:8080' proxmox/templates/media-stack-alloy.config.j2` → cAdvisor scrape
   - `grep '127.0.0.1:7100' proxmox/templates/media-stack-alloy.config.j2` → Scraparr scrape
   - `grep '127.0.0.1:8096' proxmox/templates/media-stack-alloy.config.j2` → Jellyfin scrape
   - `grep 'instance.*media-stack' proxmox/templates/media-stack-alloy.config.j2` → instance label
   - `grep 'source.*infra' proxmox/templates/media-stack-alloy.config.j2` → external label
2. Verify env template has all 4 variables: `PROMETHEUS_URL`, `LOKI_URL`, `BASIC_AUTH_USERNAME`, `BASIC_AUTH_PASSWORD`
3. Verify override template has both `EnvironmentFile` and `MemoryMax`

- [ ] **Step 5: Commit**

```bash
git add proxmox/templates/media-stack-alloy.config.j2 proxmox/templates/media-stack-alloy-env.j2 proxmox/templates/media-stack-alloy-override.conf.j2
git commit -m "feat(monitoring): add Alloy config templates for media-stack LXC"
```

---

### Task 4: RD Expiry + FUSE Mount Check Scripts

**Files:**
- Create: `proxmox/templates/media-stack-rd-expiry-check.sh.j2`
- Create: `proxmox/templates/media-stack-fuse-check.sh.j2`

- [ ] **Step 1: Create RD expiry check script template**

Create `proxmox/templates/media-stack-rd-expiry-check.sh.j2` — copy the full robust script from the spec's "RD Account Expiry Check" section. Key features:
- `set -euo pipefail`
- Uses `premium` field (seconds remaining), not `expiration`
- Atomic write via tmpfile + mv
- `curl --max-time 30 --retry 1`
- `jq` validation with `// empty` fallback
- Numeric regex guard
- All error paths write `rd_account_expiry_check_ok 0`

- [ ] **Step 2: Create FUSE mount check script template**

Create `proxmox/templates/media-stack-fuse-check.sh.j2` — copy from the spec's "FUSE Mount Health Check" section. Uses `mountpoint -q` + `ls` to test mount health, writes `rd_fuse_mount_healthy` gauge.

- [ ] **Step 3: Verify**

1. RD expiry script robustness checks:
   - `grep 'set -euo pipefail' proxmox/templates/media-stack-rd-expiry-check.sh.j2` → must exist
   - `grep 'premium' proxmox/templates/media-stack-rd-expiry-check.sh.j2` → uses premium field, NOT expiration
   - `grep '\.tmp' proxmox/templates/media-stack-rd-expiry-check.sh.j2` → atomic write via tmpfile
   - `grep 'max-time' proxmox/templates/media-stack-rd-expiry-check.sh.j2` → curl timeout
   - `grep 'write_failure_metric' proxmox/templates/media-stack-rd-expiry-check.sh.j2` → error handler function
   - `grep '\^[0-9]' proxmox/templates/media-stack-rd-expiry-check.sh.j2` → numeric regex guard
2. FUSE check script:
   - `grep 'mountpoint' proxmox/templates/media-stack-fuse-check.sh.j2` → mount probe
   - `grep 'rd_fuse_mount_healthy' proxmox/templates/media-stack-fuse-check.sh.j2` → correct metric name
3. Both scripts must be valid bash: `bash -n proxmox/templates/media-stack-rd-expiry-check.sh.j2` and `bash -n proxmox/templates/media-stack-fuse-check.sh.j2` (will warn on Jinja2 vars but should not have syntax errors)

- [ ] **Step 4: Commit**

```bash
git add proxmox/templates/media-stack-rd-expiry-check.sh.j2 proxmox/templates/media-stack-fuse-check.sh.j2
git commit -m "feat(monitoring): add RD expiry and FUSE health check scripts"
```

---

### Task 5: Ansible Play 4 — Monitoring Deployment

**Files:**
- Modify: `proxmox/media-stack.yml` (add Play 4)

This is the core integration task. Add a new Play 4 that targets `media-stack` and deploys all monitoring components.

- [ ] **Step 1: Add Play 4 to media-stack.yml**

Append after Play 3's `handlers:` block:

```yaml
# ═══════════════════════════════════════════════════════
# Play 4: Deploy monitoring (Alloy + cron jobs)
# Runs on media-stack LXC after Docker stack is up
# ═══════════════════════════════════════════════════════
- name: Deploy media-stack monitoring
  hosts: media-stack
  become: true
  gather_facts: true

  tasks:
    # ── Prerequisites ──────────────────────────────────
    - name: Install monitoring prerequisites
      ansible.builtin.apt:
        name:
          - jq
          - curl
          - apt-transport-https
          - software-properties-common
        state: present

    # ── Grafana APT repo + Alloy install ───────────────
    - name: Ensure keyrings directory exists
      ansible.builtin.file:
        path: /etc/apt/keyrings
        state: directory
        mode: "0755"

    - name: Download Grafana GPG key
      ansible.builtin.get_url:
        url: https://apt.grafana.com/gpg.key
        dest: /tmp/grafana-gpg.key
        mode: "0644"

    - name: Dearmor and install Grafana GPG key
      ansible.builtin.command:
        cmd: gpg --batch --yes --dearmor --output /etc/apt/keyrings/grafana.gpg /tmp/grafana-gpg.key
        creates: /etc/apt/keyrings/grafana.gpg

    - name: Set Grafana keyring permissions
      ansible.builtin.file:
        path: /etc/apt/keyrings/grafana.gpg
        mode: "0644"

    - name: Add Grafana APT repository
      ansible.builtin.apt_repository:
        repo: "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main"
        filename: grafana
        state: present
        update_cache: yes

    - name: Install Alloy
      ansible.builtin.apt:
        name: alloy
        state: present

    # ── Alloy config deployment ────────────────────────
    - name: Deploy Alloy River config
      ansible.builtin.template:
        src: media-stack-alloy.config.j2
        dest: /etc/alloy/config.alloy
        owner: root
        group: root
        mode: "0644"
      notify: restart alloy

    - name: Deploy Alloy credentials env file
      ansible.builtin.template:
        src: media-stack-alloy-env.j2
        dest: /etc/alloy/env
        owner: root
        group: root
        mode: "0600"
      notify: restart alloy

    - name: Create Alloy systemd override directory
      ansible.builtin.file:
        path: /etc/systemd/system/alloy.service.d
        state: directory
        mode: "0755"

    - name: Deploy Alloy systemd override
      ansible.builtin.template:
        src: media-stack-alloy-override.conf.j2
        dest: /etc/systemd/system/alloy.service.d/override.conf
        owner: root
        group: root
        mode: "0644"
      notify:
        - daemon reload
        - restart alloy

    - name: Add alloy user to required groups
      ansible.builtin.user:
        name: alloy
        groups: systemd-journal,docker
        append: yes
      notify: restart alloy

    - name: Create textfile collector directory
      ansible.builtin.file:
        path: /var/lib/alloy/textfile
        state: directory
        owner: alloy
        group: alloy
        mode: "0755"

    - name: Enable and start Alloy
      ansible.builtin.systemd:
        name: alloy
        state: started
        enabled: yes

    # ── RD expiry check cron ───────────────────────────
    - name: Deploy RD expiry check script
      ansible.builtin.template:
        src: media-stack-rd-expiry-check.sh.j2
        dest: /opt/media-stack/rd-expiry-check.sh
        owner: root
        group: root
        mode: "0700"

    - name: Schedule daily RD expiry check (03:00)
      ansible.builtin.cron:
        name: "RD account expiry check"
        hour: "3"
        minute: "0"
        job: "/opt/media-stack/rd-expiry-check.sh"

    - name: Run RD expiry check once to seed initial metric
      ansible.builtin.command:
        cmd: /opt/media-stack/rd-expiry-check.sh
      changed_when: false

    # ── FUSE mount health cron ─────────────────────────
    - name: Deploy FUSE mount check script
      ansible.builtin.template:
        src: media-stack-fuse-check.sh.j2
        dest: /opt/media-stack/fuse-check.sh
        owner: root
        group: root
        mode: "0700"

    - name: Schedule FUSE mount health check (every 5 min)
      ansible.builtin.cron:
        name: "FUSE mount health check"
        minute: "*/5"
        job: "/opt/media-stack/fuse-check.sh"

    - name: Run FUSE check once to seed initial metric
      ansible.builtin.command:
        cmd: /opt/media-stack/fuse-check.sh
      changed_when: false

  handlers:
    - name: daemon reload
      ansible.builtin.systemd:
        daemon_reload: yes

    - name: restart alloy
      ansible.builtin.systemd:
        name: alloy
        state: restarted
```

- [ ] **Step 2: Verify playbook syntax**

```bash
cd /Users/mohitsharma44/devel/myInfra/homelab2.0/kubernetes/homeops
ansible-playbook proxmox/media-stack.yml --syntax-check
```

Expected: `playbook: proxmox/media-stack.yml` (no errors)

- [ ] **Step 3: Verify**

1. Playbook syntax: `ansible-playbook proxmox/media-stack.yml --syntax-check` → must pass
2. Verify Play 4 exists as a separate play (not nested inside Play 3): `grep -c '^- name:' proxmox/media-stack.yml` → should be 4 plays
3. Verify Play 4 targets `media-stack` host: `grep 'hosts: media-stack' proxmox/media-stack.yml`
4. Verify all handlers are defined: `grep -A1 'handlers:' proxmox/media-stack.yml` → should show `daemon reload` and `restart alloy` in Play 4's handlers
5. Verify cron jobs are present: `grep 'ansible.builtin.cron' proxmox/media-stack.yml` → should find 2 cron tasks
6. Verify initial seed runs: `grep 'seed initial metric' proxmox/media-stack.yml` → should find 2 tasks (RD expiry + FUSE)
7. Verify Alloy user group membership: `grep 'systemd-journal,docker' proxmox/media-stack.yml` → must exist

- [ ] **Step 4: Commit**

```bash
git add proxmox/media-stack.yml
git commit -m "feat(monitoring): add Ansible Play 4 for media-stack monitoring deployment"
```

---

### Task 6: Jellyfin Prometheus Plugin

**Files:**
- Modify: `proxmox/media-stack.yml` (add tasks to Play 4)

**Important:** The Jellyfin plugin installation API needs research during implementation. The spec notes "The exact plugin GUID will be verified during implementation." Before writing the Ansible task:

- [ ] **Step 1: Research Jellyfin plugin API**

Search for the Jellyfin Prometheus plugin:
1. Check the Jellyfin plugin catalog API: `GET http://192.168.11.40:8096/Repositories` and `GET http://192.168.11.40:8096/Packages`
2. Find the Prometheus plugin GUID
3. Determine the correct API endpoint for plugin installation
4. Test idempotency (what happens when installing an already-installed plugin)

Document findings as comments in the Ansible task.

- [ ] **Step 2: Add Jellyfin plugin tasks to Play 4**

Add to Play 4 in `proxmox/media-stack.yml`, after the FUSE mount check tasks:

```yaml
    # ── Jellyfin Prometheus plugin ─────────────────────
    - name: Check if Jellyfin Prometheus plugin is installed
      ansible.builtin.uri:
        url: "http://127.0.0.1:8096/Plugins?api_key={{ vault_jellyfin_api_key }}"
        method: GET
        return_content: yes
      register: jellyfin_plugins
      failed_when: false

    - name: Install Jellyfin Prometheus plugin
      ansible.builtin.uri:
        url: "http://127.0.0.1:8096/Packages/Installed/{{ jellyfin_prometheus_plugin_guid }}?api_key={{ vault_jellyfin_api_key }}"
        method: POST
        status_code: [200, 204]
      when: jellyfin_prometheus_plugin_guid not in (jellyfin_plugins.content | default(''))
      register: plugin_install
      # NOTE: jellyfin_prometheus_plugin_guid must be set as a variable
      # after researching the actual GUID in Step 1

    - name: Restart Jellyfin to load plugin
      ansible.builtin.command:
        cmd: docker compose restart jellyfin
        chdir: /opt/media-stack
      when: plugin_install is changed
```

- [ ] **Step 3: Verify**

1. Playbook syntax: `ansible-playbook proxmox/media-stack.yml --syntax-check` → must pass
2. Verify the Jellyfin plugin tasks use header-based auth (`X-Emby-Token`) rather than query parameter auth, per the spec
3. Verify the plugin install task has a `when:` condition for idempotency
4. Verify the Jellyfin restart is conditional (`when: plugin_install is changed`)
5. Verify `jellyfin_prometheus_plugin_guid` is defined as a variable (either in Play 4 vars or in host_vars)

- [ ] **Step 4: Commit**

```bash
git add proxmox/media-stack.yml
git commit -m "feat(monitoring): add Jellyfin Prometheus plugin installation"
```

---

### Task 7: Grafana Alert Rules

**Files:**
- Modify: `kubernetes/apps/argocd-apps/apps/kube-prometheus-stack.yaml`

Add a new `Media Stack` alert folder with 9 rules. Follow the exact YAML structure used by the existing `Infra Node Health` folder (3-stage: query → reduce → threshold, using `datasourceUid: thanos`).

- [ ] **Step 1: Study existing alert rule format**

Read `kubernetes/apps/argocd-apps/apps/kube-prometheus-stack.yaml` lines 185-235 to understand the exact Grafana provisioned alert rule structure:
- Each rule has: `uid`, `title`, `condition`, `data` (array of refId stages), `for`, `labels`, `annotations`
- Metrics rules: refId A (PromQL query) → refId B (reduce/last) → refId C (threshold)
- Log-based rules will use the Loki datasource UID instead of thanos

- [ ] **Step 2: Add Media Stack alert folder**

Add to the `groups:` list in `kube-prometheus-stack.yaml` under `grafana.alerting.rules.yaml`:

```yaml
                - orgId: 1
                  name: media-stack
                  folder: Media Stack
                  interval: 60s
                  rules:
                    # ... 9 rules from the spec
```

Rules to implement (each following the 3-stage pattern):
1. `media-container-down` — MediaContainerDown (absent query on key containers)
2. `media-container-restart-loop` — MediaContainerRestartLoop (increase over 1h)
3. `rd-account-expiring-soon` — RdAccountExpiringSoon (< 15 days, warning)
4. `rd-account-expiry-critical` — RdAccountExpiryCritical (< 5 days, critical)
5. `rd-expiry-check-failed` — RdExpiryCheckFailed (check_ok == 0)
6. `rd-fuse-mount-down` — RdFuseMountDown (healthy == 0)
7. `jellyfin-transcoding-errors` — JellyfinTranscodingErrors (LogQL, Loki datasource)
8. `decypharr-rd-api-errors` — DecypharrRdApiErrors (LogQL, Loki datasource)
9. `media-stack-disk-usage` — MediaStackDiskUsage (filesystem > 85%)

Every rule must include:
- `annotations.summary` with template variables
- `annotations.runbook_url` pointing to `https://github.com/mohitsharma44/homeops/blob/main/docs/runbooks/media-stack-alerts.md#alertname`
- `labels.severity` (warning or critical per spec)

**LogQL-based alerts (rules 7-8):** These use the Loki datasource instead of Thanos. The `data` array structure differs from Prometheus alerts. Check the Grafana datasource provisioning in kube-prometheus-stack.yaml for the Loki datasource UID (likely `loki`). Example structure for a LogQL alert rule:

```yaml
                    - uid: jellyfin-transcoding-errors
                      title: JellyfinTranscodingErrors
                      condition: B
                      data:
                        - refId: A
                          relativeTimeRange:
                            from: 900
                            to: 0
                          datasourceUid: loki
                          model:
                            expr: 'count_over_time({container="jellyfin", instance="media-stack"} |~ "transcode.*error|ffmpeg.*error"[15m])'
                            queryType: range
                            refId: A
                        - refId: B
                          datasourceUid: __expr__
                          model:
                            type: threshold
                            expression: A
                            conditions:
                              - evaluator:
                                  type: gt
                                  params: [5]
                            refId: B
                      for: 5m
                      labels:
                        severity: warning
                      annotations:
                        summary: 'Jellyfin transcoding errors detected on media-stack'
                        runbook_url: 'https://github.com/mohitsharma44/homeops/blob/main/docs/runbooks/media-stack-alerts.md#jellyfinTranscodingerrors'
```

Note the differences from Prometheus alerts: `datasourceUid: loki`, `queryType: range` in the model, and the threshold is applied directly to the LogQL count result (no reduce step needed since `count_over_time` already returns a scalar). Verify the exact `datasourceUid` by checking the Grafana datasource provisioning config.

- [ ] **Step 3: Verify YAML validity**

```bash
python3 -c "import yaml; yaml.safe_load(open('kubernetes/apps/argocd-apps/apps/kube-prometheus-stack.yaml'))"
```

Expected: No errors

- [ ] **Step 4: Verify**

1. YAML valid: `python3 -c "import yaml; yaml.safe_load(open('kubernetes/apps/argocd-apps/apps/kube-prometheus-stack.yaml'))"` → no errors
2. Count rules: `grep -c 'uid: ' kubernetes/apps/argocd-apps/apps/kube-prometheus-stack.yaml` → should increase by 9 compared to before this task
3. Verify all 9 rule UIDs exist: `grep -E 'uid: (media-container-down|media-container-restart|rd-account-expir|rd-expiry-check|rd-fuse-mount|jellyfin-transcoding|decypharr-rd-api|media-stack-disk)' kubernetes/apps/argocd-apps/apps/kube-prometheus-stack.yaml` → 9 matches
4. Verify all rules have `runbook_url` annotation: `grep 'runbook_url' kubernetes/apps/argocd-apps/apps/kube-prometheus-stack.yaml | grep media-stack` → 9 matches
5. Verify LogQL rules use Loki datasource: `grep -B5 'jellyfin-transcoding-errors' kubernetes/apps/argocd-apps/apps/kube-prometheus-stack.yaml` → should reference loki datasource, not thanos
6. Verify folder name: `grep 'folder: Media Stack' kubernetes/apps/argocd-apps/apps/kube-prometheus-stack.yaml` → must exist

- [ ] **Step 5: Commit**

```bash
git add kubernetes/apps/argocd-apps/apps/kube-prometheus-stack.yaml
git commit -m "feat(monitoring): add Media Stack Grafana alert rules"
```

---

### Task 8: Alert Runbook

**Files:**
- Create: `docs/runbooks/media-stack-alerts.md`

- [ ] **Step 1: Create the runbook**

Create `docs/runbooks/media-stack-alerts.md` with a section for each of the 9 alerts. Each section uses this format:

```markdown
## AlertName
**Severity:** critical/warning | **For:** Xm

**Symptoms:** What the user observes when this alert fires

**Triage:**
1. SSH to media-stack: `ssh root@192.168.11.40`
2. Specific diagnostic commands
3. ...

**Resolution:** Steps to fix the issue

**False positive?** When this alert might fire incorrectly and how to confirm
```

Alerts to document:
1. MediaContainerDown — check `docker compose ps`, restart containers
2. MediaContainerRestartLoop — check `docker logs <container>`, check disk space, check OOM kills
3. RdAccountExpiringSoon — renew RD subscription, update API key if needed
4. RdAccountExpiryCritical — urgent renewal
5. RdExpiryCheckFailed — check script manually, check RD API status, check network
6. RdFuseMountDown — check Decypharr, `mountpoint /mnt/debrid`, restart Decypharr, `mount --make-rshared /`
7. JellyfinTranscodingErrors — check Jellyfin logs, check GPU passthrough, check supported codecs
8. DecypharrRdApiErrors — check Decypharr logs, check RD status page, check API key
9. MediaStackDiskUsage — check disk with `df -h`, prune Docker images, check log rotation

- [ ] **Step 2: Verify**

1. All 9 alerts documented: `grep -c '^## ' docs/runbooks/media-stack-alerts.md` → at least 9 (plus any header sections)
2. Each alert section has required subsections: `grep -c 'Triage:' docs/runbooks/media-stack-alerts.md` → 9
3. SSH command present: `grep 'ssh root@192.168.11.40' docs/runbooks/media-stack-alerts.md` → at least 7 (RD renewal alerts may not need SSH)
4. Section anchors match what's referenced in alert rule `runbook_url` annotations (case-sensitive check)

- [ ] **Step 3: Commit**

```bash
git add docs/runbooks/media-stack-alerts.md
git commit -m "docs: add media-stack alert runbook"
```

---

### Task 9: Grafana Dashboard

**Files:**
- Modify: `kubernetes/apps/argocd-apps/apps/kube-prometheus-stack.yaml`

- [ ] **Step 1: Check existing dashboard provisioning pattern**

Read how the existing `infra-node-health-overview` dashboard is provisioned in `kube-prometheus-stack.yaml`. Look for the dashboard JSON structure under `grafana.dashboardProviders` or `grafana.dashboards` or `grafana.dashboardsConfigMaps`.

- [ ] **Step 2: Create dashboard JSON**

Build the dashboard JSON with 6 panels per the spec:
1. Container Health (cAdvisor metrics: `container_cpu_usage_seconds_total`, `container_memory_usage_bytes`, `container_last_seen`)
2. Arr Queue Status (Scraparr metrics — exact metric names need discovery from Scraparr docs/metrics endpoint)
3. Jellyfin Streams (Jellyfin Prometheus plugin metrics — exact metric names need discovery)
4. Real-Debrid Health (`rd_account_days_remaining`, `rd_fuse_mount_healthy`, Loki log panel for Decypharr errors)
5. LXC Host Resources (`node_cpu_seconds_total`, `node_memory_MemAvailable_bytes`, `node_filesystem_avail_bytes`, `node_network_receive_bytes_total` — all with `instance="media-stack"`)
6. Logs Panel (Loki datasource, `{instance="media-stack"}`)

Dashboard UID: `media-stack-health`

**Note:** Scraparr and Jellyfin Prometheus plugin metric names must be verified after deployment. Build the dashboard with placeholder panels for those sections and refine after metrics are flowing. Start with host resources + container health + RD health panels (metrics are known) and iterate on arr/Jellyfin panels.

- [ ] **Step 3: Deploy dashboard via Grafana provisioning**

Add the dashboard JSON to `kube-prometheus-stack.yaml` following the existing pattern.

- [ ] **Step 4: Verify YAML validity**

```bash
python3 -c "import yaml; yaml.safe_load(open('kubernetes/apps/argocd-apps/apps/kube-prometheus-stack.yaml'))"
```

- [ ] **Step 5: Verify**

1. YAML valid: `python3 -c "import yaml; yaml.safe_load(open('kubernetes/apps/argocd-apps/apps/kube-prometheus-stack.yaml'))"` → no errors
2. Dashboard UID present: `grep 'media-stack-health' kubernetes/apps/argocd-apps/apps/kube-prometheus-stack.yaml` → must exist
3. Dashboard has all 6 panel sections (Container Health, Arr Queue, Jellyfin Streams, RD Health, LXC Resources, Logs)
4. All panels filter on `instance="media-stack"` to scope to this LXC only

- [ ] **Step 6: Commit**

```bash
git add kubernetes/apps/argocd-apps/apps/kube-prometheus-stack.yaml
git commit -m "feat(monitoring): add media-stack Grafana dashboard"
```

---

### Task 10: Deploy and Verify

This task is a deployment checklist, not code changes. Run after all previous tasks are committed.

- [ ] **Step 1: User adds secrets to SOPS vault**

Prompt user to add the 6 new secrets listed in Pre-Implementation section.

- [ ] **Step 2: Run Ansible playbook**

```bash
cd /Users/mohitsharma44/devel/myInfra/homelab2.0/kubernetes/homeops
ansible-playbook proxmox/media-stack.yml
```

Expected: Play 3 deploys new containers (cAdvisor, Scraparr, Jellystat, Jellystat-DB). Play 4 installs Alloy + cron jobs.

- [ ] **Step 3: Verify containers running**

```bash
ssh root@192.168.11.40 "docker compose -f /opt/media-stack/compose.yaml ps"
```

Expected: All containers including cadvisor, scraparr, jellystat, jellystat-db show "Up"

- [ ] **Step 4: Verify Alloy running**

```bash
ssh root@192.168.11.40 "systemctl status alloy"
```

Expected: active (running)

- [ ] **Step 5: Verify host metrics in Grafana**

Query in Grafana Explore (Thanos datasource):
```
node_cpu_seconds_total{instance="media-stack"}
```

Expected: CPU metrics from media-stack LXC

- [ ] **Step 6: Verify container metrics in Grafana**

```
container_cpu_usage_seconds_total{instance="media-stack"}
```

Expected: Per-container CPU metrics

- [ ] **Step 7: Verify container logs in Grafana**

LogQL query (Loki datasource):
```
{instance="media-stack"}
```

Expected: Logs from all media-stack containers

- [ ] **Step 8: Verify RD expiry metric**

```
rd_account_days_remaining
```

Expected: A positive number representing days until RD account expires

- [ ] **Step 9: Verify FUSE mount metric**

```
rd_fuse_mount_healthy
```

Expected: Value 1

- [ ] **Step 10: Verify Scraparr metrics**

```
{job="scraparr"}
```

Expected: Metrics from Radarr/Sonarr/Prowlarr/Bazarr

- [ ] **Step 11: Verify alerts in Grafana**

Navigate to Grafana → Alerting → Alert Rules → Media Stack folder.
Expected: 9 rules visible, all evaluating (some may be in "Normal" state)

- [ ] **Step 12: Push changes to trigger Flux/ArgoCD sync**

```bash
git push
```

Wait for Flux to reconcile and ArgoCD to sync the updated kube-prometheus-stack.

- [ ] **Step 13: Complete Jellystat setup wizard**

Browse to `http://192.168.11.40:3000`, complete the first-time wizard:
1. Create admin account
2. Connect to Jellyfin: `http://jellyfin:8096` + API key

- [ ] **Step 14: Pin container versions**

After verifying everything works, note the current image digests:
```bash
ssh root@192.168.11.40 "docker images --digests | grep -E 'cadvisor|scraparr|jellystat'"
```

Update the compose template to pin Scraparr and Jellystat to specific tags (cAdvisor is already pinned to v0.51.0).

- [ ] **Step 15: Commit version pins**

```bash
git add proxmox/templates/media-stack-compose.yaml.j2
git commit -m "chore: pin Scraparr and Jellystat container versions"
```

---

### Task 11: Update Documentation

**Files:**
- Modify: `docs/monitoring.md`
- Modify: `docs/media-stack-setup-guide.md`

- [ ] **Step 1: Add media-stack section to monitoring.md**

Add a section documenting the media-stack monitoring setup: Alloy systemd service, cAdvisor, Scraparr, Jellystat, RD health checks, alert rules, dashboard.

- [ ] **Step 2: Add monitoring section to media-stack-setup-guide.md**

Add a "Monitoring" section to the setup guide with:
- Jellystat URL (http://192.168.11.40:3000)
- Grafana dashboard link
- Alloy systemd commands
- Cron job locations

- [ ] **Step 3: Verify**

1. `grep -i 'alloy' docs/monitoring.md | grep -i media` → media-stack Alloy section exists
2. `grep 'Jellystat' docs/media-stack-setup-guide.md` → Jellystat mentioned in setup guide
3. `grep '3000' docs/media-stack-setup-guide.md` → Jellystat port documented
4. No broken markdown links or formatting issues

- [ ] **Step 4: Commit**

```bash
git add docs/monitoring.md docs/media-stack-setup-guide.md
git commit -m "docs: add media-stack monitoring to documentation"
```
