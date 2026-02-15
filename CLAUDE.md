# Claude Code Instructions - Homeops Repository

## What This Repo Is
GitOps repository for homelab infrastructure. Manages both **Kubernetes** (Flux + ArgoCD) and **Docker** containers (Komodo GitOps) from a single repo with unified secret management (SOPS + age).

Docker/Komodo-specific instructions are in `docker/CLAUDE.md` (loaded automatically when working in `docker/`).

## Architecture
```
Kubernetes: Git Push → Flux Reconciles → Infrastructure Ready → ArgoCD Deploys Apps
Docker:     Git Push → Komodo ResourceSync → pre_deploy (SOPS decrypt) → docker compose up
```

Kubernetes deployment chain (`clusters/minipcs/`):
- `infrastructure.yaml` → `infra-controllers` and `infra-configs` Kustomizations
- `apps.yaml` → `apps` Kustomization (depends on `infra-configs`)

## Directory Map

```
clusters/minipcs/          # K8s cluster entry point (Flux)
infrastructure/
├── controllers/           # HelmReleases: cert-manager, metallb, ingress-nginx, rook-ceph
└── configs/               # Post-install configs (ceph-cluster, monitoring secrets)
apps/
├── base/argocd/           # ArgoCD itself (deployed via Flux)
├── argocd-apps/apps/      # ArgoCD Application manifests go HERE
└── minipcs/               # Flux overlay (deploys argocd + root-app)
docker/                    # Docker infrastructure (Komodo GitOps) — see docker/CLAUDE.md
```

## Key Files to Read First
1. `clusters/minipcs/flux-instance.yaml` - FluxInstance CRD
2. `clusters/minipcs/infrastructure.yaml` - Flux Kustomization structure
3. `infrastructure/controllers/kustomization.yaml` - What controllers are deployed
4. `.sops.yaml` - SOPS encryption configuration

## Secrets (SOPS + age)

Both K8s and Docker use the same SOPS + age key pair.

- Config: `.sops.yaml` at repo root
- Public key: `age1y6dnshya496nf3072zudw3vd33723v02g3tfvpt563zng0xd9ghqwzj5xk`
- Private key: `~/.sops/key.txt` (local), `/etc/sops/age/keys.txt` (Docker hosts), `sops-age` secret (K8s)
- K8s: `*secret.yaml` — Flux decrypts in-cluster
- Docker: `.sops.env`/`.sops.json` next to compose files — Periphery decrypts at deploy time
- Never commit unencrypted secrets (pre-commit hooks block this)

```bash
sops -e -i path/to/secret         # encrypt
sops -d path/to/secret            # decrypt (view only)
```

## Network
```
IP Range: 192.168.11.0/24
MetalLB Pool: 192.168.11.88-98
Ingress IP: 192.168.11.90
DNS: 192.168.11.1, 9.9.9.9
Domain: sharmamohit.com (wildcard cert)
```

## K8s File Patterns

Each infrastructure component typically has: `ns.yaml`, `repo.yaml` (HelmRepository), `hr.yaml` (HelmRelease), `kustomization.yaml`.

### Adding a New K8s App (ArgoCD)
Create `apps/argocd-apps/apps/<name>.yaml` — ArgoCD auto-syncs via root-app.

### Adding a New Infrastructure Controller
Create `infrastructure/controllers/<name>/` with ns.yaml, repo.yaml, hr.yaml, kustomization.yaml. Add to `infrastructure/controllers/kustomization.yaml`.

## Gotchas

1. **Flux Kustomization vs kustomization.yaml**: Capital-K `Kustomization` is a Flux CRD. Lowercase is standard kustomize.
2. **App-of-Apps**: ArgoCD Application manifests in `apps/argocd-apps/apps/` — root-app watches this directory.
3. **Pre-commit auto-encryption**: Files matching `*secret.yaml` get auto-encrypted on commit.
4. **Rook-Ceph**: `useAllNodes: true` and `useAllDevices: true`.
5. **cert-manager**: Route53 DNS01 validation needs encrypted secret in `infrastructure/controllers/certmanager/secret.yaml`.
6. **Flux Operator**: Manages Flux controllers via `FluxInstance` CRD. To upgrade Flux, bump `version` in `flux-instance.yaml`.
7. **GitHub App auth**: Source-controller uses a GitHub App (secret `flux-system`), not a PAT.

## Commands

```bash
# Flux
flux get all
flux get kustomizations
flux get helmreleases -A
flux reconcile kustomization flux-system --with-source
flux logs --level=error

# SOPS
sops -e -i path/to/secret.yaml  # encrypt
sops -d path/to/secret.yaml     # decrypt (view only)
```
