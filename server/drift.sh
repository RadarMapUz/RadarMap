#!/bin/bash
# Сверка сервера с репозиторием: md5 каждого файла, который мы кладём на VPS.
#
# 27.09.2026 разошлось 7 файлов из 22, и все — сервер старее репо: правка
# «лимит не с дублёра» была в гите три недели, а на проде работал старый
# экстрактор. Ещё два файла жили ТОЛЬКО на сервере. Ни одно из этого не было
# видно, пока не сверили руками.
#
#   bash server/drift.sh                 # таблица, код 1 при расхождении
#   bash server/drift.sh --quiet         # только расхождения (итог после выкатки)
#   bash server/drift.sh --gate a.py b.sh  # ворота перед выкаткой этих файлов
#
# Правило проекта: на сервере ничего не правится руками. Нашлось «РАЗНЫЕ» —
# либо выкатить репо, либо перенести правку с сервера в репо, третьего нет.
#
# Чтобы было видно, какое из двух, у каждого «РАЗНЫЕ» стоит причина: git-хэш
# серверной копии ищется в истории файла. Нашёлся в истории текущей ветки —
# сервер просто старее репо, выкатка безопасна. Нашёлся только на другой
# ветке — на сервере чужая незалитая работа. Не нашёлся нигде — правка руками
# на сервере (или отличие окружения), и её надо сначала перенести в репо.
#
# Ворота (--gate, 28.10.2026). deploy_*.sh зовут их ДО заливки по ровно тем
# файлам, которые сейчас перезапишут, и останавливаются, если серверная копия
# не из истории этой ветки: горячую правку на сервере выкатка затирать не
# должна — 28.10 после deploy_api.sh всплыло девять расхождений, и ни про одно
# нельзя было сказать без ручного diff, можно ли его перезаписать. Обход —
# только явный: RADARMAP_ALLOW_DRIFT=1 (скрипт скажет, что именно затирает).
# Сервер не ответил — тоже стоп: неизвестно не значит безопасно.
#
# Коды: 0 — совпадает / ворота открыты; 1 — есть расхождения; 2 — сервер не
# ответил; 3 — ворота закрыты; 4 — файла нет в карте ниже (добавить строку).
set -uo pipefail
HOST="${RADARMAP_HOST:-radarmap-vps}"
DIR="$(cd "$(dirname "$0")" && pwd)"
QUIET=0
GATE=0
GATE_FILES=""
case "${1:-}" in
    --quiet) QUIET=1 ;;
    --gate) GATE=1; QUIET=1; shift; GATE_FILES="$*" ;;
esac

# ssh подменяется в тестах (test_drift.py) заглушкой без сети.
SSH_CMD="${RADARMAP_DRIFT_SSH:-ssh}"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=15"
[ -n "${RADARMAP_SSH_KEY:-}" ] && SSH_OPTS="$SSH_OPTS -i $RADARMAP_SSH_KEY"

# репо (относительно server/) → путь на сервере
MAP="
api.py                        /opt/radarmap/api/api.py
admin.py                      /opt/radarmap/api/admin.py
admin_auth.py                 /opt/radarmap/api/admin_auth.py
notify.py                     /opt/radarmap/api/notify.py
family_notify.py              /opt/radarmap/api/family_notify.py
telegram_bot.py               /opt/radarmap/api/telegram_bot.py
telegram_publish.py           /opt/radarmap/api/telegram_publish.py
bot_texts.py                  /opt/radarmap/api/bot_texts.py
bot_near.py                   /opt/radarmap/api/bot_near.py
bot_subs.py                   /opt/radarmap/api/bot_subs.py
map_edits.py                  /opt/radarmap/api/map_edits.py
osm_queue.py                  /opt/radarmap/api/osm_queue.py
status.py                     /opt/radarmap/api/status.py
build_hotspots.py             /opt/radarmap/api/build_hotspots.py
extract_speed_limits.py       /opt/radarmap/api/extract_speed_limits.py
update_speed_limits.sh        /opt/radarmap/api/update_speed_limits.sh
update_cameras.py             /opt/radarmap/api/update_cameras.py
update_osrm.sh                /opt/radarmap/api/update_osrm.sh
backup_db.sh                  /opt/radarmap/api/backup_db.sh
tg_bind.sh                    /opt/radarmap/api/tg_bind.sh
traffic_config.py             /opt/radarmap/api/traffic_config.py
traffic_model.py              /opt/radarmap/api/traffic_model.py
traffic_profile.py            /opt/radarmap/api/traffic_profile.py
traffic_build.py              /opt/radarmap/api/traffic_build.py
build_road_weather.py         /opt/radarmap/api/build_road_weather.py
road_weather_points.json      /opt/radarmap/api/road_weather_points.json
static/moderate.js            /opt/radarmap/api/static/moderate.js
static/editor.js              /opt/radarmap/api/static/editor.js
static/editor_gl.js           /opt/radarmap/api/static/editor_gl.js
static/vendor/maplibre-gl.js  /opt/radarmap/api/static/vendor/maplibre-gl.js
static/vendor/maplibre-gl.css /opt/radarmap/api/static/vendor/maplibre-gl.css
traffic_config.py             /opt/radarmap/osrm-mld/bin/traffic_config.py
traffic_model.py              /opt/radarmap/osrm-mld/bin/traffic_model.py
traffic_profile.py            /opt/radarmap/osrm-mld/bin/traffic_profile.py
traffic_build.py              /opt/radarmap/osrm-mld/bin/traffic_build.py
traffic_speeds.py             /opt/radarmap/osrm-mld/bin/traffic_speeds.py
osrm/route_bench.py           /opt/radarmap/osrm-mld/bin/route_bench.py
osrm/traffic_customize.sh     /opt/radarmap/osrm-mld/bin/traffic_customize.sh
update_roads.sh               /opt/radarmap/update_roads.sh
fetch_candidates.sh           /opt/radarmap/fetch_candidates.sh
build_roads.py                /opt/radarmap/work/build_roads.py
build_mvt.py                  /opt/radarmap/work/build_mvt.py
mvt.py                        /opt/radarmap/work/mvt.py
ml_candidates.py              /opt/radarmap/work/ml_candidates.py
snap_cameras.py               /opt/radarmap/work/snap_cameras.py
surface_check.py              /opt/radarmap/work/surface_check.py
lane_inference.py             /opt/radarmap/work/lane_inference.py
road_metrics.py               /opt/radarmap/work/road_metrics.py
junction_worklist.py          /opt/radarmap/work/junction_worklist.py
parking.py                    /opt/radarmap/work/parking.py
tree_planting.py              /opt/radarmap/work/tree_planting.py
nginx-radarmap.conf           /etc/nginx/conf.d/radarmap.conf
nginx-radarmap-osrm-upstream.conf /etc/nginx/conf.d/radarmap-osrm-upstream.conf
nginx-radarmap-location.conf  /etc/nginx/snippets/radarmap-location.conf
nginx-radarmap-uz.conf        /etc/nginx/sites-available/radarmap-uz
radarmap-api.service          /etc/systemd/system/radarmap-api.service
radarmap-admin.service        /etc/systemd/system/radarmap-admin.service
radarmap-bot.service          /etc/systemd/system/radarmap-bot.service
docker-user-firewall.service  /etc/systemd/system/docker-user-firewall.service
sshd-00-hardening.conf        /etc/ssh/sshd_config.d/00-hardening.conf
logrotate-radarmap            /etc/logrotate.d/radarmap
journald-00-size.conf         /etc/systemd/journald.conf.d/00-size.conf
systemd-radarmap-sandbox.conf /etc/systemd/system/radarmap-api.service.d/sandbox.conf
systemd-radarmap-sandbox.conf /etc/systemd/system/radarmap-admin.service.d/sandbox.conf
"
PAIRS="$(echo "$MAP" | awk 'NF==2')"

if [ "$GATE" = "1" ]; then
    [ -n "$GATE_FILES" ] || { echo "drift.sh --gate: не названо ни одного файла"; exit 4; }
    picked=""
    for f in $GATE_FILES; do
        lines=$(echo "$PAIRS" | awk -v r="$f" '$1==r')
        if [ -z "$lines" ]; then
            echo "drift.sh --gate: $f нет в карте drift.sh — добавьте строку «файл путь-на-сервере»"
            exit 4
        fi
        picked="$picked
$lines"
    done
    PAIRS="$(echo "$picked" | awk 'NF==2')"
fi

# md5 на маке — /sbin/md5, на linux — md5sum; PATH у launchd и cron бывает урезан.
md5of() { if [ -x /sbin/md5 ]; then /sbin/md5 -q; else md5sum | cut -c1-32; fi; }

# crontab сравнивается по действующим строкам: комментарии и пустые строки в
# репо — документация (зачем строка, когда включена), а на сервере их
# стирают deploy_traffic.sh/deploy_road_weather.sh, переписывая свою строку.
# Строка задания, её порядок и закомментированное задание — сравниваются.
active_cron() { grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$'; }

# Все git-хэши, которые файл имел в истории: $1 — HEAD (эта ветка) или --all.
history_blobs() {
    git -C "$DIR" log "$1" --raw --no-abbrev --format= -- "$2" 2>/dev/null \
        | awk '{print $3; print $4}' | grep -v '^0*$' | sort -u
}

# Почему серверная копия отличается: старее | ветка | правка.
why_differs() {
    local repo="$1" blob="$2"
    if [ -n "$blob" ] && [ "$blob" != "-" ]; then
        history_blobs HEAD "$repo" | grep -qx "$blob" && { echo "старее"; return; }
        history_blobs --all "$repo" | grep -qx "$blob" && { echo "ветка"; return; }
    fi
    echo "правка"
}

reason_text() {
    case "$1" in
        старее) echo "сервер старее репо (эта версия есть в git) — выкатить" ;;
        ветка)  echo "на сервере версия с другой ветки — сначала слить её сюда" ;;
        *)      echo "серверной версии нет в git — правка на сервере или окружение: перенести в репо" ;;
    esac
}

remote_paths=$(echo "$PAIRS" | awk 'NF==2 {print $2}' | tr '\n' ' ')
# Для каждого файла: md5, git-хэш (blob <размер>\0 + содержимое) и путь.
remote=$($SSH_CMD $SSH_OPTS "$HOST" bash -s -- $remote_paths <<'REMOTE'
for f in "$@"; do
    if [ -f "$f" ]; then
        m=$(md5sum < "$f" | cut -c1-32)
        b=$({ printf 'blob %s\0' "$(stat -c%s "$f")"; cat "$f"; } | sha1sum | cut -c1-40)
        echo "$m $b $f"
    else
        echo "- - $f"
    fi
done
c=$(crontab -l 2>/dev/null | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' | md5sum | cut -c1-32)
echo "$c - crontab"
REMOTE
)
if [ -z "$remote" ]; then
    echo "сервер не ответил"
    if [ "$GATE" = "1" ] && [ "${RADARMAP_ALLOW_DRIFT:-0}" = "1" ]; then
        echo "  RADARMAP_ALLOW_DRIFT=1: сверку пропускаю по решению запускающего"
        exit 0
    fi
    exit 2
fi

drift=0
blocked=0
older=0
while read -r repo path; do
    [ -n "$repo" ] || continue
    theirs=$(echo "$remote" | awk -v p="$path" '$3==p {print $1}')
    blob=$(echo "$remote" | awk -v p="$path" '$3==p {print $2}')
    note=""
    if [ ! -f "$DIR/$repo" ]; then state="НЕТ В РЕПО"; blocked=1
    elif [ "$theirs" = "-" ] || [ -z "$theirs" ]; then state="НЕТ НА СЕРВЕРЕ"
    elif [ "$(md5of < "$DIR/$repo")" = "$theirs" ]; then state="="
    else
        state="РАЗНЫЕ"
        kind=$(why_differs "$repo" "$blob")
        note="  — $(reason_text "$kind")"
        if [ "$kind" = "старее" ]; then older=$((older + 1)); else blocked=1; fi
    fi
    [ "$state" = "=" ] || drift=1
    if [ "$QUIET" = "0" ] || [ "$state" != "=" ]; then
        printf "%-15s %-30s %s%s\n" "$state" "$repo" "$path" "$note"
    fi
done <<< "$PAIRS"

if [ "$GATE" = "1" ]; then
    if [ "$blocked" = "0" ]; then
        echo "  ворота drift: перезапись безопасна (сервер = репо или старее его: $older)"
        exit 0
    fi
    if [ "${RADARMAP_ALLOW_DRIFT:-0}" = "1" ]; then
        echo "  ⚠ RADARMAP_ALLOW_DRIFT=1: перезаписываю файлы выше, хотя серверная копия"
        echo "    не из истории этой ветки — то, что было на сервере, будет потеряно."
        exit 0
    fi
    echo "✗ ворота drift: сервер разошёлся с репо по файлу, который эта выкатка перезапишет."
    echo "  Горячую правку на сервере затирать нельзя: перенесите её в репо (scp с"
    echo "  сервера, diff, коммит) или слейте ветку, с которой выкатывали. Выкатывали"
    echo "  незакоммиченное — сначала коммит. Перезаписать осознанно:"
    echo "    RADARMAP_ALLOW_DRIFT=1 bash server/<тот же deploy-скрипт>.sh"
    exit 3
fi

theirs=$(echo "$remote" | awk '$3=="crontab" {print $1}')
mine=$(active_cron < "$DIR/crontab.txt" | md5of)
if [ "$theirs" != "$mine" ]; then
    drift=1; printf "%-15s %-30s %s\n" "РАЗНЫЕ" "crontab.txt" "crontab -l (действующие строки)"
elif [ "$QUIET" = "0" ]; then
    printf "%-15s %-30s %s\n" "=" "crontab.txt" "crontab -l (действующие строки)"
fi

[ "$drift" = "0" ] && { [ "$QUIET" = "1" ] || echo "сервер = репо"; }
exit $drift
