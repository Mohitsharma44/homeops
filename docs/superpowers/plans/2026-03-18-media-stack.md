# Media Stack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy a self-hosted media stack (Jellyfin + arr stack + Real-Debrid via Decypharr) on pve03 as a single Docker-in-LXC, fully managed by Ansible.

**Architecture:** Single privileged LXC (ID 400) on pve03 running Docker Compose with 10 containers. Decypharr mounts Real-Debrid via WebDAV/FUSE, creates symlinks consumed by Radarr/Sonarr/Jellyfin. NFS from r720xd provides optional local media storage. Ansible playbook `media-stack.yml` handles LXC creation, Docker setup, and compose deployment.

**Tech Stack:** Proxmox LXC, Docker Compose, Ansible (`community.general.proxmox`), SOPS + age, NFS, ZFS, VAAPI GPU passthrough

**Spec:** `docs/superpowers/specs/2026-03-18-media-stack-design.md`

---

## File Map

### New Files

| File | Responsibility |
|------|---------------|
| `proxmox/media-stack.yml` | Ansible playbook — 3 plays: r720xd NFS setup, LXC creation on pve03, Docker setup inside LXC |
| `proxmox/templates/media-stack-compose.yaml.j2` | Docker Compose template (source of truth) for all 10 services |
| `proxmox/templates/decypharr-config.json.j2` | Decypharr configuration (RD API key, mount paths, symlink categories) |
| `proxmox/templates/media-stack-env.j2` | Environment file template (SOPS-decrypted secrets consumed by containers via `env_file:`) |
| `proxmox/host_vars/media-stack.yml` | media-stack LXC-specific vars (PUID/PGID, NFS config, shared with pve03 LXC vars) |

### Modified Files

| File | Changes |
|------|---------|
| `proxmox/inventory/hosts.yml` | Add `media-stack` host + introduce host groups (`pve_nodes`, `lxc_containers`) to prevent `site.yml` from targeting the LXC |
| `proxmox/host_vars/r720xd.yml` | Add `pool0/media` NFS export + Sanoid dataset |
| `proxmox/host_vars/pve03.yml` | Add `media_stack_*` vars for LXC creation (hypervisor-side config) |
| `proxmox/group_vars/all/secrets.sops.yml` | Add `vault_rd_api_key`, `vault_opensub_username`, `vault_opensub_password`, `vault_pve03_api_password` |
| `proxmox/site.yml` | Change `hosts: all` to `hosts: pve_nodes` so it skips LXC containers |
| `proxmox/requirements.yml` | Add `community.general` and `ansible.posix` collections |

---

## Task 1: Restructure Ansible Inventory with Host Groups

**Why first:** The spec reviewer flagged that adding `media-stack` to a flat inventory causes `site.yml` (`hosts: all`) to try configuring the LXC as a Proxmox node. Fix this before adding any new hosts.

**Files:**
- Modify: `proxmox/inventory/hosts.yml`
- Modify: `proxmox/site.yml:2` (change `hosts: all` to `hosts: pve_nodes`)

- [ ] **Step 1: Update inventory to use host groups**

Edit `proxmox/inventory/hosts.yml`:
```yaml
---
all:
  children:
    pve_nodes:
      hosts:
        r720xd:
          ansible_host: 192.168.11.15
          ansible_user: root
          ansible_python_interpreter: /usr/bin/python3
        pve03:
          ansible_host: 192.168.11.12
          ansible_user: root
          ansible_python_interpreter: /usr/bin/python3
    lxc_containers:
      hosts:
        media-stack:
          ansible_host: 192.168.11.40
          ansible_user: root
          ansible_python_interpreter: /usr/bin/python3
```

- [ ] **Step 2: Update site.yml to target pve_nodes only**

Change line 3 of `proxmox/site.yml` from:
```yaml
  hosts: all
```
to:
```yaml
  hosts: pve_nodes
```

- [ ] **Step 3: Verify site.yml still works**

Run (dry-run):
```bash
cd proxmox && ansible-playbook site.yml --check --diff --limit r720xd
```
Expected: No errors. All tasks should show `ok` or `skipping` (no `changed` on a check run against an already-configured host).

- [ ] **Step 4: Commit**

```bash
git add proxmox/inventory/hosts.yml proxmox/site.yml
git commit -m "refactor(proxmox): add host groups to inventory

Split flat inventory into pve_nodes and lxc_containers groups.
Update site.yml to target pve_nodes only, preventing LXC containers
from being configured as Proxmox hypervisors."
```

---

## Task 2: Add r720xd NFS Export and Sanoid for pool0/media

**Files:**
- Modify: `proxmox/host_vars/r720xd.yml`

- [ ] **Step 1: Add NFS export and Sanoid dataset**

Add to `proxmox/host_vars/r720xd.yml`:

Under `nfs_exports`, add a second entry:
```yaml
  - path: /mnt/pool0/media
    network: "192.168.11.0/24"
    options: "rw,sync,no_subtree_check,no_root_squash"
```

Under `sanoid_datasets`, add:
```yaml
  - name: "pool0/media"
    template: data_retention
    recursive: no
```

- [ ] **Step 2: Create the ZFS dataset on r720xd (manual)**

This is a one-time operation. SSH to r720xd and run:
```bash
ssh root@192.168.11.15 "zfs list pool0/media 2>/dev/null || zfs create pool0/media && chown 1100:1100 /mnt/pool0/media"
```

- [ ] **Step 3: Apply NFS export via site.yml**

```bash
cd proxmox && ansible-playbook site.yml --limit r720xd --diff
```
Expected: NFS export entry added to `/etc/exports`, NFS server reloaded. Sanoid config updated with new dataset.

- [ ] **Step 4: Verify NFS export is active**

```bash
ssh root@192.168.11.15 "exportfs -v | grep media"
```
Expected: `/mnt/pool0/media  192.168.11.0/24(rw,sync,no_subtree_check,no_root_squash,...)`

- [ ] **Step 5: Commit**

```bash
git add proxmox/host_vars/r720xd.yml
git commit -m "feat(proxmox): add NFS export and Sanoid for pool0/media

Export pool0/media via NFS for media-stack LXC on pve03.
Add Sanoid snapshot coverage for the new dataset."
```

---

## Task 3: Add SOPS Secrets for Media Stack

**Files:**
- Modify: `proxmox/group_vars/all/secrets.sops.yml`

- [ ] **Step 1: Determine what secrets to add**

The user needs to provide values for:
- `vault_rd_api_key` — Real-Debrid API key (from https://real-debrid.com/apitoken)
- `vault_opensub_username` — OpenSubtitles username
- `vault_opensub_password` — OpenSubtitles password
- `vault_pve03_api_password` — root password for pve03 Proxmox API (needed by `community.general.proxmox` module to create LXC)

Tell the user:
> "I need you to add four new vault variables to `proxmox/group_vars/all/secrets.sops.yml`. Decrypt the file with `sops proxmox/group_vars/all/secrets.sops.yml`, add the following keys with your values, save, and it will auto-re-encrypt:
> ```yaml
> vault_rd_api_key: "YOUR_REALDEBRID_API_KEY"
> vault_opensub_username: "YOUR_OPENSUBTITLES_USERNAME"
> vault_opensub_password: "YOUR_OPENSUBTITLES_PASSWORD"
> vault_pve03_api_password: "YOUR_PVE03_ROOT_PASSWORD"
> ```"

- [ ] **Step 2: Verify secrets are accessible**

```bash
cd proxmox && ansible -m debug -a "var=vault_rd_api_key" pve03
```
Expected: Shows the decrypted value (confirming SOPS auto-decrypt works).

- [ ] **Step 3: Commit**

```bash
git add proxmox/group_vars/all/secrets.sops.yml
git commit -m "feat(proxmox): add media stack secrets

Add SOPS-encrypted Real-Debrid API key, OpenSubtitles credentials,
and pve03 API password for media-stack deployment."
```

---

## Task 4: Add Media Stack Variables

Two files: pve03 host_vars for hypervisor-side LXC creation config, and a new media-stack host_vars for guest-side config (PUID/PGID, NFS, etc.) that Play 2 needs access to.

**Files:**
- Modify: `proxmox/host_vars/pve03.yml`
- Create: `proxmox/host_vars/media-stack.yml`

- [ ] **Step 1: Add LXC creation variables to pve03**

Append to `proxmox/host_vars/pve03.yml`:

```yaml

# ── Media Stack LXC ───────────────────────────────────
media_stack_vmid: 400
media_stack_hostname: "media-stack"
media_stack_ip: "192.168.11.40"
media_stack_gateway: "192.168.11.1"
media_stack_nameserver: "192.168.11.1 9.9.9.9"
media_stack_cores: 4
media_stack_memory: 16384
media_stack_swap: 2048
media_stack_disk_size: 64
media_stack_storage: "local-zfs"
media_stack_ostemplate: "local:vztmpl/debian-13-standard_13.0-1_amd64.tar.zst"
media_stack_puid: 1100
media_stack_pgid: 1100
```

- [ ] **Step 2: Create media-stack host_vars**

Create `proxmox/host_vars/media-stack.yml`:

```yaml
---
# media-stack LXC — guest-side configuration
# IP: 192.168.11.40, LXC ID: 400 on pve03

# ── Media User ────────────────────────────────────────
media_stack_puid: 1100
media_stack_pgid: 1100

# ── NFS ───────────────────────────────────────────────
media_stack_nfs_server: "192.168.11.15"
media_stack_nfs_path: "/mnt/pool0/media"

# ── Media Stack IP (used in compose template) ─────────
media_stack_ip: "192.168.11.40"
```

- [ ] **Step 3: Commit**

```bash
git add proxmox/host_vars/pve03.yml proxmox/host_vars/media-stack.yml
git commit -m "feat(proxmox): add media-stack LXC vars

pve03: LXC creation config (ID 400, 4c/16GB/64GB, Debian 13).
media-stack: guest-side config (PUID/PGID 1100, NFS mount)."
```

---

## Task 5: Add Ansible Collections to Requirements

**Files:**
- Modify: `proxmox/requirements.yml`

- [ ] **Step 1: Add community.general and ansible.posix collections**

Add to the `collections` list in `proxmox/requirements.yml`:
```yaml
  - name: community.general
    version: "10.3.0"
  - name: ansible.posix
    version: "1.6.2"
```

- [ ] **Step 2: Install the collections**

```bash
ansible-galaxy collection install -r proxmox/requirements.yml
```
Expected: Both collections installed.

- [ ] **Step 3: Commit**

```bash
git add proxmox/requirements.yml
git commit -m "feat(proxmox): add community.general and ansible.posix

community.general: proxmox module for LXC management.
ansible.posix: mount module for NFS fstab entries."
```

---

## Task 6: Create Docker Compose Template

**Files:**
- Create: `proxmox/templates/media-stack-compose.yaml.j2`

- [ ] **Step 1: Write the Docker Compose Jinja2 template**

Create `proxmox/templates/media-stack-compose.yaml.j2`:

```yaml
---
# Media Stack — rendered by Ansible, do not edit on host directly
# Re-deploy: ansible-playbook proxmox/media-stack.yml

networks:
  media-net:
    driver: bridge

services:
  # ── Decypharr (Real-Debrid bridge) ────────────────────
  decypharr:
    image: cy01/blackhole:latest
    container_name: decypharr
    restart: unless-stopped
    cap_add:
      - SYS_ADMIN
    devices:
      - /dev/fuse
    security_opt:
      - apparmor:unconfined
    environment:
      - PUID={{ media_stack_puid }}
      - PGID={{ media_stack_pgid }}
    volumes:
      - /opt/media-stack/config/decypharr:/app/config
      - /mnt/debrid:/mnt/debrid:rshared
    ports:
      - "8282:8282"
    networks:
      - media-net

  # ── Jellyfin (media server) ───────────────────────────
  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    restart: unless-stopped
    environment:
      - PUID={{ media_stack_puid }}
      - PGID={{ media_stack_pgid }}
      - JELLYFIN_PublishedServerUrl=http://{{ media_stack_ip }}
    devices:
      - /dev/dri:/dev/dri
    tmpfs:
      - /config/transcodes:size=8G
    volumes:
      - /opt/media-stack/config/jellyfin:/config
      - /mnt/debrid/decypharr_symlinks:/media/debrid:ro
      - /mnt/local-media:/media/local
    ports:
      - "8096:8096"
    networks:
      - media-net
    depends_on:
      - decypharr

  # ── Prowlarr (indexer aggregator) ─────────────────────
  prowlarr:
    image: linuxserver/prowlarr:latest
    container_name: prowlarr
    restart: unless-stopped
    environment:
      - PUID={{ media_stack_puid }}
      - PGID={{ media_stack_pgid }}
      - TZ=America/New_York
    volumes:
      - /opt/media-stack/config/prowlarr:/config
    ports:
      - "9696:9696"
    networks:
      - media-net

  # ── Radarr (movies) ──────────────────────────────────
  radarr:
    image: linuxserver/radarr:latest
    container_name: radarr
    restart: unless-stopped
    environment:
      - PUID={{ media_stack_puid }}
      - PGID={{ media_stack_pgid }}
      - TZ=America/New_York
    volumes:
      - /opt/media-stack/config/radarr:/config
      - /mnt/debrid:/mnt/debrid:rshared
      - /mnt/local-media:/mnt/local-media
    ports:
      - "7878:7878"
    networks:
      - media-net
    depends_on:
      - decypharr
      - prowlarr

  # ── Sonarr (TV) ──────────────────────────────────────
  sonarr:
    image: linuxserver/sonarr:latest
    container_name: sonarr
    restart: unless-stopped
    environment:
      - PUID={{ media_stack_puid }}
      - PGID={{ media_stack_pgid }}
      - TZ=America/New_York
    volumes:
      - /opt/media-stack/config/sonarr:/config
      - /mnt/debrid:/mnt/debrid:rshared
      - /mnt/local-media:/mnt/local-media
    ports:
      - "8989:8989"
    networks:
      - media-net
    depends_on:
      - decypharr
      - prowlarr

  # ── Bazarr (subtitles) ───────────────────────────────
  bazarr:
    image: linuxserver/bazarr:latest
    container_name: bazarr
    restart: unless-stopped
    env_file:
      - .env
    environment:
      - PUID={{ media_stack_puid }}
      - PGID={{ media_stack_pgid }}
      - TZ=America/New_York
    volumes:
      - /opt/media-stack/config/bazarr:/config
      - /mnt/debrid/decypharr_symlinks:/media/debrid:ro
      - /mnt/local-media:/media/local
    ports:
      - "6767:6767"
    networks:
      - media-net
    depends_on:
      - radarr
      - sonarr

  # ── Jellyseerr (request UI) ──────────────────────────
  jellyseerr:
    image: fallenbagel/jellyseerr:latest
    container_name: jellyseerr
    restart: unless-stopped
    environment:
      - PUID={{ media_stack_puid }}
      - PGID={{ media_stack_pgid }}
      - TZ=America/New_York
    volumes:
      - /opt/media-stack/config/jellyseerr:/app/config
    ports:
      - "5055:5055"
    networks:
      - media-net
    depends_on:
      - jellyfin
      - radarr
      - sonarr

  # ── SuggestArr (auto-request trending) ────────────────
  suggestarr:
    image: ciuse99/suggestarr:latest
    container_name: suggestarr
    restart: unless-stopped
    env_file:
      - .env
    volumes:
      - /opt/media-stack/config/suggestarr:/app/config/config_files
    ports:
      - "5000:5000"
    networks:
      - media-net
    depends_on:
      - jellyfin
      - jellyseerr

  # ── Tunarr (live TV channels) ─────────────────────────
  tunarr:
    image: jasongdove/tunarr:latest
    container_name: tunarr
    restart: unless-stopped
    env_file:
      - .env
    volumes:
      - /opt/media-stack/config/tunarr:/config
    ports:
      - "8000:8000"
    networks:
      - media-net
    depends_on:
      - jellyfin

  # ── Profilarr (quality profile management) ────────────
  profilarr:
    image: ghcr.io/dictionarry-hub/profilarr:latest
    container_name: profilarr
    restart: unless-stopped
    environment:
      - PUID={{ media_stack_puid }}
      - PGID={{ media_stack_pgid }}
      - TZ=America/New_York
    volumes:
      - /opt/media-stack/config/profilarr:/app/data
    ports:
      - "6868:6868"
    networks:
      - media-net
    depends_on:
      - radarr
      - sonarr
```

Note: `env_file: [.env]` is added to Bazarr (needs `OPENSUB_*`), SuggestArr (needs `JELLYFIN_API_KEY`), and Tunarr (needs `JELLYFIN_API_KEY`). Decypharr gets its secrets via `config.json` instead of env vars. Other services (Prowlarr, Radarr, Sonarr, Jellyfin, Jellyseerr, Profilarr) don't need secrets from the env file — they use internal API keys configured via their web UIs.

- [ ] **Step 2: Commit**

```bash
git add proxmox/templates/media-stack-compose.yaml.j2
git commit -m "feat(proxmox): add Docker Compose template for media stack

10 services: Decypharr, Jellyfin, Prowlarr, Radarr, Sonarr,
Bazarr, Jellyseerr, SuggestArr, Tunarr, Profilarr.
All on shared media-net network with PUID/PGID templating.
Secrets wired via env_file for services that need them."
```

---

## Task 7: Create Decypharr Config and Env Templates

**Files:**
- Create: `proxmox/templates/decypharr-config.json.j2`
- Create: `proxmox/templates/media-stack-env.j2`

- [ ] **Step 1: Write the Decypharr config template**

Create `proxmox/templates/decypharr-config.json.j2`:

```json
{
  "debrid": {
    "provider": "realdebrid",
    "api_key": "{{ vault_rd_api_key }}"
  },
  "qbit": {
    "port": 8282
  },
  "webdav": {
    "enabled": true,
    "port": 8282
  },
  "mount": {
    "enabled": true,
    "path": "/mnt/debrid",
    "rclone_params": "--vfs-read-ahead 256M"
  },
  "symlinks": {
    "enabled": true,
    "path": "/mnt/debrid/decypharr_symlinks",
    "categories": {
      "movies": "movies",
      "tv": "tv"
    }
  },
  "repair": {
    "enabled": true,
    "interval": 60
  }
}
```

Note: The exact Decypharr config schema may differ. Verify against the Decypharr docs/repo at deploy time and adjust. The key values (api_key, mount path, symlink paths, vfs-read-ahead) are correct per the spec. The `rclone_params` with `--vfs-read-ahead 256M` is critical for preventing Real-Debrid bans by buffering reads.

- [ ] **Step 2: Write the environment file template**

Create `proxmox/templates/media-stack-env.j2`:

```
# Media Stack Environment — rendered by Ansible from SOPS-encrypted vars
# Do not edit directly on host

RD_API_KEY={{ vault_rd_api_key }}
OPENSUB_USERNAME={{ vault_opensub_username }}
OPENSUB_PASSWORD={{ vault_opensub_password }}
{% if vault_jellyfin_api_key is defined %}
JELLYFIN_API_KEY={{ vault_jellyfin_api_key }}
{% endif %}
```

- [ ] **Step 3: Commit**

```bash
git add proxmox/templates/decypharr-config.json.j2 proxmox/templates/media-stack-env.j2
git commit -m "feat(proxmox): add Decypharr config and env templates

Decypharr: RD provider, WebDAV+mount, symlink categories, vfs-read-ahead 256M.
Env file: SOPS-decrypted secrets for RD, OpenSubtitles, Jellyfin API key."
```

---

## Task 8: Create the media-stack.yml Ansible Playbook

This is the main playbook. It has 3 plays in correct dependency order:
1. r720xd NFS setup (must exist before LXC mounts it)
2. LXC creation on pve03
3. Docker + stack inside LXC

**Files:**
- Create: `proxmox/media-stack.yml`

- [ ] **Step 1: Write the full playbook**

Create `proxmox/media-stack.yml`:

```yaml
---
# Media Stack — NFS setup + LXC creation + Docker deployment
# Usage: ansible-playbook proxmox/media-stack.yml
# Spec: docs/superpowers/specs/2026-03-18-media-stack-design.md
#
# Prerequisites:
#   - site.yml has been run on r720xd (NFS server config)
#   - SOPS secrets populated (vault_rd_api_key, vault_pve03_api_password, etc.)

# ═══════════════════════════════════════════════════════
# Play 1: Ensure r720xd NFS export for media
# Must run BEFORE Play 3 (LXC mounts NFS from r720xd)
# ═══════════════════════════════════════════════════════
- name: Ensure r720xd NFS export for media
  hosts: r720xd
  become: true
  gather_facts: false

  tasks:
    - name: Ensure pool0/media dataset exists
      ansible.builtin.command:
        cmd: zfs create pool0/media
      register: zfs_create
      changed_when: zfs_create.rc == 0
      failed_when: zfs_create.rc != 0 and 'dataset already exists' not in zfs_create.stderr

    - name: Set pool0/media ownership
      ansible.builtin.file:
        path: /mnt/pool0/media
        owner: 1100
        group: 1100
        mode: "0755"
        state: directory

# ═══════════════════════════════════════════════════════
# Play 2: Create and configure LXC on pve03
# ═══════════════════════════════════════════════════════
- name: Create media-stack LXC on pve03
  hosts: pve03
  become: true
  gather_facts: true

  tasks:
    - name: Check if Debian 13 LXC template exists
      ansible.builtin.stat:
        path: "/var/lib/vz/template/cache/{{ media_stack_ostemplate | regex_replace('^local:vztmpl/', '') }}"
      register: lxc_template

    - name: Download Debian 13 LXC template
      ansible.builtin.command:
        cmd: "pveam download local {{ media_stack_ostemplate | regex_replace('^local:vztmpl/', '') }}"
      when: not lxc_template.stat.exists

    - name: Check if SSH key pair exists
      ansible.builtin.stat:
        path: /root/.ssh/id_ed25519.pub
      register: ssh_key_stat

    - name: Generate SSH key pair if not present
      ansible.builtin.command:
        cmd: ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N ""
        creates: /root/.ssh/id_ed25519.pub
      when: not ssh_key_stat.stat.exists

    - name: Read pve03 root SSH public key
      ansible.builtin.slurp:
        src: /root/.ssh/id_ed25519.pub
      register: pve03_root_pubkey

    - name: Create media-stack LXC
      community.general.proxmox:
        vmid: "{{ media_stack_vmid }}"
        hostname: "{{ media_stack_hostname }}"
        node: "{{ ansible_hostname }}"
        api_user: root@pam
        api_password: "{{ vault_pve03_api_password }}"
        api_host: "{{ ansible_host }}"
        ostemplate: "{{ media_stack_ostemplate }}"
        storage: "{{ media_stack_storage }}"
        disk: "{{ media_stack_disk_size }}"
        cores: "{{ media_stack_cores }}"
        memory: "{{ media_stack_memory }}"
        swap: "{{ media_stack_swap }}"
        unprivileged: false
        features:
          - "nesting=1,fuse=1"
        netif:
          net0: "name=eth0,gw={{ media_stack_gateway }},ip={{ media_stack_ip }}/24,bridge=vmbr0"
        nameserver: "{{ media_stack_nameserver }}"
        pubkey: "{{ pve03_root_pubkey.content | b64decode | trim }}"
        onboot: true
        state: present
      register: lxc_created

    - name: Configure GPU passthrough in LXC config
      ansible.builtin.blockinfile:
        path: "/etc/pve/lxc/{{ media_stack_vmid }}.conf"
        marker: "# {mark} ANSIBLE MANAGED — GPU + FUSE passthrough"
        block: |
          lxc.cgroup2.devices.allow: c 226:* rwm
          lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
          lxc.cgroup2.devices.allow: c 10:229 rwm
          lxc.mount.entry: /dev/fuse dev/fuse none bind,optional,create=file

    - name: Start media-stack LXC
      community.general.proxmox:
        vmid: "{{ media_stack_vmid }}"
        node: "{{ ansible_hostname }}"
        api_user: root@pam
        api_password: "{{ vault_pve03_api_password }}"
        api_host: "{{ ansible_host }}"
        state: started

    - name: Wait for SSH to become available on media-stack LXC
      ansible.builtin.wait_for:
        host: "{{ media_stack_ip }}"
        port: 22
        delay: 5
        timeout: 120

    - name: Add media-stack to known_hosts
      ansible.builtin.known_hosts:
        name: "{{ media_stack_ip }}"
        key: "{{ lookup('pipe', 'ssh-keyscan -t ed25519 ' + media_stack_ip + ' 2>/dev/null') }}"
        state: present

# ═══════════════════════════════════════════════════════
# Play 3: Configure Docker + deploy stack inside LXC
# ═══════════════════════════════════════════════════════
- name: Configure media-stack LXC
  hosts: media-stack
  become: true
  gather_facts: true

  tasks:
    # ── System setup ──────────────────────────────────
    - name: Update apt cache
      ansible.builtin.apt:
        update_cache: yes
        cache_valid_time: 3600

    - name: Install prerequisites
      ansible.builtin.apt:
        name:
          - ca-certificates
          - curl
          - gnupg
          - nfs-common
          - fuse3
          - libfuse2
        state: present

    - name: Create media group
      ansible.builtin.group:
        name: media
        gid: "{{ media_stack_pgid }}"
        state: present

    - name: Create media user
      ansible.builtin.user:
        name: media
        uid: "{{ media_stack_puid }}"
        group: media
        shell: /usr/sbin/nologin
        create_home: false
        state: present

    # ── Docker CE installation ────────────────────────
    - name: Ensure keyrings directory exists
      ansible.builtin.file:
        path: /etc/apt/keyrings
        state: directory
        mode: "0755"

    - name: Download Docker GPG key
      ansible.builtin.get_url:
        url: https://download.docker.com/linux/debian/gpg
        dest: /tmp/docker-gpg.key
        mode: "0644"

    - name: Dearmor and install Docker GPG key
      ansible.builtin.command:
        cmd: gpg --batch --yes --dearmor --output /etc/apt/keyrings/docker.gpg /tmp/docker-gpg.key
        creates: /etc/apt/keyrings/docker.gpg

    - name: Set Docker keyring permissions
      ansible.builtin.file:
        path: /etc/apt/keyrings/docker.gpg
        mode: "0644"

    - name: Add Docker apt repository
      ansible.builtin.apt_repository:
        repo: "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian {{ ansible_distribution_release }} stable"
        filename: docker
        state: present
        update_cache: yes

    - name: Install Docker CE
      ansible.builtin.apt:
        name:
          - docker-ce
          - docker-ce-cli
          - containerd.io
          - docker-compose-plugin
        state: present

    - name: Enable and start Docker
      ansible.builtin.systemd:
        name: docker
        state: started
        enabled: yes

    # ── NFS mount ─────────────────────────────────────
    - name: Create local media mount point
      ansible.builtin.file:
        path: /mnt/local-media
        state: directory
        owner: "{{ media_stack_puid }}"
        group: "{{ media_stack_pgid }}"
        mode: "0755"

    - name: Configure NFS mount in fstab
      ansible.posix.mount:
        src: "{{ media_stack_nfs_server }}:{{ media_stack_nfs_path }}"
        path: /mnt/local-media
        fstype: nfs
        opts: rw,soft,intr
        state: mounted

    # ── Directory structure ───────────────────────────
    - name: Create media stack directories
      ansible.builtin.file:
        path: "/opt/media-stack/config/{{ item }}"
        state: directory
        owner: "{{ media_stack_puid }}"
        group: "{{ media_stack_pgid }}"
        mode: "0755"
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

    - name: Create debrid mount point
      ansible.builtin.file:
        path: /mnt/debrid
        state: directory
        owner: "{{ media_stack_puid }}"
        group: "{{ media_stack_pgid }}"
        mode: "0755"

    - name: Create local media subdirectories
      ansible.builtin.file:
        path: "/mnt/local-media/{{ item }}"
        state: directory
        owner: "{{ media_stack_puid }}"
        group: "{{ media_stack_pgid }}"
        mode: "0755"
      loop:
        - movies
        - tv

    # ── Deploy configs ────────────────────────────────
    - name: Deploy Decypharr config
      ansible.builtin.template:
        src: decypharr-config.json.j2
        dest: /opt/media-stack/config/decypharr/config.json
        owner: "{{ media_stack_puid }}"
        group: "{{ media_stack_pgid }}"
        mode: "0600"
      register: decypharr_config_changed

    - name: Deploy environment file
      ansible.builtin.template:
        src: media-stack-env.j2
        dest: /opt/media-stack/.env
        owner: root
        group: root
        mode: "0600"
      register: env_changed

    - name: Deploy Docker Compose file
      ansible.builtin.template:
        src: media-stack-compose.yaml.j2
        dest: /opt/media-stack/compose.yaml
        owner: root
        group: root
        mode: "0644"
      register: compose_changed

    # ── Start/update the stack ────────────────────────
    - name: Deploy media stack
      ansible.builtin.command:
        cmd: docker compose up -d
        chdir: /opt/media-stack
      register: compose_up
      changed_when: "'Started' in compose_up.stderr or 'Created' in compose_up.stderr or 'Recreated' in compose_up.stderr"
      when: compose_changed.changed or env_changed.changed or decypharr_config_changed.changed

    - name: Ensure media stack is running
      ansible.builtin.command:
        cmd: docker compose up -d
        chdir: /opt/media-stack
      changed_when: false
      when: not (compose_changed.changed or env_changed.changed or decypharr_config_changed.changed)
```

- [ ] **Step 2: Verify playbook syntax**

```bash
cd proxmox && ansible-playbook media-stack.yml --syntax-check
```
Expected: `playbook: media-stack.yml` (no errors)

- [ ] **Step 3: Commit**

```bash
git add proxmox/media-stack.yml
git commit -m "feat(proxmox): add media-stack Ansible playbook

Three plays in dependency order:
1. Ensure r720xd NFS export for pool0/media
2. Create LXC 400 on pve03 (privileged, GPU+FUSE passthrough)
3. Install Docker, configure NFS, deploy compose stack"
```

---

## Task 9: Dry-Run and Deploy

This task involves actually running the playbook. It requires the user to have provided SOPS secrets (Task 3) and to have network access to pve03 and r720xd.

**Files:** None (execution only)

- [ ] **Step 1: Ensure site.yml has been run on r720xd**

The NFS export config in `/etc/exports` is managed by `site.yml` via the `nfs_exports` variable. Run it first:
```bash
cd proxmox && ansible-playbook site.yml --limit r720xd --diff
```
Expected: NFS export entry for `pool0/media` added to `/etc/exports`, `exportfs -ra` called.

- [ ] **Step 2: Run the full media-stack playbook**

```bash
cd proxmox && ansible-playbook media-stack.yml -v
```

This runs all 3 plays in order:
1. r720xd: ZFS dataset created, ownership set
2. pve03: LXC 400 created, GPU+FUSE configured, started
3. media-stack: Docker installed, NFS mounted, compose deployed

- [ ] **Step 3: Verify LXC is running**

```bash
ssh root@192.168.11.12 "pct status 400"
```
Expected: `status: running`

```bash
ssh root@192.168.11.40 "cat /etc/hostname"
```
Expected: `media-stack`

- [ ] **Step 4: Verify all containers are running**

```bash
ssh root@192.168.11.40 "docker compose -f /opt/media-stack/compose.yaml ps"
```
Expected: All 10 containers showing `Up` (SuggestArr and Tunarr may show restarts until Jellyfin is configured — expected per bootstrap sequence).

- [ ] **Step 5: Verify GPU passthrough**

```bash
ssh root@192.168.11.40 "ls -la /dev/dri/"
```
Expected: `card0` and `renderD128` present.

- [ ] **Step 6: Verify NFS mount**

```bash
ssh root@192.168.11.40 "df -h /mnt/local-media && touch /mnt/local-media/.test && rm /mnt/local-media/.test"
```
Expected: NFS mount shown, test file created and removed successfully.

---

## Task 10: Bootstrap Jellyfin and Complete Setup

This is a manual/interactive task — the user configures Jellyfin via its web UI.

**Files:** None (UI configuration only)

- [ ] **Step 1: Access Jellyfin setup wizard**

Open browser to `http://192.168.11.40:8096`. Complete the setup wizard:
1. Set language
2. Create admin user and password
3. Skip media library setup for now (we'll configure paths after)
4. Complete wizard

- [ ] **Step 2: CRITICAL — Disable Real-Debrid ban-triggering features**

**WARNING: Failure to do this WILL result in a permanent Real-Debrid account ban with no refund.**

In Jellyfin Dashboard > Scheduled Tasks, disable these by unchecking or setting to "Never":
- **Chapter image extraction** — set to NEVER
- **Detect intro/credits** — set to NEVER
- **Generate trickplay images** — set to NEVER

These features download entire files to generate thumbnails. On a 50GB file, that's 50GB of bandwidth just for a thumbnail. Real-Debrid sees this as abuse (thousands of rapid API requests) and will permanently ban your account.

In Dashboard > Playback > Transcoding:
- Enable VAAPI hardware acceleration
- Select `/dev/dri/renderD128` as the device
- Enable hardware decoding for all supported codecs (H.264, HEVC, VP9, AV1)
- Enable tone mapping

- [ ] **Step 3: Add media libraries**

In Dashboard > Libraries, add:
1. **Movies (Debrid)**: Content type: Movies, Path: `/media/debrid/movies`
2. **TV Shows (Debrid)**: Content type: Shows, Path: `/media/debrid/tv`
3. **Movies (Local)**: Content type: Movies, Path: `/media/local/movies`
4. **TV Shows (Local)**: Content type: Shows, Path: `/media/local/tv`

**For each library**, in the library settings:
- Chapter images: **DISABLED**
- Trickplay images: **DISABLED**
- Extract chapter images during library scan: **DISABLED**

- [ ] **Step 4: Generate Jellyfin API key**

Dashboard > API Keys > Create. Copy the key.

- [ ] **Step 5: Add JELLYFIN_API_KEY to SOPS secrets**

Tell user:
> "Add `vault_jellyfin_api_key: "YOUR_KEY"` to `proxmox/group_vars/all/secrets.sops.yml` using `sops proxmox/group_vars/all/secrets.sops.yml`"

- [ ] **Step 6: Re-deploy env file and restart dependents**

```bash
cd proxmox && ansible-playbook media-stack.yml --limit media-stack -v
```

Then verify SuggestArr and Tunarr are healthy:
```bash
ssh root@192.168.11.40 "docker compose -f /opt/media-stack/compose.yaml ps suggestarr tunarr"
```
Expected: Both showing `Up` without restart loops.

- [ ] **Step 7: Commit updated secrets**

```bash
git add proxmox/group_vars/all/secrets.sops.yml
git commit -m "feat(proxmox): add Jellyfin API key to media stack secrets"
```

---

## Task 11: Configure Arr Stack Services

Interactive configuration via web UIs. This task walks through connecting all the services together.

**Files:** None (UI configuration only)

- [ ] **Step 1: Configure Prowlarr indexers**

Access `http://192.168.11.40:9696`:
1. Set authentication (Forms, username/password)
2. Add Torrentio custom indexer:
   - Download `torrentio.yml` from https://github.com/dreulavelle/Prowlarr-Indexers
   - Copy to: `ssh root@192.168.11.40 "mkdir -p /opt/media-stack/config/prowlarr/Definitions/Custom/"`
   - `scp torrentio.yml root@192.168.11.40:/opt/media-stack/config/prowlarr/Definitions/Custom/`
   - Restart Prowlarr: `ssh root@192.168.11.40 "docker compose -f /opt/media-stack/compose.yaml restart prowlarr"`
   - Configure Torrentio indexer with RD API key
3. Add built-in indexers: 1337x, YTS, EZTV, TorrentGalaxy
4. Add Radarr and Sonarr as apps (Settings > Apps):
   - Radarr: `http://radarr:7878`, API key from Radarr
   - Sonarr: `http://sonarr:8989`, API key from Sonarr
5. Sync indexers to apps

- [ ] **Step 2: Configure Radarr**

Access `http://192.168.11.40:7878`:
1. Set authentication
2. Settings > Media Management:
   - Add root folder: `/mnt/debrid/decypharr_symlinks/movies` (primary)
   - Add root folder: `/mnt/local-media/movies` (for local downloads)
3. Settings > Download Clients:
   - Add qBittorrent client pointing to `http://decypharr:8282`
   - No username/password needed (Decypharr doesn't require auth)
4. Settings > Profiles: will be synced by Profilarr later

- [ ] **Step 3: Configure Sonarr**

Access `http://192.168.11.40:8989`:
1. Set authentication
2. Settings > Media Management:
   - Add root folder: `/mnt/debrid/decypharr_symlinks/tv` (primary)
   - Add root folder: `/mnt/local-media/tv` (for local downloads)
3. Settings > Download Clients:
   - Add qBittorrent client pointing to `http://decypharr:8282`
4. Settings > Profiles: will be synced by Profilarr later

- [ ] **Step 4: Configure Profilarr**

Access `http://192.168.11.40:6868`:
1. Connect to Dictionarry database
2. Add Radarr instance: `http://radarr:7878` + API key
3. Add Sonarr instance: `http://sonarr:8989` + API key
4. Select quality profiles: 4K preferred, 1080p fallback
5. Sync profiles to both instances

- [ ] **Step 5: Configure Bazarr**

Access `http://192.168.11.40:6767`:
1. Settings > Languages: Add English, Hindi
2. Settings > Providers: Add OpenSubtitles (with credentials — available as env vars `OPENSUB_USERNAME`/`OPENSUB_PASSWORD`, or enter manually)
3. Settings > Sonarr: Connect to `http://sonarr:8989` + API key
4. Settings > Radarr: Connect to `http://radarr:7878` + API key

- [ ] **Step 6: Configure Jellyseerr**

Access `http://192.168.11.40:5055`:
1. Connect to Jellyfin: `http://jellyfin:8096`
2. Sign in with Jellyfin admin account
3. Add Radarr: `http://radarr:7878` + API key, select quality profile, root folder `/mnt/debrid/decypharr_symlinks/movies`
4. Add Sonarr: `http://sonarr:8989` + API key, select quality profile, root folder `/mnt/debrid/decypharr_symlinks/tv`

- [ ] **Step 7: Configure SuggestArr**

Access `http://192.168.11.40:5000`:
1. Select Jellyfin as media server
2. Enter Jellyfin URL: `http://jellyfin:8096`
3. Enter Jellyfin API key (available as `JELLYFIN_API_KEY` env var, or enter manually)
4. Connect to Jellyseerr: `http://jellyseerr:5055`
5. Configure cron schedule for auto-suggestions

- [ ] **Step 8: Configure Tunarr**

Access `http://192.168.11.40:8000`:
1. Add Jellyfin connection: `http://jellyfin:8096` + API key
2. Create sample channel (e.g., "Movies" channel from library)

---

## Task 12: End-to-End Verification

- [ ] **Step 1: Test the full request-to-playback flow**

1. Open Jellyseerr (`http://192.168.11.40:5055`)
2. Search for a popular movie
3. Click "Request"
4. Watch Radarr pick it up (check `http://192.168.11.40:7878`)
5. Watch Decypharr process it (check `http://192.168.11.40:8282`)
6. Verify symlink appears: `ssh root@192.168.11.40 "ls /mnt/debrid/decypharr_symlinks/movies/"`
7. Verify Jellyfin picks it up (check `http://192.168.11.40:8096`)
8. Play the movie in Jellyfin

- [ ] **Step 2: Test GPU transcoding**

1. Play a 4K HEVC file in Jellyfin web browser
2. Force transcoding by setting quality to 1080p in playback settings
3. Check Jellyfin Dashboard > Active Streams — should show "(HW)" next to transcoding method

- [ ] **Step 3: Test subtitle download**

1. After a movie is imported, check Bazarr (`http://192.168.11.40:6767`)
2. Verify English subtitles were auto-downloaded
3. Play the movie in Jellyfin and verify subtitles are available

- [ ] **Step 4: Verify idempotency**

Re-run the full playbook:
```bash
cd proxmox && ansible-playbook media-stack.yml -v
```
Expected: All tasks show `ok`, zero `changed`. This confirms the playbook is idempotent.

- [ ] **Step 5: Commit any remaining changes**

```bash
git add proxmox/host_vars/ proxmox/group_vars/ proxmox/templates/ proxmox/media-stack.yml proxmox/inventory/ proxmox/requirements.yml
git commit -m "feat(proxmox): media stack deployment complete

All services running on LXC 400 (192.168.11.40):
Jellyfin, Decypharr, Radarr, Sonarr, Prowlarr, Bazarr,
Jellyseerr, SuggestArr, Tunarr, Profilarr.
GPU transcoding verified, NFS mount active, end-to-end tested."
```
