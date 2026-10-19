#!/bin/bash
# Подписать базу камер Ed25519 и собрать version.json для OTA.
# Запускается на машине владельца: приватный ключ живёт ТОЛЬКО в
# ~/.radarmap/ota_signing.pem (в репозиторий не попадает; сделайте бэкап!).
#
# Использование: bash server/sign_db.sh <cameras.json> <version> [out-dir]
set -euo pipefail

KEY="${RADARMAP_OTA_KEY:-$HOME/.radarmap/ota_signing.pem}"
DB="${1:?путь к cameras.json}"
VERSION="${2:?номер версии базы}"
OUT="${3:-$(dirname "$DB")}"

[ -f "$KEY" ] || { echo "нет ключа: $KEY (openssl genpkey -algorithm ed25519 -out $KEY)"; exit 1; }

SIG=$(openssl pkeyutl -sign -inkey "$KEY" -rawin -in "$DB" | base64)
SHA=$(shasum -a 256 "$DB" | cut -d' ' -f1)
COUNT=$(python3 -c "import json; print(len(json.load(open('$DB'))))")

# Подписанная версия (S18, 20.10): версия, sha256 и число камер под одной
# подписью — в конверте SignedPayload, как правки и лимиты. Без неё версия в
# манифесте не подписана: сервер мог отдать старую подписанную базу с версией
# 999999, и настоящие обновления больше не приходили бы никогда.
RELEASE_FILE=$(mktemp)
trap 'rm -f "$RELEASE_FILE"' EXIT
printf '{"version":%s,"sha256":"%s","count":%s}' "$VERSION" "$SHA" "$COUNT" > "$RELEASE_FILE"
RELEASE_PAYLOAD=$(base64 < "$RELEASE_FILE" | tr -d '\n')
RELEASE_SIG=$(openssl pkeyutl -sign -inkey "$KEY" -rawin -in "$RELEASE_FILE" | base64 | tr -d '\n')

cat > "$OUT/version.json" <<EOF
{"version": $VERSION, "count": $COUNT, "updatedAt": "$(date +%Y-%m-%d)", "sha256": "$SHA", "sig": "$SIG", "release": {"payload": "$RELEASE_PAYLOAD", "sig": "$RELEASE_SIG"}}
EOF
echo "подписано: v$VERSION, $COUNT камер"
echo "  $OUT/version.json"
