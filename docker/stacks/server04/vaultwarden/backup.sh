#!/bin/sh
# Daily vaultwarden backup with local + SeaweedFS WebDAV storage
# Retention: $RETENTION_DAYS days (default 180)

set -eu

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RETENTION_DAYS="${RETENTION_DAYS:-180}"
WEBDAV_URL="${WEBDAV_URL}"
BACKUP_DIR="/backups"
BACKUP_FILE="vaultwarden_${TIMESTAMP}.sqlite3"

# 1. Safe SQLite backup (handles WAL correctly)
sqlite3 /data/db.sqlite3 ".backup '${BACKUP_DIR}/${BACKUP_FILE}'"
FILESIZE=$(wc -c < "${BACKUP_DIR}/${BACKUP_FILE}")
echo "[$(date)] Local backup: ${BACKUP_FILE} (${FILESIZE} bytes)"

# 2. Upload to SeaweedFS via WebDAV
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -T "${BACKUP_DIR}/${BACKUP_FILE}" \
  "${WEBDAV_URL}/${BACKUP_FILE}")
if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ]; then
  echo "[$(date)] WebDAV upload OK (${HTTP_CODE}): ${BACKUP_FILE}"
else
  echo "[$(date)] ERROR: WebDAV upload failed (${HTTP_CODE}): ${BACKUP_FILE}" >&2
fi

# 3. Prune local backups older than RETENTION_DAYS
find "${BACKUP_DIR}" -name 'vaultwarden_*.sqlite3' -mtime "+${RETENTION_DAYS}" -delete -print \
  | while read -r f; do echo "[$(date)] Pruned local: $f"; done

# 4. Prune remote backups older than RETENTION_DAYS
CUTOFF_EPOCH=$(($(date +%s) - RETENTION_DAYS * 86400))
CUTOFF=$(date -d "@${CUTOFF_EPOCH}" +%Y%m%d)
curl -s -X PROPFIND "${WEBDAV_URL}/" \
  | grep -oE 'vaultwarden_[0-9]{8}_[0-9]{6}\.sqlite3' | sort -u | while read -r fname; do
  FILE_DATE=$(echo "$fname" | grep -oE '[0-9]{8}' | head -1)
  if [ "$FILE_DATE" -lt "$CUTOFF" ]; then
    DEL_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "${WEBDAV_URL}/${fname}")
    echo "[$(date)] Pruned remote (${DEL_CODE}): ${fname}"
  fi
done

echo "[$(date)] Backup complete"
