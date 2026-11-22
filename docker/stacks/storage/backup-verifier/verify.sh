#!/bin/sh
# Verify backups that have landed from other hosts, and promote the good ones
# into the archive.
#
# This is the half of the backup that holds deletion authority. The sending host
# can only write into the landing share; it cannot see or reach the archive (the
# archive is deliberately not a UGOS shared folder, so it does not even appear in
# the sender's SFTP chroot). Everything that decides what survives happens here.
#
# Two kinds of backup arrive:
#   *.sqlite3            (server04/vaultwarden) verified by PRAGMA integrity_check
#   *.snapshot + .sha256 (omni/omni-etcd) verified by the sender's sha256; the
#                        .sha256 lands LAST, so its presence means "complete"
#
# Retention: Vaultwarden is never pruned. Decided in ticket 05 (Q19): at ~1.25 MB
# a night keeping everything costs nothing, and a prune step is one more thing
# that can fail silently. Omni etcd snapshots are ~90 MB a day (~33 GB a year),
# which revisits that decision for them only: PRUNE_DIRS keeps 30 days, never
# deletes the newest, and refuses to run at all if the newest is over 48h old.

set -eu

LANDING="${LANDING_DIR:-/landing}"
ARCHIVE="${ARCHIVE_DIR:-/archive}"
QUARANTINE="${LANDING}/_quarantine"
METRICS_FILE="${METRICS_FILE:-/run/metrics/metrics}"
# Space-separated <host>/<service> dirs under the archive that get retention.
PRUNE_DIRS="${PRUNE_DIRS:-omni/omni-etcd}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
PRUNE_MAX_NEWEST_AGE_H="${PRUNE_MAX_NEWEST_AGE_H:-48}"

log() { echo "[$(date -Is)] $*"; }
err() { echo "[$(date -Is)] ERROR: $*" >&2; }

mkdir -p "${QUARANTINE}" "$(dirname "${METRICS_FILE}")"

# Copying a 100 MB snapshot can outlast the 15-minute cron interval; never run
# two verifiers over the same landing files at once.
exec 9> /run/verify.lock
if ! flock -n 9; then
  log "another verify run is in progress; skipping"
  exit 0
fi

PROMOTED=0
FAILED=0

# Everything under the landing share is sender-controlled, including whether a
# path is a symlink. A sender that symlinks its service dir into /archive would
# otherwise make the loops below copy, "promote" and then `rm` ARCHIVED files.
# Accept a landed file only if it, its service dir and its host dir are plain
# (not symlinks), it resolves to a path still under LANDING, and the host and
# service names fit the allowlist (they also become metric labels).
safe_name() {
  case "$1" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}
landed_ok() {
  f="$1"
  svc_d=$(dirname "$f"); host_d=$(dirname "$svc_d")
  [ ! -L "$f" ] && [ ! -L "$svc_d" ] && [ ! -L "$host_d" ] || return 1
  [ -f "$f" ] || return 1
  case "$(realpath "$f" 2>/dev/null)" in
    "${LANDING}"/*) ;;
    *) return 1 ;;
  esac
  safe_name "$(basename "$host_d")" && safe_name "$(basename "$svc_d")" && safe_name "$(basename "$f")"
}
# landed_ok checks a PATH, and the sender can rename or replace a path at any
# time -- e.g. swap its service dir for a symlink to /archive between the
# check and the `rm`, so the rm deletes the copy just promoted. So pin the
# directory: cd -P into it, confirm the physical cwd is under LANDING, and
# from then on touch only ./<basename>. The cwd holds the directory INODE;
# renames of its path cannot redirect us, and rm/mv never follow a symlink
# in the final component.
pin_dir() {
  cd / && cd -P "${LANDING}/$1" 2>/dev/null || return 1
  case "$(pwd -P)" in
    "${LANDING}"/*/*) return 0 ;;
  esac
  cd /
  return 1
}

# Walk every <host>/<service>/ pair under the landing share, so adding Omni or
# Komodo's database later needs no change here -- just a new sender.
for src in "${LANDING}"/*/*/*.sqlite3; do
  [ -e "$src" ] || [ -L "$src" ] || continue
  if ! landed_ok "$src"; then
    err "unsafe landed path (symlink, escapes landing, or bad name), ignored: ${src}"
    FAILED=$((FAILED + 1))
    continue
  fi

  rel=${src#"${LANDING}/"}          # server04/vaultwarden/vaultwarden_x.sqlite3
  dir=$(dirname "$rel")             # server04/vaultwarden
  base=$(basename "$rel")           # vaultwarden_x.sqlite3
  if ! pin_dir "$dir"; then
    err "could not pin landing dir, ignored: ${rel}"
    FAILED=$((FAILED + 1))
    continue
  fi
  src="./${base}"

  mkdir -p "${ARCHIVE}/${dir}"
  staged="${ARCHIVE}/${dir}/.incoming-${base}"

  # Copy first, then verify the COPY. Checking the landed file would prove only
  # that the sender wrote something valid; checking the archived copy proves the
  # artifact we would actually restore from is intact, and covers the copy too.
  if ! cp "$src" "$staged" 2>/dev/null; then
    err "copy into archive failed: ${rel}"
    FAILED=$((FAILED + 1))
    rm -f "$staged"
    continue
  fi

  RESULT=$(sqlite3 "$staged" 'PRAGMA integrity_check;' 2>&1 || echo "check-failed")
  if [ "$RESULT" = "ok" ]; then
    # Same-directory rename: atomic. A reader never sees a partial archive file.
    mv "$staged" "${ARCHIVE}/${dir}/${base}"
    rm -f "$src"
    PROMOTED=$((PROMOTED + 1))
    log "archived: ${rel} ($(wc -c < "${ARCHIVE}/${dir}/${base}") bytes)"
  else
    rm -f "$staged"
    mkdir -p "${QUARANTINE}/${dir}"
    mv "$src" "${QUARANTINE}/${dir}/${base}"
    FAILED=$((FAILED + 1))
    err "integrity_check FAILED for ${rel}: ${RESULT}"
    err "moved to quarantine, NOT archived: ${QUARANTINE}/${dir}/${base}"
  fi
done

cd /

# Snapshots: trust nothing until the archived COPY matches the sender's sha256.
for sidecar in "${LANDING}"/*/*/*.snapshot.sha256; do
  [ -e "$sidecar" ] || [ -L "$sidecar" ] || continue
  if ! landed_ok "$sidecar"; then
    err "unsafe landed path (symlink, escapes landing, or bad name), ignored: ${sidecar}"
    FAILED=$((FAILED + 1))
    continue
  fi
  src=${sidecar%.sha256}
  rel=${src#"${LANDING}/"}          # omni/omni-etcd/<uuid>_<name>.snapshot
  dir=$(dirname "$rel")
  base=$(basename "$rel")
  if ! pin_dir "$dir"; then
    err "could not pin landing dir, ignored: ${rel}"
    FAILED=$((FAILED + 1))
    continue
  fi
  src="./${base}"
  sidecar="./${base}.sha256"

  if [ ! -f "$src" ] || [ -L "$src" ] || [ -L "$sidecar" ]; then
    err "sidecar without a plain snapshot beside it, leaving it for the sender to retry: ${rel}.sha256"
    FAILED=$((FAILED + 1))
    continue
  fi
  expected=$(cut -d' ' -f1 "$sidecar")
  mkdir -p "${ARCHIVE}/${dir}"
  target="${ARCHIVE}/${dir}/${base}"

  # The archive is write-once. A re-sent name with the same content is a
  # harmless retry; different content under an archived name is either
  # corruption or a sender trying to overwrite history, and is quarantined.
  if [ -f "$target" ]; then
    have=$(sha256sum "$target" | cut -d' ' -f1)
    if [ "$have" = "$expected" ]; then
      rm -f "$src" "$sidecar"
      log "duplicate of archived ${rel}, identical; dropped from landing"
    else
      mkdir -p "${QUARANTINE}/${dir}"
      mv "$src" "$sidecar" "${QUARANTINE}/${dir}/"
      FAILED=$((FAILED + 1))
      err "REFUSED overwrite of archived ${rel} with different content; quarantined"
    fi
    continue
  fi

  staged="${ARCHIVE}/${dir}/.incoming-${base}"
  # NOT cp -p: mtime must be the verifier's promotion time. The sender sets
  # the landed mtime (sftp put -p) and could fake it -- a future mtime would
  # defeat the 48h retention guard and fake freshness. A promotion time this
  # host chose itself cannot be forged from outside.
  if ! cp "$src" "$staged" 2>/dev/null; then
    err "copy into archive failed: ${rel}"
    FAILED=$((FAILED + 1))
    rm -f "$staged"
    continue
  fi
  actual=$(sha256sum "$staged" | cut -d' ' -f1)
  if [ -n "$expected" ] && [ "$actual" = "$expected" ]; then
    cp "$sidecar" "${target}.sha256"
    mv "$staged" "$target"
    rm -f "$src" "$sidecar"
    PROMOTED=$((PROMOTED + 1))
    log "archived: ${rel} ($(wc -c < "$target") bytes, sha256 ${actual})"
  else
    rm -f "$staged"
    mkdir -p "${QUARANTINE}/${dir}"
    mv "$src" "$sidecar" "${QUARANTINE}/${dir}/"
    FAILED=$((FAILED + 1))
    err "sha256 MISMATCH for ${rel}: expected ${expected:-<empty>}, got ${actual}; quarantined, NOT archived"
  fi
done

cd /

# ---------------------------------------------------------------------------
# Retention, for PRUNE_DIRS only. mtime is the verifier's promotion time (see
# the cp above), so "30 days" means 30 days since the copy was archived.
# ---------------------------------------------------------------------------
PRUNED=0
for pd in ${PRUNE_DIRS}; do
  adir="${ARCHIVE}/${pd}"
  [ -d "$adir" ] || continue
  newest_f=$(ls -1t "$adir"/*.snapshot 2>/dev/null | head -n 1)
  [ -n "$newest_f" ] || continue
  age_h=$(( ($(date +%s) - $(stat -c %Y "$newest_f")) / 3600 ))
  if [ "$age_h" -ge "$PRUNE_MAX_NEWEST_AGE_H" ]; then
    err "retention ${pd}: REFUSED, newest archived snapshot is ${age_h}h old (limit ${PRUNE_MAX_NEWEST_AGE_H}h)"
    FAILED=$((FAILED + 1))
    continue
  fi
  for f in $(find "$adir" -maxdepth 1 -name '*.snapshot' -mtime "+${RETENTION_DAYS}"); do
    [ "$f" = "$newest_f" ] && continue
    rm -f "$f" "${f}.sha256"
    PRUNED=$((PRUNED + 1))
    log "retention ${pd}: deleted $(basename "$f") (older than ${RETENTION_DAYS}d)"
  done
done

# ---------------------------------------------------------------------------
# Metrics. Written as a plain text file and served over HTTP by busybox httpd,
# so Prometheus pulls rather than us pushing. Pull matters here: if this
# container dies, the target goes down and `up == 0` fires, whereas a push-based
# job that stops running just leaves a stale metric that looks fine until
# someone thinks to check its age.
# ---------------------------------------------------------------------------
TMP="${METRICS_FILE}.tmp"
: > "$TMP"

emit_service() {
  svc_dir="$1"
  [ -d "$svc_dir" ] || return 0
  host=$(basename "$(dirname "$svc_dir")")
  service=$(basename "$svc_dir")
  # Label values go into the exposition format verbatim; refuse anything that
  # could break out of the quotes.
  safe_name "$host" && safe_name "$service" || return 0
  labels="host=\"${host}\",service=\"${service}\""

  # busybox find has no -printf, so walk with stat instead. Using -printf here
  # would emit zeros forever on alpine and the freshness alert would look
  # permanently broken.
  newest=0
  count=0
  bytes=0
  # The metric names say "vaultwarden" for history: the freshness alert is
  # keyed on them and already carries host/service labels, so Omni snapshots
  # are counted under the same names rather than forking the alert.
  for f in "$svc_dir"/*.sqlite3 "$svc_dir"/*.snapshot; do
    [ -f "$f" ] || continue
    mtime=$(stat -c %Y "$f")
    size=$(stat -c %s "$f")
    # NOT `[ ... ] && newest=$mtime` -- under `set -e` a false test makes the
    # whole statement return 1 and kills the script.
    if [ "$mtime" -gt "$newest" ]; then
      newest=$mtime
    fi
    count=$((count + 1))
    bytes=$((bytes + size))
  done

  {
    echo "vaultwarden_backup_last_success_timestamp_seconds{${labels}} ${newest}"
    echo "vaultwarden_backup_archived_files{${labels}} ${count}"
    echo "vaultwarden_backup_archive_bytes{${labels}} ${bytes}"
  } >> "$TMP"
}

{
  echo "# HELP vaultwarden_backup_last_success_timestamp_seconds Unix time of the newest VERIFIED backup in the archive."
  echo "# TYPE vaultwarden_backup_last_success_timestamp_seconds gauge"
  echo "# HELP vaultwarden_backup_archived_files Number of verified backups in the archive."
  echo "# TYPE vaultwarden_backup_archived_files gauge"
  echo "# HELP vaultwarden_backup_archive_bytes Total bytes of verified backups in the archive."
  echo "# TYPE vaultwarden_backup_archive_bytes gauge"
} >> "$TMP"

for svc in "${ARCHIVE}"/*/*/; do
  emit_service "${svc%/}"
done

{
  echo "# HELP vaultwarden_backup_verify_run_timestamp_seconds Unix time this verifier last completed a run."
  echo "# TYPE vaultwarden_backup_verify_run_timestamp_seconds gauge"
  echo "vaultwarden_backup_verify_run_timestamp_seconds $(date +%s)"
  echo "# HELP vaultwarden_backup_promoted_last_run Backups promoted to the archive on the last run."
  echo "# TYPE vaultwarden_backup_promoted_last_run gauge"
  echo "vaultwarden_backup_promoted_last_run ${PROMOTED}"
  echo "# HELP vaultwarden_backup_verify_failures_last_run Backups that failed integrity_check on the last run."
  echo "# TYPE vaultwarden_backup_verify_failures_last_run gauge"
  echo "vaultwarden_backup_verify_failures_last_run ${FAILED}"
} >> "$TMP"

mv "$TMP" "${METRICS_FILE}"

log "run complete: ${PROMOTED} promoted, ${FAILED} failed, ${PRUNED} pruned"
