#!/bin/bash
# Пробки в маршрутизаторе — стенд MLD рядом с продом (32D, 27.10.2026).
# Один цикл: файл скоростей → osrm-customize в запасном слоте → подмена слота
# и перезапуск контейнера стенда. Прод (radarmap-osrm, 127.0.0.1:8092, CH) и
# nginx скрипт не трогает и отказывается работать с ними. Подробно —
# server/osrm/TRAFFIC.md.
#
#   traffic_customize.sh [--speeds файл] [--force] [--dry-run]
#
#   --speeds   готовый файл скоростей вместо traffic_speeds.py (проверка
#              объезда: route_bench.py jam → этот ключ → route_bench.py check);
#   --force    customize и подмена, даже если файл не изменился;
#   --dry-run  только напечатать, что было бы сделано.
#
# Раскладка ($ROOT, по умолчанию /opt/radarmap/osrm-mld):
#   pristine/    набор MLD из build_osrm_mld.sh — эталон, только чтение;
#   a/, b/       слоты: жёсткие ссылки на эталон, кроме файлов, которые
#                customize переписывает (они копируются или создаются заново);
#   current      относительная ссылка на рабочий слот («a» или «b»); контейнер
#                смонтировал $ROOT и открывает /data/current/uzbekistan.osrm;
#   bin/         traffic_speeds.py + traffic_build.py (копии из репо: стенд не
#                зависит от того, что выложено в /opt/radarmap/api);
#   speeds.csv   последний файл скоростей.
#
# Почему так (замер 27.10, TRAFFIC.md):
#   * customize переписывает .mldgr и .geometry НА МЕСТЕ (их читает и пишет) и
#     создаёт .cell_metrics и .datasource_names; остальные 24 файла набора он
#     не открывает на запись — их можно делить с эталоном жёсткими ссылками.
#     Копия на цикл — 243 МБ, а не весь набор (856 МБ). Жёсткая ссылка на
#     переписываемый файл испортила бы эталон;
#   * каждый цикл начинается с эталона: ребро, которого нет в новом файле,
#     иначе сохранило бы прошлую пробку;
#   * подмена — перезапуск контейнера (osrm-routed с --mmap поднимается за
#     секунды), а не osrm-datastore + --shared-memory: в разделяемой памяти
#     набор страны лежит резидентно (~0,9 ГБ) — на VPS с 1,2 ГБ свободных это
#     не помещается;
#   * customize в контейнере с -m 900m без свопа и одним ядром: на машине
#     2 ядра и чужие проекты, прод должен отвечать и во время цикла. Пик
#     customize — 634 МБ (VmHWM); упёрся в предел — цикл переходит на граф без
#     пробок (старая пробка хуже, чем никакой — то же правило, что у now.json:
#     файл старше 10 минут для телефона — «нет данных»).
set -euo pipefail

ROOT="${RADARMAP_OSRM_MLD:-/opt/radarmap/osrm-mld}"
BIN="${RADARMAP_OSRM_MLD_BIN:-$ROOT/bin}"
DB="${RADARMAP_TRAFFIC_DB:-/opt/radarmap/api/traffic.db}"
IMAGE="${RADARMAP_OSRM_IMAGE:-ghcr.io/project-osrm/osrm-backend@sha256:a7091038e39a73659767f34ef2d389909b42ea80b09bd2bdca482dce2991cbad}"
CONTAINER="${RADARMAP_OSRM_MLD_CONTAINER:-radarmap-osrm-mld}"
PORT="${RADARMAP_OSRM_MLD_PORT:-8094}"
DOCKER="${RADARMAP_DOCKER:-docker}"
SOURCE="${RADARMAP_SPEEDS_SOURCE:-auto}"
MODE="${RADARMAP_SPEEDS_MODE:-weight}"
NAME=uzbekistan
MEMORY=900m
# Проба после подмены — пара аудита chil-yunus (Чиланзар → Юнусабад).
PROBE="/route/v1/driving/69.19617,41.28151;69.28866,41.36612?overview=false"

SPEEDS=""; FORCE=0; DRY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --speeds) SPEEDS="${2:?--speeds: нужен файл}"; shift ;;
        --force) FORCE=1 ;;
        --dry-run) DRY=1 ;;
        *) echo "неизвестный ключ: $1" >&2; exit 2 ;;
    esac
    shift
done

log() { echo "$(date +%Y-%m-%dT%H:%M:%S) $*"; }
# current → слот одним rename(2): ссылка подменяется целиком, а не «mv в
# каталог, куда она указывает» (mv -T есть только в GNU, тесты идут на маке).
point() {
    ln -sfn "$1" "$ROOT/current.new"
    python3 -c 'import os, sys; os.replace(sys.argv[1], sys.argv[2])' "$ROOT/current.new" "$ROOT/current"
}
run() {
    if [ "$DRY" = 1 ]; then echo "+ $*"; else "$@"; fi
}

# Прод — не наш: ни его контейнер, ни его порт, ни его каталоги.
case "$CONTAINER" in radarmap-osrm) echo "отказ: $CONTAINER — прод-контейнер" >&2; exit 2 ;; esac
[ "$PORT" != 8092 ] || { echo "отказ: 8092 — порт прода" >&2; exit 2; }
case "$ROOT" in /opt/radarmap/osrm|/opt/radarmap/osrm/|/opt/radarmap/osrm-29e|/opt/radarmap/osrm-29e/)
    echo "отказ: $ROOT — граф прода" >&2; exit 2 ;; esac

[ -s "$ROOT/pristine/$NAME.osrm.mldgr" ] || { echo "нет эталона $ROOT/pristine/$NAME.osrm.mldgr" >&2; exit 1; }

# Замок: два цикла разом не идут (customize дольше интервала cron — пропуск).
# mkdir атомарен и есть везде; замок старше 30 минут — от убитого цикла.
LOCK="$ROOT/.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
        rmdir "$LOCK" 2>/dev/null || true
        mkdir "$LOCK" 2>/dev/null || { log "замок занят — пропуск"; exit 0; }
    else
        log "прошлый цикл ещё идёт — пропуск"; exit 0
    fi
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

# 1. Файл скоростей.
if [ -n "$SPEEDS" ]; then
    [ "$DRY" = 1 ] || [ -f "$SPEEDS" ] || { echo "нет файла $SPEEDS" >&2; exit 1; }
    run cp "$SPEEDS" "$ROOT/speeds.csv"
else
    run python3 "$BIN/traffic_speeds.py" --db "$DB" --source "$SOURCE" --mode "$MODE" --out "$ROOT/speeds.csv"
fi

CURRENT="$(readlink "$ROOT/current" 2>/dev/null || true)"
if [ "$FORCE" = 0 ] && [ -n "$CURRENT" ] && [ "$DRY" = 0 ] \
        && cmp -s "$ROOT/speeds.csv" "$ROOT/$CURRENT/speeds.csv"; then
    log "без изменений (слот $CURRENT)"; exit 0
fi
NEXT=$([ "$CURRENT" = a ] && echo b || echo a)
ROWS=$([ "$DRY" = 1 ] && echo "?" || grep -c . "$ROOT/speeds.csv" || true)

# 2. Запасной слот с эталона: ссылки на неизменяемое, копии переписываемого.
STAGE="$ROOT/$NEXT.new"
run rm -rf "$STAGE"
run mkdir -p "$STAGE"
for f in "$ROOT/pristine/$NAME.osrm"*; do
    base="$(basename "$f")"
    case "$base" in
        *.osrm.cell_metrics|*.osrm.datasource_names)
            # Выход customize. Без пробок слот берёт копию эталона (там метрика
            # графа без пробок), с пробками customize создаст файл сам.
            if [ "$ROWS" = 0 ]; then run cp "$f" "$STAGE/$base"; fi ;;
        *.osrm.mldgr|*.osrm.geometry) run cp "$f" "$STAGE/$base" ;;
        *) run ln "$f" "$STAGE/$base" ;;
    esac
done
run cp "$ROOT/speeds.csv" "$STAGE/speeds.csv"

# 3. customize — только если есть пробки: пустой файл — граф эталона как есть.
SECONDS=0
customize() {
    "$DOCKER" run --rm --name "$CONTAINER-customize" -m "$MEMORY" --memory-swap "$MEMORY" --cpus 1 \
        -v "$STAGE:/data" "$IMAGE" \
        osrm-customize -t 1 --segment-speed-file /data/speeds.csv "/data/$NAME.osrm"
}
if [ "$ROWS" != 0 ]; then
    # Журнал customize (~40 строк) — в $ROOT/customize.log, в журнал cron —
    # одна итоговая строка цикла.
    if [ "$DRY" = 1 ]; then
        echo "+ $DOCKER run --rm --name $CONTAINER-customize -m $MEMORY --memory-swap $MEMORY --cpus 1 -v $STAGE:/data $IMAGE osrm-customize -t 1 --segment-speed-file /data/speeds.csv /data/$NAME.osrm"
    elif ! customize > "$ROOT/customize.log" 2>&1; then
        log "customize упал (предел памяти $MEMORY?) — слот без пробок"
        run rm -rf "$STAGE"
        run mkdir -p "$STAGE"
        for f in "$ROOT/pristine/$NAME.osrm"*; do
            base="$(basename "$f")"
            case "$base" in
                *.osrm.cell_metrics|*.osrm.datasource_names|*.osrm.mldgr|*.osrm.geometry) run cp "$f" "$STAGE/$base" ;;
                *) run ln "$f" "$STAGE/$base" ;;
            esac
        done
        run cp /dev/null "$STAGE/speeds.csv"
        ROWS=0
    fi
fi
CUSTOMIZE=$SECONDS

# 4. Подмена: слот целиком, затем ссылка current атомарно (mv поверх ссылки).
run rm -rf "$ROOT/$NEXT"
run mv "$STAGE" "$ROOT/$NEXT"
run point "$NEXT"

if [ "$DRY" = 1 ]; then
    run "$DOCKER" restart -t 5 "$CONTAINER"
    exit 0
fi
if ! "$DOCKER" inspect "$CONTAINER" >/dev/null 2>&1; then
    # Первый цикл до `docker run` стенда (TRAFFIC.md, «Стенд»): слот готов.
    log "слот $NEXT, рёбер $ROWS; контейнера $CONTAINER нет — не перезапускался"
    exit 0
fi

# 5. Перезапуск и проба; не ответил за 30 с — назад на прошлый слот.
SECONDS=0
"$DOCKER" restart -t 5 "$CONTAINER" >/dev/null
ok=0
for _ in $(seq 1 60); do
    if curl -sf -m 5 "http://127.0.0.1:$PORT$PROBE" >/dev/null 2>&1; then ok=1; break; fi
    sleep 0.5
done
DOWN=$SECONDS
if [ "$ok" = 0 ]; then
    if [ -n "$CURRENT" ] && [ -d "$ROOT/$CURRENT" ]; then
        point "$CURRENT"
        "$DOCKER" restart -t 5 "$CONTAINER" >/dev/null
    fi
    log "ОШИБКА: стенд не ответил после подмены на $NEXT — возврат на ${CURRENT:-?}"
    exit 1
fi
log "слот $NEXT, рёбер $ROWS, customize ${CUSTOMIZE} с, простой ${DOWN} с"
