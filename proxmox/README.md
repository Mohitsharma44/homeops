# Proxmox VE Ansible Playbook

Automated configuration for Proxmox VE nodes (currently R720XD standalone) using Ansible and the [lae.proxmox](https://github.com/lae/ansible-role-proxmox) role.

## What Gets Configured

- **Base Proxmox VE setup** via `lae.proxmox` role:
  - APT repositories (no-subscription)
  - ZFS configuration and optimization
  - Storage backends (ZFS pools)
  - Users, groups, and ACLs
  - Datacenter settings

- **Infrastructure components:**
  - NFS exports (for NVR data sharing)
  - Sanoid (ZFS snapshot automation)
  - Alloy (Grafana observability agent)
  - smartctl-exporter (SMART disk health metrics)

## Prerequisites

1. Fresh Proxmox VE installation (8.0+)
2. ZFS pools already imported (e.g., `pool0`, `ssdpool0`)
3. Ansible 2.10+ installed on control machine
4. SSH access as `root` to the Proxmox host
5. Python 3 available on the Proxmox host

## Quick Start

### 1. Install Role Dependencies

```bash
ansible-galaxy install -r requirements.yml
```

### 2. Secrets (SOPS + age)

Secrets are managed via SOPS + age — the same mechanism used for K8s and Docker secrets in this repo. The `community.sops` Ansible collection auto-decrypts `*.sops.yml` files in `group_vars/`.

Secrets file: `group_vars/all/secrets.sops.yml`

```bash
# View secrets
sops -d group_vars/all/secrets.sops.yml

# Edit secrets
sops group_vars/all/secrets.sops.yml
```

Non-secret config (URLs, instance names, retention policies) lives in `group_vars/all/vars.yml`.

### 3. Run the Playbook

```bash
ansible-playbook site.yml
```

## Inventory

Edit `inventory/hosts.yml` to add/modify Proxmox nodes:

```yaml
all:
  hosts:
    r720xd:
      ansible_host: 192.168.11.15
      ansible_user: root
      ansible_python_interpreter: /usr/bin/python3
```

## Variables

### Non-Secret (group_vars/all/vars.yml)

- `pve_group` - Proxmox group name (required by lae.proxmox)
- `pve_cluster_enabled` - Enable clustering (false for standalone)
- `pve_repository` - APT repository configuration
- `pve_zfs_enabled` - Enable ZFS support
- `pve_zfs_options` - ZFS tuning (ARC cache size)
- `pve_storages` - Storage backend definitions
- `pve_users`, `pve_groups`, `pve_acls` - User and permissions
- `nfs_exports` - NFS export paths and options
- `sanoid_datasets` - ZFS datasets to snapshot
- `smartctl_exporter_*` - SMART exporter configuration
- `alloy_instance_name` - Node name for metrics labels

### Secrets (group_vars/all/secrets.sops.yml — SOPS encrypted)

- `vault_alloy_basic_auth_username` - Basic auth username for Prometheus/Loki
- `vault_alloy_basic_auth_password` - Basic auth password

## Customization

### Adding Storage Backends

Edit `group_vars/all/vars.yml`:

```yaml
pve_storages:
  - name: pool0-store
    type: zfspool
    content: ["images", "rootdir"]
    pool: pool0
```

### Modifying Snapshot Retention

Edit `group_vars/all/vars.yml` under `sanoid_templates`:

```yaml
sanoid_templates:
  data_retention:
    hourly: 24
    daily: 30
    weekly: 4
    monthly: 12
```

### Adding Users/ACLs

Edit `group_vars/all/vars.yml`:

```yaml
pve_users:
  - name: ops@pve
    email: ops@example.com

pve_acls:
  - path: /vms
    roles: ["PVEVMUser"]
    users: ["ops@pve"]
```

## Troubleshooting

### Connection issues

Verify SSH access:

```bash
ssh -i /path/to/key root@192.168.11.15
```

### SOPS decryption issues

Ensure the age private key is at `~/.sops/key.txt`:

```bash
ls -la ~/.sops/key.txt
sops -d group_vars/all/secrets.sops.yml  # test decryption
```

### Role installation problems

Clear cache and reinstall:

```bash
rm -rf ~/.ansible/roles/*
ansible-galaxy install -r requirements.yml --force
```

## Monitoring

Once deployed, metrics flow to:

- **Prometheus**: `https://prometheus.sharmamohit.com`
- **Loki**: `https://loki.sharmamohit.com`

Dashboards and alerts can reference labels:
- `instance=r720xd` (hostname)
- `source=infra` (infrastructure origin)
- `job=node|smartctl|journal` (metric job type)

## Files

- `site.yml` - Main playbook
- `requirements.yml` - Galaxy role dependencies
- `ansible.cfg` - Ansible configuration
- `inventory/hosts.yml` - Host inventory
- `group_vars/all/vars.yml` - Non-secret variables
- `group_vars/all/secrets.sops.yml` - SOPS-encrypted secrets (same age key as K8s/Docker)
- `templates/` - Jinja2 configuration templates

## References

- [lae.proxmox role](https://github.com/lae/ansible-role-proxmox)
- [Proxmox VE docs](https://pve.proxmox.com/wiki/)
- [Sanoid documentation](https://github.com/jimsalterjrs/sanoid)
- [Alloy documentation](https://grafana.com/docs/alloy/)
