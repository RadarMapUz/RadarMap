#!/bin/bash
# Публикация горячих точек треног: hotspots.json — подписанный снимок мест,
# где водители отмечали радар снова и снова.
#
#   bash server/publish_hotspots.sh
#   bash server/publish_hotspots.sh --dry-run
#
# Запускает ВЛАДЕЛЕЦ с локальной машины: сборку считает VPS (там база отметок),
# подпись ставится здесь (ключ ~/.radarmap/ota_signing.pem никуда не уезжает).
# Поэтому взломанный сервер не может ни выдумать точку, ни стереть настоящую —
# приложение проверяет подпись до применения и при любой неисправности живёт
# вообще без подсказок (fail closed).
#
# Подсказка «здесь часто ставят треногу» — это ЗНАНИЕ, а не факт: она обязана
# звучать тише камеры и появляться только там, где за место ручались разные
# люди. Пороги — в build_hotspots.py, они же проверяются ниже перед подписью.
set -euo pipefail

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

KEY="${RADARMAP_OTA_KEY:-$HOME/.radarmap/ota_signing.pem}"
HOST="${RADARMAP_HOST:-root@45.130.148.94}"
WEBROOT="${RADARMAP_WEBROOT:-/opt/radarmap/www}"
APIDIR="${RADARMAP_APIDIR:-/opt/radarmap/api}"
DIR="$(cd "$(dirname "$0")" && pwd)"

[ -f "$KEY" ] || { echo "нет ключа подписи: $KEY"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "→ Самотест логики сборки (локально, без базы)…"
(cd "$DIR" && python3 test_build_hotspots.py 2>&1 | tail -3)

echo "→ Заливаю сборщик и считаю точки на сервере…"
scp -q "$DIR/build_hotspots.py" "$HOST:$APIDIR/build_hotspots.py"
ssh "$HOST" "python3 $APIDIR/build_hotspots.py --db $APIDIR/reports.db" > "$WORK/hotspots.payload"

# Проверка ДО подписи: подписанный мусор доехал бы до всех телефонов и был бы
# молча отброшен — то есть подсказки просто исчезли бы, а понять почему было
# бы неоткуда.
python3 - "$WORK/hotspots.payload" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
spots = data.get("spots")
if data.get("version") != 1 or not isinstance(spots, list):
    sys.exit("не тот контракт: ожидался version=1 и список spots")
for spot in spots:
    if sorted(spot) != ["days", "lat", "lon", "n", "pdays", "peak", "src"]:
        sys.exit(f"лишние или недостающие поля в точке: {sorted(spot)}")
    if not (0 <= spot["src"] <= 9 and 0 <= spot["pdays"] <= spot["days"]):
        sys.exit(f"src/pdays вне пределов: {spot}")
    if not (37.0 <= spot["lat"] <= 46.0 and 55.0 <= spot["lon"] <= 74.0):
        sys.exit(f"точка вне Узбекистана: {spot['lat']}, {spot['lon']}")
    if spot["n"] < 3 or spot["days"] < 2:
        sys.exit(f"точка ниже порога доверия просочилась: {spot}")
raw = open(sys.argv[1], encoding="utf-8").read()
for leak in ("device", '"ip"', "created"):
    if leak in raw:
        sys.exit(f"в payload попало «{leak}» — это утечка маршрутов, публикация отменена")
print(f"  точек: {len(spots)}")
PY

if [ "$DRY_RUN" = 1 ]; then
  echo "--dry-run: подпись и заливка пропущены. Payload:"
  head -c 400 "$WORK/hotspots.payload"; echo
  exit 0
fi

echo "→ Подпись…"
SIG=$(openssl pkeyutl -sign -inkey "$KEY" -rawin -in "$WORK/hotspots.payload" | base64 | tr -d '\n')
PAYLOAD=$(base64 -i "$WORK/hotspots.payload" | tr -d '\n')
printf '{"payload":"%s","sig":"%s"}' "$PAYLOAD" "$SIG" > "$WORK/hotspots.json"

scp -q "$WORK/hotspots.json" "$HOST:$WEBROOT/hotspots.json"
echo "✓ Опубликовано: $WEBROOT/hotspots.json ($(wc -c < "$WORK/hotspots.json") байт)"
