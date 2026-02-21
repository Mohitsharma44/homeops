# Infrastructure Audit — February 2026

Security and platform engineering review of the homeops infrastructure.
Covers both Kubernetes (Flux + ArgoCD) and Docker (Komodo GitOps) across 7 hosts.

---

## Security findings

### High priority

**1. VPS Traefik missing HTTP-to-HTTPS redirect**

The internet-facing Traefik on racknerd-aegis listens on port 80 but does not redirect to HTTPS. The LAN Traefik on server04 does have this redirect. Without it, clients can interact with services over unencrypted HTTP.

- File: `docker/stacks/racknerd-aegis/aegis-gateway/compose.yaml`
- Fix: Add `--entrypoints.web.http.redirections.entrypoint.to=websecure` and `--entrypoints.web.http.redirections.entrypoint.scheme=https` to Traefik command args.

**2. LAN Traefik dashboard unauthenticated + wildcard CORS**

The Traefik dashboard at `traefik.sharmamohit.com` has no auth middleware — only a CORS middleware with `accesscontrolalloworiginlist=*`. Anyone on the LAN can view and interact with the dashboard.

- File: `docker/stacks/server04/traefik/compose.yaml`
- Fix: Add basic auth or IP-allowlist middleware to the dashboard router. Restrict the CORS origin to `https://traefik.sharmamohit.com`.

**3. VPS Traefik dashboard internet-accessible with no auth**

The VPS Traefik dashboard at `traefik.proxy.sharmamohit.com` only has CrowdSec bouncer middleware. Any non-banned visitor can view routing rules, backend names, and cert metadata.

- File: `docker/stacks/racknerd-aegis/aegis-gateway/compose.yaml`
- Fix: Add basic auth middleware, or route through Pangolin-Traefik with PocketID OIDC, or restrict to Pangolin private resources only.

**4. Komodo API on plaintext HTTP (port 9120)**

The Komodo API runs on HTTP with `network_mode: host`. API key/secret are transmitted in plain text over the LAN.

- File: `docker/stacks/komodo/core/compose.yaml`
- Fix: Put the Komodo API behind server04 Traefik with TLS, or bind to localhost and proxy through Traefik.

**5. SeaweedFS WebDAV unauthenticated**

WebDAV on port 7333 has no auth. Any LAN host can read, write, and delete files — including Vaultwarden password database backups. The S3 gateway has credentials, but WebDAV does not.

- File: `docker/stacks/seaweedfs/seaweedfs/compose.yaml`
- Fix: Enable filer auth for WebDAV, switch backups to authenticated S3, or bind WebDAV to localhost behind a reverse proxy.

**6. Vaultwarden signups not explicitly disabled**

The compose file does not set `SIGNUPS_ALLOWED=false`. Vaultwarden defaults to allowing signups. Anyone on the LAN can register an account.

- File: `docker/stacks/server04/vaultwarden/compose.yaml`
- Fix: Add `SIGNUPS_ALLOWED=false` and `INVITATIONS_ALLOWED=false` to the environment section (or `.sops.env`).

### Medium priority

**7. Traefik metrics port (9091) exposed without auth**

Port 9091 maps to Traefik's internal API port 8080. The Prometheus metrics endpoint is accessible without authentication to any LAN host.

- File: `docker/stacks/server04/traefik/compose.yaml`
- Fix: Bind to localhost only (`127.0.0.1:9091:8080`). Alloy runs with `network_mode: host` so localhost scraping works fine.

**8. Single age key shared across all environments**

One key pair is used on the developer laptop, all 7 Docker hosts, and the K8s cluster. A compromise on any single host exposes every secret in the repository.

- File: `.sops.yaml`
- Fix: Create separate key pairs for K8s, LAN Docker, and VPS. Update `.sops.yaml` `creation_rules` with path-based recipients.

**9. CrowdSec uses `:latest` tag on the internet-facing VPS**

The daily `GlobalAutoUpdate` could pull a breaking or compromised CrowdSec version. Every other container in the stack is pinned.

- File: `docker/stacks/racknerd-aegis/aegis-gateway/compose.yaml`
- Fix: Pin to a specific version (e.g., `crowdsecurity/crowdsec:v1.6.4`).

**10. Decrypted `.env` files persist on hosts after deploy**

`sops-decrypt.sh` writes plaintext `.env` files that remain on disk indefinitely after `docker compose up` reads them.

- File: `docker/periphery/scripts/sops-decrypt.sh`
- Fix: Add a cleanup trap or `post_deploy` hook to remove decrypted files. Alternatively, use process substitution to avoid writing plaintext to disk.

**11. Grafana using default admin password, no SSO**

The kube-prometheus-stack values don't configure `adminPassword` or OIDC. Grafana uses the default chart password.

- File: `kubernetes/apps/argocd-apps/apps/kube-prometheus-stack.yaml`
- Fix: Set a SOPS-encrypted `adminPassword`, or configure OIDC auth against PocketID.

### Low priority

**12. Ingress-nginx admission webhooks disabled**

Admission webhooks are set to `enabled: false`. Bad Ingress resources won't be caught before hitting the API server.

- File: `kubernetes/infrastructure/controllers/ingress-nginx/hr.yaml`
- Fix: Set `admissionWebhooks.enabled: true`.

**13. LAN Traefik global TLS skip-verify**

`serverstransport.insecureskipverify=true` disables cert verification for all backend connections.

- File: `docker/stacks/server04/traefik/compose.yaml`
- Fix: Remove the global flag and configure per-service `serversTransport` only where needed.

**14. Komodo DB backups local only — no offsite copy**

Backups go to `/etc/komodo/backups/` on the komodo LXC only. If the LXC storage fails, everything is lost.

- File: `docker/komodo-resources/procedures.toml`
- Fix: Add a post-backup step that uploads to SeaweedFS, similar to the vaultwarden backup pattern.

---

## Platform engineering findings

### High priority

**1. Alertmanager has no notification routes**

PrometheusRules exist (cert expiry, 5xx spikes, config reload failures) but Alertmanager has no receivers or routes. Alerts fire into the void.

- File: `kubernetes/apps/argocd-apps/apps/kube-prometheus-stack.yaml`
- Fix: Add an `alertmanagerConfig` section with a Discord/Slack webhook or ntfy.sh receiver. Route critical alerts by `severity: critical`.
- Effort: Small

**2. SeaweedFS is an unreplicated SPOF for the observability stack**

Single master, single volume server, `-defaultReplication=000`. Holds all Thanos metrics, Loki logs, and Tempo traces. Disk failure = total loss of historical observability data.

- Fix: Verify TrueNAS ZFS snapshots are enabled on `/mnt/seaweedfs/`. Add scheduled snapshot-based backup to a separate dataset or offsite. Consider `-defaultReplication=001` if a second volume server is added later.
- Effort: Medium

**3. Unpinned container image tags**

Several images use non-deterministic tags that the daily `GlobalAutoUpdate` could silently upgrade:
- `crowdsecurity/crowdsec:latest` (aegis-gateway)
- `lldap/lldap:stable` (identity)
- `ghcr.io/blakeblackshear/frigate:stable` (nvr)
- `mohitsharma44/komodo-periphery-sops:latest` (periphery)
- `ghcr.io/pocket-id/pocket-id:v2` (major tag, not patch-pinned)

- Fix: Pin all to specific version tags. Tag custom periphery builds with the upstream version. Intentional upgrades happen by bumping tags in git — the correct GitOps workflow.
- Effort: Small

**4. Newt version skew — kasm 1.7.0 vs everywhere else 1.9.0**

Kasm Newt is two minor versions behind. Pangolin and Newt use a tight protocol — version mismatches can cause subtle tunnel issues.

- File: `docker/stacks/kasm/newt/compose.yaml`
- Fix: Bump to `fosrl/newt:1.9.0`. Consider defining `NEWT_VERSION` as a Komodo variable for consistency.
- Effort: Small

**5. LAN Traefik 6 minor versions behind VPS Traefik**

server04 runs `traefik:v3.0` while the VPS runs `v3.6.1`. v3.0 was the initial v3 release with known bugs since patched.

- File: `docker/stacks/server04/traefik/compose.yaml`
- Fix: Bump to `traefik:v3.6.1`.
- Effort: Small

### Medium priority

**6. Komodo webhook disabled — manual sync required**

`webhook_enabled = false` in `sync.toml`. Every Docker change requires a manual `km execute sync`. Flux (K8s side) polls automatically, but Docker does not.

- File: `docker/komodo-resources/sync.toml`
- Fix: Enable webhook + add a GitHub webhook to Komodo, or add `config.schedule` for polling (e.g., every 5 minutes).
- Effort: Small

**7. VPS Alloy override is a full copy prone to drift**

The VPS Alloy compose is a standalone copy of the shared config with CrowdSec additions. The CLAUDE.md warns to keep it in sync manually. Drift only surfaces when the VPS stops reporting metrics.

- Fix: Add a pre-commit hook or CI step that diffs the shared portions and fails on divergence.
- Effort: Medium

**8. No GitHub Actions CI for validation**

No `.github/workflows/` directory. Validation relies on local pre-commit hooks only. A typo in YAML or TOML is only caught after Flux/ArgoCD tries to apply it.

- Fix: Add a minimal workflow: `yamllint`, TOML lint, `kustomize build`, SOPS `forbid-secrets`.
- Effort: Small

**9. Vaultwarden backup has no integrity check or failure alerting**

The backup script doesn't verify the SQLite file is valid after creation. WebDAV upload failure logs to stderr but exits 0. No notification if backups fail.

- File: `docker/stacks/server04/vaultwarden/backup.sh`
- Fix: Add `sqlite3 ... "PRAGMA integrity_check"` after backup. Exit non-zero on WebDAV failure. Pipe failures to a webhook (ntfy.sh, Discord).
- Effort: Small

**10. SeaweedFS S3 traffic is unencrypted HTTP on LAN**

All S3 credentials (Thanos, Loki, Tempo) are transmitted in plaintext between K8s and SeaweedFS at `seaweedfs.sharmamohit.com:8333`.

- Fix: Enable TLS on SeaweedFS. Update S3 endpoint URLs and remove `insecure: true` from Thanos/Loki/Tempo configs.
- Effort: Medium

**11. Komodo DB backup local only on LXC**

Same as Security #14. Daily backup stays on the komodo LXC container with no offsite copy.

- Fix: Add a `curl -T` to SeaweedFS after the backup, or a separate scheduled procedure.
- Effort: Small

### Low priority

**12. `.sops.yaml` second rule matches all YAML files**

`path_regex: .*.yaml` with `encrypted_regex: '^(data|stringData)$'` matches every YAML in the repo. Running `sops -e -i` on a non-secret YAML with a `data` key would encrypt it.

- File: `.sops.yaml`
- Fix: Narrow to `kubernetes/.*secret.*\.yaml$` to match the pre-commit hook pattern.
- Effort: Small

**13. No provisioned Grafana dashboards for Docker hosts**

Alloy collects metrics from all Docker hosts but no dashboards are provisioned as code. Docker-specific views require manual creation.

- Fix: Create a ConfigMap with a Docker hosts dashboard (node_exporter + cAdvisor, filtered by `source="docker"`).
- Effort: Medium

**14. Single age key with no rotation procedure documented**

If the key needs rotation, there's no runbook. Rotation requires re-encrypting every secret and distributing the new key to 7 hosts + K8s.

- Fix: Document the rotation procedure in docs/. Add a second age recipient as an offline recovery key.
- Effort: Medium

---

## Overlapping findings

These issues were flagged by both audits:

| Issue | Security # | Platform # |
|-------|-----------|------------|
| CrowdSec `:latest` tag | 9 | 3 |
| Komodo DB backup local only | 14 | 11 |
| Single age key | 8 | 14 |
| LAN Traefik dashboard auth + version | 2 | 5 |

## Suggested quick wins

High priority + small effort — all doable in one session:

1. Pin CrowdSec, LLDAP, Frigate, PocketID to specific versions
2. Bump kasm Newt from 1.7.0 to 1.9.0
3. Bump LAN Traefik from v3.0 to v3.6.1
4. Add `SIGNUPS_ALLOWED=false` to Vaultwarden
5. Add HTTP→HTTPS redirect to VPS Traefik
6. Configure Alertmanager notification routes
