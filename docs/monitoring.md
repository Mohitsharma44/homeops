# Phase 3: K8s Observability Stack Deployment

## Overview

Full metrics/logs/traces observability stack deployed in the `monitoring` namespace via ArgoCD, with long-term storage on SeaweedFS S3 (TrueNAS).

## Components

| Component | Chart | Version | Purpose |
|-----------|-------|---------|---------|
| kube-prometheus-stack | prometheus-community | 81.x | Prometheus, Grafana, Alertmanager, node-exporter, kube-state-metrics |
| Thanos | bitnami/thanos | 17.x | Long-term metrics (Query, Store Gateway, Compactor) |
| Loki | grafana/loki | 6.x | Log aggregation (SingleBinary mode) |
| Tempo | grafana/tempo | 1.x | Distributed tracing (monolithic mode) |
| Alloy | grafana/alloy | 1.x | Log collection + trace forwarding (DaemonSet) |

## Architecture

```
┌─ K8s Cluster (minipcs) ─────────────────────────────────────────────────────┐
│                                                                             │
│  ┌─────────────────────────────────────────┐                                │
│  │              Grafana                     │                                │
│  │     grafana.sharmamohit.com              │                                │
│  │  Datasources: Thanos, Loki, Tempo       │                                │
│  └──────┬──────────┬──────────┬────────────┘                                │
│         │          │          │                                              │
│  ┌──────▼──────┐ ┌─▼──────┐ ┌▼──────┐                                      │
│  │Thanos Query │ │  Loki  │ │ Tempo │                                       │
│  └──────┬──────┘ │ Single │ │ Mono  │                                       │
│         │        │ Binary │ │lithic │                                       │
│   ┌─────┼────┐   └───┬────┘ └──┬────┘                                      │
│   │     │    │       │         │                                            │
│ ┌─▼───┐ │ ┌─▼──────┐│         │      Alloy DaemonSet                      │
│ │Store│ │ │Compactor││         │        ├─ Logs  → Loki                    │
│ │GW   │ │ └────────┘│         │        └─ Traces → Tempo                   │
│ └──┬──┘ │           │         │                                             │
│    │  ┌─▼──────┐    │         │                                             │
│    │  │Thanos  │    │         │                                             │
│    │  │Sidecar │    │         │                                             │
│    │  └────────┘    │         │                                             │
│    │                │         │                                             │
│    │   S3 (HTTP)    │         │                                             │
└────┼────────────────┼─────────┼─────────────────────────────────────────────┘
     │                │         │
─ ─ ─│─ ─ ─ ─ ─ ─ ─ ─│─ ─ ─ ─ ─│─ ─ ─  LAN (192.168.11.0/24) ─ ─ ─ ─ ─ ─ ─
     │                │         │
┌────▼────────────────▼─────────▼─────────────────────────────────────────────┐
│  TrueNAS (VM) ── SeaweedFS S3  ──  seaweedfs.sharmamohit.com:8333          │
│                                                                             │
│  ┌──────────────┐  ┌──────────┐  ┌───────────┐  ┌───────────────┐          │
│  │thanos-metrics│  │loki-chunks│  │loki-ruler │  │ tempo-traces  │          │
│  └──────────────┘  └──────────┘  └───────────┘  └───────────────┘          │
│                                                                             │
│  IAM Identity: observability (Read/Write/List)                              │
│  Storage: HDD-backed (long-term cold storage)                               │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Endpoints

| Service | URL / Address |
|---------|---------------|
| Grafana | https://grafana.sharmamohit.com |
| Prometheus | http://kube-prometheus-stack-prometheus.monitoring.svc:9090 |
| Thanos Query | http://thanos-query.monitoring.svc:9090 |
| Loki | http://loki.monitoring.svc:3100 |
| Tempo HTTP | http://tempo.monitoring.svc:3100 |
| Tempo OTLP gRPC | tempo.monitoring.svc:4317 |
| Tempo OTLP HTTP | http://tempo.monitoring.svc:4318 |
| Alertmanager | http://kube-prometheus-stack-alertmanager.monitoring.svc:9093 |

## S3 Backend (SeaweedFS on TrueNAS)

SeaweedFS runs inside a VM on TrueNAS, providing S3-compatible object storage over the LAN for long-term observability data.

- **Host**: TrueNAS (VM running SeaweedFS)
- **Endpoint**: http://seaweedfs.sharmamohit.com:8333
- **IAM Identity**: observability (Read/Write/List)
- **Buckets**: thanos-metrics, loki-chunks, loki-ruler, tempo-traces

## Secrets

Two SOPS-encrypted secrets in `infrastructure/configs/`:

| Secret | Namespace | Keys | Used By |
|--------|-----------|------|---------|
| `seaweedfs-s3-secret` | monitoring | `aws-access-key-id`, `aws-secret-access-key` | Loki, Tempo (via env vars) |
| `thanos-objstore-secret` | monitoring | `objstore.yml` | Prometheus Thanos sidecar, Thanos components |

**Credential rotation note**: Both secrets contain the same SeaweedFS observability IAM credentials. When rotating credentials, update **both** `seaweedfs-s3-secret` and `thanos-objstore-secret`, then re-encrypt with SOPS.

## Retention Policy

| Data Type | Hot (NVMe) | Cold (SeaweedFS/HDD) |
|-----------|-----------|---------------------|
| Metrics (raw) | 3 days | 7 days |
| Metrics (5m downsample) | — | 30 days |
| Metrics (1h downsample) | — | 180 days |
| Logs | — | 30 days |
| Traces | — | 7 days |

## Storage (Ceph PVCs)

| Component | Size | StorageClass |
|-----------|------|-------------|
| Prometheus | 20Gi | ceph-block |
| Alertmanager | 1Gi | ceph-block |
| Thanos Store Gateway | 10Gi | ceph-block |
| Thanos Compactor | 10Gi | ceph-block |
| Loki WAL | 10Gi | ceph-block |
| Tempo WAL | 10Gi | ceph-block |
| Grafana | 2Gi | ceph-block |
| **Total** | **63Gi** | (~189Gi raw with 3x Ceph replication) |

## Sync Wave Order

1. **Wave 1**: kube-prometheus-stack (CRDs, Prometheus, Grafana, Alertmanager)
2. **Wave 2**: Thanos, Loki, Tempo (depend on CRDs and sidecar)
3. **Wave 3**: Alloy (depends on Loki and Tempo endpoints)

## Security

- **Pod Security Standards**: `monitoring` namespace enforces `baseline` PSS with `restricted` warnings
- **Loki multi-tenancy**: `auth_enabled: true` with tenant ID `homelab` — all clients must send `X-Scope-OrgID: homelab` header
- **S3 transport**: Currently HTTP (`insecure: true`) over LAN. **TODO**: Enable TLS on SeaweedFS and update all S3 endpoint configs to remove `insecure: true`

## ServiceMonitors Enabled

The following infrastructure components have ServiceMonitors enabled:

- ingress-nginx (metrics + prometheusRule)
- MetalLB (serviceMonitor + prometheusRule)
- rook-ceph operator
- Ceph cluster (+ PrometheusRules)
- cert-manager

## Manual Steps

### 1. Encrypt secrets with SOPS

```bash
cd infrastructure/configs/
sops -e -i seaweedfs-s3-secret.yaml
sops -e -i thanos-objstore-secret.yaml
```

### 2. Verify Ceph StorageClass exists

```bash
kubectl get sc ceph-block
```

### 3. Commit and push

```bash
git add -A
git commit -m "feat: add Phase 3 observability stack"
git push
```

### 4. Monitor deployment

```bash
# Flux reconciles infrastructure (namespace + secrets)
flux reconcile kustomization flux-system --with-source
flux get kustomizations

# ArgoCD syncs applications
kubectl get applications -n argocd
kubectl get pods -n monitoring -w
```

### 5. Get Grafana admin password

```bash
kubectl get secret kube-prometheus-stack-grafana -n monitoring \
  -o jsonpath="{.data.admin-password}" | base64 -d
```

### 6. Verify observability stack

```bash
# Check all pods are running
kubectl get pods -n monitoring

# Check Prometheus targets
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090
# Visit http://localhost:9090/targets

# Check Thanos stores
kubectl port-forward -n monitoring svc/thanos-query 9090
# Visit http://localhost:9090/stores

# Check Loki readiness
kubectl port-forward -n monitoring svc/loki 3100
# Visit http://localhost:3100/ready

# Check Tempo readiness
kubectl port-forward -n monitoring svc/tempo 3100
# Visit http://localhost:3100/ready
```
