#!/bin/bash
# Сверка сервера с репозиторием: md5 каждого файла, который мы кладём на VPS.
#
# 27.09.2026 разошлось 7 файлов из 22, и все — сервер старее репо: правка
# «лимит не с дублёра» была в гите три недели, а на проде работал старый
# экстрактор. Ещё два файла жили ТОЛЬКО на сервере. Ни одно из этого не было
# видно, пока не сверили руками.
#
#   bash server/drift.sh          # таблица, код 1 при расхождении
#   bash server/drift.sh --quiet  # только расхождения (для deploy_api.sh)
#
# Правило проекта: на сервере ничего не правится руками. Нашлось «РАЗНЫЕ» —
# либо выкатить репо, либо перенести правку с сервера в репо, третьего нет.
set -uo pipefail
HOST="${RADARMAP_HOST:-radarmap-vps}"
DIR="$(cd "$(dirname "$0")" && pwd)"
QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

# репо (относительно server/) → путь на сервере
MAP="
api.py                        /opt/radarmap/api/api.py
admin.py                      /opt/radarmap/api/admin.py
admin_auth.py                 /opt/radarmap/api/admin_auth.py
notify.py                     /opt/radarmap/api/notify.py
family_notify.py              /opt/radarmap/api/family_notify.py
map_edits.py                  /opt/radarmap/api/map_edits.py
osm_queue.py                  /opt/radarmap/api/osm_queue.py
status.py                     /opt/radarmap/api/status.py
extract_speed_limits.py       /opt/radarmap/api/extract_speed_limits.py
update_speed_limits.sh        /opt/radarmap/api/update_speed_limits.sh
update_cameras.py             /opt/radarmap/api/update_cameras.py
update_osrm.sh                /opt/radarmap/api/update_osrm.sh
backup_db.sh                  /opt/radarmap/api/backup_db.sh
tg_bind.sh                    /opt/radarmap/api/tg_bind.sh
static/moderate.js            /opt/radarmap/api/static/moderate.js
static/editor.js              /opt/radarmap/api/static/editor.js
static/editor_gl.js           /opt/radarmap/api/static/editor_gl.js
update_roads.sh               /opt/radarmap/update_roads.sh
fetch_candidates.sh           /opt/radarmap/fetch_candidates.sh
build_roads.py                /opt/radarmap/work/build_roads.py
build_mvt.py                  /opt/radarmap/work/build_mvt.py
mvt.py                        /opt/radarmap/work/mvt.py
ml_candidates.py              /opt/radarmap/work/ml_candidates.py
snap_cameras.py               /opt/radarmap/work/snap_cameras.py
surface_check.py              /opt/radarmap/work/surface_check.py
nginx-radarmap.conf           /etc/nginx/conf.d/radarmap.conf
nginx-radarmap-location.conf  /etc/nginx/snippets/radarmap-location.conf
radarmap-api.service          /etc/systemd/system/radarmap-api.service
radarmap-admin.service        /etc/systemd/system/radarmap-admin.service
docker-user-firewall.service  /etc/systemd/system/docker-user-firewall.service
sshd-00-hardening.conf        /etc/ssh/sshd_config.d/00-hardening.conf
logrotate-radarmap            /etc/logrotate.d/radarmap
journald-00-size.conf         /etc/systemd/journald.conf.d/00-size.conf
systemd-radarmap-sandbox.conf /etc/systemd/system/radarmap-api.service.d/sandbox.conf
systemd-radarmap-sandbox.conf /etc/systemd/system/radarmap-admin.service.d/sandbox.conf
"

# Файлы, которые в репо хранят не байт в байт: боевой nginx-конфиг снят с
# сервера с шапкой-комментарием сверху.
strip_header() {
    case "$1" in
        nginx-radarmap.conf) sed '1,/^$/d' "$DIR/$1" ;;
        *) cat "$DIR/$1" ;;
    esac
}

# md5 на маке — /sbin/md5, на linux — md5sum; PATH у launchd и cron бывает урезан.
md5of() { if [ -x /sbin/md5 ]; then /sbin/md5 -q; else md5sum | cut -c1-32; fi; }

remote_paths=$(echo "$MAP" | awk 'NF==2 {print $2}' | tr '\n' ' ')
remote=$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST" \
    "for f in $remote_paths; do if [ -f \"\$f\" ]; then md5sum \"\$f\"; else echo \"- \$f\"; fi; done; crontab -l | md5sum | sed 's#-#crontab#'")
[ -n "$remote" ] || { echo "сервер не ответил"; exit 2; }

drift=0
while read -r repo path; do
    [ -n "$repo" ] || continue
    theirs=$(echo "$remote" | awk -v p="$path" '$2==p {print $1}')
    if [ ! -f "$DIR/$repo" ]; then state="НЕТ В РЕПО"
    elif [ "$theirs" = "-" ] || [ -z "$theirs" ]; then state="НЕТ НА СЕРВЕРЕ"
    elif [ "$(strip_header "$repo" | md5of)" = "$theirs" ]; then state="="
    else state="РАЗНЫЕ"
    fi
    [ "$state" = "=" ] || drift=1
    if [ "$QUIET" = "0" ] || [ "$state" != "=" ]; then
        printf "%-15s %-30s %s\n" "$state" "$repo" "$path"
    fi
done <<< "$(echo "$MAP" | awk 'NF==2')"

theirs=$(echo "$remote" | awk '$2=="crontab" {print $1}')
mine=$(md5of < "$DIR/crontab.txt")
if [ "$theirs" != "$mine" ]; then
    drift=1; printf "%-15s %-30s %s\n" "РАЗНЫЕ" "crontab.txt" "crontab -l"
elif [ "$QUIET" = "0" ]; then
    printf "%-15s %-30s %s\n" "=" "crontab.txt" "crontab -l"
fi

[ "$drift" = "0" ] && { [ "$QUIET" = "1" ] || echo "сервер = репо"; }
exit $drift
