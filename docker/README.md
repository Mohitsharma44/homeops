# Docker Infrastructure — Komodo GitOps

Manages Docker containers across 6 hosts via [Komodo](https://komo.do) Resource Sync. All resource definitions, compose files, and encrypted secrets live in this directory and are synced to Komodo via a single ResourceSync pointing at `docker/komodo-resources/`.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│  GitHub (homeops repo)                                                   │
│  docker/komodo-resources/*.toml   ←── ResourceSync reads these          │
│  docker/stacks/{host}/{svc}/      ←── Compose files + .sops.env         │
└──────────┬───────────────────────────────────────────────────────────────┘
           │  git pull
┌──────────▼───────────────────────────────────────────────────────────────┐
│  Komodo Core (komodo host, port 9120)                                    │
│  - Parses TOML declarations → creates/updates/deletes resources          │
│  - Orchestrates deployments via Periphery agents                         │
└──────────┬───────────────────────────────────────────────────────────────┘
           │  gRPC (port 8120, TLS)
    ┌──────┼──────┬──────┬──────┬──────┐
    ▼      ▼      ▼      ▼      ▼      ▼
 komodo   nvr   kasm   omni  server04  seaweedfs
 (Core)                        (Build
  systemd Periphery agents on each host:  Server)
  - Runs pre_deploy hooks (sops-decrypt.sh)
  - Executes docker compose up/down
  - Reports container health back to Core
```

## Hosts

| Host | Address | SSH | Role | Managed Stacks |
|------|---------|-----|------|----------------|
| **komodo** | 192.168.11.200 | `root@komodo` | Komodo Core (self-managed) + systemd Periphery | komodo-core, komodo-alloy |
| **nvr** | 192.168.11.89 | `root@nvr` | Video recording | frigate, nvr-alloy |
| **kasm** | 192.168.11.34 | `root@kasm` | Remote desktop (KASM) | newt, kasm-alloy |
| **omni** | 192.168.11.30 | `root@omni` | Talos K8s management | omni, omni-alloy |
| **server04** | 192.168.11.17 | `mohitsharma44@server04` | App server + build server | traefik, vaultwarden, server04-alloy |
| **seaweedfs** | 192.168.11.133 | `mohitsharma44@seaweedfs` | Object storage | seaweedfs, seaweedfs-alloy |

**Notes:**
- KASM Workspaces is installer-managed and NOT managed by Komodo. Only Newt (tunnel agent) is managed on that host.
- server04 doubles as the Docker build server for custom images.
- komodo runs inside a Proxmox LXC container (ID 200).

For detailed per-host information (OS, containers, hardware, quirks), see [docs/docker-hosts.md](/docs/docker-hosts.md).

### Periphery Compose Locations

| Host | Periphery Compose Path |
|------|----------------------|
| komodo | systemd service — `/etc/komodo/periphery.config.toml` |
| nvr, kasm, omni | `/root/komodo-periphery/compose.yaml` |
| server04, seaweedfs | `~/komodo-periphery/compose.yaml` |

## Directory Structure

```
docker/
├── komodo-resources/           # TOML resource declarations (synced by Komodo)
│   ├── sync.toml               # ResourceSync self-definition
│   ├── servers.toml            # 6 host/server definitions
│   ├── variables.toml          # Non-secret variables
│   ├── builds.toml             # Custom periphery image build + builder
│   ├── procedures.toml         # Scheduled jobs (backup, rebuild, auto-update)
│   ├── stacks-komodo.toml      # Stacks for komodo host
│   ├── stacks-nvr.toml         # Stacks for nvr host
│   ├── stacks-kasm.toml        # Stacks for kasm host
│   ├── stacks-omni.toml        # Stacks for omni host
│   ├── stacks-server04.toml    # Stacks for server04 host
│   └── stacks-seaweedfs.toml   # Stacks for seaweedfs host
├── stacks/                     # Compose files + encrypted secrets
│   ├── shared/alloy/           # Shared Alloy monitoring template (all hosts)
│   ├── komodo/core/            # Komodo Core (self-managed stack)
│   ├── nvr/frigate/
│   ├── kasm/newt/
│   ├── omni/omni/
│   ├── server04/traefik/
│   ├── server04/vaultwarden/
│   └── seaweedfs/seaweedfs/
└── periphery/                  # Custom periphery Docker image
    ├── Dockerfile
    └── scripts/sops-decrypt.sh
```

## Secret Management (SOPS + age)

Secrets are SOPS-encrypted at rest in git and decrypted at deploy time by the Periphery agent.

### How It Works

1. Secrets stored as `.sops.env` or `.sops.json` files next to each `compose.yaml`
2. Compose files reference decrypted secrets via `env_file: .env`
3. Each stack's `pre_deploy` hook runs `sops-decrypt.sh` in the compose directory
4. The script decrypts `*.sops.env` → `*.env` and `*.sops.json` → `*.json`
5. Docker Compose picks up the decrypted `.env` file during `docker compose up`

### Key Locations

| Item | Path |
|------|------|
| Age public key | `age1y6dnshya496nf3072zudw3vd33723v02g3tfvpt563zng0xd9ghqwzj5xk` |
| Age private key (local) | `~/.sops/key.txt` |
| Age private key (hosts) | `/etc/sops/age/keys.txt` (perms `600`, owner `root`) |
| SOPS config | `.sops.yaml` (repo root) |

### Encrypting a New Secret

```bash
# Create a plaintext .sops.env file
cat > docker/stacks/myhost/myservice/.sops.env << 'EOF'
MY_SECRET=supersecret
DB_PASSWORD=hunter2
EOF

# Encrypt in-place (uses .sops.yaml rules)
sops -e -i docker/stacks/myhost/myservice/.sops.env

# Verify it's encrypted
cat docker/stacks/myhost/myservice/.sops.env  # Should show ENC[AES256_GCM,...] values
```

### Viewing Encrypted Secrets

```bash
sops -d docker/stacks/server04/vaultwarden/.sops.env
```

## Custom Periphery Image

The standard Komodo Periphery image doesn't include SOPS/age. A custom image extends it:

```dockerfile
FROM ghcr.io/moghtech/komodo-periphery:${PERIPHERY_TAG}
# Adds: sops (v3.9.4), age (v1.2.1), sops-decrypt.sh
```

- **Registry**: `docker.io/mohitsharma44/komodo-periphery-sops:latest`
- **Build server**: server04 (via Komodo's `periphery-custom` build)
- **Script**: `sops-decrypt.sh` — decrypts all `.sops.env`/`.sops.json`/`.sops.yaml` in the working directory

**Note**: The komodo host uses systemd Periphery with native sops+age installed directly on the host, not the custom Docker image.

### Rebuilding the Image

Via Komodo UI or CLI:
```bash
km execute run-build periphery-custom
```

Then pull and restart periphery on all hosts:
```bash
# Root hosts (excluding komodo which uses systemd Periphery)
for host in root@nvr root@kasm root@omni; do
  ssh $host "docker pull mohitsharma44/komodo-periphery-sops:latest"
done

# User hosts
for host in mohitsharma44@seaweedfs mohitsharma44@server04; do
  ssh $host "docker pull mohitsharma44/komodo-periphery-sops:latest"
done

# komodo uses systemd Periphery -- update separately:
# ssh root@komodo "curl -sSL https://raw.githubusercontent.com/moghtech/komodo/main/scripts/setup-periphery.py | python3 - --version=<new-version>"
# ssh root@komodo "systemctl restart periphery"
```

## Alloy Monitoring

Every host runs a Grafana Alloy container that collects:
- **Host metrics** — CPU, memory, disk, network (via node_exporter)
- **Container metrics** — per-container resource usage (via cAdvisor)
- **Container logs** — stdout/stderr from all Docker containers

Data is pushed to the K8s observability stack:
- Metrics → `https://prometheus.sharmamohit.com/api/v1/write`
- Logs → `https://loki.sharmamohit.com/loki/api/v1/push`

All alloy stacks share `docker/stacks/shared/alloy/compose.yaml` with per-host `HOSTNAME` set via Komodo's `environment` field in each stack TOML. Credentials (Prometheus/Loki URLs and basic auth) are in the shared `.sops.env`.

## TOML Stack Definition Pattern

Each stack follows this pattern in its TOML file:

```toml
[[stack]]
name = "my-service"
description = "What this service does"
tags = ["category", "hostname"]
[stack.config]
server_id = "hostname"
file_paths = ["docker/stacks/hostname/my-service/compose.yaml"]
repo = "mohitsharma44/homeops"
branch = "main"
environment = """
NON_SECRET_VAR=value
"""
[stack.config.pre_deploy]
path = "docker/stacks/hostname/my-service"
command = "sops-decrypt.sh"
```

Key fields:
- **`server_id`**: Which Periphery agent deploys this stack
- **`file_paths`**: Path to compose file(s) relative to repo root
- **`environment`**: Non-secret env vars (injected as `.env` at stack root)
- **`pre_deploy.path`**: Directory where the hook runs (must match compose file location for sops to find `.sops.env`)
- **`pre_deploy.command`**: Script to run before `docker compose up`

## Common Operations

### Sync Resources from Git

```bash
km execute sync 'mohitsharma44/homeops'
```

### Deploy a Stack

```bash
km execute deploy-stack <stack-name>
```

### Deploy All Alloy Stacks

```bash
for stack in kasm-alloy komodo-alloy nvr-alloy omni-alloy seaweedfs-alloy server04-alloy; do
  km execute deploy-stack "$stack" --yes
done
```

### Check Stack Status

```bash
km list stacks -a
```

### Check Server Health

```bash
km list servers -a
```

### View Deployment Logs

Check the Komodo UI at `https://komodo.sharmamohit.com` or query the API:
```bash
curl -s -H "X-API-KEY: $KEY" -H "X-API-SECRET: $SECRET" \
  -H "Content-Type: application/json" \
  -d '{"type":"ListUpdates","params":{"query":{}}}' \
  http://komodo.sharmamohit.com:9120/read
```

### Adding a New Stack

1. Create compose file at `docker/stacks/{host}/{service}/compose.yaml`
2. Create `.sops.env` with secrets (then encrypt with `sops -e -i`)
3. Add stack definition to `docker/komodo-resources/stacks-{host}.toml`
4. Commit, push, then sync: `km execute sync 'mohitsharma44/homeops'`
5. Deploy: `km execute deploy-stack {stack-name}`

## Komodo Access

| Item | Value |
|------|-------|
| UI | `https://komodo.sharmamohit.com` |
| API | `http://komodo.sharmamohit.com:9120` |
| CLI | `km` (config at `~/.config/komodo/komodo.cli.toml`) |
| Core | Port 9120 on komodo host |
| Periphery | Port 8120 on each host (TLS) |

## Known Issues and Workarounds

### Komodo Self-Management

The `komodo-core` stack is self-managed by Komodo. When Core redeploys, it restarts itself but systemd Periphery survives to bring it back. Constraints:
- `auto_update` is NOT enabled -- Core updates must be deliberate
- `deploy-all-stacks` procedure excludes `komodo-core` to prevent self-restart mid-procedure
- Deploy independently: `km execute deploy-stack komodo-core`

### AppArmor on Komodo LXC

The komodo host runs in an unprivileged Proxmox LXC container (ID 200). Docker's AppArmor integration fails because the LXC can't read `/sys/kernel/security/apparmor/profiles`. A systemd service (`mask-apparmor.service`) mounts an empty tmpfs over `/sys/kernel/security` before Docker starts, hiding AppArmor entirely.

### DNS on server04

Docker's embedded DNS doesn't forward correctly on server04. The periphery compose has explicit `dns: ["192.168.11.1"]` to work around this. Without it, `git clone` from GitHub fails inside the container.

### Age Key Ownership

The age private key at `/etc/sops/age/keys.txt` must be owned by `root:root` with `600` permissions. On hosts accessed via non-root SSH (server04, seaweedfs), the key may be initially owned by the SSH user — run `sudo chown root:root /etc/sops/age/keys.txt` to fix.

### ResourceSync Self-Reference

The ResourceSync with `delete = true` (deletes unmatched resources) must define itself in `sync.toml` to avoid self-deletion. The sync cannot modify its own config during execution — use the write API directly for changes to sync settings.
