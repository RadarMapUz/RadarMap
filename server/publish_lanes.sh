#!/bin/bash
# Публикация подписанного слоя полос на перекрёстках
# (lanes/lanes_index.json + lanes/lanes.<sha16>.json, контракт —
# docs/lanes_overlay_contract.md, руководство — docs/integration_lanes.md).
# Запускает ВЛАДЕЛЕЦ с локальной машины: приватный ключ живёт только здесь
# (~/.radarmap/ota_signing.pem), поэтому взломанный VPS не может подсунуть
# телефонам свои полосы — индекс с sha256 и размером файла подписан, а файл,
# не сошедшийся с ним, телефон отбрасывает.
#
#   bash server/publish_lanes.sh --check                     # только проверка: без ключа и без сети
#   bash server/publish_lanes.sh                             # server/lanes/lanes.csv → подписать → выложить
#   bash server/publish_lanes.sh --input a.csv --input b.geojson   # свои входы вместо lanes.csv
#   bash server/publish_lanes.sh --osm                       # + подходы из turn:lanes OSM (экстракт на VPS)
#   bash server/publish_lanes.sh --osm-input roads.geojsonl  # + то же из своего экстракта
#   bash server/publish_lanes.sh --min-confidence 0.8        # порог для строк регистратора
#   bash server/publish_lanes.sh --dry-run                   # всё, кроме выкладки (ключ нужен)
#
# --check — самотест и ворота на этих данных: ключ не читается, на сервер не
# ходит (с --osm нельзя — экстракт на VPS; дайте --osm-input). Им проверяют
# данные перед публикацией, его же гоняет test_build_lane_overlay.py.
#
# ЧТО ПОДПИСЫВАЕТСЯ. Слой собирается ЗДЕСЬ (build_lane_overlay.py), ворота
# (--verify) пересчитывают sha и размер от этих байтов и перечитывают каждую
# запись по контракту — и на сервер уезжают ИМЕННО ЭТИ байты. С --osm на VPS
# только вытаскиваются подходы из экстракта (небольшой JSON), сборка и
# проверка — всё равно здесь.
#
# ПОРЯДОК не случаен: сначала файл, потом индекс. Пока индекс старый,
# телефоны качают старый слой; новый индекс приезжает последним и ссылается
# на уже лежащий файл. Откат — та же публикация прошлых данных (docs/integration_lanes.md).
set -euo pipefail

KEY="${RADARMAP_OTA_KEY:-$HOME/.radarmap/ota_signing.pem}"
HOST="${RADARMAP_HOST:-root@45.130.148.94}"
WEBROOT="${RADARMAP_WEBROOT:-/opt/radarmap/www}"
EXTRACT="${RADARMAP_ROADS_GEOJSONL:-/opt/radarmap/work/roads.geojsonl}"
REMOTE_WORK="/opt/radarmap/work"
DIR="$(cd "$(dirname "$0")" && pwd)"
# Каталог в вебруте. Свой, как limits/ и routes/: сюда пишет только этот
# скрипт, и чистить его можно, не задевая чужого. Отдаёт его общий location
# /radarmap/; отдельный блок nginx (индекс no-cache, данные навсегда) —
# в nginx-radarmap-location.conf, ставится руками.
LANES="lanes"
INDEX_NAME="lanes_index.json"

CHECK=0
DRY_RUN=0
OSM_REMOTE=0
OSM_LOCAL=""
INPUTS=()
EXTRA=()
while [ $# -gt 0 ]; do
    case "$1" in
        --check) CHECK=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --osm) OSM_REMOTE=1 ;;
        --osm-input) OSM_LOCAL="${2:?после --osm-input нужен путь к geojsonl}"; shift ;;
        --input) INPUTS+=("${2:?после --input нужен путь}"); shift ;;
        --version) EXTRA+=(--version "${2:?после --version нужно число}"); shift ;;
        --min-confidence) EXTRA+=(--min-confidence "${2:?после --min-confidence нужно число}"); shift ;;
        *) echo "неизвестный аргумент: $1"; exit 1 ;;
    esac
    shift
done

# Вход по умолчанию — рабочий файл обхода. Шаблон (lanes_template.csv) сюда
# не подставляется никогда: его строки-образцы сборщик и так отвергнет.
if [ ${#INPUTS[@]} -eq 0 ] && [ -f "$DIR/lanes/lanes.csv" ]; then
    INPUTS=("$DIR/lanes/lanes.csv")
fi
if [ ${#INPUTS[@]} -eq 0 ] && [ "$OSM_REMOTE" = "0" ] && [ -z "$OSM_LOCAL" ]; then
    echo "нет входа: ни server/lanes/lanes.csv, ни --input, ни --osm"; exit 1
fi
if [ "$CHECK" = "1" ] && [ "$OSM_REMOTE" = "1" ]; then
    echo "--check не ходит на сервер, а экстракт OSM лежит там: дайте --osm-input <файл>"; exit 1
fi
# Без ключа дальше проверки идти незачем — и лучше узнать это до ssh.
if [ "$CHECK" = "0" ]; then
    [ -f "$KEY" ] || { echo "нет ключа подписи: $KEY"; exit 1; }
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "=== 1/6: самотест сборщика (локально) ==="
# RADARMAP_LANES_SELFTEST: тест, гоняющий этот скрипт с --check, внутри
# самотеста пропускается — иначе скрипт и тест вызывали бы друг друга.
(cd "$DIR" && RADARMAP_LANES_SELFTEST=1 python3 -W ignore -m unittest test_build_lane_overlay 2>&1 | tail -3)

echo "=== 2/6: подходы из turn:lanes OSM ==="
OSM_ROWS=()
if [ -n "$OSM_LOCAL" ]; then
    python3 "$DIR/build_lane_overlay.py" --from-osm "$OSM_LOCAL" --osm-out "$WORK/lanes_osm.json"
    OSM_ROWS=("$WORK/lanes_osm.json")
elif [ "$OSM_REMOTE" = "1" ]; then
    # Экстракт страны — сотни мегабайт, и лежит он на VPS: туда едет сборщик,
    # обратно — только подходы (JSON в контракте, десятки килобайт).
    scp -q "$DIR/build_lane_overlay.py" "$HOST:$REMOTE_WORK/"
    ssh "$HOST" "set -e; cd '$REMOTE_WORK'; \
        python3 build_lane_overlay.py --from-osm '$EXTRACT' --osm-out '$REMOTE_WORK/lanes_osm.json'"
    scp -q "$HOST:$REMOTE_WORK/lanes_osm.json" "$WORK/lanes_osm.json"
    OSM_ROWS=("$WORK/lanes_osm.json")
else
    echo "    пропуск (без --osm / --osm-input)"
fi

echo "=== 3/6: сборка и ворота (локально) ==="
# Не прошли ворота — дальше не идём: подписанный неверный ряд доехал бы до
# всех телефонов, и водитель встал бы не в тот ряд перед поворотом.
python3 "$DIR/build_lane_overlay.py" ${INPUTS[@]+"${INPUTS[@]}"} ${OSM_ROWS[@]+"${OSM_ROWS[@]}"} \
    --out-dir "$WORK/stage" --report ${EXTRA[@]+"${EXTRA[@]}"}
python3 "$DIR/build_lane_overlay.py" --verify "$WORK/stage"

# Имя и хэш — из payload, который пойдёт под подпись: другого источника
# правды о наборе нет. Имя в индексе — без каталога (телефон сам приставляет
# «lanes/»), а sha256sum на сервере идёт из вебрута — приставляем здесь.
python3 -c 'import json,sys
for f in json.load(open(sys.argv[1]))["files"]:
    print(f["sha256"] + "  " + sys.argv[2] + "/" + f["name"])' \
    "$WORK/stage/index_payload.json" "$LANES" > "$WORK/manifest.txt"
echo "набор:"
sed 's/^/    /' "$WORK/manifest.txt"

if [ "$CHECK" = "1" ]; then
    echo "--check: данные годны; ключ не читался, на сервер не ходил"
    exit 0
fi

echo "=== 4/6: подпись локально ==="
# Тот же конверт, что у дорог, лимитов, графа, пульта и правок: base64 ТОЧНЫХ
# байтов payload плюс подпись Ed25519 под ними (SignedPayload в приложении).
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
echo "    индекс подписан"

if [ "$DRY_RUN" = "1" ]; then
    echo "--dry-run: проверено и подписано, не выкладываю"
    exit 0
fi

echo "=== 5/6: файл — первым, индекс — последним ==="
# На какой файл ссылается действующий индекс — его не трогаем при уборке:
# телефон, взявший старый индекс минуту назад, ещё качает по нему.
ssh "$HOST" "cat '$WEBROOT/$LANES/$INDEX_NAME' 2>/dev/null" > "$WORK/live_envelope.json" || true
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

ssh "$HOST" "mkdir -p '$WEBROOT/$LANES'"
while read -r _sha name; do
    # Через .tmp и mv: по этому адресу никто не должен увидеть полфайла.
    scp -q "$WORK/stage/${name#$LANES/}" "$HOST:$WEBROOT/$name.tmp"
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

scp -q "$WORK/$INDEX_NAME" "$HOST:$WEBROOT/$LANES/$INDEX_NAME.tmp"
ssh "$HOST" "mv '$WEBROOT/$LANES/$INDEX_NAME.tmp' '$WEBROOT/$LANES/$INDEX_NAME'"
echo "    индекс выложен: $WEBROOT/$LANES/$INDEX_NAME"

echo "=== 6/6: уборка lanes/ ==="
# Оставляем файл нового и предыдущего индекса, остальное — прошлые сборки,
# которые никто больше не запросит. Предыдущий — ещё и быстрый откат.
{ awk '{print $2}' "$WORK/manifest.txt" | sed "s#^$LANES/##"; cat "$WORK/live_names.txt"; } \
    | sort -u > "$WORK/keep.txt"
ssh "$HOST" "cd '$WEBROOT/$LANES' || exit 0
    keep=\$(cat)
    for f in lanes.*.json lanes.*.json.gz; do
        [ -e \"\$f\" ] || continue
        printf '%s\n' \"\$keep\" | grep -qxF \"\${f%.gz}\" && continue
        rm -f -- \"\$f\" && echo \"    убран \$f\"
    done" < "$WORK/keep.txt"

echo "готово. Телефоны подхватят при своей проверке индекса, свежая установка — сразу."
echo "Проверка: docs/integration_lanes.md, раздел «Проверить»."
