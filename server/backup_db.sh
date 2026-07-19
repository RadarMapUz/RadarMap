#!/bin/bash
# Ежедневный бэкап краудсорс-базы (reports.db): консистентная копия через
# sqlite .backup (не cp — база живая), gzip, храним 7 последних.
# Cron на VPS:  17 3 * * *  /opt/radarmap/api/backup_db.sh
set -euo pipefail

DB="${1:-/opt/radarmap/api/reports.db}"
DEST="${2:-/opt/radarmap/backups}"
mkdir -p "$DEST"

STAMP=$(date +%Y%m%d)
sqlite3 "$DB" ".backup '$DEST/reports-$STAMP.db'"
gzip -f "$DEST/reports-$STAMP.db"
ls -1t "$DEST"/reports-*.db.gz | tail -n +8 | xargs -r rm --
echo "бэкап: $DEST/reports-$STAMP.db.gz"
