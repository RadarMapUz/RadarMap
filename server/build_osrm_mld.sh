#!/bin/bash
# Граф OSRM на MLD — собирается на МАКЕ владельца, на VPS едут готовые файлы
# (27.E, подготовка к пробкам; в cron НЕ подключено, на прод НЕ выкладывает).
#
#   bash server/build_osrm_mld.sh [--city] [--pbf файл] [--work каталог]
#                                 [--speeds speeds.csv] [--fetch] [--dry-run]
#                                 [--profile car_radarmap.lua] [--ch]
#
#   --city      только Ташкент с пригородом (osmium extract по рамке CITY_BBOX):
#               отдельный городской граф для маршрутов с пробками;
#   --pbf       выгрузка OSM (по умолчанию $WORK/uzbekistan-latest.osm.pbf);
#   --fetch     скачать свежую выгрузку Geofabrik с проверкой md5;
#   --speeds    пробный customize копии набора с файлом скоростей
#               (traffic_speeds.py) и отчёт, КАКИЕ файлы он переписал;
#   --dry-run   только напечатать команды;
#   --profile   свой профиль вместо стокового /opt/car.lua (29.E:
#               server/osrm/car_radarmap.lua — махалли, светофоры, левые без
#               светофора). Файл монтируется в /opt рядом со стоковыми lib/;
#   --ch        собрать CH (osrm-contract) вместо MLD — для замены графа на
#               VPS без смены режима сервера (тот же --algorithm ch). Каталог
#               набора — ch-<имя>, чтобы не смешать с MLD.
#
# Почему так (замер VPS 22.10.2026, только чтение):
#   * VPS: 2 ГБ ОЗУ (1963 МБ, доступно ~1,2 ГБ), своп 3 ГБ, 2 ядра QEMU; на той
#     же машине чужие проекты (postgres, node, minio). osrm-routed (CH, --mmap)
#     держит ~186 МБ резидентно; набор .osrm — 889 МБ на диске, из них .hsgr
#     (CH) 262 МБ, .geometry 124 МБ, .ebg 105 МБ.
#   * Сборка 15.07: osrm-extract — пик 1,61 ГБ, osrm-contract — пик 1,16 ГБ и
#     11,5 мин; граф с тех пор не обновлялся (update_osrm.sh снят с cron 19.07:
#     «не влезает в память»). Граф: 2,19 млн узлов и 4,35 млн рёбер
#     edge-based, 3,27 млн узлов OSM.
#   * MLD, оценка по тем же числам (ПРОВЕРИТЬ первым прогоном этого скрипта —
#     он печатает пики «RAM: peak bytes used» каждого шага и размеры файлов):
#       osrm-partition — пик порядка extract (1–1,6 ГБ) → только на маке;
#       .mldgr ≈ .ebg (~100–130 МБ), .partition ~20 МБ, .cells 20–40 МБ,
#       .cell_metrics 30–80 МБ — вместо .hsgr 262 МБ, то есть на диске и в
#       page cache не больше, чем сейчас;
#       osrm-customize с файлом скоростей грузит граф MLD + .geometry +
#       развороты/повороты: пик ~0,4–0,7 ГБ на страну, ~60–120 МБ на город,
#       секунды–десятки секунд на 2 ядрах.
#   * Вывод: страну на VPS только раздавать (сборка — здесь), customize страны
#     каждые 5 минут на общей машине с 1,2 ГБ свободных — на грани (своп и
#     соседи); городской граф (--city, ~1/8 страны) — с запасом. Предложение:
#     страна остаётся CH (межгород, `match` для пробок), город — MLD с
#     customize раз в 5 минут; маршрут, у которого оба конца в CITY_BBOX, идёт
#     в городской OSRM.
#
# Цикл на VPS (НЕ подключён; описание для владельца):
#   1. эталон: $OSRM/mld-pristine/ — файлы из этого скрипта, только чтение;
#   2. раз в 5 минут: python3 traffic_speeds.py --source auto --out speeds.csv;
#      «без изменений» — конец цикла;
#   3. копия эталона в mld-next/ (customize переписывает файлы набора НА
#      МЕСТЕ — .cell_metrics, .mldgr и, с файлом скоростей, обновлённые веса;
#      рёбра, которых нет в следующем файле, сохранили бы прошлую пробку —
#      поэтому каждый цикл начинается с эталона; --speeds ниже это проверяет);
#   4. docker run --rm -m 900m … osrm-customize --segment-speed-file speeds.csv;
#   5. подмена без простоя: osrm-routed --shared-memory + osrm-datastore
#      --only-metric (метрика городского графа целиком в памяти — десятки МБ),
#      либо два каталога A/B и перезапуск контейнера (1–2 с простоя);
#   6. ключи рёбер — id узлов OSM, они постоянны между пересборками: файл
#      скоростей подходит к любому свежему графу.
#
# Версия OSRM закреплена ДАЙДЖЕСТОМ образа, тем же, что крутится на VPS
# (v26.7.3): файлы .osrm несут отпечаток версии, и граф, собранный другой
# версией, osrm-routed не откроет. Платформа — linux/amd64 (VPS x86-64); на
# маке с Apple Silicon она идёт через эмуляцию Docker — медленнее, но
# побайтно тот же результат, что на сервере.
set -euo pipefail

IMAGE="${RADARMAP_OSRM_IMAGE:-ghcr.io/project-osrm/osrm-backend@sha256:a7091038e39a73659767f34ef2d389909b42ea80b09bd2bdca482dce2991cbad}"
PLATFORM="linux/amd64"
WORK="${RADARMAP_OSRM_WORK:-$HOME/RadarMapBuild/osrm}"
# Ташкент с кольцевой и ближними пригородами (lon_min,lat_min,lon_max,lat_max).
CITY_BBOX="69.05,41.15,69.55,41.48"
GEOFABRIK="https://download.geofabrik.de/asia/uzbekistan-latest.osm.pbf"
THREADS="${RADARMAP_OSRM_THREADS:-4}"

CITY=0; DRY=0; FETCH=0; PBF=""; SPEEDS=""; PROFILE=""; CH=0
while [ $# -gt 0 ]; do
    case "$1" in
        --city) CITY=1 ;;
        --dry-run) DRY=1 ;;
        --fetch) FETCH=1 ;;
        --pbf) PBF="${2:?--pbf: нужен файл}"; shift ;;
        --work) WORK="${2:?--work: нужен каталог}"; shift ;;
        --speeds) SPEEDS="${2:?--speeds: нужен файл}"; shift ;;
        --profile) PROFILE="${2:?--profile: нужен файл .lua}"; shift ;;
        --ch) CH=1 ;;
        *) echo "неизвестный ключ: $1" >&2; exit 2 ;;
    esac
    shift
done
PBF="${PBF:-$WORK/uzbekistan-latest.osm.pbf}"
NAME=$([ "$CITY" = 1 ] && echo tashkent || echo uzbekistan)
KIND=$([ "$CH" = 1 ] && echo ch || echo mld)
OUT="$WORK/$KIND-$NAME"
# Профиль: стоковый из образа или свой, смонтированный рядом со стоковыми lib/.
LUA="/opt/car.lua"; MOUNT=()
if [ -n "$PROFILE" ]; then
    [ "$DRY" = 1 ] || [ -s "$PROFILE" ] || { echo "нет профиля $PROFILE" >&2; exit 1; }
    PROFILE_ABS="$(cd "$(dirname "$PROFILE")" && pwd)/$(basename "$PROFILE")"
    LUA="/opt/$(basename "$PROFILE")"
    MOUNT=(-v "$PROFILE_ABS:$LUA:ro")
fi

run() {
    echo "+ $*"
    [ "$DRY" = 1 ] || "$@"
}

osrm() {
    # Каталог набора монтируется как /data; лог шага — рядом, для пиков памяти.
    local step="$1"; shift
    if [ "$DRY" = 1 ]; then
        echo "+ docker run --rm --platform $PLATFORM -v $OUT:/data ${MOUNT[*]+${MOUNT[*]} }$IMAGE $step $*"
        return
    fi
    docker run --rm --platform "$PLATFORM" -v "$OUT:/data" ${MOUNT[@]+"${MOUNT[@]}"} "$IMAGE" "$step" "$@" 2>&1 | tee "$OUT/$step.log"
}

[ "$DRY" = 1 ] || command -v docker >/dev/null || { echo "нет docker: запустите Docker Desktop" >&2; exit 1; }
run mkdir -p "$WORK" "$OUT"

if [ "$FETCH" = 1 ]; then
    run curl -sSfL -o "$PBF.new" "$GEOFABRIK"
    run curl -sSfL -o "$PBF.md5" "$GEOFABRIK.md5"
    if [ "$DRY" = 0 ]; then
        [ "$(md5 -q "$PBF.new")" = "$(cut -d' ' -f1 "$PBF.md5")" ] || { echo "md5 не сошёлся" >&2; exit 1; }
        # Защита от битой выгрузки — как в update_osrm.sh.
        [ "$(stat -f%z "$PBF.new")" -ge 50000000 ] || { echo "выгрузка подозрительно мала" >&2; exit 1; }
    fi
    run mv "$PBF.new" "$PBF"
fi
[ "$DRY" = 1 ] || [ -s "$PBF" ] || { echo "нет выгрузки $PBF (ключ --fetch скачает)" >&2; exit 1; }

if [ "$CITY" = 1 ]; then
    [ "$DRY" = 1 ] || command -v osmium >/dev/null || { echo "нет osmium: brew install osmium-tool" >&2; exit 1; }
    run osmium extract --overwrite -b "$CITY_BBOX" --strategy=complete_ways -o "$OUT/$NAME.osm.pbf" "$PBF"
else
    run cp "$PBF" "$OUT/$NAME.osm.pbf"
fi

start=$(date +%s)
osrm osrm-extract -p "$LUA" -t "$THREADS" "/data/$NAME.osm.pbf"
if [ "$CH" = 1 ]; then
    osrm osrm-contract -t "$THREADS" "/data/$NAME.osrm"
else
    osrm osrm-partition -t "$THREADS" "/data/$NAME.osrm"
    osrm osrm-customize -t "$THREADS" "/data/$NAME.osrm"
fi
run rm -f "$OUT/$NAME.osm.pbf"

if [ "$DRY" = 0 ]; then
    echo "→ собрано за $(( ($(date +%s) - start) / 60 )) мин; пики памяти по шагам:"
    for step in osrm-extract osrm-partition osrm-customize osrm-contract; do
        [ -f "$OUT/$step.log" ] || continue
        peak=$(grep -h "RAM: peak bytes used" "$OUT/$step.log" | tail -1 | awk '{print $NF}')
        echo "  $step: $(( ${peak:-0} / 1048576 )) МБ"
    done
    echo "→ размеры набора:"
    ls -l "$OUT"/*.osrm* | awk '{printf "  %-48s %6.1f МБ\n", $NF, $5 / 1048576}'
    # Манифест: что за граф и чем собран — VPS сверит sha перед подменой.
    ( cd "$OUT" && { echo "image $IMAGE"; echo "pbf $(md5 -q "$PBF")"; echo "built $(date -u +%FT%TZ)";
                     echo "algorithm $KIND"; echo "profile ${PROFILE:-/opt/car.lua} $( [ -n "$PROFILE" ] && shasum -a 256 "$PROFILE" | cut -d' ' -f1)";
                     shasum -a 256 "$NAME".osrm*; } > manifest.txt )
fi

if [ -n "$SPEEDS" ]; then
    # Пробный customize на КОПИИ: какие файлы он переписывает (ловушка шага 3
    # цикла в шапке). Эталон не трогается.
    TRIAL="$OUT.trial"
    run rm -rf "$TRIAL"
    run cp -R "$OUT" "$TRIAL"
    run cp "$SPEEDS" "$TRIAL/speeds.csv"
    if [ "$DRY" = 1 ]; then
        echo "+ docker run --rm --platform $PLATFORM -v $TRIAL:/data $IMAGE osrm-customize --segment-speed-file /data/speeds.csv /data/$NAME.osrm"
    else
        ( cd "$TRIAL" && shasum -a 256 "$NAME".osrm* > before.sha )
        docker run --rm --platform "$PLATFORM" -v "$TRIAL:/data" "$IMAGE" \
            osrm-customize -t "$THREADS" --segment-speed-file /data/speeds.csv "/data/$NAME.osrm" 2>&1 \
            | tee "$TRIAL/customize-speeds.log" | grep -E "RAM|speed|Updated|segment" || true
        echo "→ customize с пробками переписал:"
        ( cd "$TRIAL" && shasum -a 256 -c before.sha 2>/dev/null | grep -v ': OK$' || echo "  ничего" )
    fi
fi
echo "✓ Набор $KIND: $OUT (на VPS не выкладывался)"
