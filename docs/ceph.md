# Rook-Ceph Storage

## Overview

Distributed storage via Rook-Ceph, providing block, filesystem, and object storage to the cluster. Deployed by Flux in the `rook-ceph` namespace.

## Deployment Structure

Rook-Ceph is split into three parts to avoid Helm lifecycle issues with immutable StorageClass fields:

| Part | Managed By | Location |
|------|-----------|----------|
| Rook operator (v1.19.x) | Flux HelmRelease | `kubernetes/infrastructure/controllers/rook-ceph/` |
| CephCluster | Flux HelmRelease (`rook-ceph-cluster`) | `kubernetes/infrastructure/configs/ceph-cluster.yaml` |
| Storage resources | Flux Kustomization (standalone YAML) | `kubernetes/infrastructure/configs/ceph/` |

**Why standalone manifests?** StorageClass parameters (like `region`) are immutable in Kubernetes. When the Helm chart renders a StorageClass with different parameters during an upgrade, `helm upgrade` fails. By managing CephBlockPool, CephFilesystem, CephObjectStore, and their StorageClasses as standalone manifests outside Helm, Flux applies them independently and avoids this problem.

## Storage Resources

```
kubernetes/infrastructure/configs/ceph/
├── ceph-blockpool.yaml        # CephBlockPool + ceph-block StorageClass (default)
├── ceph-filesystem.yaml       # CephFilesystem + SubVolumeGroup + ceph-filesystem StorageClass
├── ceph-objectstore.yaml      # CephObjectStore (erasure-coded) + ceph-bucket StorageClass
├── ceph-objectstore-user.yaml # CephObjectStoreUser for S3 API access
└── kustomization.yaml
```

### StorageClasses

| StorageClass | Type | Provisioner | Replication | Default |
|-------------|------|-------------|-------------|---------|
| `ceph-block` | RBD (block) | `rook-ceph.rbd.csi.ceph.com` | 3x replicated | Yes |
| `ceph-filesystem` | CephFS (shared) | `rook-ceph.cephfs.csi.ceph.com` | 3x replicated | No |
| `ceph-bucket` | RGW (S3 object) | `rook-ceph.ceph.rook.io/bucket` | Erasure coded (2+1) | No |

All StorageClasses have `allowVolumeExpansion: true` and `reclaimPolicy: Delete`.

### Object Store

The CephObjectStore uses erasure coding (2 data + 1 coding chunk) for the data pool and 3x replication for metadata — more storage-efficient than full replication for bulk object data.

- **RGW gateway**: 1 instance, port 80
- **S3 user**: `s3user` with full bucket access + read-only metadata/usage
- **Region**: `ca-west-1`

## Cluster Configuration

- **Nodes**: All nodes (`useAllNodes: true`, `useAllDevices: true`)
- **Toolbox**: Enabled (deploy/rook-ceph-tools)
- **Monitoring**: Enabled (ServiceMonitors + PrometheusRules)
- **Dashboard**: `rook-ceph.sharmamohit.com` (HTTPS passthrough)

## Common Operations

```bash
# Access toolbox
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- bash

# Cluster health
ceph status
ceph osd status
ceph df

# Pool details
ceph osd pool ls detail
rados df

# Check RGW users
radosgw-admin user list
radosgw-admin user info --uid=s3user
```

## Consumers

| Consumer | StorageClass | Size |
|----------|-------------|------|
| Prometheus | ceph-block | 20Gi |
| Alertmanager | ceph-block | 1Gi |
| Grafana | ceph-block | 2Gi |
| Thanos Store Gateway | ceph-block | 10Gi |
| Thanos Compactor | ceph-block | 10Gi |
| Loki WAL | ceph-block | 10Gi |
| Tempo WAL | ceph-block | 10Gi |

## Current version and CephX security state (2026-11-23)

CVE-2025-30156 daemon-key remediation completed on Rook v1.19.12 / Ceph
19.2.6 during P4. P6 subsequently upgraded Ceph to **19.2.7**, retaining
**Rook v1.19.12** and daemon key generation 2. `cephImage` is explicitly pinned to
`quay.io/ceph/ceph:v19.2.7`; all 18 running daemon/toolbox pods (32 containers)
use digest `sha256:3fc0a79f1c671f0e75be24ba77a4ab32227e5ea080e16dfc0840a1dc6c30bf7e`.
The linux/amd64 platform manifest is
`sha256:b7363bbc7e9e905dcc91a0c542a81916e95a96724018b8d85a374d21714bb1f9`.
`ceph versions` confirms all 11 mon/mgr/osd/mds/rgw daemons at 19.2.7.

The patch roll kept at most one OSD down and monitor quorum at two or more.
The three nonclean-PG intervals recovered to 201 active+clean in 22.03, 24.04
and 20.03 seconds. The independent filesystem reconciler briefly raised
`MDS_ALL_DOWN` during its roll (about eight seconds), then restored active and
standby-replay MDS automatically. Child reconcilers can roll alongside the core
upgrade, so the daemon ordering is not globally serial. Final CephCluster,
CephFilesystem and CephObjectStore phases are Ready, Ceph is HEALTH_OK, and all
nine existing claims remain Bound. Ceph image downgrades are unsupported.

The CephCluster uses `security.cephx.daemon.keyRotationPolicy: KeyGeneration`
and `keyGeneration: 2`. Admin, monitor, manager, OSD, crash collector and exporter
status all report generation 2, as do the filesystem MDS and object-store RGW
child resources. Core daemon auth keys are AES256K. Ceph reports `HEALTH_OK`,
all 201 PGs are active+clean, all 3 OSDs are up/in and all 3 monitors are in quorum.
The toolbox needed one restart after the admin key changed; its old keyring had
not refreshed within the allowed three-minute window.

CSI rotation remains disabled. The four existing CSI identities retain their
original AES keys, compatible with kernel `6.18.63-talos`; AES256K CSI keys require
kernel >=7.0. RBD mirror peer keys were also left unchanged. The cluster's existing
preferred/service-ticket ciphers remain AES256K and its allowed cipher set remains
`[aes, aes256k]`; this operation did not change the allowed cipher policy.

**Unresolved CSI field discrepancy:** `security.cephx.csi.keyType: aes` is present
in Git, the local chart render **and the installed Helm release manifest**, but is
absent from the live CephCluster spec (`csi: {}`). The live CRD JSON and fresh
`kubectl explain` both include this field. The cause remains **UNRESOLVED**;
candidates are an operator spec
write-back or chart behavior. Compatibility was verified using the unchanged AES
CSI identities and an empty/Disabled CSI rotation policy. Re-check this discrepancy
during the Rook 1.20+ migration **before enabling any CSI rotation**.

The following three health warnings are intentionally muted with
`healthCheck.muteHealthWarning.<code>.policy: mute`: `AUTH_INSECURE_CLIENT_KEY_TYPE`,
`AUTH_INSECURE_KEYS_ALLOWED` and `AUTH_INSECURE_KEYS_CREATABLE`. Each has a kernel
>=7.0 revisit comment in the HelmRelease. These are sticky mutes; removing a config
entry does not unmute it. After all clients can migrate, set `policy: unmute`
explicitly. Neither `AUTH_INSECURE_SERVICE_KEY_TYPE` nor
`AUTH_INSECURE_ROTATING_SERVICE_KEY_TYPE` remains raised; the rotating service
cipher was already AES256K before this operation.

`auth_allow_insecure_global_id_reclaim` was already `false` and remains unchanged.
`auth_expose_insecure_global_id_reclaim` remains `true`; all three monitors reported
zero `reclaim_insecure` sessions. No global-ID config write was needed.

Verification provisioned a fresh 1Gi claim on **both** `ceph-block` and
`ceph-filesystem`: write/read and a second read passed on `talos01`, then persistent
reads passed after remounting both claims on `talos02`. The `c2-p4-test` namespace,
its two pods, two claims and their normally reclaimed PVs were removed. Existing
workloads remained healthy. CephFS testing is mandatory for future changes because
the nine pre-existing claims were all RBD and did not cover kernel CephFS mounts.

During the single-OSD rolling restarts, transient undersized/degraded/peering and
`stale+active+clean` states recovered to all PGs clean within the five-minute gate.
Do not mistake a transient `stale` flag for an inactive/incomplete PG or automatically
re-rotate keys for a CSI mount error. Overriding `daemon.keyType: aes` also downgrades
`auth_preferred_cipher` and `auth_service_cipher`, raising
`AUTH_INSECURE_SERVICE_TICKETS` below the pre-rotation security baseline; that is a
temporary daemon-auth recovery only, requiring a later return to AES256K.

Reference: [Rook v1.19.12 CephX key rotation](https://github.com/rook/rook/blob/v1.19.12/Documentation/Storage-Configuration/Advanced/cephx-key-rotation.md).
