#!/bin/bash
# Decrypt all SOPS-encrypted files in the current directory.
# Called as pre_deploy hook by Komodo stacks.
set -euo pipefail
shopt -s dotglob

export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-/etc/sops/age/keys.txt}"

for f in *.sops.env; do
    [ -f "$f" ] || continue
    sops -d "$f" > "${f/.sops.env/.env}"
done

for f in *.sops.json; do
    [ -f "$f" ] || continue
    sops -d "$f" > "${f/.sops.json/.json}"
done

for f in *.sops.yaml; do
    [ -f "$f" ] || continue
    sops -d "$f" > "${f/.sops.yaml/.yaml}"
done
