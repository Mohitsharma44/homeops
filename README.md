# Homeops - FluxCD GitOps Repository

GitOps repository for Kubernetes clusters in homelab. Uses FluxCD for infrastructure bootstrapping and ArgoCD for application delivery.

## Architecture

```
Flux (Infrastructure) → ArgoCD (Applications)
```

**Deployment Order (via Flux Kustomization dependencies):**
```
flux-operator → flux-instance → infra-controllers → infra-configs → apps (ArgoCD)
```

## Directory Structure

```
├── clusters/minipcs/           # Cluster entry point
│   ├── flux-instance.yaml      # FluxInstance CRD (Flux Operator manages controllers)
│   ├── kustomization.yaml      # Aggregates flux-instance, infrastructure, apps
│   ├── infrastructure.yaml     # Triggers infra-controllers + infra-configs
│   └── apps.yaml               # Triggers apps deployment (ArgoCD + root-app)
├── infrastructure/
│   ├── controllers/            # Core infra (cert-manager, metallb, ingress-nginx, rook-ceph)
│   └── configs/                # Post-controller configs (ceph-cluster)
└── apps/
    ├── base/argocd/            # ArgoCD itself (deployed by Flux)
    ├── argocd-apps/            # App-of-Apps pattern
    │   ├── root-app.yaml       # Root Application (watches apps/ directory)
    │   └── apps/               # ArgoCD Application manifests
    │       └── podinfo.yaml    # Example app managed by ArgoCD
    └── minipcs/                # Cluster-specific Flux overlay
```

## App-of-Apps Pattern

Applications are managed by ArgoCD using the App-of-Apps pattern:

```
Flux deploys:
├── ArgoCD (the tool)
└── root-app.yaml (ArgoCD Application)
        │
        └── Watches: apps/argocd-apps/apps/
                     ├── podinfo.yaml    → deploys podinfo
                     └── future-app.yaml → add more apps here
```

**To add a new application:**
1. Create an ArgoCD Application manifest in `apps/argocd-apps/apps/<name>.yaml`
2. Commit and push - ArgoCD auto-syncs

**Example Application manifest:**
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://charts.example.com
    chart: my-chart
    targetRevision: "1.0.0"
    helm:
      valuesObject:
        key: value
  destination:
    server: https://kubernetes.default.svc
    namespace: my-app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

## Infrastructure Components

| Component | Purpose | Key Config |
|-----------|---------|------------|
| **MetalLB** | LoadBalancer IPs | Pool: `192.168.11.88-98` |
| **Ingress-NGINX** | HTTP routing | LB IP: `192.168.11.90`, default SSL cert |
| **Cert-Manager** | TLS certificates | Let's Encrypt via Route53 DNS01 |
| **Rook-Ceph** | Distributed storage | Uses all nodes/devices |
| **ArgoCD** | Application delivery | `argocd.sharmamohit.com` |

## Secrets Management (SOPS + age)

**How it works:**
- `.sops.yaml` defines encryption rules (encrypts `data` and `stringData` fields)
- Public key: `age1y6dnshya496nf3072zudw3vd33723v02g3tfvpt563zng0xd9ghqwzj5xk`
- Private key: `~/.sops/key.txt` (must exist on your machine)
- Flux decrypts secrets in-cluster using the `sops-age` secret in `flux-system` namespace

**Pre-commit hooks prevent committing unencrypted secrets:**
- `encrypt-sops-files.sh` - auto-encrypts files matching `*secret.yaml`
- `forbid-secrets` - blocks commits with unencrypted secret data

**Encrypt a secret manually:**
```bash
sops -e -i path/to/secret.yaml
```

**Decrypt for viewing:**
```bash
sops -d path/to/secret.yaml
```

## Bootstrap (Fresh Cluster)

### Prerequisites
- Kubernetes cluster accessible via kubectl
- [Helm](https://helm.sh/docs/intro/install/) installed
- age key at `~/.sops/key.txt`
- GitHub App for Flux (see setup below)

### Create the GitHub App

1. Go to **GitHub → Settings → Developer settings → GitHub Apps → New GitHub App**
2. Fill in:
   - **Name**: anything (e.g. `flux-homeops`)
   - **Homepage URL**: `https://github.com/Mohitsharma44/homeops`
   - **Webhook**: uncheck "Active"
   - **Repository permissions → Contents**: Read-only
   - **Where can this app be installed**: Only on this account
3. Click **Create GitHub App** — note the **App ID** from the app settings page
4. Scroll to **Private keys** → **Generate a private key** (saves a `.pem` file)
5. Click **Install App** → select **Only select repositories** → pick `homeops`
6. Note the **Installation ID** from the URL: `https://github.com/settings/installations/<id>`

You'll need three values for the bootstrap: **App ID**, **Installation ID**, and the **private key `.pem` file**.

### Steps

```bash
# 1. Create the flux-system namespace
kubectl create namespace flux-system

# 2. Create the SOPS decryption secret (Flux needs this to decrypt secrets)
kubectl -n flux-system create secret generic sops-age \
  --from-file=age.agekey=$HOME/.sops/key.txt

# 3. Create the GitHub App secret (used by source-controller to pull the repo)
kubectl -n flux-system create secret generic flux-system \
  --from-literal=githubAppID=<app-id> \
  --from-literal=githubAppInstallationID=<installation-id> \
  --from-file=githubAppPrivateKey=<path-to-private-key.pem>

# 4. Install the Flux Operator via Helm
helm install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
  --namespace flux-system

# 5. Apply the FluxInstance to start GitOps reconciliation
kubectl apply -f clusters/minipcs/flux-instance.yaml

# 6. Watch reconciliation
kubectl -n flux-system get fluxinstance flux -w
flux get kustomizations --watch
```

### Post-Bootstrap Verification

```bash
kubectl -n flux-system get deploy                # 4 controllers + flux-operator
kubectl -n flux-system get fluxinstance flux      # Ready: True
kubectl -n flux-system get gitrepository flux-system  # Ready: True
flux get kustomizations                          # All 3 Ready
flux get helmreleases -A                         # All Ready
```

After Flux reconciles, ArgoCD will be available at `argocd.sharmamohit.com`.

**Get ArgoCD admin password:**
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

## Network Layout

```
Gateway/DNS: 192.168.11.1
MetalLB Pool: 192.168.11.88 - 192.168.11.98
Ingress LB:   192.168.11.90
```

**Domains (wildcard cert: `*.sharmamohit.com`):**
- `argocd.sharmamohit.com` - ArgoCD UI
- `podinfo.sharmamohit.com` - Test app
- `rook-ceph.sharmamohit.com` - Ceph dashboard

## Rook-Ceph Storage

Deployed via HelmRelease in two parts:
1. `rook-ceph` operator (in `infrastructure/controllers/rook-ceph/`)
2. `ceph-cluster` config (in `infrastructure/configs/`)

**Config:** Uses all nodes and all devices (`useAllNodes: true`, `useAllDevices: true`)

**Access toolbox:**
```bash
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- bash
ceph status
ceph osd status
```

## Common Operations

**Force reconciliation:**
```bash
flux reconcile kustomization flux-system --with-source
```

**Check Flux Operator / FluxInstance status:**
```bash
kubectl -n flux-system get fluxinstance flux
kubectl -n flux-system describe fluxinstance flux
```

**Check Flux status:**
```bash
flux get all
flux logs --level=error
```

**Suspend/resume a resource:**
```bash
flux suspend kustomization apps
flux resume kustomization apps
```

**Debug HelmRelease:**
```bash
flux get helmreleases -A
kubectl describe helmrelease <name> -n <namespace>
```

## Adding New Infrastructure

1. Create directory under `infrastructure/controllers/<name>/`
2. Add: `ns.yaml`, `repo.yaml` (if new helm repo), `hr.yaml`, `kustomization.yaml`
3. Reference in `infrastructure/controllers/kustomization.yaml`
4. Commit and push - Flux auto-reconciles

## Adding New Apps (via ArgoCD)

1. Create ArgoCD Application manifest in `apps/argocd-apps/apps/<name>.yaml`
2. Commit and push - ArgoCD auto-syncs via root-app

See the "App-of-Apps Pattern" section above for the manifest template.

## Generating a New age Key (if lost)

```bash
age-keygen -o ~/.sops/key.txt
# Update .sops.yaml with the new public key
# Re-encrypt all secrets with the new key
# Update the sops-age secret in the cluster
```

## Troubleshooting

**Flux not reconciling:**
```bash
kubectl -n flux-system get fluxinstance flux        # Check operator status
kubectl get gitrepository -n flux-system
kubectl describe kustomization flux-system -n flux-system
```

**Secret decryption failing:**
```bash
kubectl get secret sops-age -n flux-system  # Verify it exists
kubectl logs -n flux-system deploy/kustomize-controller | grep -i sops
```

**HelmRelease stuck:**
```bash
kubectl get helmrelease -A
flux get helmreleases -A
helm list -A  # Check Helm directly
```
