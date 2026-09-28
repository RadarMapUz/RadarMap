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
    # Ship the MVT encoder with the road builder; otherwise a rebuild keeps
    # using the old tile coverage logic on the server.
    scp -q "$(dirname "$0")/build_roads.py" \
        "$(dirname "$0")/build_mvt.py" "$(dirname "$0")/mvt.py" \
        "$HOST:/opt/radarmap/work/"
    # ТЕ ЖЕ слои, что собирает крон.
    #
    # Здесь стояла одна строка «--in roads --tiles», и это была мина: ручная
    # публикация пересобирала тайлы ОДНИМИ ДОРОГАМИ. Индекс после неё
    # перечисляет только то, что написано в этот раз, — то есть местность,
    # обстановка, дома, адреса и правки панели пропадали с карты целиком, а
    # заметить это можно было только на телефоне.
    #
    # Каждый слой подаётся, только если его экстракт на месте: сборка обязана
    # работать и на машине, где половины файлов ещё нет.
    ssh "$HOST" "
      set -e
      cd /opt/radarmap/work
      args=''
      for pair in areas:areas.geojsonl points:points.geojsonl \
                  houses:houses.geojsonl addresses:addresses.geojsonl \
                  places:places.geojsonl edits:edits.json; do
          key=\${pair%%:*}; file=\${pair#*:}
          [ -s \"\$file\" ] && args=\"\$args --\$key \$file\"
      done
      # --mvt — та же мина, что и со слоями, и в том же месте. Крон собирает
      # с ним (update_roads.sh), ручная публикация — нет, и подпись индекса
      # MVT молча пропускалась: телефон на движке продолжал читать СТАРУЮ
      # геометрию, сколько бы раз владелец ни публиковал вручную.
      #
      # Поверхность дорог — тоже как в кроне: на тесной памяти её не считают,
      # иначе сборка уходит в своп рядом с работающими api и панелью.
      free_mb=\$(free -m | awk '/^Mem:/ {print \$7}')
      surface=''
      [ \"\${free_mb:-0}\" -lt 600 ] && surface='--no-surface'
      echo \"    слои: \$args \$surface --mvt\"
      python3 build_roads.py --in '$EXTRACT' \$args \$surface --mvt --tiles '$TILES'"
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
# Индекс MVT забираем ОТДЕЛЬНО и терпимо к отсутствию: сборки без --mvt его не
# пишут, и это не повод останавливать публикацию. Строку легко забыть — я и
# забыл: подпись стояла, а файла на маке не появлялось, и индекс молча не
# выкладывался.
rm -f "$WORK/mvt_index_payload.json"
scp -q "$HOST:$TILES/mvt_index_payload.json" "$WORK/mvt_index_payload.json" 2>/dev/null || true
sign_index "$WORK/index_payload.json" "$WORK/roads_index.json"
sign_index "$WORK/index_payload_v2.json" "$WORK/roads_index_v2.json"
# Индекс MVT — под той же подписью, если сборка шла с --mvt. Пока его читала
# одна панель, подпись была не нужна; телефон на движке читает ту же
# геометрию, и неподписанной она приходить не вправе.
if [ -f "$WORK/mvt_index_payload.json" ]; then
    sign_index "$WORK/mvt_index_payload.json" "$WORK/mvt_index.json"
fi

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
# Массивом, а не строкой: причина пропуска — это фраза с пробелами, и в
# строке она разваливалась на слова. В журнале осталось «пропуск: дома» вместо
# всей причины — то есть ровно то, ради чего причину и требуют.
GATE_ARGS=()
[ "$ALLOW_GRID" = "1" ] && GATE_ARGS+=("--allow-grid-change")
# Осознанный пропуск объёмных ворот. Только с причиной и только руками:
#
#   RADARMAP_ALLOW_BIG="дома поехали впервые" bash server/publish_roads.sh --auto
#
# Ворота не мешают — они спрашивают. Пропускать их «чтобы прошло» нельзя: они
# ловили настоящую потерю не раз, последний — пропавший пруд в тайле
# 2615_4994, у которого в OSM только линейный вид.
[ -n "${RADARMAP_ALLOW_BIG:-}" ] && GATE_ARGS+=("--allow-big-change=$RADARMAP_ALLOW_BIG")
if ! GATE_OUT=$(python3 "$(dirname "$0")/roads_gate.py" \
        "$WORK/live_payload.json" "$WORK/index_payload_v2.json" \
        ${GATE_ARGS[@]+"${GATE_ARGS[@]}"}); then
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

# Через find, а не через маску оболочки.
#
# Маска разворачивается в список аргументов, и на первой же сборке страны
# `cp $TILES/road2_*.json` упёрлась в предел: «Argument list too long» при
# 41 041 файле. Хуже, что упёрлась она ПОСЛЕ удаления старых: вебрут остался
# без тайлов, а индекс ещё указывал на них.
#
# find … -exec … + сам делит список на порции, и предела у него нет.
ssh "$HOST" "set -e; mkdir -p '$WEBROOT/roads'; \
    find '$WEBROOT/roads' -maxdepth 1 \( -name 'tile_*.json' -o -name 'tile_*.json.gz' \
         -o -name 'road2_*.json' -o -name 'road2_*.json.gz' \) -delete; \
    find '$TILES' -maxdepth 1 \( -name 'tile_*.json' -o -name 'road2_*.json' \) \
         -exec cp -t '$WEBROOT/roads/' {} +; \
    find '$WEBROOT/roads' -maxdepth 1 -name '*.json' -exec gzip -kf {} +; \
    echo \"    в вебруте: \$(find '$WEBROOT/roads' -name '*.json' | wc -l) файлов\""

# --- MVT: рядом, если сборка его написала.
#
# Наш формат остаётся главным: его читают телефон и панель. MVT нужен всему,
# что умеет рисовать векторные карты в браузере, и лежит он отдельным деревом
# mvt/<z>/<x>/<y>.mvt — не в индексе и не под подписью.
#
# Подпись здесь не потеря, а разграничение. Индекс подписан ради ТЕЛЕФОНА:
# взломанный сервер не должен подсунуть водителю свою геометрию. MVT читает
# панель, а она за входом и работает по своей сессии; заводить вторую подпись
# на дерево из тысяч файлов значило бы завести второе место, где подпись
# расходится с данными.
if ssh "$HOST" "[ -d '$TILES/mvt' ]"; then
    echo "=== 3б/4: MVT рядом ==="
    ssh "$HOST" "set -e; rm -rf '$WEBROOT/mvt.new'; \
        cp -r '$TILES/mvt' '$WEBROOT/mvt.new'; \
        find '$WEBROOT/mvt.new' -name '*.mvt' -exec gzip -kf {} +; \
        rm -rf '$WEBROOT/mvt.old'; \
        if [ -d '$WEBROOT/mvt' ]; then mv '$WEBROOT/mvt' '$WEBROOT/mvt.old'; fi; \
        mv '$WEBROOT/mvt.new' '$WEBROOT/mvt'; \
        rm -rf '$WEBROOT/mvt.old'; \
        echo \"    тайлов MVT: \$(find '$WEBROOT/mvt' -name '*.mvt' | wc -l)\""
else
    echo "MVT в кандидате нет — сборка шла без --mvt, пропускаем"
fi

# Глифы подписей рядом с MVT.
#
# Раньше их отдавала ТОЛЬКО панель модератора, из-под входа: там подписи и
# были нужны. Как только карту на движке начинает рисовать телефон, глифы
# становятся частью данных карты, а не панели, — и лежать они обязаны в
# открытом вебруте, рядом с тайлами.
#
# Их три диапазона на триста килобайт, и это не экономия ради экономии:
# 72 % улиц центра записаны латиницей, 28 % — кириллицей, и в узбекских
# названиях есть oʻ и gʻ. Остальные двести пятьдесят диапазонов набора —
# иероглифы и арабица, которых на наших улицах нет.
GLYPHS_SRC="$(cd "$(dirname "$0")" && pwd)/static/vendor/glyphs"
if [ -d "$GLYPHS_SRC" ]; then
    echo "=== 3в/4: глифы подписей ==="
    # Через tar, а не scp: в имени шрифтового набора ЕСТЬ ПРОБЕЛЫ («Noto Sans
    # Regular» — так его просит движок в {fontstack}), и scp с таким путём
    # ломается на удалённом mkdir, обрывая всю публикацию на полпути. Один
    # обрыв это уже стоило: тайлы уехали, а индекс — нет.
    COPYFILE_DISABLE=1 tar --no-xattrs -c -C "$GLYPHS_SRC" . | ssh "$HOST" "mkdir -p '$WEBROOT/glyphs/Noto Sans Regular' && tar x -C '$WEBROOT/glyphs/Noto Sans Regular'"
    ssh "$HOST" "echo \"    диапазонов: \$(ls '$WEBROOT/glyphs/Noto Sans Regular' | wc -l)\""
else
    echo "глифов нет в $GLYPHS_SRC — пропускаем"
fi

echo "=== 4/4: подписанные индексы — последними ==="
# Порядок публикации не случаен: сначала тайлы, потом индексы. Пока индекс
# старый, клиенты видят согласованный старый набор.
scp -q "$WORK/roads_index.json" "$HOST:$WEBROOT/roads_index.json"
scp -q "$WORK/roads_index_v2.json" "$HOST:$WEBROOT/roads_index_v2.json"
# Индекс MVT кладётся ПОСЛЕ самих тайлов и последним из индексов: пока его
# нет, телефон на движке просто не начнёт читать дерево, а не прочитает
# половину.
if [ -f "$WORK/mvt_index.json" ]; then
    scp -q "$WORK/mvt_index.json" "$HOST:$WEBROOT/mvt_index.json"
    echo "    индекс MVT подписан и выложен"
fi
echo "готово: v1 — $TILE_COUNT тайлов, v2 — $TILE_COUNT_V2 файлов"
notify "опубликовано. $GATE_OUT"
echo "телефоны подхватят при проверке (раз в трое суток), свежая установка — сразу"
