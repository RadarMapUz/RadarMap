#!/bin/bash
# Публикация дорожных тайлов для схемы на приборке. Запускает ВЛАДЕЛЕЦ с
# локальной машины: приватный ключ живёт только здесь
# (~/.radarmap/ota_signing.pem), поэтому взломанный VPS не может подсунуть
# телефонам свою «геометрию дорог» — индекс с sha256 всех тайлов подписан,
# а тайл, не сошедшийся по хэшу, телефон отбрасывает.
#
#   bash server/publish_roads.sh            # собрать на VPS, подписать, выложить
#   bash server/publish_roads.sh --dry-run  # собрать и подписать, не выкладывая
#   bash server/publish_roads.sh --auto     # взять кандидата update_roads.sh,
#                                           # проверить ворота, опубликовать
#
# Режим --auto ставится на маке владельца в launchd (см. RUNBOOK). Автоматикой
# становится ВСЁ, а ключ никуда не уезжает: VPS готовит кандидата по крону,
# мак раз в неделю его забирает, проверяет воротами и подписывает.
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
AUTO=0
ALLOW_GRID=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --auto) AUTO=1 ;;
        --allow-grid-change) ALLOW_GRID=1 ;;
    esac
done

# Уведомление тем же каналом, что и сторож (healthcheck.sh): токен и чат
# лежат в admin.conf на VPS, в crontab их класть нельзя.
notify() {
    [ "$AUTO" = "1" ] || return 0
    local conf token chat
    conf=$(ssh "$HOST" "cat /opt/radarmap/admin.conf 2>/dev/null" || true)
    token=$(printf '%s' "$conf" | grep -E '^tg_token=' | cut -d= -f2-)
    chat=$(printf '%s' "$conf" | grep -E '^tg_chat=' | cut -d= -f2-)
    [ -n "$token" ] && [ -n "$chat" ] || return 0
    curl -sf --max-time 10 -X POST \
        "https://api.telegram.org/bot$token/sendMessage" \
        -d "chat_id=$chat" --data-urlencode "text=Дороги: $1" >/dev/null || true
}

[ -f "$KEY" ] || { echo "нет ключа подписи: $KEY"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ "$AUTO" = "1" ]; then
    # Кандидат уже собран крон-задачей update_roads.sh. Пересобирать его здесь
    # значило бы проверить ворота на одном наборе, а опубликовать другой.
    TILES="/opt/radarmap/work/roads_tiles_candidate"
    echo "=== 1/4: кандидат от update_roads.sh ==="
    ssh "$HOST" "[ -f '$TILES/index_payload_v2.json' ]" || {
        echo "кандидата нет — крон не отработал"
        notify "кандидата нет, крон не отработал"
        exit 1
    }
else
    echo "=== 1/4: сборка тайлов на VPS (экстракт лежит там) ==="
    scp -q "$(dirname "$0")/build_roads.py" "$HOST:/opt/radarmap/work/build_roads.py"
    ssh "$HOST" "python3 /opt/radarmap/work/build_roads.py --in '$EXTRACT' --tiles '$TILES'"
fi

echo "=== 2/4: подпись индексов локально ==="
# Индексов ДВА. Старый формат остаётся рабочим, пока в проде есть сборки,
# знающие только его: клиент отбрасывает индекс чужой версии обеими точками
# загрузки, то есть выкатить только новый значило бы оставить их без дорог
# совсем. Подпись у каждого своя и своим вызовом — общей быть не может.
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

scp -q "$HOST:$TILES/index_payload.json" "$WORK/index_payload.json"
scp -q "$HOST:$TILES/index_payload_v2.json" "$WORK/index_payload_v2.json"
sign_index "$WORK/index_payload.json" "$WORK/roads_index.json"
sign_index "$WORK/index_payload_v2.json" "$WORK/roads_index_v2.json"

count_of() { python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))['tiles']))" "$1"; }
TILE_COUNT=$(count_of "$WORK/index_payload.json")
TILE_COUNT_V2=$(count_of "$WORK/index_payload_v2.json")
echo "индексы подписаны: v1 — $TILE_COUNT тайлов, v2 — $TILE_COUNT_V2 файлов"

# --- Ворота публикации. Логика — в roads_gate.py, с тестами: решение о том,
# что уедет на телефоны, не должно жить в арифметике bash.
echo "=== ворота публикации ==="
ssh "$HOST" "cat '$WEBROOT/roads_index_v2.json' 2>/dev/null" > "$WORK/live_envelope.json" || true
python3 - "$WORK/live_envelope.json" "$WORK/live_payload.json" <<'PYGATE' || true
import base64, json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        envelope = json.load(handle)
    payload = json.loads(base64.b64decode(envelope["payload"]))
except Exception:
    payload = {"tiles": {}}
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PYGATE
GATE_ARGS=""
[ "$ALLOW_GRID" = "1" ] && GATE_ARGS="--allow-grid-change"
if ! GATE_OUT=$(python3 "$(dirname "$0")/roads_gate.py" \
        "$WORK/live_payload.json" "$WORK/index_payload_v2.json" $GATE_ARGS); then
    echo "$GATE_OUT"
    notify "НЕ опубликовано. $(printf '%s' "$GATE_OUT" | tr '\n' ' ')"
    exit 1
fi
echo "$GATE_OUT"

if [ "$DRY_RUN" = "1" ]; then
    echo "--dry-run: собрано и подписано, не выкладываю"
    exit 0
fi

echo "=== 3/4: тайлы обоих форматов в webroot (и .gz для gzip_static) ==="
# Файлы, которых в новом наборе нет, удаляем ТУТ ЖЕ. Смена сетки с 0.5° на
# 0.05° делает мусором весь прежний набор разом, и оставить его на сервере
# значит платить за него местом и путать себя же при разборе инцидента.
# Прошлый набор — на откат (rollback_roads.sh). Делается ДО выкладки: после
# неё возвращать будет уже нечего.
ssh "$HOST" "set -e; rm -rf '$WEBROOT/roads_prev'; \
    if [ -d '$WEBROOT/roads' ]; then cp -r '$WEBROOT/roads' '$WEBROOT/roads_prev'; fi; \
    if [ -f '$WEBROOT/roads_index.json' ]; then cp '$WEBROOT/roads_index.json' '$WEBROOT/roads_prev_index.json'; fi; \
    if [ -f '$WEBROOT/roads_index_v2.json' ]; then cp '$WEBROOT/roads_index_v2.json' '$WEBROOT/roads_prev_index_v2.json'; fi"

ssh "$HOST" "set -e; mkdir -p '$WEBROOT/roads'; \
    rm -f '$WEBROOT/roads'/tile_*.json '$WEBROOT/roads'/tile_*.json.gz \
          '$WEBROOT/roads'/road2_*.json '$WEBROOT/roads'/road2_*.json.gz; \
    cp '$TILES'/tile_*.json '$WEBROOT/roads/'; \
    cp '$TILES'/road2_*.json '$WEBROOT/roads/'; \
    gzip -kf '$WEBROOT/roads/'tile_*.json '$WEBROOT/roads/'road2_*.json"

echo "=== 4/4: подписанные индексы — последними ==="
# Порядок публикации не случаен: сначала тайлы, потом индексы. Пока индекс
# старый, клиенты видят согласованный старый набор.
scp -q "$WORK/roads_index.json" "$HOST:$WEBROOT/roads_index.json"
scp -q "$WORK/roads_index_v2.json" "$HOST:$WEBROOT/roads_index_v2.json"
echo "готово: v1 — $TILE_COUNT тайлов, v2 — $TILE_COUNT_V2 файлов"
notify "опубликовано. $GATE_OUT"
echo "телефоны подхватят при проверке (раз в трое суток), свежая установка — сразу"
