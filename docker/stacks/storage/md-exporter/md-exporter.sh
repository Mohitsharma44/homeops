#!/bin/sh
# Export md-array scrub state that node_exporter's mdadm collector does not.
#
# node_exporter gives node_md_disks / node_md_state, which answers "is the
# array degraded". It does NOT expose:
#
#   - mismatch_cnt        -- the parity-inconsistency count a scrub produces,
#                            which is the entire *result* of scrubbing
#   - last_sync_action    -- whether the last sync was a scrub (`check`) or
#                            merely the array build (`resync`)
#   - when a scrub last finished -- sysfs has no such field at all
#
# The last one is why this polls rather than just reads. The kernel records
# that a check is running (`sync_action`), but the moment it finishes it
# reverts to `idle` and keeps no timestamp. So completion has to be *observed*:
# poll, and when the action transitions check -> idle, stamp the clock and
# persist it. State lives on /volume2 so it survives container recreation.
#
# Why scrub freshness is worth a metric at all: UGOS schedules the scrub
# ("Data Organizing", monthly on the 18th at 03:00). Nothing tells us if that
# schedule silently stops -- which is precisely the failure mode this whole
# map exists to clean up, where Loki was down 50 days while everything
# reported healthy.

set -eu

STATE_DIR="${STATE_DIR:-/state}"
METRICS_FILE="${METRICS_FILE:-/run/metrics/metrics}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"

mkdir -p "$STATE_DIR"

# State is keyed by the array's UUID, NEVER by its device name.
#
# /etc/mdadm/mdadm.conf on this host has no ARRAY lines and both arrays share
# the superblock name UGREEN-DATA-x86_64-61DAE2, so md0/md1/md2 are assigned by
# assembly order at boot and are NOT stable. They demonstrably swapped across
# the 2026-08-19 reboot: md1 went from 4 disks to 2 and md2 from 2 to 4,
# confirmed in the node_md_disks history.
#
# When that happened, this exporter's state -- then keyed by device name --
# stayed put while the arrays moved underneath it. The RAID6's scrub of
# 2026-08-18 was thereafter reported as belonging to the RAID1, and the RAID6,
# which actually holds Garage, the Vaultwarden archive and the Frigate
# recordings, reported 0 ("never scrubbed"). Both numbers were wrong and the
# freshness alert was watching the wrong array entirely.
#
# `uuid` is exposed at /sys/block/mdX/md/uuid (present on this host's 6.12
# kernel) and is the array's identity, not its enumeration. The device name is
# still exported as a label because it is what a human sees in /proc/mdstat --
# but nothing keys off it.

# Read a persisted scalar, defaulting to 0 when this is the first ever run.
# 0 is deliberate and meaningful: "no scrub has ever been observed" is exactly
# what a completion timestamp of 0 says, and it makes the freshness alert fire
# rather than stay silent on an array that has genuinely never been scrubbed.
read_state() {
    _f="$STATE_DIR/$1"
    if [ -r "$_f" ]; then cat "$_f"; else echo 0; fi
}

write_state() {
    printf '%s\n' "$2" > "$STATE_DIR/$1"
}

collect() {
    _now=$(date +%s)
    _tmp="${METRICS_FILE}.tmp"

    {
        echo "# HELP md_exporter_last_poll_timestamp_seconds Unix time of the last successful poll of sysfs."
        echo "# TYPE md_exporter_last_poll_timestamp_seconds gauge"
        echo "md_exporter_last_poll_timestamp_seconds ${_now}"

        echo "# HELP md_array_mismatch_cnt Sectors where the array's parity did not agree, as counted by the most recent sync."
        echo "# TYPE md_array_mismatch_cnt gauge"

        echo "# HELP md_array_scrub_in_progress 1 while a check (scrub) is running on the array."
        echo "# TYPE md_array_scrub_in_progress gauge"

        echo "# HELP md_array_scrub_last_completion_timestamp_seconds Unix time a check last finished. 0 means no scrub has ever been observed."
        echo "# TYPE md_array_scrub_last_completion_timestamp_seconds gauge"

        echo "# HELP md_array_last_sync_was_check 1 if the array's most recent sync action was a check (scrub) rather than a resync or recovery."
        echo "# TYPE md_array_last_sync_was_check gauge"

        for _dir in /sys/block/md*/md; do
            [ -d "$_dir" ] || continue
            _md=$(basename "$(dirname "$_dir")")

            # The stable identity. Falls back to the device name only on a
            # kernel too old to expose uuid, which this host is not -- and the
            # fallback is explicitly the unstable behaviour, so it is better to
            # know it is in use than to silently key off a name.
            _uuid=$(cat "$_dir/uuid" 2>/dev/null || echo "")
            _level=$(cat "$_dir/level" 2>/dev/null || echo unknown)
            if [ -n "$_uuid" ]; then
                _key="$_uuid"
            else
                _key="$_md"
                echo "md-exporter: ${_md} exposes no uuid; falling back to the UNSTABLE device name as state key" >&2
            fi

            _action=$(cat "$_dir/sync_action" 2>/dev/null || echo unknown)
            _last=$(cat "$_dir/last_sync_action" 2>/dev/null || echo unknown)
            _mismatch=$(cat "$_dir/mismatch_cnt" 2>/dev/null || echo 0)

            # Transition detection. The previous action is remembered across
            # polls; a check that has just stopped running is the only thing
            # that advances the completion stamp. Note this deliberately
            # stamps completion for an *aborted* check too -- the kernel does
            # not distinguish, and treating an abort as "never scrubbed" would
            # make the freshness alert fire forever on a host where scrubs are
            # cancelled for load. mismatch_cnt is the signal that matters, and
            # it is exported regardless.
            _prev=$(read_state "${_key}.prev_action")
            if [ "$_prev" = "check" ] && [ "$_action" != "check" ]; then
                write_state "${_key}.last_check_completion" "$_now"
            fi
            write_state "${_key}.prev_action" "$_action"

            _completion=$(read_state "${_key}.last_check_completion")

            _in_progress=0
            [ "$_action" = "check" ] && _in_progress=1

            _was_check=0
            [ "$_last" = "check" ] && _was_check=1

            # Alerts MUST select on level (or uuid), never on array -- see the
            # comment above read_state. `array` is here for humans only.
            _lbl="array=\"${_md}\",uuid=\"${_uuid}\",level=\"${_level}\""

            echo "md_array_mismatch_cnt{${_lbl}} ${_mismatch}"
            echo "md_array_scrub_in_progress{${_lbl}} ${_in_progress}"
            echo "md_array_scrub_last_completion_timestamp_seconds{${_lbl}} ${_completion}"
            echo "md_array_last_sync_was_check{${_lbl}} ${_was_check}"
        done
    } > "$_tmp"

    # Rename rather than write in place, so a scrape that lands mid-collection
    # never reads a half-written exposition and fails to parse.
    mv "$_tmp" "$METRICS_FILE"
}

while true; do
    # A failed collection must not kill the loop. If it did, the exporter would
    # stop serving the very metric whose absence is supposed to raise the
    # alarm -- and `up` would still be 1 because httpd is a separate process.
    collect || echo "md-exporter: collection failed; keeping previous metrics" >&2
    sleep "$POLL_INTERVAL"
done
