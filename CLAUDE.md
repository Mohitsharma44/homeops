# Claude Code Instructions - Homeops Repository

## What This Repo Is
FluxCD GitOps repository for a Kubernetes homelab cluster named `minipcs`. Flux handles infrastructure bootstrapping; ArgoCD (deployed by Flux) handles applications.

## Architecture Pattern
```
Git Push → Flux Reconciles → Infrastructure Ready → ArgoCD Deploys Apps
```

Deployment dependency chain defined in `clusters/minipcs/`:
- `infrastructure.yaml` defines `infra-controllers` and `infra-configs` Kustomizations
- `apps.yaml` defines `apps` Kustomization (depends on `infra-configs`)

## Directory Map

```
clusters/minipcs/          # START HERE - cluster entry point
├── flux-system/           # Auto-generated, don't edit manually
├── infrastructure.yaml    # Defines infra Kustomizations
└── apps.yaml              # Defines apps Kustomization

infrastructure/
├── controllers/           # HelmReleases: cert-manager, metallb, ingress-nginx, rook-ceph
└── configs/               # Post-install configs (ceph-cluster)

apps/
├── base/argocd/           # ArgoCD itself (deployed via Flux)
├── argocd-apps/           # App-of-Apps pattern
│   ├── root-app.yaml      # Root Application (watches apps/ subdir)
│   └── apps/              # ArgoCD Application manifests go HERE
│       └── podinfo.yaml   # Example app
└── minipcs/               # Flux overlay (deploys argocd + root-app)
```

## Key Files to Read First
1. `clusters/minipcs/infrastructure.yaml` - Understand the Flux Kustomization structure
2. `infrastructure/controllers/kustomization.yaml` - See what controllers are deployed
3. `.sops.yaml` - SOPS encryption configuration
4. Any `hr.yaml` file - Standard HelmRelease pattern used throughout

## Secrets Handling

**CRITICAL**: Secrets use SOPS + age encryption.

- Config: `.sops.yaml` (encrypts `data`/`stringData` fields only)
- Public key: `age1y6dnshya496nf3072zudw3vd33723v02g3tfvpt563zng0xd9ghqwzj5xk`
- Private key location: `~/.sops/key.txt`
- Naming convention: `*secret.yaml`

When creating secrets:
1. Create YAML with `kind: Secret` and `stringData` field
2. User must encrypt with: `sops -e -i <file>.yaml`
3. Never commit unencrypted secrets (pre-commit hooks block this)

When reading encrypted secrets:
- The encrypted content is visible but not human-readable
- User can decrypt locally with: `sops -d <file>.yaml`

## Standard File Patterns

Each component typically has:
- `ns.yaml` - Namespace
- `repo.yaml` - HelmRepository (source for helm charts)
- `hr.yaml` - HelmRelease (actual deployment)
- `kustomization.yaml` - Aggregates the above files

## Adding New Components

### New Infrastructure Controller
```bash
# Create structure
mkdir -p infrastructure/controllers/<name>

# Required files:
# - ns.yaml (namespace)
# - repo.yaml (HelmRepository if new chart source)
# - hr.yaml (HelmRelease)
# - kustomization.yaml (references above files)

# Add to parent kustomization
# Edit: infrastructure/controllers/kustomization.yaml
```

### New Application (via ArgoCD App-of-Apps)
```bash
# Create ArgoCD Application manifest
# File: apps/argocd-apps/apps/<name>.yaml

# Template:
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <name>
  namespace: argocd
spec:
  project: default
  source:
    repoURL: <helm-repo-url>
    chart: <chart-name>
    targetRevision: "<version>"
    helm:
      valuesObject:
        key: value
  destination:
    server: https://kubernetes.default.svc
    namespace: <target-namespace>
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true

# Commit and push - ArgoCD auto-syncs via root-app
```

## Network Context
```
IP Range: 192.168.11.0/24
MetalLB Pool: 192.168.11.88-98
Ingress IP: 192.168.11.90
DNS: 192.168.11.1, 9.9.9.9
Domain: sharmamohit.com (wildcard cert)
```

## Common User Requests

**"Add a new app"** → Create ArgoCD Application manifest in `apps/argocd-apps/apps/<name>.yaml`

**"Check what's deployed"** →
- Infrastructure: `infrastructure/controllers/kustomization.yaml`
- Apps: `apps/argocd-apps/apps/` directory (each .yaml is an app)

**"Debug deployment issues"** → User should run: `flux get all`, `flux logs --level=error`, or check ArgoCD UI

**"Add a secret"** → Create secret YAML, remind user to run `sops -e -i` before committing

**"Bootstrap a new cluster"** → Refer to README.md bootstrap section

## Gotchas

1. **Flux Kustomization vs kustomization.yaml**: Capital-K `Kustomization` is a Flux CRD. Lowercase `kustomization.yaml` is the standard kustomize file. Both exist in this repo.

2. **App-of-Apps pattern**: ArgoCD Application manifests live in `apps/argocd-apps/apps/`. The root-app watches this directory and auto-syncs new Applications.

3. **Pre-commit auto-encryption**: Files matching `*secret.yaml` get auto-encrypted on commit via pre-commit hooks.

4. **Rook-Ceph consumes all storage**: Config uses `useAllNodes: true` and `useAllDevices: true`.

5. **cert-manager needs AWS creds**: Route53 DNS01 validation requires the encrypted secret in `infrastructure/controllers/certmanager/secret.yaml`.

6. **Legacy podinfo overlay**: `apps/minipcs/podinfo/` and `apps/base/podinfo/` exist but are NOT deployed (podinfo is now ArgoCD-managed via `apps/argocd-apps/apps/podinfo.yaml`).

## Useful Commands for User

```bash
# Flux status
flux get all
flux get kustomizations
flux get helmreleases -A

# Force sync
flux reconcile kustomization flux-system --with-source

# Logs
flux logs --level=error

# SOPS
sops -e -i path/to/secret.yaml  # encrypt
sops -d path/to/secret.yaml     # decrypt (view only)
```
