# Flux

Flux is installed and upgraded by **flux-operator**, and flux-operator is itself managed by Flux.

| What | Where | Pin |
|---|---|---|
| flux-operator chart | `kubernetes/clusters/minipcs/flux-operator.yaml` (OCIRepository `ref.tag` + HelmRelease) | exact chart version |
| Flux distribution | `kubernetes/clusters/minipcs/flux-instance.yaml` (`spec.distribution.version`) | exact Flux version |

Current (2026-11-23): **flux-operator 0.63.1, Flux 2.10.1**. The controllers are source-controller 1.10.2, kustomize-controller 1.10.2, helm-controller 1.7.2 and notification-controller 1.10.1. Flux 2.10 supports Kubernetes 1.35 (≥1.35.2) through 1.37.

## Known gap: GAP-P5-1 (open)
flux-operator **v0.63.0/v0.63.1** cannot run its forced CRD migration.
- On every Flux minor bump it logs `failed to migrate resources … continue list option is not supported by the cache` for every CRD, and still reports Ready.
- The cause is upstream PR #1106, which paginates the migrator through the cached client. v0.62.x did not have the bug.
- Effect: the `alerts` and `providers` CRDs keep `status.storedVersions: [v1beta3, v1]` after the 2.10 storage switch. Both kinds have **0 objects**, so this is harmless until a future Flux release removes `v1beta3`; that CRD update would then be refused.
- **Cleanup**, once an operator release fixes the migrator:
  1. Bump `ref.tag` in `flux-operator.yaml`.
  2. Force a migration: annotate the FluxInstance with `reconcile.fluxcd.io/requestedAt` and `reconcile.fluxcd.io/forceAt` set to the *same* fresh value.
  3. Confirm the operator logs `CRD migrated alerts…`/`providers…`, and both CRDs show `storedVersions: [v1]`.
- Do this **before** any Flux upgrade that drops `v1beta3`. Never patch `status.storedVersions` by hand.

## Upgrade rules
- **Use exact versions only.** With a range such as `"2.x"`, the operator elects the newest Flux it bundles. An operator upgrade then silently jumps Flux minors, and a minor *downgrade* is rejected by the operator ("downgrading … is not supported"). `git revert` of a Flux minor bump is therefore not a rollback.
- **Order:**
  1. Bump the operator chart first, while Flux stays pinned. Check that the new operator still bundles the pinned version (`config/data/flux/` at the operator tag).
  2. Then bump Flux one minor per commit.
  3. After each bump, check that every Kustomization and HelmRelease is Ready at the new commit, and that the operator logged `CRD migrated` with no `failed to migrate`. FluxInstance Ready does not prove that the migration worked.
- Any chart bump through the OCI `chartRef` restarts the operator pod. helm-controller records the version as `<ver>+<digest>`, and the chart puts that into a pod label.
- **Never delete the flux-operator HelmRelease while it is unsuspended**: helm-controller would uninstall the operator. Suspend it first. Both objects have `kustomize.toolkit.fluxcd.io/prune: disabled`, and the operator CRDs carry `helm.sh/resource-policy: keep`.
- **Never delete or uninstall the FluxInstance.** Its finalizer removes the Flux controllers and CRDs, and with them every Flux object.

## Hop log
- 2026-11-23: FluxInstance pinned `2.x` → `2.7.5` (the running version) before touching the operator.
- 2026-11-23: argo-helm HelmRepository `source.toolkit.fluxcd.io/v1beta2` → `v1`. The stale `v1beta2` managedFields entry was cleared by the operator's forced migration (`reconcile.fluxcd.io/requestedAt` and `forceAt` set to the same token).
- 2026-11-23: flux-operator adopted into GitOps at chart 0.40.0 (helm rev 2), then upgraded to 0.63.1 (rev 3). Flux held at 2.7.5.
- 2026-11-23: **Flux 2.7.5 → 2.8.8.** All HelmReleases stayed at their revisions through the Helm v4 switch.
- 2026-11-23: **Flux 2.8.8 → 2.9.6.** notification v1beta2 is no longer served; all HelmReleases stayed at their revisions.
- 2026-11-23: **Flux 2.9.6 → 2.10.1.** SOPS decryption verified: infra-controllers and infra-configs reconciled at the hop commit, and all 13 decrypted Secrets are present. alerts/providers storage moved to v1 (see GAP-P5-1).
