#!/bin/bash
# Публикация дорожных тайлов для схемы на приборке. Запускает ВЛАДЕЛЕЦ с
# локальной машины: приватный ключ живёт только здесь
# (~/.radarmap/ota_signing.pem), поэтому взломанный VPS не может подсунуть
# телефонам свою «геометрию дорог» — индекс с sha256 всех тайлов подписан,
# а тайл, не сошедшийся по хэшу, телефон отбрасывает.
#
#   bash server/publish_roads.sh            # собрать на VPS, подписать, выложить
#   bash server/publish_roads.sh --dry-run  # собрать и подписать, не выкладывая
#
# Порядок публикации не случаен: сначала тайлы, потом индекс. Пока индекс
# старый, старые клиенты видят согласованный старый набор; новый индекс
# приезжает последним и ссылается на уже лежащие файлы.
set -euo pipefail

KEY="${RADARMAP_OTA_KEY:-$HOME/.radarmap/ota_signing.pem}"
HOST="${RADARMAP_HOST:-root@45.130.148.94}"
WEBROOT="${RADARMAP_WEBROOT:-/opt/radarmap/www}"
EXTRACT="${RADARMAP_ROADS_GEOJSONL:-/opt/radarmap/work/roads.geojsonl}"
TILES="/opt/radarmap/work/roads_tiles"

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then DRY_RUN=1; fi

[ -f "$KEY" ] || { echo "нет ключа подписи: $KEY"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "=== 1/4: сборка тайлов на VPS (экстракт лежит там) ==="
scp -q "$(dirname "$0")/build_roads.py" "$HOST:/opt/radarmap/work/build_roads.py"
ssh "$HOST" "python3 /opt/radarmap/work/build_roads.py --in '$EXTRACT' --tiles '$TILES'"

echo "=== 2/4: подпись индекса локально ==="
scp -q "$HOST:$TILES/index_payload.json" "$WORK/index_payload.json"
SIG=$(openssl pkeyutl -sign -inkey "$KEY" -rawin -in "$WORK/index_payload.json" | base64 | tr -d '\n')
PAYLOAD=$(base64 < "$WORK/index_payload.json" | tr -d '\n')
printf '{"payload": "%s", "sig": "%s"}\n' "$PAYLOAD" "$SIG" > "$WORK/roads_index.json"

# Самопроверка: подпись обязана сойтись здесь, а не «у пользователей».
openssl pkeyutl -verify -pubin \
    -inkey <(openssl pkey -in "$KEY" -pubout) \
    -rawin -in "$WORK/index_payload.json" \
    -sigfile <(printf '%s' "$SIG" | base64 -d) >/dev/null \
    || { echo "подпись не сошлась локально — не публикую"; exit 1; }

TILE_COUNT=$(python3 -c "import json; print(len(json.load(open('$WORK/index_payload.json'))['tiles']))")
echo "индекс подписан: $TILE_COUNT тайлов"

if [ "$DRY_RUN" = "1" ]; then
    echo "--dry-run: собрано и подписано, не выкладываю"
    exit 0
fi

echo "=== 3/4: тайлы в webroot (и .gz для gzip_static) ==="
ssh "$HOST" "mkdir -p '$WEBROOT/roads' \
    && cp '$TILES'/tile_*.json '$WEBROOT/roads/' \
    && gzip -kf '$WEBROOT/roads/'tile_*.json"

echo "=== 4/4: подписанный индекс — последним ==="
scp -q "$WORK/roads_index.json" "$HOST:$WEBROOT/roads_index.json"
echo "готово: $TILE_COUNT тайлов, индекс roads_index.json"
echo "телефоны подхватят при недельной проверке, свежая установка — сразу"
