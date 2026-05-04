#!/bin/bash
# ThreatHive blocklist import script for CrowdSec
# Downloads and imports IPs from ThreatHive into CrowdSec decisions.
#
# Two non-obvious facts about `cscli decisions import` (CrowdSec 1.7.x):
# - The `origin` field in the input JSON is IGNORED — cscli hard-codes
#   imported decisions to origin="cscli-import". Don't bother setting it.
# - The expected scenario field is named `reason`, NOT `scenario`. Anything
#   under `scenario` is silently dropped and the decision ends up tagged
#   scenario="manual" (the cscli default), which makes targeted deletion
#   impossible — bug we hit on 2026-05-04.

set -e

BLOCKLIST_URL="https://threathive.net/hiveblocklist.txt"
TMP_FILE="/tmp/threathive_blocklist.txt"
JSON_FILE="/tmp/threathive_decisions.json"
SCENARIO="threathive/blocklist"
DB_FILE="/var/lib/crowdsec/data/crowdsec.db"

echo "[$(date)] Starting ThreatHive blocklist import..."

# Download the blocklist (using wget - curl not available in alpine)
wget -q -O "$TMP_FILE" "$BLOCKLIST_URL"

if [ ! -s "$TMP_FILE" ]; then
    echo "[$(date)] ERROR: Failed to download blocklist or file is empty"
    exit 1
fi

IP_COUNT=$(wc -l < "$TMP_FILE" | tr -d ' ')
echo "[$(date)] Downloaded $IP_COUNT IPs from ThreatHive"

# Remove previous ThreatHive decisions before re-importing. Match by
# --scenario (preserved through `cscli decisions import` via the `reason`
# JSON field) rather than --origin "threathive" (would match nothing —
# cscli forces origin=cscli-import on every import).
echo "[$(date)] Removing previous ThreatHive decisions..."
cscli decisions delete --scenario "$SCENARIO" --all 2>/dev/null || true

# Safety net: cscli-import decisions don't get an alert FK, so CrowdSec's
# normal alert-retention flush never reaches them. Without this sweep, any
# decision the scenario-based delete above misses (e.g. legacy entries with
# scenario=manual) accumulates forever — we found 712k such orphans at
# 527MB and it took out the LAPI stream endpoint for ~3 months.
if [ -f "$DB_FILE" ]; then
    apk add --no-cache sqlite >/dev/null 2>&1 || true
    if command -v sqlite3 >/dev/null; then
        SWEPT=$(sqlite3 "$DB_FILE" "DELETE FROM decisions WHERE until < datetime('now') RETURNING 1;" 2>/dev/null | wc -l)
        echo "[$(date)] Swept $SWEPT expired orphan decisions from sqlite"
    fi
fi

# Convert IPs to JSON format. `reason` is the field cscli decisions import
# actually honors; it ends up as the decision's scenario in the DB.
echo "[$(date)] Converting to JSON format..."
echo "[" > "$JSON_FILE"
first=true
while IFS= read -r ip; do
    # Skip empty lines and comments
    [[ -z "$ip" || "$ip" =~ ^# ]] && continue

    if [ "$first" = true ]; then
        first=false
    else
        echo "," >> "$JSON_FILE"
    fi

    cat >> "$JSON_FILE" << EOF
  {
    "duration": "24h",
    "reason": "$SCENARIO",
    "scope": "ip",
    "type": "ban",
    "value": "$ip"
  }
EOF
done < "$TMP_FILE"
echo "]" >> "$JSON_FILE"

# Import decisions
echo "[$(date)] Importing decisions into CrowdSec..."
cscli decisions import -i "$JSON_FILE"

# Cleanup
rm -f "$TMP_FILE" "$JSON_FILE"

echo "[$(date)] ThreatHive import complete"
