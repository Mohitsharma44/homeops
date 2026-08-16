#!/bin/sh
# Trigger a Garage metadata snapshot on wall clock, prune old ones, and export
# the age of the newest as Prometheus metrics.
#
# Why this exists at all, rather than trusting Garage's own
# metadata_auto_snapshot_interval = "6h":
#
#   1. The built-in timer schedules off Instant::now() at process start (first
#      fire at interval/2) and NEVER PERSISTS. Every restart resets it, so a
#      container that restarts more often than ~3h snapshots never -- silently.
#      Garage restarted three times on 2026-08-16 alone. Ticket 10 measured this
#      and found no snapshot had EVER been taken despite the setting being right.
#   2. Garage exports no snapshot metric in any of its 44 metric families, so
#      freshness cannot be alarmed from Garage itself. It has to be measured on
#      the filesystem, which is what the metrics below do.
#
# The built-in timer is deliberately left at 6h as a backstop. Do NOT lower it:
# a short interval crash-loops Garage at startup, and the failure only appears
# at the next restart, possibly long after the edit.
#
# A snapshot is the only protection this store's metadata has. replication_factor
# is 1, so Garage provides no redundancy for the index; the data blocks sit on
# RAID6 but the LMDB that names them does not.

set -eu

SNAP_DIR="${SNAPSHOT_DIR:-/snapshots}"
ADMIN="${GARAGE_ADMIN_URL:-http://127.0.0.1:3903}"
KEEP="${SNAPSHOT_KEEP:-12}"
METRICS_FILE="${METRICS_FILE:-/run/metrics/metrics}"

log() { echo "[$(date -Is)] $*"; }
err() { echo "[$(date -Is)] ERROR: $*" >&2; }

mkdir -p "$(dirname "${METRICS_FILE}")"

# ---------------------------------------------------------------------------
# Trigger.
#
# node=self is REQUIRED -- without it the endpoint returns 400. The call is
# synchronous and slow: measured at 28 s onto the SSD and 96 s onto the RAID6
# for ~429 MB of metadata, so the timeout is generous on purpose. A snapshot cut
# short is worse than no snapshot, because it still lands in the directory and
# would satisfy the freshness alert while being unrestorable.
# ---------------------------------------------------------------------------
TRIGGER_OK=0
if RESP=$(curl -sS -X POST --max-time 600 \
            -H "Authorization: Bearer ${GARAGE_ADMIN_TOKEN}" \
            "${ADMIN}/v2/CreateMetadataSnapshot?node=self" 2>&1); then
  # The endpoint returns 200 with a per-node success/error map, so an HTTP 200
  # is not by itself proof. Check that the error map is empty.
  case "$RESP" in
    *'"error":{}'*) TRIGGER_OK=1; log "snapshot created" ;;
    *) err "snapshot call returned 200 but reported an error: ${RESP}" ;;
  esac
else
  err "snapshot call failed: ${RESP}"
fi

# ---------------------------------------------------------------------------
# Prune.
#
# Snapshots are full copies of the LMDB, not increments -- at the measured
# 2322 bytes/object they reach ~450 MB at 200k objects, so four a day fills the
# array without this. Names are ISO-8601 UTC timestamps, which sort
# lexicographically in time order, so "all but the last N" is just a sort.
#
# Pruning runs even when the trigger failed: keeping a fixed count is safe
# either way, and skipping it on failure would let a store that cannot snapshot
# also stop reclaiming space.
# ---------------------------------------------------------------------------
PRUNED=0
if [ -d "${SNAP_DIR}" ]; then
  # -maxdepth 1 -mindepth 1 so the snapshot directory itself is never a
  # candidate. Anchored to -type d: a stray file here must not be deleted
  # silently, it should be noticed.
  TOTAL=$(find "${SNAP_DIR}" -mindepth 1 -maxdepth 1 -type d | wc -l)
  if [ "${TOTAL}" -gt "${KEEP}" ]; then
    DROP=$((TOTAL - KEEP))
    find "${SNAP_DIR}" -mindepth 1 -maxdepth 1 -type d | sort | head -n "${DROP}" |
      while IFS= read -r old; do
        # Belt and braces: never recurse outside the snapshot directory.
        case "$old" in
          "${SNAP_DIR}"/*)
            rm -rf "$old" && log "pruned $(basename "$old")"
            ;;
          *)
            err "refusing to prune path outside ${SNAP_DIR}: ${old}"
            ;;
        esac
      done
    PRUNED="${DROP}"
  fi
fi

# ---------------------------------------------------------------------------
# Metrics. Same reasoning as backup-verifier: a text file served by busybox
# httpd, so Prometheus pulls. If this container dies the target goes down and
# up == 0 fires, whereas a push job that stops running leaves a stale metric
# that looks healthy until somebody thinks to check its age. That is exactly
# how the SeaweedFS outage went unnoticed for 50 days.
# ---------------------------------------------------------------------------
NEWEST=0
COUNT=0
BYTES=0
if [ -d "${SNAP_DIR}" ]; then
  for d in "${SNAP_DIR}"/*/; do
    [ -d "$d" ] || continue
    mtime=$(stat -c %Y "$d")
    # NOT `[ ... ] && NEWEST=$mtime` -- under `set -e` a false test makes the
    # whole statement return 1 and kills the script.
    if [ "$mtime" -gt "$NEWEST" ]; then
      NEWEST=$mtime
    fi
    COUNT=$((COUNT + 1))
    size=$(du -sk "$d" 2>/dev/null | cut -f1)
    BYTES=$((BYTES + size * 1024))
  done
fi

TMP="${METRICS_FILE}.tmp"
{
  echo "# HELP garage_snapshot_newest_timestamp_seconds Unix time of the newest metadata snapshot on disk."
  echo "# TYPE garage_snapshot_newest_timestamp_seconds gauge"
  echo "garage_snapshot_newest_timestamp_seconds ${NEWEST}"
  echo "# HELP garage_snapshot_count Number of metadata snapshots retained."
  echo "# TYPE garage_snapshot_count gauge"
  echo "garage_snapshot_count ${COUNT}"
  echo "# HELP garage_snapshot_bytes Total bytes of retained metadata snapshots."
  echo "# TYPE garage_snapshot_bytes gauge"
  echo "garage_snapshot_bytes ${BYTES}"
  echo "# HELP garage_snapshot_trigger_success Whether the last snapshot trigger succeeded."
  echo "# TYPE garage_snapshot_trigger_success gauge"
  echo "garage_snapshot_trigger_success ${TRIGGER_OK}"
  echo "# HELP garage_snapshot_pruned_last_run Snapshots deleted on the last run."
  echo "# TYPE garage_snapshot_pruned_last_run gauge"
  echo "garage_snapshot_pruned_last_run ${PRUNED}"
  echo "# HELP garage_snapshot_run_timestamp_seconds Unix time this snapshotter last completed a run."
  echo "# TYPE garage_snapshot_run_timestamp_seconds gauge"
  echo "garage_snapshot_run_timestamp_seconds $(date +%s)"
} > "$TMP"
mv "$TMP" "${METRICS_FILE}"

log "run complete: trigger_ok=${TRIGGER_OK} count=${COUNT} pruned=${PRUNED} newest=${NEWEST}"
