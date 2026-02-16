# Phase 3: K8s Observability Stack Deployment

## Overview

Full metrics/logs/traces observability stack deployed in the `monitoring` namespace via ArgoCD, with long-term storage on SeaweedFS S3 (TrueNAS).

## Components

| Component | Chart | Version | Purpose |
|-----------|-------|---------|---------|
| kube-prometheus-stack | prometheus-community | 81.x | Prometheus, Grafana, Alertmanager, node-exporter, kube-state-metrics |
| Thanos | bitnami/thanos (OCI: `registry-1.docker.io/bitnamicharts`) | 17.x | Long-term metrics (Query, Store Gateway, Compactor) |
| Loki | grafana/loki | 6.x | Log aggregation (SingleBinary mode) |
| Tempo | grafana/tempo | 1.x | Distributed tracing (monolithic mode) |
| Alloy | grafana/alloy | 1.x | Log collection + trace forwarding (DaemonSet) |

## How It Works

Three data pipelines — **metrics**, **logs**, and **traces** — all converge in Grafana.

### Metrics Pipeline

Prometheus scrapes `/metrics` endpoints from pods, node-exporters, and kube-state-metrics every 30s. It stores 3 days of raw data on a local NVMe PVC. The Thanos Sidecar watches Prometheus's TSDB and uploads completed 2-hour blocks to SeaweedFS S3.

For queries, Thanos Query federates two sources: the Sidecar (recent data) and the Store Gateway (old data from S3), deduplicating overlapping blocks and presenting a single Prometheus-compatible API. The Compactor runs in the background downsampling old data (5-minute resolution for 30 days, 1-hour resolution for 180 days) to keep long-range queries fast.

```
Pods/Exporters
  │  scrape /metrics (pull)
  ▼
Prometheus (3d on NVMe)
  │
  ├─ Thanos Sidecar ──uploads──→ SeaweedFS S3 (thanos-metrics)
  │                                  │
  │                     ┌────────────┼───────────┐
  │                     ▼            ▼           │
  │              Store Gateway    Compactor       │
  │              (serves old      (downsample     │
  │               blocks)          + compact)     │
  │                     │                         │
  └──────┐              │                         │
         ▼              ▼                         │
       Thanos Query ◄───┘                         │
         ▲  (federates sidecar + store gateway,   │
         │   deduplicates, single PromQL API)     │
       Grafana                                    │
```

### Logs Pipeline

Alloy runs as a DaemonSet on every node. It discovers pods via the Kubernetes API, reads their stdout/stderr logs, enriches them with labels (namespace, pod, container, node, app), and pushes to Loki with `tenant_id = "homelab"`.

Loki runs in SingleBinary mode — one pod handling ingestion, storage, and queries. It writes a local WAL to NVMe, then flushes chunks to SeaweedFS S3. Retention is 30 days.

```
Pods (stdout/stderr)
  │
  ▼
Alloy DaemonSet (every node)
  │  discovers pods, reads logs, adds labels
  │  POST /loki/api/v1/push  (X-Scope-OrgID: homelab)
  ▼
Loki SingleBinary (WAL on NVMe)
  │  flushes chunks
  ▼
SeaweedFS S3 (loki-chunks)
  ▲
  │  LogQL queries
Grafana
```

### Traces Pipeline

Traces are opt-in. Applications instrumented with OpenTelemetry send OTLP data to Alloy, which forwards it to Tempo. Alloy listens on `:4317` (gRPC) and `:4318` (HTTP) for any app that emits traces.

Tempo stores trace data in a local WAL, then flushes to SeaweedFS S3. Retention is 7 days.

```
Apps (OpenTelemetry instrumented)
  │  OTLP gRPC (:4317) or HTTP (:4318)
  ▼
Alloy DaemonSet
  │  forwards via OTLP gRPC
  ▼
Tempo Monolithic (WAL on NVMe)
  │  flushes traces
  ▼
SeaweedFS S3 (tempo-traces)
  ▲
  │  TraceQL queries
Grafana
```

### Key Differences

| | Metrics | Logs | Traces |
|---|---------|------|--------|
| **Collection** | Pull (Prometheus scrapes) | Push (Alloy ships) | Push (apps emit OTLP) |
| **Query language** | PromQL | LogQL | TraceQL |
| **Retention** | 180 days (downsampled) | 30 days | 7 days |
| **Hot storage** | Prometheus PVC (3d) | Loki WAL | Tempo WAL |
| **Cold storage** | thanos-metrics bucket | loki-chunks bucket | tempo-traces bucket |

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
| Tempo HTTP | http://tempo.monitoring.svc:3200 |
| Tempo OTLP gRPC | tempo.monitoring.svc:4317 |
| Tempo OTLP HTTP | http://tempo.monitoring.svc:4318 |
| Alertmanager | http://kube-prometheus-stack-alertmanager.monitoring.svc:9093 |

## Docker Host Monitoring (Alloy via Komodo)

In addition to the K8s Alloy DaemonSet, Grafana Alloy runs on all 6 Docker hosts (managed by [Komodo](/docker/README.md)). Each host collects:

- **Host metrics**: CPU, memory, disk, network via embedded node_exporter
- **Container metrics**: per-container resource usage via embedded cAdvisor
- **Container logs**: stdout/stderr from all Docker containers

Data is pushed to the K8s observability stack via the external write endpoints below. All Docker metrics include `source="docker"` and `instance=<hostname>` labels for filtering in Grafana.

Alloy compose and config: `docker/stacks/shared/alloy/compose.yaml`
Per-host credentials: `docker/stacks/shared/alloy/.sops.env` (SOPS-encrypted)

## External Write Endpoints

Authenticated Ingress endpoints allow external Docker hosts to push metrics and logs into the K8s observability stack. Both use basic auth (`monitoring-basic-auth` secret) and `pathType: Exact` to restrict access to write-only paths — no query endpoints are exposed.

| Endpoint | URL | Backend | Purpose |
|----------|-----|---------|---------|
| Prometheus remote-write | `https://prometheus.sharmamohit.com/api/v1/write` | prometheus:9090 | Metrics ingestion from Docker Alloy |
| Loki push | `https://loki.sharmamohit.com/loki/api/v1/push` | loki:3100 | Log ingestion from Docker Alloy |

**Prometheus remote-write receiver**: Enabled via `enableRemoteWriteReceiver: true` in kube-prometheus-stack, which passes the `--web.enable-remote-write-receiver` flag to Prometheus.

**Ingress annotations** (both):
- `auth-type: basic` + `auth-secret: monitoring-basic-auth`
- `force-ssl-redirect: true` (ensure credentials are never sent over plain HTTP)
- `proxy-body-size: 10m` (accommodate metric/log batches)
- `proxy-read-timeout: 300` (allow slow remote-write flushes)
- No TLS section — wildcard cert handled by ingress-nginx `default-ssl-certificate`

**Verification**:
```bash
# Prometheus remote-write accepts POSTs (400 = active, not 405)
curl -u alloy:<password> -X POST https://prometheus.sharmamohit.com/api/v1/write
# Loki push (expect 400 or 204, not 401)
curl -u alloy:<password> -H "X-Scope-OrgID: homelab" -X POST https://loki.sharmamohit.com/loki/api/v1/push
# Auth blocks unauthenticated (expect 401)
curl -X POST https://prometheus.sharmamohit.com/api/v1/write
```

## S3 Backend (SeaweedFS on TrueNAS)

SeaweedFS runs inside a VM on TrueNAS, providing S3-compatible object storage over the LAN for long-term observability data.

- **Host**: TrueNAS (VM running SeaweedFS)
- **Endpoint**: http://seaweedfs.sharmamohit.com:8333
- **IAM Identity**: observability (Read/Write/List)
- **Buckets**: thanos-metrics, loki-chunks, loki-ruler, tempo-traces

## Secrets

SOPS-encrypted secrets in `kubernetes/infrastructure/configs/`:

| Secret | Namespace | Keys | Used By |
|--------|-----------|------|---------|
| `seaweedfs-s3-secret` | monitoring | `aws-access-key-id`, `aws-secret-access-key` | Loki, Tempo (via env vars) |
| `thanos-objstore-secret` | monitoring | `objstore.yml` | Prometheus Thanos sidecar, Thanos components |
| `monitoring-basic-auth` | monitoring | `auth` (htpasswd) | Ingress basic auth for external write endpoints |

**Credential rotation note**: The `seaweedfs-s3-secret` and `thanos-objstore-secret` both contain the same SeaweedFS observability IAM credentials. When rotating credentials, update **both** secrets, then re-encrypt with SOPS.

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

- **Pod Security Standards**: `monitoring` namespace enforces `privileged` PSS (required by node-exporter: hostNetwork, hostPID, hostPath) with `baseline` warnings
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
cd kubernetes/infrastructure/configs/
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
kubectl port-forward -n monitoring svc/tempo 3200
# Visit http://localhost:3200/ready
```
