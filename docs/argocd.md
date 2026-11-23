# ArgoCD

ArgoCD runs as a Flux HelmRelease (`kubernetes/apps/base/argocd/argocd-hr.yaml`). It deploys the
Applications under `kubernetes/apps/argocd-apps/apps/` through `root-app` (app-of-apps).

## Current state (2026-11-22)

| | value |
|---|---|
| ArgoCD | **v3.6.2** (bundled Helm 4.3.2, Kustomize 5.8.3) |
| Chart | `argo-cd` **10.18.2**, an exact pin (never a range) |
| Resource tracking | **`label`**, pinned explicitly in `configs.cm` (3.0+ defaults to annotation) |
| NetworkPolicies | `global.networkPolicy.create: false`. Flannel does not enforce them; revisit if the CNI changes |
| SSO | PocketID, direct OIDC, **public client + PKCE**. Since 3.1 the server runs the PKCE flow; the PocketID client must have `/auth/callback` registered |
| RBAC | `g, argocd_admins, role:admin`; `policy.default: ""` |
| Child app charts | **exact versions** (alloy 1.16.0, kube-prometheus-stack 85.4.0, loki 6.55.0, prometheus-operator-crds 28.0.1, smartctl-exporter 0.19.2, tempo 1.24.4, thanos 17.3.1). Bump them deliberately, never via a range |

## Upgrade rules (learned in the 2.14 → 3.6 migration, campaign c2/P7)

1. **Read every crossed guide** (`docs/operator-manual/upgrading/<x>-<y>.md`) and the chart README "Changelog".
2. **One step per hop:** one ArgoCD minor, OR one chart-major boundary at a fixed ArgoCD minor. Never both, except where no build exists (7.x → 8.x had to cross 2.14 → 3.0).
3. **Freeze first:** remove `automated` from root-app and every child, and exact-pin floating chart ranges. Then a controller upgrade can only *show* drift, never apply or prune it. Unfreeze at the end.
4. **Check render parity for every bundled-Helm change.** ArgoCD's Helm version comes from `hack/tool-versions.sh` at the target tag. Render every child the way the repo-server does (`--name-template <app> --namespace <dest> --kube-version <cluster> --api-versions <discovered> --include-crds`, live valuesObject) with the old and new Helm, and compare object by object.
   - **Helm 4 drops null-valued chart defaults:** at 3.5 (Helm 4.2.1) tempo lost `opencensus: null`, so its ConfigMap and pod changed. That was the only render difference across 3.16.3 → 4.3.2.
5. **Pin `application.resourceTrackingMethod` before 3.0.** The chart does not set it, so 3.0 would silently switch to annotation tracking.
6. **Expected log noise:** right after the controller starts on a cold Redis, it may log `DiffFromCache error: … cache: key is missing` for the server-side-diff apps (kps, prometheus-operator-crds). It is transient (within seconds), and any other error class is real.
7. **Rollback** = git revert of the last hop only. The argoproj CRD schemas are additive (v1alpha1 only), so a one-hop chart downgrade is safe. Recovery must not depend on an ArgoCD login (see below).

## Hop log (2026-11-22)

| hop | chart / app | note |
|---|---|---|
| P0 | 7.x → 7.9.1 | exact pin, no re-release |
| F | — | all 11 Applications manual, 7 charts pinned |
| H1 | 8.2.7 / v3.0.12 | tracking pinned `label` |
| H2 | 8.6.4 / v3.1.8 | server-side PKCE. The user's passkey login, apps list and Logs tab were verified |
| H3 | 9.0.6 / v3.1.9 | chart 9 drops the `configs.params` defaults (21 keys; binary defaults equivalent) |
| H4 | 9.3.7 / v3.2.6 | Redis 8 (cache only) |
| H5 | 9.5.11 / v3.3.9 | reconciliation 120s + 60s jitter |
| H6 | 9.7.1 / v3.4.4 | — |
| H7 | 10.2.2 / v3.4.6 | chart 10; NetworkPolicies disabled |
| H8 | 10.11.7 / v3.5.7 | Helm 4.2.1; predicted tempo change synced after review |
| H9 | 10.18.2 / v3.6.2 | Helm 4.3.2; all pods roll once (pod-template label change) |
| U | — | automated sync restored, pins kept |

In every hop: all 191 managed resources kept their UIDs and content, nothing was pruned, and the no-op sync passed.
Removed afterwards: the never-deployed argo-events/rollouts/workflows HelmRelease files.

## Known gaps / follow-ups

- **No working local-admin break-glass.** `argocd-initial-admin-secret` is stale (login returns 401). Recovery from an SSO failure is git revert + Flux + kubectl, operating directly on the Application CRs, which needs no ArgoCD login. Resetting the admin password is a deliberate credential change and was not done.
- **Tracking migration to `annotation+label` (deferred).** If wanted:
  1. Switch the tracking method.
  2. Hard-refresh.
  3. Per app, a **selective** sync of exactly `.status.resources` (selective syncs run no hooks), with prune off.
  4. Verify each non-CRD's tracking-id equals `<app>:<group>/<kind>:<ns>/<name>`; CRDs are never tracked.
  
  The labels stay, so going back to `label` is lossless.
- Dex runs but is unused (SSO is direct OIDC).
