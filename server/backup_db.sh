#!/bin/bash
# Ежедневный бэкап краудсорс-базы (reports.db): консистентная копия через
# sqlite .backup (не cp — база живая), gzip, храним 7 последних.
# Больше не надо: в копии — UUID и адреса, а их потолок 90 дней считается
# вместе с копиями (server/RETENTION.md, тест test_api.RetentionDocTest).
# Cron на VPS:  17 3 * * *  /opt/radarmap/api/backup_db.sh
set -euo pipefail

DB="${1:-/opt/radarmap/api/reports.db}"
DEST="${2:-/opt/radarmap/backups}"
mkdir -p "$DEST"

STAMP=$(date +%Y%m%d)
python3 - "$DB" "$DEST/reports-$STAMP.db" <<'PY'
import sqlite3, sys
src = sqlite3.connect(sys.argv[1]); dst = sqlite3.connect(sys.argv[2])
src.backup(dst); dst.close(); src.close()
PY
gzip -f "$DEST/reports-$STAMP.db"
ls -1t "$DEST"/reports-*.db.gz | tail -n +8 | xargs rm -f --
echo "бэкап: $DEST/reports-$STAMP.db.gz"
