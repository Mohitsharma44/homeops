#!/bin/bash
# ThreatHive blocklist import script for CrowdSec
# Downloads and imports IPs from ThreatHive into CrowdSec decisions

set -e

BLOCKLIST_URL="https://threathive.net/hiveblocklist.txt"
TMP_FILE="/tmp/threathive_blocklist.txt"
JSON_FILE="/tmp/threathive_decisions.json"

echo "[$(date)] Starting ThreatHive blocklist import..."

# Download the blocklist (using wget - curl not available in alpine)
wget -q -O "$TMP_FILE" "$BLOCKLIST_URL"

if [ ! -s "$TMP_FILE" ]; then
    echo "[$(date)] ERROR: Failed to download blocklist or file is empty"
    exit 1
fi

IP_COUNT=$(wc -l < "$TMP_FILE" | tr -d ' ')
echo "[$(date)] Downloaded $IP_COUNT IPs from ThreatHive"

# Remove old ThreatHive decisions before importing new ones
echo "[$(date)] Removing old ThreatHive decisions..."
cscli decisions delete --origin threathive --all 2>/dev/null || true

# Convert IPs to JSON format for bulk import
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
    "origin": "threathive",
    "scenario": "threathive/blocklist",
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
