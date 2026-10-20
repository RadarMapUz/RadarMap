#!/bin/bash
# Публикация подписанного графа трасс для маршрута без сети
# (routes/route_graph_index.json + routes/route_graph.<sha16>.json).
# Запускает ВЛАДЕЛЕЦ с локальной машины: приватный ключ живёт только здесь
# (~/.radarmap/ota_signing.pem), поэтому взломанный VPS не может подсунуть
# телефонам свой граф — индекс с sha256 и размером файла подписан, а файл,
# не сошедшийся с ним, телефон отбрасывает.
#
#   bash server/publish_route_graph.sh                      # собрать на VPS, проверить, подписать, выложить
#   bash server/publish_route_graph.sh --input roads.geojsonl  # собрать здесь из своего экстракта
#   bash server/publish_route_graph.sh --dry-run            # всё, кроме выкладки
#
# КОГДА: после месячного обновления экстракта дорог (update_roads.sh) — граф
# собирается из того же roads.geojsonl. Телефон перепроверяет индекс раз в
# неделю (AppConfig.offlineGraphIndexInterval), чаще публиковать незачем.
#
# ЧТО ПОДПИСЫВАЕТСЯ. Граф собирается на VPS (там экстракт), забирается сюда,
# проверяется здесь (build_route_graph.py --verify: sha и размер пересчитаны
# от этих байтов, разбор, классы, флаги, пороги размера) — и на сервер
# уезжают ИМЕННО ЭТИ байты. Как у лимитов: подписывать «по месту» нельзя.
#
# ПОРЯДОК не случаен: сначала файл, потом индекс. Пока индекс старый,
# телефоны качают старый граф; новый индекс приезжает последним и ссылается
# на уже лежащий файл.
set -euo pipefail

KEY="${RADARMAP_OTA_KEY:-$HOME/.radarmap/ota_signing.pem}"
HOST="${RADARMAP_HOST:-root@45.130.148.94}"
WEBROOT="${RADARMAP_WEBROOT:-/opt/radarmap/www}"
EXTRACT="${RADARMAP_ROADS_GEOJSONL:-/opt/radarmap/work/roads.geojsonl}"
REMOTE_STAGE="/opt/radarmap/work/route_graph_stage"
DIR="$(cd "$(dirname "$0")" && pwd)"
# Каталог в вебруте. Отдельный, как limits/: сюда пишет только этот скрипт,
# и чистить его можно, не задевая ничего чужого. nginx отдаёт его общим
# location /radarmap/ (gzip_static on) — отдельной правки конфига не нужно.
ROUTES="routes"
INDEX_NAME="route_graph_index.json"

DRY_RUN=0
LOCAL_INPUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --input) LOCAL_INPUT="${2:?после --input нужен путь к geojsonl}"; shift ;;
        *) echo "неизвестный аргумент: $1"; exit 1 ;;
    esac
    shift
done

[ -f "$KEY" ] || { echo "нет ключа подписи: $KEY"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "=== 1/5: самотест сборщика графа (локально) ==="
(cd "$DIR" && python3 -W ignore -m unittest test_build_route_graph 2>&1 | tail -3)

if [ -n "$LOCAL_INPUT" ]; then
    echo "=== 2/5: сборка графа здесь из $LOCAL_INPUT ==="
    python3 "$DIR/build_route_graph.py" --input "$LOCAL_INPUT" --out-dir "$WORK/stage"
else
    echo "=== 2/5: сборка графа на VPS (экстракт лежит там) и забор сюда ==="
    # build_route_graph импортирует build_roads, а тот — surface_check: везём
    # все три, иначе на сервере соберёт старый код.
    scp -q "$DIR/build_route_graph.py" "$DIR/build_roads.py" "$DIR/surface_check.py" \
        "$HOST:/opt/radarmap/work/"
    # Каталог сборки — с нуля: иначе вместе с новым графом приехал бы и
    # прошлый, и на маке было бы неясно, какой из них в индексе.
    ssh "$HOST" "set -e; cd /opt/radarmap/work; rm -rf '$REMOTE_STAGE'; \
        python3 build_route_graph.py --input '$EXTRACT' --out-dir '$REMOTE_STAGE'"
    scp -q -r "$HOST:$REMOTE_STAGE" "$WORK/stage"
fi

echo "=== 3/5: ворота (локально) ==="
# Не прошли ворота — дальше не идём: подписанный обрывок графа доехал бы до
# всех телефонов, и маршрут без сети молча говорил бы «пути нет».
python3 "$DIR/build_route_graph.py" --verify "$WORK/stage"

echo "=== 4/5: подпись локально ==="
# Тот же конверт, что у дорог, лимитов, пульта и правок: base64 ТОЧНЫХ байтов
# payload плюс подпись Ed25519 под ними (SignedPayload в приложении).
sign_index() {
    local payload="$1" out="$2"
    local sig payload_b64
    sig=$(openssl pkeyutl -sign -inkey "$KEY" -rawin -in "$payload" | base64 | tr -d '\n')
    payload_b64=$(base64 < "$payload" | tr -d '\n')
    printf '{"payload": "%s", "sig": "%s"}\n' "$payload_b64" "$sig" > "$out"
    # Самопроверка: подпись обязана сойтись здесь, а не «у пользователей».
    openssl pkeyutl -verify -pubin \
        -inkey <(openssl pkey -in "$KEY" -pubout) \
        -rawin -in "$payload" \
        -sigfile <(printf '%s' "$sig" | base64 -d) >/dev/null \
        || { echo "подпись не сошлась локально ($payload) — не публикую"; exit 1; }
}
sign_index "$WORK/stage/index_payload.json" "$WORK/$INDEX_NAME"

# Имя и хэш — из payload, который только что подписан: другого источника
# правды о наборе нет. Имя в индексе — без каталога (телефон сам приставляет
# «routes/»), а sha256sum на сервере идёт из вебрута — приставляем здесь.
python3 -c 'import json,sys
for f in json.load(open(sys.argv[1]))["files"]:
    print(f["sha256"] + "  " + sys.argv[2] + "/" + f["name"])' \
    "$WORK/stage/index_payload.json" "$ROUTES" > "$WORK/manifest.txt"
echo "индекс подписан:"
sed 's/^/    /' "$WORK/manifest.txt"

if [ "$DRY_RUN" = "1" ]; then
    echo "--dry-run: проверено и подписано, не выкладываю"
    exit 0
fi

echo "=== 5/5: файл — первым, индекс — последним ==="
# На какой файл ссылается действующий индекс — его не трогаем при уборке:
# телефон, взявший старый индекс минуту назад, ещё качает по нему.
ssh "$HOST" "cat '$WEBROOT/$ROUTES/$INDEX_NAME' 2>/dev/null" > "$WORK/live_envelope.json" || true
python3 - "$WORK/live_envelope.json" > "$WORK/live_names.txt" <<'PYLIVE' || true
import base64, json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        payload = json.loads(base64.b64decode(json.load(handle)["payload"]))
    for entry in payload["files"]:
        print(entry["name"])
except Exception:
    pass   # индекса ещё нет или он битый — беречь нечего
PYLIVE

ssh "$HOST" "mkdir -p '$WEBROOT/$ROUTES'"
while read -r _sha name; do
    # Через .tmp и mv: по этому адресу никто не должен увидеть полфайла.
    scp -q "$WORK/stage/${name#$ROUTES/}" "$HOST:$WEBROOT/$name.tmp"
    # .gz рядом — обязательно и тоже атомарно: nginx с gzip_static on отдаёт
    # готовый .gz на Accept-Encoding: gzip (URLSession шлёт его всегда), не
    # глядя на сам файл. ssh -n: иначе ssh съест stdin цикла.
    ssh -n "$HOST" "set -e; cd '$WEBROOT'; mv '$name.tmp' '$name'; \
        gzip -9 -n -c '$name' > '$name.gz.tmp'; mv '$name.gz.tmp' '$name.gz'"
done < "$WORK/manifest.txt"

# Проверка на сервере: лежат ли там ровно подписанные байты — и в обычной
# отдаче, и в сжатой. Не сошлось — индекс не выкладываем вовсе.
ssh "$HOST" "cd '$WEBROOT' && sha256sum --quiet -c -" < "$WORK/manifest.txt" \
    || { echo "на сервере не те байты — индекс НЕ выложен"; exit 1; }
while read -r _sha name; do
    ssh -n "$HOST" "cd '$WEBROOT' && gzip -dc '$name.gz' | cmp -s - '$name'" \
        || { echo "$name.gz расходится с файлом — индекс НЕ выложен"; exit 1; }
done < "$WORK/manifest.txt"

scp -q "$WORK/$INDEX_NAME" "$HOST:$WEBROOT/$ROUTES/$INDEX_NAME.tmp"
ssh "$HOST" "mv '$WEBROOT/$ROUTES/$INDEX_NAME.tmp' '$WEBROOT/$ROUTES/$INDEX_NAME'"
echo "    индекс выложен: $WEBROOT/$ROUTES/$INDEX_NAME"

# Уборка routes/: оставляем файл нового и предыдущего индекса, остальное —
# прошлые сборки, которые никто больше не запросит.
{ awk '{print $2}' "$WORK/manifest.txt" | sed "s#^$ROUTES/##"; cat "$WORK/live_names.txt"; } \
    | sort -u > "$WORK/keep.txt"
ssh "$HOST" "cd '$WEBROOT/$ROUTES' || exit 0
    keep=\$(cat)
    for f in route_graph.*.json route_graph.*.json.gz; do
        [ -e \"\$f\" ] || continue
        printf '%s\n' \"\$keep\" | grep -qxF \"\${f%.gz}\" && continue
        rm -f -- \"\$f\" && echo \"    убран \$f\"
    done" < "$WORK/keep.txt"

echo "готово. Телефоны подхватят при недельной проверке индекса, свежая установка — сразу."
