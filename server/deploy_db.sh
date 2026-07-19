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
scp "$DB" "$HOST:$WEBROOT/cameras.json"
scp /tmp/version.json "$HOST:$WEBROOT/version.json"
echo "готово: прод раздаёт v$VERSION"
