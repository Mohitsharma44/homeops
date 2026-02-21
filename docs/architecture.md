# Homeops Architecture

Progressive-zoom reference for the homeops infrastructure.
Each level adds detail — start at L0 for orientation, drill down as needed.

---

## L0 — Bird's Eye

```
                         ┌─────────────────────────────────────────────────────────────┐
                         │                      INTERNET                               │
                         └────────────┬──────────────────────────┬─────────────────────┘
                                      │ :80/:443                 │ :80/:443
                                      ▼                          ▼
                  ┌───────────────────────────────┐   ┌──────────────────────────────┐
                  │  VPS  (racknerd-aegis)         │   │  Homelab LAN  192.168.11.0/24│
                  │  23.94.73.98                   │   │                              │
                  │                                │   │  ┌────────────────────────┐  │
                  │  aegis-traefik ─► CrowdSec     │   │  │ K8s Cluster (3 nodes)  │  │
                  │  Pangolin + Gerbil + Traefik   │   │  │ ingress-nginx :90      │  │
                  │  PocketID + LLDAP              │   │  │ Prometheus, Loki,      │  │
                  │  Periphery (Komodo agent)      │   │  │ Grafana, Tempo, Thanos │  │
                  │  Alloy (monitoring)            │   │  │ ArgoCD, Rook-Ceph      │  │
                  │                                │   │  └────────────────────────┘  │
                  │  Pangolin Client ──WireGuard──►│◄──│◄── Newt (K8s pod)           │
                  │  (reaches K8s Prom/Loki)       │   │                              │
                  │                                │   │  ┌────────────────────────┐  │
                  │  Newt ──────────WireGuard──────►│◄──│◄── Machine Client (komodo) │
                  │  (exposes Periphery)           │   │  │  (reaches Periphery)   │  │
                  │                                │   │  └────────────────────────┘  │
                  └───────────────────────────────┘   │                              │
                                                       │  6 Docker hosts + Komodo    │
                                                       │  (details in L1)            │
                                                       └──────────────────────────────┘
```

**What is this?** A GitOps-managed homelab. Two platforms:
- **Kubernetes** — Flux bootstraps infra, ArgoCD deploys apps. 3-node Talos cluster.
- **Docker** — Komodo orchestrates 19 stacks across 7 hosts (6 LAN + 1 VPS).

**How does the VPS connect?** Pangolin WireGuard tunnels — no ports exposed for management.
Komodo reaches VPS Periphery through a private resource tunnel. VPS Alloy pushes
metrics/logs to K8s through a separate tunnel. SSH (:2244) is the emergency backdoor.

---

## L1 — Docker Hosts & Stacks

```
┌─ komodo (192.168.11.200) ─ LXC CT200 ─ Proxmox ──────────────────────────────┐
│  Periphery: systemd (native sops+age)                                         │
│  ┌──────────────┐  ┌──────────────┐  ┌─────────────────────────────────────┐  │
│  │ komodo-core  │  │ komodo-alloy │  │ Machine Client (/opt/pangolin-     │  │
│  │ Core+Ferret  │  │ Alloy→K8s    │  │ client/) reaches VPS Periphery     │  │
│  │ DB+Postgres  │  │              │  │ via periphery.private.             │  │
│  └──────────────┘  └──────────────┘  │ sharmamohit.com:8120               │  │
│                                       └─────────────────────────────────────┘  │
├───────────────────────────────────────────────────────────────────────────────┤

┌─ server04 (192.168.11.17) ─ Bare metal ───────────────────────────────────────┐
│  Periphery: Docker (periphery-sops)                                           │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────┐                      │
│  │ traefik      │  │ vaultwarden  │  │ server04-alloy │                      │
│  │ LAN reverse  │  │ Bitwarden    │  │ Alloy→K8s      │                      │
│  │ proxy :80/443│  │              │  │                │                      │
│  └──────────────┘  └──────────────┘  └────────────────┘                      │
├───────────────────────────────────────────────────────────────────────────────┤

┌─ nvr (192.168.11.89) ─ LXC ─ Proxmox ────────────────────────────────────────┐
│  Periphery: Docker (periphery-sops)                                           │
│  ┌──────────────┐  ┌──────────────┐                                           │
│  │ frigate      │  │ nvr-alloy    │                                           │
│  │ NVR+Coral TPU│  │ Alloy→K8s    │                                           │
│  └──────────────┘  └──────────────┘                                           │
├───────────────────────────────────────────────────────────────────────────────┤

┌─ kasm (192.168.11.34) ─ Bare metal ───────────────────────────────────────────┐
│  Periphery: Docker (periphery-sops)                                           │
│  ┌──────────────┐  ┌──────────────┐                                           │
│  │ newt         │  │ kasm-alloy   │  KASM Workspaces managed by installer,   │
│  │ Pangolin     │  │ Alloy→K8s    │  only Newt is Komodo-managed.            │
│  │ tunnel agent │  │              │                                           │
│  └──────────────┘  └──────────────┘                                           │
├───────────────────────────────────────────────────────────────────────────────┤

┌─ omni (192.168.11.30) ─ LXC ─ Proxmox ───────────────────────────────────────┐
│  Periphery: Docker (periphery-sops)                                           │
│  ┌──────────────┐  ┌──────────────┐                                           │
│  │ omni         │  │ omni-alloy   │                                           │
│  │ Talos mgmt   │  │ Alloy→K8s    │                                           │
│  └──────────────┘  └──────────────┘                                           │
├───────────────────────────────────────────────────────────────────────────────┤

┌─ seaweedfs (192.168.11.133) ─ TrueNAS VM ────────────────────────────────────┐
│  Periphery: Docker (periphery-sops)                                           │
│  ┌──────────────┐  ┌──────────────────┐                                       │
│  │ seaweedfs    │  │ seaweedfs-alloy  │  S3 backend for Loki, Tempo, Thanos  │
│  │ Object store │  │ Alloy→K8s        │  at seaweedfs.sharmamohit.com:8333   │
│  └──────────────┘  └──────────────────┘                                       │
├───────────────────────────────────────────────────────────────────────────────┤

┌─ racknerd-aegis (23.94.73.98) ─ VPS ─────────────────────────── 7 stacks ────┐
│  Periphery: Docker (periphery-sops) — isolated, no ports, tunnel-only access  │
│  ┌───────────────┐ ┌───────────────┐ ┌───────────────┐ ┌──────────────────┐  │
│  │ aegis-gateway │ │ aegis-pangolin│ │ aegis-identity│ │ aegis-periphery  │  │
│  │ Traefik+      │ │ Pangolin+     │ │ PocketID+     │ │ Komodo agent     │  │
│  │ CrowdSec      │ │ Gerbil+Traefik│ │ LLDAP         │ │ (network-isolatd)│  │
│  └───────────────┘ └───────────────┘ └───────────────┘ └──────────────────┘  │
│  ┌───────────────┐ ┌─────────────────────┐ ┌──────────────────────────────┐  │
│  │ aegis-newt    │ │ aegis-pangolin-client│ │ racknerd-aegis-alloy         │  │
│  │ Tunnel to own │ │ Machine Client→K8s   │ │ Alloy→K8s (via tunnel)      │  │
│  │ Pangolin      │ │ Prom+Loki routes     │ │                             │  │
│  └───────────────┘ └─────────────────────┘ └──────────────────────────────┘  │
└───────────────────────────────────────────────────────────────────────────────┘
```

### Stack inventory (19 total)

| Host | Stacks | Notes |
|------|--------|-------|
| komodo | komodo-core, komodo-alloy | + Machine Client for VPS mgmt |
| server04 | traefik, vaultwarden, server04-alloy | LAN reverse proxy |
| nvr | frigate, nvr-alloy | Coral TPU for object detection |
| kasm | newt, kasm-alloy | KASM installer-managed separately |
| omni | omni, omni-alloy | Talos Linux management |
| seaweedfs | seaweedfs, seaweedfs-alloy | S3 for Loki/Tempo/Thanos |
| racknerd-aegis | aegis-gateway, aegis-pangolin, aegis-identity, aegis-periphery, aegis-newt, aegis-pangolin-client, racknerd-aegis-alloy | VPS — 7 stacks |

All hosts run a shared Alloy stack (`docker/stacks/shared/alloy/compose.yaml`).
Per-host config via Komodo `environment` field → `INSTANCE_NAME`, `PROMETHEUS_URL`, `LOKI_URL`.

---

## L2 — Kubernetes Cluster

```
┌─ K8s Cluster (Talos Linux, 3 nodes) ─────────────────────────────────────────┐
│  Managed by: Omni (Siderolabs)                                                │
│  Bootstrap:  Flux Operator → FluxInstance CRD                                 │
│                                                                                │
│  ┌─ Flux Kustomizations (deployment chain) ────────────────────────────────┐  │
│  │                                                                          │  │
│  │  flux-system                                                             │  │
│  │    ├─► infra-controllers        ├─► infra-configs          ├─► apps      │  │
│  │    │   cert-manager (3 rep.)    │   ClusterIssuer          │   ArgoCD    │  │
│  │    │   metallb (L2)             │   *.sharmamohit.com cert │             │  │
│  │    │   ingress-nginx (:90)      │   MetalLB IPPool 88-98   │             │  │
│  │    │   rook-ceph operator       │   CephCluster + pools    │             │  │
│  │    │                            │   Monitoring ingresses   ├─► apps-cfg  │  │
│  │    │                            │   Monitoring secrets     │   root-app  │  │
│  │    │                            │   Namespaces             │   (App of   │  │
│  │    │                            │   Newt credentials       │    Apps)    │  │
│  │    │   depends: nothing         │   depends: controllers   │   dep: apps │  │
│  └────┴────────────────────────────┴──────────────────────────┴─────────────┘  │
│                                                                                │
│  ┌─ ArgoCD Applications (monitoring project) ──────────────────────────────┐  │
│  │                                                                          │  │
│  │  wave 1: kube-prometheus-stack                                           │  │
│  │    Prometheus (20Gi, 3d, remote_write receiver, Thanos sidecar)          │  │
│  │    Grafana (grafana.sharmamohit.com, Thanos+Loki+Tempo datasources)     │  │
│  │    AlertManager (1Gi, 120h)                                              │  │
│  │                                                                          │  │
│  │  wave 2: loki (SingleBinary, S3→seaweedfs, 720h, auth=true)             │  │
│  │  wave 2: thanos (Query, StoreGateway, Compactor, S3→seaweedfs)          │  │
│  │  wave 2: tempo (S3→seaweedfs, OTLP gRPC:4317 + HTTP:4318, 168h)        │  │
│  │                                                                          │  │
│  │  wave 3: alloy (DaemonSet, pod logs→Loki, OTLP traces→Tempo)           │  │
│  │                                                                          │  │
│  │  (no wave): newt (ns: pangolin, Helm chart, connects to VPS Pangolin)   │  │
│  └──────────────────────────────────────────────────────────────────────────┘  │
│                                                                                │
│  ┌─ Storage ───────────────────────────────────────────────────────────────┐  │
│  │  Rook-Ceph: useAllNodes, useAllDevices, failureDomain=host, 3x repl.   │  │
│  │  StorageClass: ceph-block (default, RBD)                                │  │
│  │  CephFileSystem, CephObjectStore also available                         │  │
│  └──────────────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────────────┘
```

---

## L3 — VPS Network Segmentation

This is the most complex host. Four Docker networks enforce isolation —
a compromised public container cannot reach Periphery or LLDAP.

```
INTERNET ──► :80/:443                     :51820/udp  :21820/udp
             │                                │            │
┌────────────┼────────────────────────────────┼────────────┼────────────────┐
│ VPS        │                                │            │                │
│            ▼                                ▼            ▼                │
│  ┌─── traefik-public (external network) ─────────────────────────────┐   │
│  │                                                                    │   │
│  │  aegis-traefik ◄──► aegis-crowdsec        gerbil ◄────────────┐   │   │
│  │  :80 :443           reads traefik logs    :51820  :21820      │   │   │
│  │  TLS (Route53       CrowdSec bouncer      WireGuard mgr      │   │   │
│  │  DNS01 ACME)        feeds ban decisions   NAT hole punch      │   │   │
│  │                                                                │   │   │
│  └────────────────────────────────────────────────────────────────┘   │
│                                                        │              │
│                                              gerbil bridges           │
│                                              both networks            │
│                                                        │              │
│  ┌─── pangolin-internal (external network) ────────────┼──────────┐   │
│  │                                                     │          │   │
│  │  pangolin           gerbil ◄────────────────────────┘          │   │
│  │  tunnel mgmt        (also on traefik-public)                   │   │
│  │  :3001 (API)                                                   │   │
│  │                     pangolin-traefik                            │   │
│  │                     network_mode: service:gerbil                │   │
│  │                     (shares gerbil's network namespace —        │   │
│  │                      inherits both networks, no own interface)  │   │
│  │                                                                 │   │
│  │  pocketid ◄─────────────────────────────────────────────┐      │   │
│  │  OIDC provider                                          │      │   │
│  │  https://pocketid.proxy.sharmamohit.com                 │      │   │
│  │  (routed via pangolin-traefik)                    bridges│      │   │
│  └─────────────────────────────────────────────────────┼───┘      │
│                                                        │          │
│  ┌─── identity-internal (bridge network) ──────────────┼──────┐   │
│  │                                                     │      │   │
│  │  lldap              pocketid ◄──────────────────────┘      │   │
│  │  LDAP directory     (also on pangolin-internal)            │   │
│  │  :3890 (LDAP)       talks to lldap:3890                    │   │
│  │  :17170 (web/health)                                       │   │
│  │                                                             │   │
│  │  ⚠ lldap is ONLY on this network — NOT reachable from      │   │
│  │    pangolin-internal or traefik-public                      │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  ┌─── newt-periphery (external network) ───────────────────────┐   │
│  │                                                              │   │
│  │  pangolin-newt           periphery                           │   │
│  │  (fosrl/newt)            (komodo-periphery-sops)             │   │
│  │  connects to own         Komodo management agent             │   │
│  │  Pangolin via WAN        NO ports published                  │   │
│  │                          docker.sock + age key               │   │
│  │  Newt reaches            only reachable by Newt              │   │
│  │  periphery:8120          via Docker DNS                      │   │
│  │  via Docker DNS                                              │   │
│  │                                                              │   │
│  │  ⚠ periphery is ONLY on this network — completely isolated   │   │
│  │    from all public-facing containers                         │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  ┌─── host network ────────────────────────────────────────────┐   │
│  │                                                              │   │
│  │  pangolin-client-obs     racknerd-aegis-alloy                │   │
│  │  (fosrl/pangolin-cli)    (grafana/alloy)                     │   │
│  │  Machine Client          network_mode: host                  │   │
│  │  WireGuard tunnel to     pushes to K8s via tunnel:           │   │
│  │  K8s private resources   k8s-prometheus.private...:9090      │   │
│  │  NET_ADMIN + /dev/tun    k8s-loki.private...:3100            │   │
│  └──────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

### Container → Network matrix

| Container | traefik-public | pangolin-internal | identity-internal | newt-periphery | host |
|-----------|:-:|:-:|:-:|:-:|:-:|
| aegis-traefik | **X** | | | | |
| aegis-crowdsec | **X** | | | | |
| gerbil | **X** | **X** | | | |
| pangolin | | **X** | | | |
| pangolin-traefik | *(via gerbil)* | *(via gerbil)* | | | |
| pocketid | | **X** | **X** | | |
| lldap | | | **X** | | |
| pangolin-newt | | | | **X** | |
| periphery | | | | **X** | |
| pangolin-client-obs | | | | | **X** |
| alloy | | | | | **X** |

### Security boundaries

```
Can a compromised container reach...       Periphery?  LLDAP?  Pangolin DB?
─────────────────────────────────────────  ──────────  ──────  ────────────
aegis-traefik (internet-facing)            NO          NO      NO
aegis-crowdsec                             NO          NO      NO
gerbil (WireGuard, internet-facing)        NO          NO      YES (same net)
pangolin-traefik (via gerbil netns)        NO          NO      YES (same net)
pocketid                                   NO          YES     YES (same net)
lldap                                      NO          -       NO
pangolin-newt                              YES (same)  NO      NO
```

---

## L4 — Pangolin Tunnel Topology

Two independent tunnel paths. Pangolin is control plane only —
data flows peer-to-peer via WireGuard (or Gerbil relay if hole punch fails).

```
┌─ Path 1: Komodo → VPS Periphery (management) ─────────────────────────────┐
│                                                                             │
│  komodo (192.168.11.200)              VPS (23.94.73.98)                    │
│  ┌─────────────────────┐              ┌─────────────────────┐              │
│  │ Machine Client      │  WireGuard   │ pangolin-newt       │              │
│  │ /opt/pangolin-client│◄────────────►│ (newt-periphery net)│              │
│  │ network_mode: host  │  peer-to-peer│                     │              │
│  └─────────┬───────────┘  (or relay)  └─────────┬───────────┘              │
│            │                                     │ Docker DNS               │
│            │ WireGuard route installed            │                          │
│            │ on komodo host network               ▼                          │
│            │                           ┌─────────────────────┐              │
│            │                           │ periphery :8120     │              │
│            ▼                           │ (newt-periphery net)│              │
│  Komodo Core connects to               │ NO ports published  │              │
│  periphery.private.                    └─────────────────────┘              │
│  sharmamohit.com:8120                                                       │
│                                                                             │
│  Pangolin role: peer discovery + credential validation only                 │
│  Data path: Machine Client ◄─WireGuard─► Newt (direct or relayed)         │
└─────────────────────────────────────────────────────────────────────────────┘

┌─ Path 2: VPS Alloy → K8s Prometheus/Loki (observability) ──────────────────┐
│                                                                             │
│  VPS (23.94.73.98)                    K8s Cluster                          │
│  ┌─────────────────────┐              ┌─────────────────────┐              │
│  │ pangolin-client-obs │  WireGuard   │ Newt (K8s pod)      │              │
│  │ (Machine Client)    │◄────────────►│ ns: pangolin        │              │
│  │ network_mode: host  │  peer-to-peer│ Helm chart (ArgoCD) │              │
│  └─────────┬───────────┘  (or relay)  └─────────┬───────────┘              │
│            │                                     │ K8s service DNS           │
│            │ WireGuard route + DNS proxy          │                          │
│            │ installed on VPS host network         ▼                          │
│            │                           ┌─────────────────────┐              │
│            ▼                           │ prometheus :9090    │              │
│  Alloy pushes metrics to               │ loki :3100          │              │
│  k8s-prometheus.private.               │ (monitoring ns)     │              │
│  sharmamohit.com:9090                  └─────────────────────┘              │
│  k8s-loki.private.                                                          │
│  sharmamohit.com:3100                                                       │
│                                                                             │
│  ⚠ VPS→K8s hole punch fails (VPS is its own Pangolin) — uses Gerbil relay │
│  RTT: ~2-5s. Acceptable for async metrics/logs push.                       │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Private resource DNS names

| DNS Name | Resolves Via | Target | Used By |
|----------|-------------|--------|---------|
| `periphery.private.sharmamohit.com:8120` | komodo Machine Client | VPS Periphery | Komodo Core |
| `k8s-prometheus.private.sharmamohit.com:9090` | VPS Machine Client | K8s Prometheus | VPS Alloy |
| `k8s-loki.private.sharmamohit.com:3100` | VPS Machine Client | K8s Loki | VPS Alloy |

### Circular dependency & emergency recovery

```
Pangolin crash on VPS
  → Newt loses connection
    → Periphery unreachable via tunnel
      → Komodo cannot redeploy Pangolin
        → STUCK

Emergency backdoor: SSH on port 2244
  ssh hs "docker restart gerbil && docker restart pangolin-newt"
```

---

## L5 — Observability Pipeline

```
┌─ METRICS ──────────────────────────────────────────────────────────────────┐
│                                                                            │
│  6 LAN Docker hosts                    VPS (racknerd-aegis)               │
│  ┌──────────────────┐                  ┌──────────────────────────┐       │
│  │ Alloy (per host) │                  │ Alloy                    │       │
│  │ ┌──────────────┐ │                  │ ┌──────────────┐         │       │
│  │ │ node_exporter│ │                  │ │ node_exporter│         │       │
│  │ │ cAdvisor     │ │                  │ │ cAdvisor     │         │       │
│  │ └──────┬───────┘ │                  │ └──────┬───────┘         │       │
│  │        │ relabel  │                  │        │ relabel         │       │
│  │        │ instance │                  │        │ instance        │       │
│  │        │ =host    │                  │        │ =racknerd-aegis │       │
│  │        ▼          │                  │        ▼                 │       │
│  │  remote_write ────┼──── HTTPS ──────►│  remote_write ──────────┼───┐   │
│  │  basic auth       │  public ingress  │  basic auth             │   │   │
│  └──────────────────┘  prometheus.      └──────────────────────────┘   │   │
│                         sharmamohit.com          WireGuard tunnel      │   │
│                         /api/v1/write            k8s-prometheus.       │   │
│                              │                   private...            │   │
│                              │                   /api/v1/write         │   │
│                              │                        │                │   │
│                              ▼                        ▼                │   │
│                     ┌─────────────────────────────────────┐            │   │
│                     │ K8s Prometheus (monitoring ns)       │            │   │
│                     │ 20Gi ceph-block, 3d retention        │            │   │
│                     │ remote_write receiver enabled        │            │   │
│                     │ Thanos sidecar → long-term storage   │            │   │
│                     └───────────┬─────────────────────────┘            │   │
│                                 ▼                                      │   │
│                     ┌─────────────────────────────────────┐            │   │
│                     │ Thanos (Query + StoreGateway +       │            │   │
│                     │ Compactor) → S3 at seaweedfs:8333    │            │   │
│                     │ Retention: raw=7d, 5m=30d, 1h=180d  │            │   │
│                     └─────────────────────────────────────┘            │   │
│                                                                        │   │
│  All metrics carry: source="docker", instance="<INSTANCE_NAME>"       │   │
│  job="node" (host metrics), job="cadvisor" (container metrics)         │   │
└────────────────────────────────────────────────────────────────────────┘

┌─ LOGS ─────────────────────────────────────────────────────────────────────┐
│                                                                            │
│  6 LAN Docker hosts                    VPS (racknerd-aegis)               │
│  ┌──────────────────┐                  ┌──────────────────────────┐       │
│  │ Alloy (per host) │                  │ Alloy                    │       │
│  │ discovery.docker  │                  │ discovery.docker          │       │
│  │ → container name │                  │ → container name         │       │
│  │ → image name     │                  │ → image name             │       │
│  │ → instance=host  │                  │ → instance=racknerd-aegis│       │
│  │        │          │                  │        │                 │       │
│  │        ▼          │                  │        ▼                 │       │
│  │  loki.write ──────┼──── HTTPS ──────►│  loki.write ────────────┼───┐   │
│  │  tenant=homelab   │  loki.           │  tenant=homelab         │   │   │
│  │  basic auth       │  sharmamohit.com │  basic auth             │   │   │
│  └──────────────────┘  /loki/api/v1/   └──────────────────────────┘   │   │
│                         push                     WireGuard tunnel      │   │
│                              │                   k8s-loki.private...   │   │
│                              │                   /loki/api/v1/push     │   │
│                              ▼                        │                │   │
│                     ┌─────────────────────────────────────┐            │   │
│                     │ K8s Loki (monitoring ns)             │            │   │
│                     │ SingleBinary mode, auth_enabled=true │            │   │
│                     │ 10Gi ceph-block, 720h retention      │            │   │
│                     │ S3 backend → seaweedfs:8333          │            │   │
│                     └─────────────────────────────────────┘            │   │
│                                                                        │   │
│  K8s pod logs collected separately by K8s Alloy DaemonSet              │   │
│  (ArgoCD app, wave 3) — discovery.kubernetes → Loki                    │   │
└────────────────────────────────────────────────────────────────────────┘

┌─ TRACES ───────────────────────────────────────────────────────────────────┐
│                                                                            │
│  K8s Alloy DaemonSet (monitoring ns)                                      │
│  OTLP receiver gRPC:4317 + HTTP:4318 → Tempo                             │
│  Tempo: S3→seaweedfs:8333, 168h retention, 10Gi ceph-block               │
│                                                                            │
│  Docker hosts do NOT emit traces (no OTLP instrumentation).               │
└────────────────────────────────────────────────────────────────────────────┘

┌─ VISUALIZATION ────────────────────────────────────────────────────────────┐
│                                                                            │
│  Grafana (grafana.sharmamohit.com)                                        │
│  Datasources:                                                              │
│    Thanos  → long-term metrics (queries Prometheus + S3 via StoreGateway) │
│    Loki    → logs (all Docker + K8s pod logs, tenant=homelab)             │
│    Tempo   → traces (K8s only)                                             │
│                                                                            │
└────────────────────────────────────────────────────────────────────────────┘
```

---

## L6 — GitOps & Deployment Flow

```
┌─ KUBERNETES ───────────────────────────────────────────────────────────────┐
│                                                                            │
│  Developer                                                                 │
│    │ git push                                                              │
│    ▼                                                                       │
│  GitHub (mohitsharma44/homeops)                                           │
│    │                                                                       │
│    ├──► Flux (watches repo via GitHub App)                                 │
│    │      ├─ infra-controllers/  → HelmReleases (cert-manager, metallb..) │
│    │      ├─ infra-configs/      → CRDs, secrets, certs                   │
│    │      └─ apps/               → ArgoCD HelmRelease                     │
│    │                                                                       │
│    └──► ArgoCD (watches kubernetes/apps/argocd-apps/apps/)                │
│           └─ root-app (App of Apps, auto-sync, prune, selfHeal)           │
│              ├─ kube-prometheus-stack                                       │
│              ├─ loki, thanos, tempo                                        │
│              ├─ alloy (K8s DaemonSet)                                      │
│              └─ newt (Pangolin tunnel)                                     │
│                                                                            │
│  Secrets: SOPS-encrypted *secret.yaml, Flux decrypts in-cluster           │
└────────────────────────────────────────────────────────────────────────────┘

┌─ DOCKER ───────────────────────────────────────────────────────────────────┐
│                                                                            │
│  Developer                                                                 │
│    │ git push                                                              │
│    ▼                                                                       │
│  GitHub (mohitsharma44/homeops)                                           │
│    │                                                                       │
│    └──► km execute sync 'mohitsharma44/homeops'                           │
│           │                                                                │
│           ▼                                                                │
│         Komodo Core (komodo:9120)                                         │
│           │ reads docker/komodo-resources/*.toml                           │
│           │                                                                │
│           ├─ servers.toml    → 7 server definitions                       │
│           ├─ builds.toml     → periphery-custom image build               │
│           ├─ procedures.toml → scheduled + manual deploy procedures       │
│           └─ stacks-*.toml   → 19 stack definitions                       │
│                │                                                           │
│                ▼ deploy-stack or deploy-all-stacks                         │
│         Periphery agent on target host                                     │
│           │ 1. git clone/pull repo                                         │
│           │ 2. pre_deploy: sops-decrypt.sh (*.sops.env → *.env)           │
│           │ 3. docker compose up -d                                        │
│           │                                                                │
│           │ Komodo environment field → project .env                        │
│           │ (INSTANCE_NAME, PROMETHEUS_URL, LOKI_URL)                      │
│           │ compose ${VAR:-default} interpolation reads from it            │
│           │                                                                │
│  Secrets: SOPS-encrypted .sops.env/.sops.json next to compose files       │
│           Decrypted at deploy time by Periphery, never committed plain    │
└────────────────────────────────────────────────────────────────────────────┘

┌─ DEPLOYMENT PROCEDURES ───────────────────────────────────────────────────┐
│                                                                            │
│  Scheduled (automatic):                                                    │
│    01:00  Backup Core Database                                            │
│    04:00  Rebuild Periphery Image (periphery-custom on server04)          │
│    05:00  Global Auto Update (pull latest images, redeploy if changed)    │
│                                                                            │
│  Manual:                                                                   │
│    deploy-all-stacks                                                       │
│      1. traefik (Infrastructure First)                                     │
│      2. BatchDeployIfChanged * (excludes: komodo-core, aegis-pangolin,    │
│         aegis-newt, aegis-periphery, aegis-pangolin-client)               │
│                                                                            │
│    deploy-vps-infra (ordered — dependency chain)                           │
│      1. aegis-gateway        (CrowdSec + public Traefik)                  │
│      2. aegis-pangolin       (tunnel server — depends on gateway TLS)     │
│      3. aegis-newt           (tunnel agent — depends on Pangolin)         │
│      4. aegis-periphery      (Komodo agent — depends on Newt network)    │
│      5. aegis-pangolin-client (obs tunnel — depends on Pangolin)          │
│      6. aegis-identity + racknerd-aegis-alloy (parallel, leaf services)   │
│                                                                            │
│  ⚠ Excluded stacks must NEVER be batch-deployed:                          │
│    komodo-core         — self-restart kills the deployer                   │
│    aegis-pangolin/newt — severs the tunnel Komodo uses to reach VPS       │
│    aegis-periphery     — severs management on VPS                         │
│    aegis-pangolin-client — severs observability tunnel                     │
└────────────────────────────────────────────────────────────────────────────┘
```

---

## L7 — Secret Management

```
┌─ SOPS + age (single key pair) ─────────────────────────────────────────────┐
│                                                                            │
│  Public key: age1y6dnshya496nf3072zudw3vd33723v02g3tfvpt563zng0xd9ghqwzj5xk│
│  Config:     .sops.yaml (repo root)                                        │
│                                                                            │
│  Private key locations:                                                    │
│    ~/.sops/key.txt                       developer laptop                  │
│    /etc/sops/age/keys.txt                all 7 Docker hosts (root:root 600)│
│    sops-age secret (flux-system ns)      K8s cluster                       │
│                                                                            │
│  Encryption targets:                                                       │
│    K8s:    *secret.yaml files            Flux decrypts in-cluster          │
│    Docker: .sops.env / .sops.json        Periphery decrypts at deploy     │
│                                                                            │
│  Pre-commit hooks block unencrypted secrets from being committed.          │
│                                                                            │
│  Docker decrypt flow:                                                      │
│    Komodo deploy → pre_deploy hook → sops-decrypt.sh on Periphery          │
│    *.sops.env → *.env   (compose reads via env_file: .env)                │
│    *.sops.json → *.json (compose reads via volume/config)                  │
│                                                                            │
│  Stacks WITHOUT secrets (no pre_deploy): frigate, aegis-periphery          │
│  All others have .sops.env with credentials.                               │
└────────────────────────────────────────────────────────────────────────────┘
```

---

## Quick Reference

### Network cheat sheet

| Network | Subnet | Key endpoints |
|---------|--------|---------------|
| LAN | 192.168.11.0/24 | All homelab hosts |
| MetalLB | 192.168.11.88-98 | K8s LoadBalancer services |
| K8s Ingress | 192.168.11.90 | *.sharmamohit.com |
| VPS public | 23.94.73.98 | *.proxy.sharmamohit.com |
| Pangolin private | *.private.sharmamohit.com | WireGuard tunnel resources |

### DNS cheat sheet

| Domain | Points to |
|--------|-----------|
| `*.sharmamohit.com` | K8s ingress (192.168.11.90) |
| `*.proxy.sharmamohit.com` | VPS Traefik (23.94.73.98) |
| `*.private.sharmamohit.com` | Pangolin private resources (WireGuard) |
| `komodo.sharmamohit.com:9120` | Komodo Core API (HTTP) |

### Port cheat sheet

| Port | Protocol | Service |
|------|----------|---------|
| 80, 443 | TCP | Traefik (LAN + VPS) |
| 8120 | TCP/TLS | Periphery agents (all hosts) |
| 9120 | TCP/HTTP | Komodo Core API |
| 51820 | UDP | Gerbil WireGuard (primary) |
| 21820 | UDP | Gerbil WireGuard (relay) |
| 2244 | TCP | SSH to VPS (emergency backdoor) |
| 8333 | TCP | SeaweedFS S3 API |

### Emergency procedures

| Scenario | Action |
|----------|--------|
| VPS tunnel down | `ssh hs "docker restart gerbil && docker restart pangolin-newt"` |
| Komodo can't reach VPS | Check Machine Client: `ssh root@komodo "docker logs pangolin-client"` |
| All VPS containers down | SSH in: `ssh hs "docker ps -a"` then restart manually |
| Need to redeploy VPS | `km execute deploy-vps-infra` (ordered procedure) |
| Komodo self-update | See `docker/CLAUDE.md` — Updating Komodo section |
