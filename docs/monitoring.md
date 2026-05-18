# Phase 3: K8s Observability Stack Deployment

## Overview

Full metrics/logs/traces observability stack deployed in the `monitoring` namespace via ArgoCD, with long-term storage on a SeaweedFS S3 VM hosted on the `r720xd` Proxmox node.

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
│  r720xd (Proxmox) ── SeaweedFS VM ── S3 :8333 ── seaweedfs.sharmamohit.com │
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

## Alerting

All alert notifications are delivered to Slack via Grafana Alerting:

```
Grafana rules → Grafana contact point → Slack (#homelab-alerts)
```

### Grafana Alerting (Slack)

Grafana evaluates its own alert rules against the Thanos datasource (`uid: thanos`) and sends notifications to Slack via a provisioned contact point. Configuration is in `kubernetes/apps/argocd-apps/apps/kube-prometheus-stack.yaml` under `grafana.alerting`.

**18 rules** across 4 folders:

| Folder | Eval Interval | Rules |
|--------|---------------|-------|
| Infra Node Health | 60s | InfraHostDown, FilesystemSpaceLow, FilesystemSpaceCritical, FilesystemWillFillIn24h, HighMemoryUsage, HighCpuLoad |
| Infra SMART Health | 60s | SmartDiskUnhealthy, SmartReallocatedSectorsGrowing, SmartPendingSectorsGrowing, SmartDiskTemperatureHigh, SmartDiskTemperatureCritical, SmartNvmeMediaErrors, SmartNvmeCriticalWarning, SmartExporterDown |
| Infra ZFS Health | 30s | ZfsPoolDegraded, ZfsPoolFaulted, ZfsPoolUnavail |
| Infra Watchdog | 60s | GrafanaAlertingWatchdog |

The watchdog rule (`vector(1)`) fires continuously to verify the Grafana→Slack pipeline is working. If the periodic notification stops, the pipeline is broken.

### Alertmanager

Alertmanager is still deployed but only routes Prometheus-generated alerts to the `"null"` receiver (silencing them). All notification delivery is handled by Grafana Alerting via Slack.

### Threshold Sync Requirement

Prometheus rules and Grafana rules monitor the same metrics with the same thresholds. **Changing a threshold in one place without the other causes drift.** Both are defined in the same file (`kube-prometheus-stack.yaml`), with a comment block marking this dependency.

### Rule UID Stability

Grafana alert rule UIDs (e.g., `infra-host-down`, `smart-temp-high`) are stable kebab-case identifiers. Changing a UID resets that rule's state history and firing timers. Avoid renaming UIDs unless necessary.

## Infrastructure Host Monitoring (Alloy)

In addition to the K8s Alloy DaemonSet, Grafana Alloy runs on all infrastructure hosts outside K8s. Each host collects:

- **Host metrics**: CPU, memory, disk, network via embedded node_exporter
- **Container metrics**: per-container resource usage via embedded cAdvisor (Docker hosts only)
- **Container logs**: stdout/stderr from all Docker containers (Docker hosts only)

Data is pushed to the K8s observability stack via the external write endpoints below. All infrastructure host metrics include `source="infra"` and `instance=<hostname>` labels for filtering in Grafana.

**Komodo-managed Alloy** (5 LAN hosts + VPS): `docker/stacks/shared/alloy/compose.yaml`, credentials in `docker/stacks/shared/alloy/.sops.env`
**Systemd Alloy** (server04, r720xd, pve03): These hosts run smartctl_exporter + Alloy on the host. server04 is bare metal (Ubuntu 22.04); r720xd and pve03 are Proxmox nodes provisioned by the `proxmox/site.yml` Ansible playbook. All three use `/etc/alloy/config.alloy` with credentials in `/etc/default/alloy-env`. The historical TrueNAS arrangement (persistent ZFS storage at `/mnt/ssdpool1/admin/`, Post Init Script) was retired when the R720XD was migrated to Proxmox on 2026-03-14 — Alloy now lives in standard `/etc/...` locations.



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

## S3 Backend (SeaweedFS VM on r720xd)

SeaweedFS runs inside a Proxmox VM on the `r720xd` node (192.168.11.15), providing S3-compatible object storage over the LAN for long-term observability data. (Originally a TrueNAS VM; migrated to Proxmox on 2026-03-14, see `docs/truenas-to-proxmox-migration-log.md`.)

- **Hypervisor**: r720xd (Proxmox VE)
- **Guest**: seaweedfs (Ubuntu 25.10, 192.168.11.133)
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
| `grafana-admin` | monitoring | `admin-user`, `admin-password` | Grafana local admin (break-glass login at `/login`) |
| `grafana-oidc` | monitoring | `oauth-client-id`, `oauth-client-secret` | Grafana PocketID SSO (env vars in pod) |

**Credential rotation note**: The `seaweedfs-s3-secret` and `thanos-objstore-secret` both contain the same SeaweedFS observability IAM credentials. When rotating credentials, update **both** secrets, then re-encrypt with SOPS.

## Grafana SSO (PocketID OIDC)

Grafana is wired to PocketID via the generic OAuth provider (config in `kubernetes/apps/argocd-apps/apps/kube-prometheus-stack.yaml` under `grafana.grafana.ini["auth.generic_oauth"]`). Config follows [PocketID's official Grafana guide](https://pocket-id.org/docs/client-examples/grafana) with two deliberate departures noted below.

- **Login page**: `/login` shows the "Sign in with PocketID" button alongside the local username/password form. `auto_login: false` keeps the local admin (`grafana-admin` secret) as break-glass.
- **Callback URL** (register in PocketID): `https://grafana.sharmamohit.com/login/generic_oauth`
- **Role mapping** (via the `groups` claim from PocketID — these must match the group's **Name** field, which is what PocketID puts in the claim, *not* the Friendly Name):
  - `grafana_admins` → Admin
  - `grafana_editors` → Editor
  - anything else → **rejected** (`role_attribute_strict: true`, JMESPath fallback is empty)
- **Auto-provisioning**: `allow_sign_up: true`. PocketID is the access gate via "Allowed User Groups" on the OIDC client, and `role_attribute_strict` ensures only users in one of the two role groups get in (no silent default-Viewer). Grafana doesn't keep a parallel user roster.

### PocketID quirks vs vanilla OIDC

- `api_url` is intentionally omitted: PocketID returns all claims in the ID token, so Grafana doesn't need a `/userinfo` round-trip.
- `email_attribute_name: "email:primary"` is PocketID's recommended idiom (Grafana's primary-email helper) rather than `email_attribute_path: email`.
- `login_attribute_path` / `name_attribute_path` left to defaults per PocketID guide.
- **Departure from PocketID guide**: `signout_redirect_url` set so Grafana logout also ends the PocketID session (true SSO logout) — guide says leave empty (Grafana-only logout).
- **Departure from PocketID guide**: `allow_sign_up: true` (guide says disabled). PocketID is already the access gate; duplicating the user roster in Grafana adds friction without security. Paired with `role_attribute_strict: true` so the gate still has teeth.

### Bootstrap

1. In PocketID UI (`https://pocketid.proxy.sharmamohit.com`), create a new OIDC client:
   - Callback URL: `https://grafana.sharmamohit.com/login/generic_oauth`
   - Scopes requested by Grafana: `openid profile email groups`
   - Allowed user groups: restrict here.
2. Create `grafana_admins` and/or `grafana_editors` groups in PocketID and assign users. Use those underscored strings in the group's **Name** field (the claim value); the Friendly Name shown in the UI can be anything. The `role_attribute_path` matches against the Name exactly (case-sensitive).
3. Fill in the real client credentials:
   ```bash
   sops kubernetes/infrastructure/configs/grafana-oidc-secret.yaml
   # replace REPLACE_WITH_POCKETID_CLIENT_ID and REPLACE_WITH_POCKETID_CLIENT_SECRET
   ```
4. Commit. Flux applies the secret, ArgoCD picks up the helm value changes and restarts the Grafana pod. Users are auto-provisioned in Grafana on their first successful sign-in.

### Troubleshooting

- **Sign-in rejected after PocketID redirect with "user does not have a role" / no-role error**: expected when the user isn't in `grafana_admins` or `grafana_editors`. Either add them to one of those PocketID groups, or loosen `role_attribute_strict` to `false` and let unmatched users default to Viewer.
- **User lands as Editor when they should be Admin (or vice versa)**: verify the group's **Name** field in PocketID is exactly `grafana_admins` / `grafana_editors` (not the Friendly Name, and not hyphenated — the claim uses the Name verbatim).
- **"You're not allowed to access this service" on the PocketID consent screen**: the OIDC client has an "Allowed User Groups" allowlist that doesn't include any group the user is in. Add the user's group to the client's Allowed User Groups (or empty the field to allow all PocketID users).

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

1. **Wave -1**: prometheus-operator-crds (the 10 `monitoring.coreos.com` CRDs; standalone chart)
2. **Wave 1**: kube-prometheus-stack (Prometheus, Grafana, Alertmanager; `crds.enabled: false`)
3. **Wave 2**: Thanos, Loki, Tempo (depend on CRDs and sidecar)
4. **Wave 3**: Alloy (depends on Loki and Tempo endpoints)

See [CRD lifecycle](#crd-lifecycle) for why CRDs are split from the main chart.

## CRD lifecycle

The 10 prometheus-operator CRDs (`Alertmanager`, `Prometheus`, `ServiceMonitor`, `PodMonitor`, `PrometheusRule`, `Probe`, `ThanosRuler`, `AlertmanagerConfig`, `PrometheusAgent`, `ScrapeConfig`) live in a dedicated ArgoCD Application — `prometheus-operator-crds` (file: `kubernetes/apps/argocd-apps/apps/prometheus-operator-crds.yaml`), separate from `kube-prometheus-stack`.

### Why they're separate

On 2026-05-16, bumping the kps chart `81.x → 85.x` failed with ArgoCD `ComparisonError: .spec.hostNetwork: field not declared in schema`. The new chart's templates render `Alertmanager`/`Prometheus` CRs with a top-level `hostNetwork` field, but the live CRDs (operator v0.88.1) didn't declare it. ArgoCD's structured-merge diff library errors out before any sync apply, so the new CRDs can never be installed by the chart itself — a chicken-and-egg.

Splitting CRDs into their own Application at lower sync-wave (`-1` vs kps's `1`) ensures CRDs upgrade first, so kps's diff against the new schema succeeds.

### Version invariant

| CRD chart range | Operator (CRD app `appVersion`) | Matches kps chart |
|---|---|---|
| 26.0.x | v0.88.x | 81.x |
| 27.0.x | v0.89.x | 82.x |
| 28.0.x | v0.90.x | 83.x, 84.x, 85.x |
| 29.0.x | v0.91.x | (future) |

CRD chart MINOR follows operator MINOR. Patch versions track operator patches (28.0.0 → v0.90.0, 28.0.1 → v0.90.1).

### Upgrade procedure

1. **Look up the operator version** for the target kps chart:
   ```bash
   helm repo update prometheus-community
   helm search repo prometheus-community/kube-prometheus-stack --versions | head -10
   ```
   The `APP VERSION` column shows the operator version.

2. **Bump the CRD app FIRST** to a `prometheus-operator-crds` chart range that matches:
   - Edit `kubernetes/apps/argocd-apps/apps/prometheus-operator-crds.yaml`
   - Update `spec.source.targetRevision`
   - Commit + push
   - Wait for the new revision to land in the cluster
   - **Trigger a hard refresh** (soft refresh uses the cached chart and won't actually apply the new CRDs):
     ```bash
     kubectl patch application -n argocd prometheus-operator-crds \
       --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
     ```
   - Verify the new operator version is on the CRD:
     ```bash
     kubectl get crd alertmanagers.monitoring.coreos.com \
       -o jsonpath='{.metadata.annotations.operator\.prometheus\.io/version}{"\n"}'
     ```

3. **Bump the kps app** to the target chart version:
   - Edit `kubernetes/apps/argocd-apps/apps/kube-prometheus-stack.yaml`
   - Update `spec.source.targetRevision`
   - Commit + push
   - Hard-refresh the kps app the same way
   - Verify operator pod rolled to the new image and `kubectl get application -n argocd kube-prometheus-stack` reports `Synced/Healthy`

### Why not just upgrade kps first?

Tried on 2026-05-16. Failed exactly as described above. The chart bundles CRDs under `charts/crds/`, but ArgoCD's diff phase runs *before* sync apply, so the new CRDs the chart would install can never reach the cluster if the diff fails.

### Pruning protection

All 10 CRDs are annotated with `argocd.argoproj.io/sync-options=Prune=false` and the CRD Application itself has `syncPolicy.automated.prune: false`. CRDs are never auto-pruned by GitOps — removal must be deliberate (manual `kubectl delete crd`). This protects against catastrophic cascade-deletion of all `ServiceMonitor` / `PrometheusRule` / etc. instances if a chart bug ever removes a CRD from its rendered manifest.

To re-apply the annotation if a CRD ever loses it (e.g., recreated by another tool):
```bash
for crd in alertmanagerconfigs alertmanagers podmonitors probes \
           prometheusagents prometheuses prometheusrules \
           scrapeconfigs servicemonitors thanosrulers; do
  kubectl annotate crd ${crd}.monitoring.coreos.com \
    argocd.argoproj.io/sync-options=Prune=false --overwrite
done
```

See `CLAUDE.md` Gotcha #8 for the short version.

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
