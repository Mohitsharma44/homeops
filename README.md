# Homeops

GitOps repository for homelab infrastructure. Manages **Kubernetes** (via Flux + ArgoCD), **Docker** containers (via Komodo), and **Proxmox** nodes (via Ansible) from a single repo with unified secret management (SOPS + age).

## Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          homeops (this repo)                            │
├──────────────────┬──────────────────────┬────────────────────────────────┤
│  Kubernetes      │  Docker              │  Proxmox                       │
│  (Flux + ArgoCD) │  (Komodo GitOps)     │  (Ansible)                     │
│                  │                      │                                │
│  3-node cluster  │  6 Docker hosts      │  R720XD standalone node        │
│  Infrastructure: │  komodo, nvr, kasm,  │  ZFS storage (pool0, ssdpool0) │
│   MetalLB,       │  omni, server04,     │  SeaweedFS VM (S3/WebDAV)      │
│   Ingress,       │  seaweedfs           │  NFS exports, Sanoid snapshots │
│   Cert-Manager,  │  13 stacks           │  Alloy + smartctl monitoring   │
│   Rook-Ceph      │                      │                                │
├──────────────────┴──────────────────────┴────────────────────────────────┤
│  Shared: SOPS + age encryption, *.sharmamohit.com domain,               │
│          pre-commit hooks, observability (all telemetry → Grafana)       │
└─────────────────────────────────────────────────────────────────────────┘
```

## Directory Structure

```
├── kubernetes/
│   ├── clusters/minipcs/       # K8s cluster entry point (Flux)
│   ├── infrastructure/
│   │   ├── controllers/        # Core infra (cert-manager, metallb, ingress-nginx, rook-ceph)
│   │   └── configs/            # Post-controller configs (ceph-cluster, monitoring namespace)
│   │       └── ceph/           # Standalone Ceph resource manifests
│   └── apps/
│       ├── base/argocd/        # ArgoCD itself (deployed by Flux)
│       ├── argocd-apps/        # App-of-Apps pattern
│       │   ├── root-app.yaml   # Root Application (watches apps/ directory)
│       │   └── apps/           # ArgoCD Application + AppProject manifests
│       └── minipcs/            # Cluster-specific Flux overlay
├── docker/                     # Docker infrastructure (Komodo GitOps)
│   ├── komodo-resources/       # TOML resource declarations
│   ├── stacks/                 # Compose files + SOPS-encrypted secrets
│   └── periphery/              # Custom periphery image (SOPS + age)
├── proxmox/                    # Proxmox node config (Ansible)
│   ├── site.yml                # Main playbook (lae.proxmox + NFS + Sanoid + monitoring)
│   ├── inventory/hosts.yml     # R720XD at 192.168.11.15
│   ├── group_vars/all/         # vars.yml + secrets.sops.yml
│   └── templates/              # Alloy, Sanoid, smartctl-exporter configs
└── docs/                       # Additional documentation
    ├── ceph.md                 # Rook-Ceph storage
    ├── monitoring.md           # Observability stack architecture
    ├── docker-hosts.md         # Docker host operational reference
    └── talos-nodes.md          # Talos node provisioning (Omni)
```

## Kubernetes

### Architecture

```
Flux (Infrastructure) → ArgoCD (Applications)
```

**Deployment Order (via Flux Kustomization dependencies):**
```
flux-operator → flux-instance → infra-controllers → infra-configs → apps (ArgoCD)
```

### Infrastructure Components

| Component | Purpose | Key Config |
|-----------|---------|------------|
| **MetalLB** | LoadBalancer IPs | Pool: `192.168.11.88-98` |
| **Ingress-NGINX** | HTTP routing | LB IP: `192.168.11.90`, default SSL cert |
| **Cert-Manager** | TLS certificates | Let's Encrypt via Route53 DNS01 |
| **Rook-Ceph** | Distributed storage | Uses all nodes/devices |
| **ArgoCD** | Application delivery | `argocd.sharmamohit.com` |

### App-of-Apps Pattern

Applications are managed by ArgoCD using the App-of-Apps pattern:

```
Flux deploys:
├── ArgoCD (the tool)
└── root-app.yaml (ArgoCD Application)
        │
        └── Watches: kubernetes/apps/argocd-apps/apps/
                     ├── project-monitoring.yaml → AppProject definition
                     ├── kube-prometheus-stack.yaml → project: monitoring
                     ├── thanos.yaml               → project: monitoring
                     ├── loki.yaml                  → project: monitoring
                     ├── tempo.yaml                 → project: monitoring
                     ├── alloy.yaml                 → project: monitoring
                     └── ...more apps
```

**To add a new application:**
1. Create an ArgoCD Application manifest in `kubernetes/apps/argocd-apps/apps/<name>.yaml`
2. Set `project:` to the appropriate AppProject (or `default`)
3. Commit and push - ArgoCD auto-syncs

### Rook-Ceph Storage

Distributed storage (block, filesystem, object) via Rook-Ceph. See [docs/ceph.md](docs/ceph.md).

| StorageClass | Type | Replication |
|-------------|------|-------------|
| `ceph-block` (default) | RBD block | 3x replicated |
| `ceph-filesystem` | CephFS shared | 3x replicated |
| `ceph-bucket` | RGW S3 object | Erasure coded (2+1) |

## Docker (Komodo GitOps)

Manages Docker containers across 6 hosts via [Komodo](https://komo.do) Resource Sync. See [docker/README.md](docker/README.md) for full documentation.

### Hosts

| Host | Role | Key Services |
|------|------|-------------|
| **komodo** | Komodo Core | Core (self-managed), Periphery (systemd), Alloy |
| **nvr** | Video Recording | Frigate (Coral TPU), Alloy |
| **kasm** | Remote Desktop | KASM Workspaces, Newt, Alloy |
| **omni** | K8s Management | Siderolabs Omni, Alloy |
| **server04** | App Server + Build | Traefik, Vaultwarden, Alloy |
| **seaweedfs** | Object Storage | SeaweedFS (5 containers), Alloy |

### How It Works

1. Resource definitions (TOML) in `docker/komodo-resources/` declare servers, stacks, builds, and procedures
2. A single ResourceSync pulls from this repo and creates/updates/deletes Komodo resources
3. Each stack references a compose file in `docker/stacks/{host}/{service}/`
4. Secrets are SOPS-encrypted `.sops.env` files decrypted at deploy time by a custom periphery image (komodo host uses systemd Periphery with native sops+age)
5. Alloy monitoring runs on every host, pushing metrics/logs to the K8s observability stack

## Proxmox (Ansible)

Manages Proxmox VE node configuration via Ansible. See [proxmox/README.md](proxmox/README.md).

### Node: R720XD (standalone)

| Property | Value |
|----------|-------|
| **IP** | 192.168.11.15 |
| **Hardware** | Dell R720XD, 256GB RAM, 14 drives |
| **ZFS Pools** | pool0 (21.8T raidz1), ssdpool0 (7.27T raidz1) — both encrypted (aes-256-gcm) |
| **VMs** | SeaweedFS (S3 object storage, 4 buckets) |
| **Services** | NFS export (/mnt/pool0/nvr for Frigate), Sanoid snapshots, Alloy, smartctl-exporter |

```bash
cd proxmox
ansible-galaxy install -r requirements.yml
ansible-playbook site.yml
```

## Observability

Full metrics, logs, and traces stack. See [docs/monitoring.md](docs/monitoring.md) for architecture, data flow, and retention policies.

### K8s Observability (ArgoCD)

| Component | Role |
|-----------|------|
| **kube-prometheus-stack** | Prometheus, Grafana, Alertmanager, node-exporter |
| **Thanos** | Long-term metrics (query, store gateway, compactor) |
| **Loki** | Log aggregation |
| **Tempo** | Distributed tracing |
| **Alloy** | K8s log/trace collection (DaemonSet) |

### Docker Host Observability (Komodo)

Grafana Alloy runs on all 6 Docker hosts, collecting host metrics (node_exporter), container metrics (cAdvisor), and container logs. Data is pushed to the K8s Prometheus and Loki instances via authenticated external write endpoints.

```
Docker hosts (Alloy)  ──metrics──→  prometheus.sharmamohit.com  ──→  Prometheus  ──→  Thanos  ──→  Grafana
                      ──logs────→  loki.sharmamohit.com         ──→  Loki               ──→  Grafana
```

### Access

| Service | URL |
|---------|-----|
| Grafana | `https://grafana.sharmamohit.com` |
| ArgoCD | `https://argocd.sharmamohit.com` |
| Ceph Dashboard | `https://rook-ceph.sharmamohit.com` |
| Komodo | `https://komodo.sharmamohit.com` |

## Secrets Management (SOPS + age)

Both Kubernetes and Docker secrets use the same SOPS + age encryption with the same key pair.

| Layer | Secret Format | Decryption |
|-------|--------------|------------|
| **Kubernetes** | `*secret.yaml` (encrypts `data`/`stringData` fields) | Flux decrypts in-cluster via `sops-age` secret |
| **Docker** | `.sops.env`, `.sops.json` (encrypts entire file) | Periphery agent decrypts at deploy time via `pre_deploy` hook |
| **Proxmox** | `*.sops.yml` (encrypts all values) | `community.sops` Ansible vars plugin decrypts at playbook runtime |

**Key:**
- Public: `age1y6dnshya496nf3072zudw3vd33723v02g3tfvpt563zng0xd9ghqwzj5xk`
- Private: `~/.sops/key.txt` (local), `/etc/sops/age/keys.txt` (Docker hosts), `sops-age` secret (K8s cluster)

**Pre-commit hooks** prevent committing unencrypted secrets:
- `encrypt-sops-files.sh` — auto-encrypts files matching `*secret.yaml`
- `forbid-secrets` — blocks commits with unencrypted secret data

```bash
# Encrypt
sops -e -i path/to/secret.yaml        # K8s
sops -e -i docker/stacks/host/svc/.sops.env  # Docker

# Decrypt (view only)
sops -d path/to/secret.yaml
```

## Network Layout

```
Gateway/DNS: 192.168.11.1
MetalLB Pool: 192.168.11.88 - 192.168.11.98
Ingress LB:   192.168.11.90
```

**Domains (wildcard cert: `*.sharmamohit.com`):**

| Domain | Service |
|--------|---------|
| `argocd.sharmamohit.com` | ArgoCD UI |
| `grafana.sharmamohit.com` | Grafana dashboards |
| `rook-ceph.sharmamohit.com` | Ceph dashboard |
| `komodo.sharmamohit.com` | Komodo UI |
| `bitwarden.sharmamohit.com` | Vaultwarden |
| `prometheus.sharmamohit.com` | Prometheus remote-write endpoint |
| `loki.sharmamohit.com` | Loki push endpoint |

## Bootstrap

### Kubernetes (Fresh Cluster)

**Prerequisites:** Kubernetes cluster, Helm, age key at `~/.sops/key.txt`, GitHub App for Flux

```bash
# 1. Create flux-system namespace
kubectl create namespace flux-system

# 2. Create SOPS decryption secret
kubectl -n flux-system create secret generic sops-age \
  --from-file=age.agekey=$HOME/.sops/key.txt

# 3. Create GitHub App secret
kubectl -n flux-system create secret generic flux-system \
  --from-literal=githubAppID=<app-id> \
  --from-literal=githubAppInstallationID=<installation-id> \
  --from-file=githubAppPrivateKey=<path-to-private-key.pem>

# 4. Install Flux Operator
helm install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
  --namespace flux-system

# 5. Apply FluxInstance
kubectl apply -f kubernetes/clusters/minipcs/flux-instance.yaml

# 6. Watch reconciliation
flux get kustomizations --watch
```

### Docker (Komodo)

See [docker/README.md](docker/README.md) for full setup. In short:

1. Komodo Core deployed as self-managed stack; systemd Periphery on komodo host
2. Custom periphery image (with SOPS + age) deployed on all 6 hosts
3. Age private key distributed to `/etc/sops/age/keys.txt` on each host
4. ResourceSync created pointing at `docker/komodo-resources/`
5. Stacks deployed via `km execute deploy-stack <name>` or Komodo UI

## Common Operations

### Kubernetes

```bash
# Force Flux reconciliation
flux reconcile kustomization flux-system --with-source

# Check status
flux get all
flux get helmreleases -A

# Suspend/resume
flux suspend kustomization apps
flux resume kustomization apps
```

### Docker (Komodo)

```bash
# Sync resources from git
km execute sync 'mohitsharma44/homeops'

# Deploy a stack
km execute deploy-stack <stack-name>

# Check status
km list stacks -a
km list servers -a
```

### Adding New Infrastructure

**K8s controller:**
1. Create directory under `kubernetes/infrastructure/controllers/<name>/`
2. Add `ns.yaml`, `repo.yaml`, `hr.yaml`, `kustomization.yaml`
3. Reference in `kubernetes/infrastructure/controllers/kustomization.yaml`
4. Commit and push

**K8s app (ArgoCD):**
1. Create ArgoCD Application manifest in `kubernetes/apps/argocd-apps/apps/<name>.yaml`
2. Set `project:` and commit

**Docker stack:**
1. Create `docker/stacks/{host}/{service}/compose.yaml` + `.sops.env`
2. Add stack definition to `docker/komodo-resources/stacks-{host}.toml`
3. Commit, push, sync, deploy

## Troubleshooting

**Flux not reconciling:**
```bash
kubectl -n flux-system get fluxinstance flux
kubectl describe kustomization flux-system -n flux-system
```

**Secret decryption failing (K8s):**
```bash
kubectl get secret sops-age -n flux-system
kubectl logs -n flux-system deploy/kustomize-controller | grep -i sops
```

**Komodo stack deploy failing:**
```bash
km list stacks -a                    # Check state
# View deployment logs in Komodo UI or via API
```

**Generating a new age key:**
```bash
age-keygen -o ~/.sops/key.txt
# Update .sops.yaml with new public key
# Re-encrypt all secrets
# Update sops-age secret in K8s cluster
# Distribute new key to all Docker hosts
```
