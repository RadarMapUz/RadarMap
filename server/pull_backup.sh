#!/bin/bash
# Копия данных RadarMap ВНЕ VPS — на машину владельца, раз в сутки (launchd).
#
# До 27.09.2026 все семь ночных копий reports.db лежали на том же диске, что и
# сама база: умер диск — умерло всё сразу. Здесь забирается последняя копия
# (отметки, жалобы, решения модератора, журнал правок конструктора) и хранится
# 30 дней.
#
# admin.conf (хэш пароля панели, токен Telegram, ключ карт) сюда НЕ едет
# намеренно: секреты не размножаем по дискам. Его восстанавливают заново
# (admin.py --set-password), а не из бэкапа.
#
# После удачной копии на сервере трогается метка backups/.offsite — по её
# возрасту пульт (status.py) показывает «копия вне VPS: N ч назад».
#
#   bash server/pull_backup.sh            # вручную
#   ставится: server/uz.radarmap.backup.plist → ~/Library/LaunchAgents
set -euo pipefail
HOST="${RADARMAP_HOST:-radarmap-vps}"
DEST="${RADARMAP_BACKUP_DIR:-$HOME/RadarMapBackups}"
KEEP_DAYS=30
mkdir -p "$DEST"

latest=$(ssh -o BatchMode=yes -o ConnectTimeout=20 "$HOST" \
    'ls -1t /opt/radarmap/backups/reports-*.db.gz | head -1')
[ -n "$latest" ] || { echo "$(date "+%F %T") на сервере нет бэкапов" >&2; exit 1; }
name=$(basename "$latest")

scp -q -o BatchMode=yes "$HOST:$latest" "$DEST/$name.part"
# Целостность: gzip читается до конца, внутри — sqlite.
gzip -t "$DEST/$name.part"
head -c 16 < <(gzip -dc "$DEST/$name.part") | grep -q "SQLite format 3" \
    || { echo "$(date "+%F %T") $name: внутри не sqlite" >&2; rm -f "$DEST/$name.part"; exit 1; }
mv "$DEST/$name.part" "$DEST/$name"

find "$DEST" -name 'reports-*.db.gz' -mtime +$KEEP_DAYS -delete
ssh -o BatchMode=yes "$HOST" 'touch /opt/radarmap/backups/.offsite'
echo "$(date "+%F %T") копия $name → $DEST ($(du -h "$DEST/$name" | cut -f1))"
