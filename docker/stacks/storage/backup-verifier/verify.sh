#!/bin/sh
# Verify backups that have landed from other hosts, and promote the good ones
# into the archive.
#
# This is the half of the backup that holds deletion authority. The sending host
# can only write into the landing share; it cannot see or reach the archive (the
# archive is deliberately not a UGOS shared folder, so it does not even appear in
# the sender's SFTP chroot). Everything that decides what survives happens here.
#
# There is no retention prune. Decided in ticket 05 (Q19): at ~1.25 MB a night on
# an 11 TB volume, keeping everything costs nothing, and a prune step is one more
# thing that can fail silently -- which is the exact class of bug this whole
# ticket exists to fix. Do not add one without revisiting that decision.

set -eu

LANDING="${LANDING_DIR:-/landing}"
ARCHIVE="${ARCHIVE_DIR:-/archive}"
QUARANTINE="${LANDING}/_quarantine"
METRICS_FILE="${METRICS_FILE:-/run/metrics/metrics}"

log() { echo "[$(date -Is)] $*"; }
err() { echo "[$(date -Is)] ERROR: $*" >&2; }

mkdir -p "${QUARANTINE}" "$(dirname "${METRICS_FILE}")"

PROMOTED=0
FAILED=0

# Walk every <host>/<service>/ pair under the landing share, so adding Omni or
# Komodo's database later needs no change here -- just a new sender.
for src in "${LANDING}"/*/*/*.sqlite3; do
  [ -f "$src" ] || continue

  rel=${src#"${LANDING}/"}          # server04/vaultwarden/vaultwarden_x.sqlite3
  dir=$(dirname "$rel")             # server04/vaultwarden
  base=$(basename "$rel")           # vaultwarden_x.sqlite3

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
  labels="host=\"${host}\",service=\"${service}\""

  # busybox find has no -printf, so walk with stat instead. Using -printf here
  # would emit zeros forever on alpine and the freshness alert would look
  # permanently broken.
  newest=0
  count=0
  bytes=0
  for f in "$svc_dir"/*.sqlite3; do
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

log "run complete: ${PROMOTED} promoted, ${FAILED} failed"
