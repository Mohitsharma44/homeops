#!/bin/sh
# Nightly vaultwarden backup: local snapshot + local prune + off-host push to the
# storage host (UGREEN NAS) over SFTP.
#
# Ordering is deliberate and load-bearing. The previous version ran
#   snapshot -> upload -> local prune -> remote prune
# under `set -eu`. When the upload host died, curl exited 7, `set -e` killed the
# script before the `if` that would have logged the error, and BOTH prunes were
# skipped. The failure was silent by construction: the error branch was
# unreachable. See ticket 05.
#
# This version runs
#   snapshot -> local prune -> off-host push
# so the two steps that must always happen are done before anything that talks to
# the network, and the push is called in an `if` so a failure is reported rather
# than fatal.
#
# Deletion authority does NOT live here. This script only ever adds files
# off-host; pruning the off-host copy is the storage host's job, and the archive
# directory there is not writable by this host's identity. Do not add a remote
# prune step.

set -eu

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RETENTION_DAYS="${RETENTION_DAYS:-180}"
BACKUP_DIR="/backups"
BACKUP_FILE="vaultwarden_${TIMESTAMP}.sqlite3"

SFTP_HOST="${SFTP_HOST}"
SFTP_USER="${SFTP_USER}"
SFTP_DEST="${SFTP_DEST}"
SSH_KEY="/run/backup/id_ed25519"
KNOWN_HOSTS="/run/backup/known_hosts"

log() { echo "[$(date -Is)] $*"; }
err() { echo "[$(date -Is)] ERROR: $*" >&2; }

# ---------------------------------------------------------------------------
# 1. Local snapshot. If this fails the script SHOULD die -- there is nothing to
#    push and nothing to prune, and `set -e` gives us a non-zero exit.
# ---------------------------------------------------------------------------
sqlite3 /data/db.sqlite3 ".backup '${BACKUP_DIR}/${BACKUP_FILE}'"
FILESIZE=$(wc -c < "${BACKUP_DIR}/${BACKUP_FILE}")
log "local backup: ${BACKUP_FILE} (${FILESIZE} bytes)"

# Verify what we just wrote before it is offered to anyone else. A snapshot that
# fails integrity_check is worse than no snapshot, because it looks like one.
INTEGRITY=$(sqlite3 "${BACKUP_DIR}/${BACKUP_FILE}" 'PRAGMA integrity_check;' 2>&1 || echo "check-failed")
if [ "$INTEGRITY" != "ok" ]; then
  err "local snapshot failed integrity_check: ${INTEGRITY}"
  err "not pushing a corrupt snapshot off-host; leaving it in place for inspection"
  exit 1
fi
log "integrity_check ok: ${BACKUP_FILE}"

# ---------------------------------------------------------------------------
# 2. Prune local backups. Runs BEFORE the network step so a push failure can
#    never skip it again.
# ---------------------------------------------------------------------------
PRUNED=0
for f in $(find "${BACKUP_DIR}" -name 'vaultwarden_*.sqlite3' -mtime "+${RETENTION_DAYS}" 2>/dev/null); do
  rm -f "$f" && PRUNED=$((PRUNED + 1))
  log "pruned local: $f"
done
log "local prune complete: ${PRUNED} file(s) removed, retention ${RETENTION_DAYS}d"

# ---------------------------------------------------------------------------
# 3. Push off-host over SFTP.
#
#    Called inside `if` so `set -e` does not abort on failure -- that is the
#    whole bug this rewrite exists to fix. Upload to a .part name and rename on
#    completion, so the storage host never sees a half-written file and mistakes
#    it for a finished backup.
# ---------------------------------------------------------------------------
push_offhost() {
  # -b - reads commands from stdin in BATCH mode: sftp aborts on the first failed
  # command and exits non-zero. Without -b it keeps going and can exit 0 even
  # when the put failed, which would make this whole rewrite pointless.
  sftp -q -b - \
    -i "${SSH_KEY}" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="${KNOWN_HOSTS}" \
    -o ConnectTimeout=30 \
    "${SFTP_USER}@${SFTP_HOST}" <<SFTPEOF
put ${BACKUP_DIR}/${BACKUP_FILE} ${SFTP_DEST}/${BACKUP_FILE}.part
rename ${SFTP_DEST}/${BACKUP_FILE}.part ${SFTP_DEST}/${BACKUP_FILE}
SFTPEOF
}

if push_offhost; then
  log "off-host push OK: ${SFTP_USER}@${SFTP_HOST}:${SFTP_DEST}/${BACKUP_FILE}"
else
  err "off-host push FAILED (exit $?): ${SFTP_USER}@${SFTP_HOST}:${SFTP_DEST}/${BACKUP_FILE}"
  err "local backup and local prune both completed; only the off-host copy is missing"
  err "the storage host will not emit a success metric, so the freshness alert will fire"
fi

log "backup complete"
