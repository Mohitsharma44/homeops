# LLM Agent Context - Homeops Repository

## Repository Purpose
FluxCD GitOps repository for Kubernetes homelab. Flux manages infrastructure; ArgoCD manages applications.

## Critical Knowledge

### File Locations
- **Cluster entry point**: `clusters/minipcs/`
- **Infrastructure controllers**: `infrastructure/controllers/`
- **Infrastructure configs**: `infrastructure/configs/`
- **ArgoCD deployment**: `apps/base/argocd/` (Flux-managed)
- **ArgoCD Applications**: `apps/argocd-apps/apps/` (App-of-Apps)
- **Root App-of-Apps**: `apps/argocd-apps/root-app.yaml`
- **SOPS config**: `.sops.yaml`
- **Pre-commit hooks**: `.pre-commit-config.yaml`

### Dependency Chain
```
flux-system → infra-controllers → infra-configs → apps
```
Kustomizations in `clusters/minipcs/infrastructure.yaml` and `apps.yaml` define this ordering via `dependsOn`.

### Secrets (SOPS + age)
- **Encryption**: age public key in `.sops.yaml`
- **Decryption key**: `~/.sops/key.txt` (local) or `sops-age` secret in `flux-system` namespace (cluster)
- **Pattern**: Files named `*secret.yaml` are encrypted
- **Encrypted fields**: Only `data` and `stringData` in YAML

### Network Constants
```
MetalLB IP Pool: 192.168.11.88-98
Ingress LoadBalancer: 192.168.11.90
Gateway/DNS: 192.168.11.1
Domain: *.sharmamohit.com (wildcard cert via Let's Encrypt + Route53)
```

### Component Versions (pinned)
- cert-manager: v1.13.2
- metallb: v0.14.5
- rook-ceph: v1.9.x

## Common Tasks

### Add new infrastructure component
1. Create `infrastructure/controllers/<name>/` with: `ns.yaml`, `repo.yaml`, `hr.yaml`, `kustomization.yaml`
2. Add path to `infrastructure/controllers/kustomization.yaml`

### Add new application (via ArgoCD App-of-Apps)
1. Create `apps/argocd-apps/apps/<name>.yaml` with ArgoCD Application manifest
2. Commit and push - ArgoCD auto-syncs via root-app

### Create encrypted secret
1. Create YAML with `stringData` or `data` fields
2. Run: `sops -e -i <file>.yaml`
3. File name should match `*secret.yaml` pattern

### Bootstrap fresh cluster
```bash
kubectl create namespace flux-system
kubectl -n flux-system create secret generic sops-age --from-file=age.agekey=$HOME/.sops/key.txt
flux bootstrap github --token-auth --owner=Mohitsharma44 --repository=homeops --branch=main --path=clusters/minipcs --personal
```

## File Patterns

| Pattern | Purpose |
|---------|---------|
| `ns.yaml` | Namespace definition |
| `repo.yaml` | HelmRepository source |
| `hr.yaml` | HelmRelease deployment |
| `kustomization.yaml` | Kustomize aggregation |
| `*secret.yaml` | SOPS-encrypted secrets |
| `values.yaml` | Helm values override (in overlays) |

## HelmRelease Structure
```yaml
apiVersion: helm.toolkit.fluxcd.io/v2beta1
kind: HelmRelease
metadata:
  name: <name>
  namespace: <namespace>
spec:
  interval: 30m
  chart:
    spec:
      chart: <chart-name>
      version: <version>
      sourceRef:
        kind: HelmRepository
        name: <repo-name>
  values:
    # inline helm values
```

## Kustomization Structure (Flux)
```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: <name>
  namespace: flux-system
spec:
  interval: 10m
  path: <path>
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  dependsOn:
    - name: <dependency>
  decryption:
    provider: sops
    secretRef:
      name: sops-age
```

## Validation Commands
```bash
flux get all                           # Overall status
flux get kustomizations               # Kustomization status
flux get helmreleases -A              # HelmRelease status
flux logs --level=error               # Error logs
kubectl get gitrepository -n flux-system  # Git sync status
```

## ArgoCD Application Structure
```yaml
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
        # inline helm values
  destination:
    server: https://kubernetes.default.svc
    namespace: <target-namespace>
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

## Gotchas
1. Pre-commit hooks auto-encrypt `*secret.yaml` files - don't be surprised if file changes on commit
2. Flux Kustomization (capital K, flux CRD) ≠ kustomization.yaml (kustomize file)
3. ArgoCD apps are managed via App-of-Apps pattern in `apps/argocd-apps/apps/`
4. Rook-Ceph uses ALL nodes and ALL devices - be careful with node additions
5. cert-manager uses Route53 DNS01 validation - requires AWS credentials in encrypted secret
6. root-app.yaml watches `apps/argocd-apps/apps/` - add Application manifests there for auto-sync
