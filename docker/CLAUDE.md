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
├── shared/alloy/          # Shared Alloy compose (6 LAN hosts)
├── racknerd-aegis/alloy-override/  # VPS-specific Alloy (adds CrowdSec scrape)
└── {host}/{service}/      # Per-host compose + .sops.env
periphery/                 # Custom periphery Dockerfile + sops-decrypt.sh
```

## Hosts & Stacks (19 total)

| Host | IP | SSH | Stacks |
|------|----|-----|--------|
| komodo | 192.168.11.200 | root@komodo | komodo-core, komodo-alloy |
| nvr | 192.168.11.89 | root@nvr | frigate, nvr-alloy |
| kasm | 192.168.11.34 | root@kasm | newt, kasm-alloy |
| omni | 192.168.11.30 | root@omni | omni, omni-alloy |
| server04 | 192.168.11.17 | mohitsharma44@server04 | traefik, vaultwarden |
| seaweedfs | 192.168.11.133 | mohitsharma44@seaweedfs | seaweedfs, seaweedfs-alloy |
| racknerd-aegis | 23.94.73.98 | root@hs | aegis-gateway, aegis-pangolin, aegis-identity, aegis-periphery, aegis-newt, aegis-pangolin-client, racknerd-aegis-alloy |

**Note**: server04 monitoring uses a systemd Alloy service (not a Komodo-managed Docker stack). See `docs/hardware-monitoring-plan.md` for details.

## Komodo Access
- **UI**: https://komodo.sharmamohit.com
- **API**: http://komodo.sharmamohit.com:9120 (HTTP, not HTTPS)
- **CLI**: `km`
- **Periphery**: port 8120 on each host (TLS)

## Secrets (SOPS + age)

`.sops.env` (or `.sops.json`) files live next to each `compose.yaml`. At deploy time, Komodo's `pre_deploy` hook runs `sops-decrypt.sh` on the Periphery agent, decrypting `*.sops.env` → `*.env`. Compose reads via `env_file: .env`.

Stacks with secrets: all alloy stacks (shared `.sops.env`), newt, omni, traefik, vaultwarden, seaweedfs (`s3.sops.json`), aegis-gateway, aegis-pangolin, aegis-identity, aegis-newt. Only frigate and aegis-periphery have no secrets.

## Custom Periphery Image
`mohitsharma44/komodo-periphery-sops:latest` — upstream Periphery + sops + age + `sops-decrypt.sh`. Built on server04 via `km execute run-build periphery-custom`. Dockerfile at `periphery/Dockerfile`.

**Note**: The komodo host uses systemd Periphery with native sops+age installed directly on the host, not the custom Docker image.

## Periphery Compose Locations
| Host | Path |
|------|------|
| komodo | systemd service — `/etc/komodo/periphery.config.toml` |
| nvr, kasm, omni | `/root/komodo-periphery/compose.yaml` |
| server04, seaweedfs | `~/komodo-periphery/compose.yaml` |
| racknerd-aegis | Komodo-managed stack (`aegis-periphery`) — isolated on `newt-periphery` network |

## Adding a New Stack
1. Create `stacks/{host}/{service}/compose.yaml` + `.sops.env`
2. Add to `komodo-resources/stacks-{host}.toml` (must include `pre_deploy.path` and `pre_deploy.command = "sops-decrypt.sh"`)
3. Commit, push, sync, deploy

## Gotchas
- **pre_deploy.path required**: Must point to the compose directory so `sops-decrypt.sh` finds `.sops.env`. Without it, runs from repo root.
- **DNS on server04**: Periphery compose needs `dns: ["192.168.11.1"]` — Docker embedded DNS broken.
- **Age key ownership**: Must be `root:root` with `600` on all hosts. Non-root SSH hosts (server04/seaweedfs) may need `sudo chown`.
- **ResourceSync self-reference**: `sync.toml` must define itself to avoid self-deletion (`delete=true`).
- **KASM**: Installer-managed — only Newt is Komodo-managed.
- **AppArmor on komodo LXC**: `mask-apparmor.service` hides `/sys/kernel/security` for Docker in unprivileged LXC.
- **Komodo self-management**: komodo-core is a self-managed stack. Do NOT enable auto_update. Deploy independently via `km execute deploy-stack komodo-core`. The deploy-all-stacks procedure excludes it to prevent self-restart.
- **VPS tunnel-critical stacks**: `aegis-pangolin`, `aegis-newt`, `aegis-periphery` are excluded from batch deploy (same reason as komodo-core — redeploying severs the management tunnel). Use `km execute deploy-vps-infra` for ordered VPS deployment.
- **VPS Pangolin connectivity**: Komodo reaches VPS Periphery via Pangolin private resource tunnel (`periphery.private.sharmamohit.com:8120`). A Machine Client on komodo (`/opt/pangolin-client/`) provides the WireGuard route. If the tunnel is down, use SSH (`ssh hs`) as the emergency backdoor.
- **VPS network segmentation**: VPS uses multi-network isolation. Only containers needing WAN access touch `traefik-public` or `pangolin-internal`. Periphery is isolated on `newt-periphery` only (no ports published). LLDAP is on `identity-internal` only (PocketID bridges both networks).
- **Komodo file_paths**: Only the first entry is used as the compose file. Komodo does NOT support Docker Compose file merge (multiple `-f` flags). To customize a shared stack for one host, create a standalone copy instead of an override.
- **VPS Alloy override**: `racknerd-aegis-alloy` uses a standalone compose at `stacks/racknerd-aegis/alloy-override/compose.yaml` (not the shared one) to add CrowdSec metrics scraping. This is a full copy of the shared config — **keep it in sync** when the shared Alloy config changes. Its `env_file` points to `../../shared/alloy/.env` via relative path.

## Updating Komodo (Core + Periphery)

Core and Periphery are released together — update both at the same time.

1. Check current vs latest: `km get version` and Komodo UI banner
2. Bump image tag in `docker/stacks/komodo/core/compose.yaml`
3. Commit, push, then sync: `km execute sync 'mohitsharma44/homeops'`
4. Deploy Core: `km execute deploy-stack komodo-core`
5. Update systemd Periphery on komodo:
   ```bash
   ssh root@komodo "curl -sSL https://raw.githubusercontent.com/moghtech/komodo/main/scripts/setup-periphery.py | python3 - --version=<new-version>"
   ssh root@komodo "systemctl restart periphery"
   ```
6. Rebuild custom Docker Periphery for other 6 hosts: `km execute run-build periphery-custom`
   - Then pull on each host (daily rebuild handles this, or manually trigger)
7. Verify all healthy: `km list servers -a`

## Commands
```bash
km execute sync 'mohitsharma44/homeops'   # sync resources from git
km execute deploy-stack <name>            # deploy a stack
km list stacks -a                         # check stack status
km list servers -a                        # check server health
km execute run-build periphery-custom     # rebuild periphery image
km execute deploy-vps-infra              # deploy VPS stacks in order

# Systemd Periphery on komodo
systemctl status periphery               # check periphery status
systemctl restart periphery              # restart periphery
journalctl -u periphery -f               # follow periphery logs
```
