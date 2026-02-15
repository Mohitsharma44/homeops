# Docker Infrastructure — Komodo GitOps

Manages Docker containers across 6 hosts via [Komodo](https://komo.do) Resource Sync.

## Structure

```
docker/
├── komodo-resources/   # TOML declarations for Komodo Resource Sync
├── stacks/             # Compose files + SOPS-encrypted secrets per host/service
│   ├── nvr/            # Frigate NVR
│   ├── kasm/           # Newt tunnel agent
│   ├── omni/           # Siderolabs Omni
│   ├── server04/       # Traefik, Vaultwarden, BookStack, DNS, etc.
│   ├── seaweedfs/      # SeaweedFS distributed storage
│   └── shared/         # Shared templates (Alloy monitoring)
└── periphery/          # Custom periphery image (SOPS + age)
```

## Secret Management

Secrets are stored as SOPS-encrypted files (`.sops.env`, `.sops.json`) alongside compose files.
A custom periphery image with `sops` + `age` decrypts them at deploy time via `pre_deploy` hooks.

Age key location on hosts: `/etc/sops/age/keys.txt`
