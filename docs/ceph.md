# Rook-Ceph Storage

## Overview

Distributed storage via Rook-Ceph, providing block, filesystem, and object storage to the cluster. Deployed by Flux in the `rook-ceph` namespace.

## Deployment Structure

Rook-Ceph is split into three parts to avoid Helm lifecycle issues with immutable StorageClass fields:

| Part | Managed By | Location |
|------|-----------|----------|
| Rook operator (v1.19.x) | Flux HelmRelease | `infrastructure/controllers/rook-ceph/` |
| CephCluster | Flux HelmRelease (`rook-ceph-cluster`) | `infrastructure/configs/ceph-cluster.yaml` |
| Storage resources | Flux Kustomization (standalone YAML) | `infrastructure/configs/ceph/` |

**Why standalone manifests?** StorageClass parameters (like `region`) are immutable in Kubernetes. When the Helm chart renders a StorageClass with different parameters during an upgrade, `helm upgrade` fails. By managing CephBlockPool, CephFilesystem, CephObjectStore, and their StorageClasses as standalone manifests outside Helm, Flux applies them independently and avoids this problem.

## Storage Resources

```
infrastructure/configs/ceph/
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
