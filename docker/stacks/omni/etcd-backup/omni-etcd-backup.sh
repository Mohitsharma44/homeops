#!/bin/bash
# Prune local Omni etcd backups and push new ones off-host to the storage host.
#
# HOST-LEVEL, NOT A KOMODO STACK. Installed on the omni host (root@omni) as
# /usr/local/sbin/omni-etcd-backup and run hourly by omni-etcd-backup.timer.
# Install / update:
#   scp omni-etcd-backup.sh       root@omni:/usr/local/sbin/omni-etcd-backup
#   scp omni-etcd-backup.service omni-etcd-backup.timer root@omni:/etc/systemd/system/
#   ssh root@omni 'chmod 755 /usr/local/sbin/omni-etcd-backup && systemctl daemon-reload \
#                  && systemctl enable --now omni-etcd-backup.timer'
#
# Omni writes a backup of each cluster's etcd to
# /opt/omni-etcd-backups/<cluster-uuid>/<name>.snapshot every 24h and never
# deletes one. Names are an INVERTED timestamp (the newest has the smallest
# name), so everything here orders by mtime, never by name.
#
# Order matters (the Vaultwarden `set -e` lesson): the local prune runs first and
# the network push is called inside `if`, so a dead NAS can never skip the prune
# or hide its own failure. The unit still exits non-zero when anything failed,
# so `systemctl --failed` shows it.
#
# Off-host design mirrors server04/vaultwarden: the sender (svc-omni) can only
# write into the NAS's backup-landing share. The backup-verifier container on the
# NAS checks each snapshot against the .sha256 written here, promotes it into
# backup-archive (a share no sender can see) and owns retention there.
#
#   omni-etcd-backup            prune + push
#   omni-etcd-backup --dry-run  print what the prune WOULD delete; no push

set -u

BACKUP_ROOT="${BACKUP_ROOT:-/opt/omni-etcd-backups}"
KEEP="${KEEP:-14}"                         # newest N kept per cluster
MAX_NEWEST_AGE_H="${MAX_NEWEST_AGE_H:-48}" # refuse to prune if the newest is older
MIN_AGE_MIN="${MIN_AGE_MIN:-10}"           # never push a file Omni may still be writing
STATE_DIR="${STATE_DIR:-/var/lib/omni-etcd-backup}"
CONF_DIR="${CONF_DIR:-/etc/omni-etcd-backup}"
SFTP_HOST="${SFTP_HOST:-192.168.11.244}"
SFTP_USER="${SFTP_USER:-svc-omni}"
# A path inside UGOS's SFTP chroot, which shows share names at /:
# this is /volume1/backup-landing/omni/omni-etcd on the NAS.
SFTP_DEST="${SFTP_DEST:-/backup-landing/omni/omni-etcd}"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

log() { echo "[$(date -Is)] $*"; }
err() { echo "[$(date -Is)] ERROR: $*" >&2; }

FAILED=0
now=$(date +%s)

# ---------------------------------------------------------------------------
# 1. Local prune: keep the newest $KEEP per cluster, by mtime.
# ---------------------------------------------------------------------------
for cdir in "${BACKUP_ROOT}"/*/; do
  [ -d "$cdir" ] || continue
  cluster=$(basename "$cdir")
  mapfile -t snaps < <(ls -1t "${cdir}"*.snapshot 2>/dev/null)
  count=${#snaps[@]}
  if [ "$count" -eq 0 ]; then
    log "prune ${cluster}: no snapshots"
    continue
  fi
  newest_age_h=$(( (now - $(stat -c %Y "${snaps[0]}")) / 3600 ))
  if [ "$newest_age_h" -ge "$MAX_NEWEST_AGE_H" ]; then
    # Omni has stopped producing backups. Pruning now would age out the last
    # good copies one by one, so do nothing and make the failure loud.
    err "prune ${cluster}: REFUSED, newest snapshot is ${newest_age_h}h old (limit ${MAX_NEWEST_AGE_H}h); Omni backups may be broken"
    FAILED=1
    continue
  fi
  if [ "$count" -le "$KEEP" ]; then
    log "prune ${cluster}: ${count} snapshot(s), keep ${KEEP}; nothing to delete (newest ${newest_age_h}h old)"
    continue
  fi
  # snaps[0] is the newest; indices >= KEEP (>= 1 always) are the excess.
  for ((i = KEEP; i < count; i++)); do
    if [ "$DRY_RUN" -eq 1 ]; then
      log "prune ${cluster}: WOULD delete ${snaps[$i]}"
    else
      rm -f -- "${snaps[$i]}" && log "prune ${cluster}: deleted ${snaps[$i]}"
    fi
  done
done

if [ "$DRY_RUN" -eq 1 ]; then
  log "dry run: no push"
  exit "$FAILED"
fi

# ---------------------------------------------------------------------------
# 2. Push every local snapshot not yet pushed, oldest first.
#    Remote name: <cluster-uuid>_<name>.snapshot, plus <that>.sha256.
#    Both upload as .part and are renamed; the .sha256 rename is LAST because
#    it is what tells the verifier the snapshot is complete.
# ---------------------------------------------------------------------------
PUSHED_LIST="${STATE_DIR}/pushed"
touch "$PUSHED_LIST"
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

push_one() {
  local src="$1" rname="$2"
  ( cd "$TMPD" && sha256sum "$src" | awk -v n="$rname" '{print $1 "  " n}' > "${rname}.sha256" ) || return 1
  # -b - is batch mode: abort on the first failed command and exit non-zero.
  # A leading '-' ignores that command's failure: it clears debris from an
  # earlier interrupted attempt so the renames below cannot collide with it.
  sftp -q -b - \
    -i "${CONF_DIR}/id_ed25519" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="${CONF_DIR}/known_hosts" \
    -o ConnectTimeout=30 \
    "${SFTP_USER}@${SFTP_HOST}" <<SFTPEOF
-rm ${SFTP_DEST}/${rname}.part
-rm ${SFTP_DEST}/${rname}.sha256.part
-rm ${SFTP_DEST}/${rname}.sha256
-rm ${SFTP_DEST}/${rname}
put -p ${src} ${SFTP_DEST}/${rname}.part
put ${TMPD}/${rname}.sha256 ${SFTP_DEST}/${rname}.sha256.part
rename ${SFTP_DEST}/${rname}.part ${SFTP_DEST}/${rname}
rename ${SFTP_DEST}/${rname}.sha256.part ${SFTP_DEST}/${rname}.sha256
SFTPEOF
}

PUSHED=0
while IFS= read -r src; do
  [ -n "$src" ] || continue
  cluster=$(basename "$(dirname "$src")")
  rname="${cluster}_$(basename "$src")"
  grep -qxF "$rname" "$PUSHED_LIST" && continue
  if [ $(( now - $(stat -c %Y "$src") )) -lt $(( MIN_AGE_MIN * 60 )) ]; then
    log "push: skipping ${rname}, younger than ${MIN_AGE_MIN}m"
    continue
  fi
  if push_one "$src" "$rname"; then
    echo "$rname" >> "$PUSHED_LIST"
    PUSHED=$((PUSHED + 1))
    log "push OK: ${SFTP_USER}@${SFTP_HOST}:${SFTP_DEST}/${rname} ($(cut -d' ' -f1 "${TMPD}/${rname}.sha256"))"
  else
    err "push FAILED: ${rname}; local prune already ran, only the off-host copy is missing"
    FAILED=1
    break   # the NAS is unreachable or refusing; retry next hour
  fi
done < <(ls -1tr "${BACKUP_ROOT}"/*/*.snapshot 2>/dev/null)

# Forget names that no longer exist locally, so the state file stays bounded.
if [ -s "$PUSHED_LIST" ]; then
  : > "${PUSHED_LIST}.new"
  while IFS= read -r rname; do
    f="${BACKUP_ROOT}/${rname%%_*}/${rname#*_}"
    [ -f "$f" ] && echo "$rname" >> "${PUSHED_LIST}.new"
  done < "$PUSHED_LIST"
  mv "${PUSHED_LIST}.new" "$PUSHED_LIST"
fi

log "run complete: ${PUSHED} pushed, failed=${FAILED}"
exit "$FAILED"
