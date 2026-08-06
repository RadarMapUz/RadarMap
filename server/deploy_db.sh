#!/bin/bash
# Деплой базы камер на прод: подпись → scp → OTA раздаёт всем.
# Использование: bash server/deploy_db.sh <version>
# (запускает владелец: нужен SSH-доступ к VPS и ключ подписи)
set -euo pipefail

VERSION="${1:?номер версии базы (текущая на проде +1)}"
HOST="${RADARMAP_HOST:-root@45.130.148.94}"
WEBROOT="${RADARMAP_WEBROOT:-/opt/radarmap/www}"
DB="RadarMap/Resources/cameras.json"

bash "$(dirname "$0")/sign_db.sh" "$DB" "$VERSION" /tmp

# Готовый .gz рядом с файлом: nginx (gzip_static on) отдаёт его как есть вместо
# того, чтобы жать мегабайт на каждую из тысяч загрузок. Подпись считается по
# ИСХОДНОМУ файлу — приложение проверяет её после распаковки транспортом,
# так что .gz на неё не влияет.
gzip -9 -k -f -c "$DB" > /tmp/cameras.json.gz

scp "$DB" "$HOST:$WEBROOT/cameras.json"
scp /tmp/cameras.json.gz "$HOST:$WEBROOT/cameras.json.gz"
scp /tmp/version.json "$HOST:$WEBROOT/version.json"
echo "готово: прод раздаёт v$VERSION ($(du -h /tmp/cameras.json.gz | cut -f1) по сети)"
