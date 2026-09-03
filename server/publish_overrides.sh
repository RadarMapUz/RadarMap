#!/bin/bash
# Публикация решений модератора: overrides.json — подписанный снимок
# действующих правок поверх базы камер.
#
#   bash server/publish_overrides.sh <версия>
#   bash server/publish_overrides.sh <версия> --dry-run
#
# Запускает ВЛАДЕЛЕЦ с локальной машины. Панель на VPS ничего не публикует
# сама — и это главное свойство схемы: ключ подписи живёт только здесь
# (~/.radarmap/ota_signing.pem), поэтому взломанный сервер не может ни скрыть
# камеру у пользователей, ни подсунуть свою. Панель копит решения, публикует
# человек, а приложение проверяет подпись до применения (fail closed).
#
# Файл ~2 КБ против мегабайта базы, так что публиковать можно хоть каждый день,
# а откат — это снять правку в панели («Вернуть камеру») и запустить это снова.
set -euo pipefail

VERSION="${1:?номер версии правок (предыдущая +1)}"
# Только цифры: строка уходит внутрь ssh-команды, то есть в шелл на VPS от
# root. `publish_overrides.sh '1; systemctl stop radarmap-api'` исполнял там
# всё после точки с запятой.
[[ "$VERSION" =~ ^[0-9]+$ ]] || { echo "версия правок — только цифры: $VERSION"; exit 1; }
DRY_RUN=0
[ "${2:-}" = "--dry-run" ] && DRY_RUN=1

KEY="${RADARMAP_OTA_KEY:-$HOME/.radarmap/ota_signing.pem}"
HOST="${RADARMAP_HOST:-root@45.130.148.94}"
WEBROOT="${RADARMAP_WEBROOT:-/opt/radarmap/www}"
ADMIN="${RADARMAP_ADMIN:-/opt/radarmap/api/admin.py}"

[ -f "$KEY" ] || { echo "нет ключа подписи: $KEY"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "→ Забираю решения с сервера…"
ssh "$HOST" "python3 $ADMIN --export $VERSION" > "$WORK/overrides.payload"

# Проверка ДО подписи. Подписанный мусор доехал бы до всех телефонов и был
# молча отброшен ими — то есть решения модератора не применились бы, а понять
# это по факту было бы неоткуда.
python3 - "$WORK/overrides.payload" <<'PY'
import json, sys
raw = open(sys.argv[1], encoding="utf-8").read()
data = json.loads(raw)
items = data.get("items")
if not isinstance(items, list):
    sys.exit("нет списка items")
hides = 0
for item in items:
    if item.get("op") not in ("hide", "move", "retype"):
        sys.exit(f"неизвестная операция: {item.get('op')}")
    if item["op"] == "hide":
        hides += 1
    if item["op"] == "move" and not (37.0 <= item.get("lat", 0) <= 46.0
                                     and 55.0 <= item.get("lon", 0) <= 74.0):
        sys.exit(f"координата вне Узбекистана у камеры {item.get('id')}")
    if item["op"] == "retype" and not item.get("type"):
        sys.exit(f"пустой тип у камеры {item.get('id')}")
print(f"правок: {len(items)} (скрыть: {hides})")
# Приложение отвергает файл, гасящий больше 5% базы, целиком. Ловим это здесь,
# а не по факту молчаливого отказа на телефонах.
if hides > 100:
    sys.exit("слишком много скрытий — приложение отвергнет файл целиком, проверьте панель")
PY

SIG=$(openssl pkeyutl -sign -inkey "$KEY" -rawin -in "$WORK/overrides.payload" | base64 | tr -d '\n')
PAYLOAD=$(base64 < "$WORK/overrides.payload" | tr -d '\n')
printf '{"payload": "%s", "sig": "%s"}\n' "$PAYLOAD" "$SIG" > "$WORK/overrides.json"

openssl pkeyutl -verify -pubin \
    -inkey <(openssl pkey -in "$KEY" -pubout) \
    -rawin -in "$WORK/overrides.payload" \
    -sigfile <(printf '%s' "$SIG" | base64 -d) >/dev/null \
    || { echo "подпись не сошлась локально — не публикую"; exit 1; }

if [ "$DRY_RUN" = "1" ]; then
    echo "--dry-run: собрано и проверено, не заливаю"
    cat "$WORK/overrides.payload"
    exit 0
fi

scp "$WORK/overrides.json" "$HOST:$WEBROOT/overrides.json"
ssh "$HOST" "python3 $ADMIN --mark-published $VERSION"
echo "опубликовано: v$VERSION ($(wc -c < "$WORK/overrides.json") байт)"
echo "приложения подхватят в течение 3 часов, на холодном старте — сразу"
