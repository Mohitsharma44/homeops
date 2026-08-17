# Docker Infrastructure — Komodo GitOps

## How It Works
Single ResourceSync reads TOML from `komodo-resources/`, manages stacks across 7 hosts via Periphery agents. Secrets decrypted at deploy time by custom periphery image with SOPS+age.

## Directory Layout
```
komodo-resources/          # TOML declarations (synced by Komodo)
├── sync.toml              # ResourceSync self-definition (delete=true)
├── servers.toml           # 7 host definitions
├── builds.toml            # Custom periphery image build
├── procedures.toml        # Scheduled jobs (backup, rebuild, auto-update)
└── stacks-{host}.toml     # Stack definitions per host
stacks/                    # Compose files + encrypted secrets
├── shared/alloy/          # Shared Alloy compose (4 LAN hosts: komodo, nvr, kasm, omni)
├── racknerd-aegis/alloy-override/  # VPS-specific Alloy (adds CrowdSec scrape)
└── {host}/{service}/      # Per-host compose + .sops.env
periphery/                 # Custom periphery Dockerfile + sops-decrypt.sh
```

## Hosts & Stacks

| Host | IP | SSH | Stacks |
|------|----|-----|--------|
| komodo | 192.168.11.200 | root@komodo | komodo-core, komodo-alloy |
| nvr | 192.168.11.89 | root@nvr | frigate, nvr-alloy |
| kasm | 192.168.11.34 | root@kasm | newt, kasm-alloy |
| omni | 192.168.11.30 | root@omni | omni, omni-alloy |
| server04 | 192.168.11.17 | mohitsharma44@server04 | traefik, vaultwarden |
| storage | 192.168.11.244 | mohitsharma44@192.168.11.244 | garage, garage-snapshotter, backup-verifier, storage-alloy, smartctl-exporter, md-exporter |
| racknerd-aegis | <VPS_PUBLIC_IP> | <vps-user>@hs | aegis-gateway, aegis-pangolin, aegis-identity, aegis-periphery, aegis-newt, aegis-pangolin-client, racknerd-aegis-alloy |

**Note**: server04 monitoring uses a systemd Alloy service (not a Komodo-managed Docker stack). See `docs/hardware-monitoring-plan.md` for details.

**Note**: the storage host runs its own Alloy (`storage-alloy`), a standalone copy of `shared/alloy` — not an override, because Komodo cannot merge compose files. It exists so this host's scrape config lives in git rather than being appended to server04's in-place, ungoverned `/etc/alloy/config.alloy`. Keep the common parts in step with `stacks/shared/alloy/compose.yaml`. UGOS cannot take APT packages, so everything on that host is containers.

## Komodo Access
- **UI**: https://komodo.sharmamohit.com
- **API**: http://komodo.sharmamohit.com:9120 (HTTP, not HTTPS)
- **CLI**: `km`
- **Periphery**: v2.3.2 on the 6 reachable hosts; kasm is stranded at 2.2.0 (host unreachable — it converges on next boot). All 7 in outbound mode (dial Core on websocket :9120 over PKI keypair). Port 8120 is still bound on each host as a legacy inbound endpoint but is unused for management.

## Secrets (SOPS + age)

`.sops.env` (or `.sops.json`) files live next to each `compose.yaml`. At deploy time, Komodo's `pre_deploy` hook runs `sops-decrypt.sh` on the Periphery agent, decrypting `*.sops.env` → `*.env`. Compose reads via `env_file: .env`.

Stacks with secrets: all alloy stacks (shared `.sops.env`), newt, omni, traefik, vaultwarden, garage, garage-snapshotter, aegis-gateway, aegis-pangolin, aegis-identity, aegis-newt. Only frigate and aegis-periphery have no secrets.

## Custom Periphery Image
`mohitsharma44/komodo-periphery-sops:latest` — upstream Periphery + sops + age + `sops-decrypt.sh`. Built on server04 via `km execute run-build periphery-custom`. Dockerfile at `periphery/Dockerfile`.

**Note**: The komodo host uses systemd Periphery with native sops+age installed directly on the host, not the custom Docker image.

## Periphery Compose Locations
| Host | Path |
|------|------|
| komodo | systemd service — `/etc/komodo/periphery.config.toml` |
| nvr, kasm, omni | `/root/komodo-periphery/compose.yaml` |
| server04 | `~/komodo-periphery/compose.yaml` |
| storage | `/volume2/komodo/periphery/compose.yaml` — everything on `/volume2`, never `/etc`, because `/` is a firmware-replaceable overlay |
| racknerd-aegis | Komodo-managed stack (`aegis-periphery`) — isolated on `newt-periphery` network |

## Adding a New Stack
1. Create `stacks/{host}/{service}/compose.yaml` + `.sops.env`
2. Add to `komodo-resources/stacks-{host}.toml` (must include `pre_deploy.path` and `pre_deploy.command = "sops-decrypt.sh"`)
3. Commit, push, sync, deploy

## Gotchas
- **pre_deploy.path required**: Must point to the compose directory so `sops-decrypt.sh` finds `.sops.env`. Without it, runs from repo root.
- **DNS on server04**: Periphery compose needs `dns: ["192.168.11.1"]` — Docker embedded DNS broken.
- **Age key ownership**: Must be `root:root` with `600` on all hosts. Non-root SSH hosts (server04, storage) may need `sudo chown`.
- **ResourceSync self-reference**: `sync.toml` must define itself to avoid self-deletion (`delete=true`).
- **KASM**: Installer-managed — only Newt is Komodo-managed.
- **AppArmor on komodo LXC**: `mask-apparmor.service` hides `/sys/kernel/security` for Docker in unprivileged LXC.
- **Auto-update disabled stacks** (4 exceptions — never enable `auto_update` on these):
  | Stack | Reason |
  |-------|--------|
  | `komodo-core` | Komodo cannot redeploy itself — kills the process mid-deploy |
  | `aegis-pangolin` | Provides the WireGuard tunnel Komodo uses to reach VPS Periphery — restart severs management connection |
  | `aegis-newt` | Same — Newt is the tunnel client; dropping it cuts the VPS management path |
  | `aegis-periphery` | Same — Periphery is the Komodo agent on the VPS; restarting it makes the VPS unreachable |

  All other stacks have `auto_update = true` and redeploy automatically after a sync. For these 4, deploy manually:
  - `komodo-core`: `km execute deploy-stack komodo-core`
  - VPS tunnel stacks: `km execute run-procedure deploy-vps-infra` (runs in safe order)

- **deploy-vps-infra stage order**: gateway → pangolin → 30s sleep → **pangolin-client** → newt → periphery → identity + monitoring. The pangolin-client (aegis-pangolin-client / racknerd-aegis-obs Machine Client) is deployed right after the sleep so it gets a fresh WireGuard handshake before downstream stacks come up — this self-heals the WG state in the happy path.

- **deploy-vps-infra failure mode** (Pangolin stage timeout): When `aegis-pangolin`'s image actually changes (real upgrade, not idempotent redeploy), the Gerbil/WG restart can hang Komodo's WebSocket session to VPS Periphery beyond the deploy timeout (~85s observed). The procedure aborts mid-way: pangolin container actually came up healthy, but downstream stages never run — `aegis-pangolin-client`'s WireGuard to the K8s newt site can be left in a hung DISCONNECTED state, and Periphery sits in connection-retry backoff. Symptoms: VPS shows "Unreachable" in Komodo, `docker logs periphery` shows `Failed to connect to websocket ... Connection timed out`.
  - **Recovery**: `km execute run-procedure 'recover-racknerd-aegis-tunnel'` — redeploys aegis-pangolin-client (fresh WG handshake) + aegis-periphery (drops retry backoff, reconnects).
  - **Verify**: `km list servers -a` shows 7/7 Ok, plus `ssh hs docker ps` shows pangolin/gerbil/periphery all running.
  - **DNS edge case**: pangolin-client-obs's container restart rewrites `/etc/resolv.conf` and can clobber the split-DNS routing for `*.private.sharmamohit.com`. If Periphery still can't resolve the private domain after recovery, also run: `ssh hs sudo systemctl restart pangolin-dns`. Komodo procedures can't run systemd commands, so this step is manual.
  - When `deploy-vps-infra` fails at a non-Pangolin stage (e.g., Gateway), **investigate the actual failure** instead of immediately running recover — the recover procedure won't help and would mask the real problem.
- **VPS Pangolin connectivity**: VPS Periphery dials Komodo Core over a Pangolin private resource (`komodo.private.sharmamohit.com:9120` → `192.168.11.200:9120`), routed through the `racknerd-aegis-obs` Machine Client on the VPS. Split DNS for `*.private.sharmamohit.com` is configured by the `pangolin-dns.service` systemd unit on the VPS (and on the komodo host for symmetric setups). If the tunnel is down, Periphery cannot reach Core — use SSH (`ssh hs`) as the emergency backdoor.
- **VPS network segmentation**: VPS uses multi-network isolation. Only containers needing WAN access touch `traefik-public` or `pangolin-internal`. Periphery is isolated on `newt-periphery` only (no ports published). LLDAP is on `identity-internal` only (PocketID bridges both networks).
- **Komodo file_paths**: Only the first entry is used as the compose file. Komodo does NOT support Docker Compose file merge (multiple `-f` flags). To customize a shared stack for one host, create a standalone copy instead of an override.
- **VPS Alloy override**: `racknerd-aegis-alloy` uses a standalone compose at `stacks/racknerd-aegis/alloy-override/compose.yaml` (not the shared one) to add CrowdSec metrics scraping. This is a full copy of the shared config — **keep it in sync** when the shared Alloy config changes. Its `env_file` points to `../../shared/alloy/.env` via relative path.

## Updating Komodo (Core + Periphery)

Core and Periphery release in lockstep and mismatched versions are unsupported — move both together.

**The version lives in THREE places that must all change.** Bumping only one is the
most common way to get a deploy that silently reinstalls the old version:

| File | Field | Why it's separate |
|------|-------|-------------------|
| `komodo-resources/variables.toml` | `KOMODO_VERSION` | Feeds `PERIPHERY_TAG` build arg via `[[VAR]]` |
| `komodo-resources/builds.toml` | `image_tag` | **Hardcoded** — `[[VAR]]` interpolation does NOT apply here (docker validates the tag before interpolation runs) |
| `stacks/komodo/core/.sops.env` | `KOMODO_VERSION` | Encrypted; update with `sops set`. Lives here, NOT in a stack `environment` block — see the env-file shadowing note below |

```bash
# 1. Bump all three (the encrypted one via sops set), commit, push
sops set docker/stacks/komodo/core/.sops.env '["KOMODO_VERSION"]' '"<new>"'
echo "" | km execute run-sync 'mohitsharma44/homeops'

# 2. Pre-pull on the komodo host so a registry hiccup can't strand Core mid-deploy
ssh root@komodo "docker pull ghcr.io/moghtech/komodo-core:<new>"

# 3. Deploy Core manually (auto_update is disabled — Komodo cannot redeploy itself)
km execute deploy-stack komodo-core
#    A "401 Unauthorized" here is EXPECTED when the image actually changes: Core
#    kills its own process mid-deploy, so the CLI's follow-up call fails. Always
#    verify over SSH before reacting. If the container is left in `Created`, finish
#    it by hand:  cd /etc/komodo/stacks/komodo-core/docker/stacks/komodo/core \
#                 && docker compose -p komodo-core up -d

# 4. Upgrade the local km CLI to match Core (a stale CLI gets schema-decode errors)
gh release download v<new> --repo moghtech/komodo -p km-apple

# 5. systemd Periphery on the komodo host — the `v` PREFIX IS MANDATORY
ssh root@komodo "cp /usr/local/bin/periphery /usr/local/bin/periphery.<old>-bak"
ssh root@komodo "curl -sSL https://raw.githubusercontent.com/moghtech/komodo/main/scripts/setup-periphery.py | python3 - --version=v<new>"
ssh root@komodo "systemctl restart periphery"

# 6. Rebuild the custom image, then PUSH IT BY HAND — run-build does NOT push
km execute run-build periphery-custom
ssh mohitsharma44@server04 "docker push mohitsharma44/komodo-periphery-sops:<new>"

# 7. Bump the pin + pull/restart on each Docker Periphery host
#    nvr, omni       -> /root/komodo-periphery/compose.yaml   (not in git)
#    server04        -> ~/komodo-periphery/compose.yaml       (not in git)
#    racknerd-aegis  -> docker/stacks/racknerd-aegis/periphery/compose.yaml (IN git)

# 8. Verify
km list servers -a
```

**Gotchas that have bitten this upgrade before:**

- **`--version` needs the `v` prefix.** `--version=2.3.2` builds a 404 URL, and
  setup-periphery.py **deletes the existing binary before downloading** — so a wrong
  version string bricks the service. Back the binary up first, and sanity-check the
  URL returns 200 before running it.
- **Stale top-level `.env` shadowing.** If a stack ever had a TOML `environment`
  block, Komodo wrote `/etc/komodo/stacks/<stack>/.env` and *keeps passing*
  `--env-file` to compose even after the block is removed. That stale file shadows
  the SOPS-decrypted compose-dir `.env`, so `${KOMODO_VERSION}` resolves to whatever
  it said months ago and the deploy quietly reinstalls the old image. Check for it:
  `ssh root@komodo 'ls -la /etc/komodo/stacks/komodo-core/.env'` — there should be
  none. (Removed 2026-08-13; it had pinned Core to 2.2.0 since May.)
- **VPS `aegis-periphery` is chicken-and-egg.** Deploying it recreates the very agent
  Komodo is talking through, so the deploy reports failure and leaves the new container
  `Created` under a hash-prefixed name. Recover:
  `docker rm periphery && docker rename <hash>_periphery periphery && docker start periphery`.
- **kasm** is unreachable and will stay on the old version. That's accepted; nothing is
  actively managed on it.

## Commands
```bash
km execute sync 'mohitsharma44/homeops'   # sync resources from git
km execute deploy-stack <name>            # deploy a stack
km list stacks -a                         # check stack status
km list servers -a                        # check server health
km execute run-build periphery-custom     # rebuild periphery image
km execute run-procedure deploy-vps-infra              # deploy VPS stacks in order
km execute run-procedure recover-racknerd-aegis-tunnel # recover VPS tunnel if deploy-vps-infra fails at Pangolin stage

# Systemd Periphery on komodo
systemctl status periphery               # check periphery status
systemctl restart periphery              # restart periphery
journalctl -u periphery -f               # follow periphery logs
```
