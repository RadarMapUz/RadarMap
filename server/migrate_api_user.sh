#!/bin/bash
# API, панель и бот — не от root (38A, 02.11.2026). Запускается с мака
# владельца, как deploy-скрипты; на VPS работает от root по ssh.
#
#   bash server/migrate_api_user.sh --check      # что будет сделано; ничего не меняет
#   bash server/migrate_api_user.sh              # миграция (простой ~10 с)
#   bash server/migrate_api_user.sh --rollback   # откат одной командой
#
# Что меняется:
#   * пользователь radarmap (системный, без входа и без домашнего каталога);
#   * базы reports/traffic/family/bot.db (с -wal/-shm) переезжают в
#     /opt/radarmap/data (radarmap:radarmap 750, файлы 640), а на старом месте
#     остаются символьные ссылки — пути во всём коде и в cron прежние. SQLite
#     (≥ 3.10, на VPS 3.37) раскрывает ссылку, и -wal/-shm ложатся рядом с
#     настоящим файлом, в data/;
#   * /opt/radarmap/api — root:radarmap 750 и НЕ доступен api на запись. Это
#     главное: оттуда cron от root исполняет status.py, traffic_build.py,
#     backup_db.sh, и Python ищет модули сначала в каталоге скрипта — право
#     записи туда у api (json.py рядом со status.py) было бы root через пять
#     минут. Потому базы и уезжают, а не каталог меняет хозяина;
#   * admin.conf — radarmap 600 (панель пишет секрет сессий, api читает токен
#     уведомлений), telegram_bot.conf — root:radarmap 640, бэкапы — 700/600,
#     reports.db.before-* — 600;
#   * drop-in user.conf у radarmap-{api,admin,bot}: User=radarmap и запись
#     только в /opt/radarmap/data (+ admin.conf у панели).
#
# Cron от root (traffic_build.py, status.py, backup_db.sh, traffic_customize.sh)
# работает как раньше: root пишет и читает всё, а -wal/-shm, созданные root,
# SQLite сам отдаёт хозяину базы (robustFchown в os_unix.c) — скрипт это
# проверяет прогоном traffic_build.py после миграции.
#
# Порядок: остановить юниты → взять замок traffic_build (traffic.db.lock) и
# замок цикла стенда (osrm-mld/.lock) → дождаться, что базы никем не открыты
# (fuser) → перенести → права → drop-in → запустить → здоровье. Здоровье не
# сошлось — откат сам, тем же кодом, что --rollback. Прежние владельцы и права
# каждого тронутого пути — в /opt/radarmap/.migrate_api_user.state; откат
# возвращает их байт в байт. Пользователь radarmap после отката остаётся
# (убрать: userdel radarmap).
set -euo pipefail

HOST="${RADARMAP_HOST:-root@45.130.148.94}"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=15)
SCP=(scp -o BatchMode=yes -o ConnectTimeout=15)
if [ -n "${RADARMAP_SSH_KEY:-}" ]; then
    SSH+=(-i "$RADARMAP_SSH_KEY"); SCP+=(-i "$RADARMAP_SSH_KEY")
fi
DIR="$(cd "$(dirname "$0")" && pwd)"
DROPINS=(systemd-radarmap-user-api.conf systemd-radarmap-user-admin.conf systemd-radarmap-user-bot.conf)
STAGE=/root/.radarmap-migrate

case "${1:-}" in
    "") MODE=apply ;;
    --check) MODE=check ;;
    --rollback) MODE=rollback ;;
    *) echo "ключи: --check | --rollback | без ключа — миграция" >&2; exit 2 ;;
esac

if [ "$MODE" = apply ]; then
    echo "→ Ворота: drop-in на сервере не разошлись с репо (drift.sh --gate)…"
    RADARMAP_HOST="$HOST" bash "$DIR/drift.sh" --gate "${DROPINS[@]}" || {
        echo "✗ Миграция остановлена до заливки: на сервере ничего не тронуто."; exit 1; }
    "${SSH[@]}" "$HOST" "mkdir -p $STAGE && chmod 700 $STAGE"
    for f in "${DROPINS[@]}"; do "${SCP[@]}" "$DIR/$f" "$HOST:$STAGE/$f"; done
fi

"${SSH[@]}" "$HOST" bash -s -- "$MODE" "$STAGE" <<'REMOTE'
set -euo pipefail
cd /
MODE="$1"; STAGE="$2"
# Третий и четвёртый — только для test_migrate_api_user.py (временный корень).
R="${3:-/opt/radarmap}"
UNITDIR="${4:-/etc/systemd/system}"
API=$R/api
DATA=$R/data
STATE=$R/.migrate_api_user.state
DBS="reports.db traffic.db family.db bot.db"
UNITS="radarmap-api radarmap-admin radarmap-bot"
CUSTOMIZE_LOCK=$R/osrm-mld/.lock
HELD_CUSTOMIZE=0

say() { echo "  $*"; }
die() { echo "✗ $*"; exit 1; }

release() {
    [ "$HELD_CUSTOMIZE" = 1 ] && rmdir "$CUSTOMIZE_LOCK" 2>/dev/null || true
    HELD_CUSTOMIZE=0
    exec 8>&- 2>/dev/null || true
}
trap release EXIT

lock_cron() {
    # traffic_build.py (cron */2, пишет traffic.db) — тот же flock, что у него.
    exec 8>"$API/traffic.db.lock"
    flock -w 180 8 || die "traffic_build.py держит замок дольше 3 минут"
    # Цикл стенда (cron 3-59/5) читает traffic.db и reports.db.
    if [ -d "$R/osrm-mld" ]; then
        for _ in $(seq 1 90); do
            if mkdir "$CUSTOMIZE_LOCK" 2>/dev/null; then HELD_CUSTOMIZE=1; break; fi
            sleep 2
        done
        [ "$HELD_CUSTOMIZE" = 1 ] || die "цикл customize держит замок дольше 3 минут"
    fi
}

# Базы никем не открыты: status.py (cron */5) и backup_db.sh читают reports.db.
wait_free() {
    local busy f
    for _ in $(seq 1 60); do
        busy=""
        for f in "$@"; do
            [ -e "$f" ] && [ ! -L "$f" ] && fuser -s "$f" 2>/dev/null && busy="$busy $f"
        done
        [ -z "$busy" ] && return 0
        sleep 2
    done
    die "базы открыты дольше 2 минут:$busy"
}

db_files() {   # $1 — каталог: все файлы баз с -wal/-shm, что есть
    local d=$1 db
    for db in $DBS; do for f in "$d/$db" "$d/$db-wal" "$d/$db-shm"; do
        [ -e "$f" ] && [ ! -L "$f" ] && echo "$f"
    done; done
    return 0
}

unit_user() { ps -o user= -p "$(systemctl show -p MainPID --value "$1")" 2>/dev/null | tr -d ' '; }

health() {   # $1 — ожидаемый пользователь; $2 — с какого времени смотреть журнал
    local want=$1 since=$2 ok=1 code u
    sleep 2
    for u in radarmap-api radarmap-admin; do
        systemctl is-active -q "$u" || { echo "  ✗ $u не поднялся"; ok=0; continue; }
        [ "$(unit_user "$u")" = "$want" ] || { echo "  ✗ $u работает не от $want"; ok=0; }
    done
    if [ "$BOT_WAS" = active ]; then
        systemctl is-active -q radarmap-bot || { echo "  ✗ radarmap-bot не поднялся"; ok=0; }
    fi
    curl -sf -m 5 http://127.0.0.1:8091/api/health | grep -q '"ok"' || { echo "  ✗ /api/health"; ok=0; }
    for path in /api/mobile /api/road; do
        code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:8091$path")
        [ "$code" = 200 ] || { echo "  ✗ $path → $code"; ok=0; }
    done
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' http://127.0.0.1:8093/login)
    [ "$code" = 200 ] || { echo "  ✗ панель /login → $code"; ok=0; }
    if journalctl -u radarmap-api -u radarmap-admin -u radarmap-bot --since "$since" --no-pager 2>/dev/null \
            | grep -Eiq 'readonly database|unable to open database|Permission denied|PermissionError|база не открылась'; then
        echo "  ✗ в журнале юнитов ошибки доступа:"
        journalctl -u radarmap-api -u radarmap-admin -u radarmap-bot --since "$since" --no-pager \
            | grep -Ei 'readonly database|unable to open database|Permission denied|PermissionError|база не открылась' | tail -5
        ok=0
    fi
    [ "$ok" = 1 ]
}

# Запись от radarmap — без изменений: BEGIN IMMEDIATE берёт блокировку записи,
# заводит -wal/-shm и откатывается.
probe_write() {
    local db
    for db in $DBS; do
        [ -e "$DATA/$db" ] || continue
        runuser -u radarmap -- python3 -c 'import sqlite3, sys
c = sqlite3.connect(sys.argv[1], timeout=10)
c.execute("BEGIN IMMEDIATE"); c.rollback(); c.close()' "$API/$db" \
            || { echo "  ✗ radarmap не пишет $db"; return 1; }
    done
}

preflight() {
    python3 -c 'import sqlite3, sys
v = tuple(int(x) for x in sqlite3.sqlite_version.split("."))
sys.exit(0 if v >= (3, 10, 0) else 1)' || die "SQLite старше 3.10 — не раскрывает ссылки на базу"
    for tool in fuser runuser flock useradd; do command -v "$tool" >/dev/null || die "нет $tool"; done
    for u in radarmap-api radarmap-admin; do systemctl cat "$u" >/dev/null 2>&1 || die "нет юнита $u"; done
    [ "$(stat -c %d "$API")" = "$(stat -c %d "$R")" ] || die "$API и $R на разных разделах — перенос не rename"
}

save_state() {
    [ -f "$STATE" ] && { say "состояние уже сохранено ($STATE) — повторный запуск"; return; }
    (
        umask 077
        for p in "$API" "$R/admin.conf" "$R/telegram_bot.conf" "$R/backups" $(db_files "$API") \
                 "$API"/reports.db.before-* "$R"/backups/*; do
            if [ -e "$p" ]; then stat -c '%U %G %a %n' "$p"; fi
        done > "$STATE"
    )
    say "прежние права: $STATE ($(wc -l < "$STATE") путей)"
}

restore_state() {
    local u g m p
    while read -r u g m p; do
        [ -e "$p" ] || continue
        chown "$u:$g" "$p" && chmod "$m" "$p"
    done < "$STATE"
}

stop_units() {
    BOT_WAS=$(systemctl is-active radarmap-bot 2>/dev/null || true)
    systemctl stop radarmap-bot 2>/dev/null || true
    systemctl stop radarmap-admin radarmap-api
}

start_units() {
    systemctl start radarmap-api radarmap-admin
    [ "$BOT_WAS" = active ] && systemctl start radarmap-bot || true
}

do_rollback() {
    [ -f "$STATE" ] || die "нет $STATE — откатывать нечего"
    local since db f
    since=$(date '+%Y-%m-%d %H:%M:%S')
    echo "→ Откат: юниты стоп, замки cron…"
    stop_units
    lock_cron
    wait_free $(db_files "$DATA")
    rm -f "$UNITDIR"/radarmap-{api,admin,bot}.service.d/user.conf
    systemctl daemon-reload
    for db in $DBS; do
        [ -L "$API/$db" ] && rm -f "$API/$db"
        for f in "$DATA/$db" "$DATA/$db-wal" "$DATA/$db-shm"; do
            [ -e "$f" ] || continue
            mv "$f" "$API/"
            chown root:root "$API/$(basename "$f")"; chmod 644 "$API/$(basename "$f")"
        done
    done
    restore_state
    rmdir "$DATA" 2>/dev/null || say "в $DATA остались чужие файлы — каталог не удалён"
    release
    start_units
    if health root "$since"; then
        mv "$STATE" "$STATE.rolled-back.$(date +%Y%m%d%H%M%S)"
        echo "✓ Откат: api, панель и бот снова от root, базы в $API. Пользователь radarmap остался (userdel radarmap)."
    else
        die "после отката здоровье не сошлось — смотреть journalctl -u radarmap-api"
    fi
}

preflight
case "$MODE" in
check)
    echo "→ Проверка (ничего не меняю):"
    say "SQLite $(python3 -c 'import sqlite3; print(sqlite3.sqlite_version)'), пользователь radarmap: $(id radarmap 2>/dev/null || echo 'нет — будет создан')"
    for u in $UNITS; do say "$u: $(systemctl is-active "$u" 2>/dev/null || true), от $(unit_user "$u" || echo '—')"; done
    for db in $DBS; do
        if [ -L "$API/$db" ]; then say "$db: уже ссылка → $(readlink "$API/$db")"
        elif [ -e "$API/$db" ]; then say "$db: $(stat -c '%U:%G %a %s байт' "$API/$db") → переедет в $DATA"
        else say "$db: нет — будет ссылка на $DATA/$db (создаст тот, кто первым откроет)"; fi
    done
    for p in "$R/admin.conf" "$R/telegram_bot.conf" "$R/backups" "$API"; do
        [ -e "$p" ] && say "$(stat -c '%U:%G %a' "$p") $p"
    done
    say "drop-in: $(ls "$UNITDIR"/radarmap-*.service.d/ 2>/dev/null | tr '\n' ' ')"
    echo "✓ Проверка пройдена. Миграция: bash server/migrate_api_user.sh"
    ;;
apply)
    for f in systemd-radarmap-user-api.conf systemd-radarmap-user-admin.conf systemd-radarmap-user-bot.conf; do
        [ -s "$STAGE/$f" ] || die "нет $STAGE/$f — заливка не дошла"
    done
    SINCE=$(date '+%Y-%m-%d %H:%M:%S')
    echo "→ Пользователь radarmap…"
    id radarmap >/dev/null 2>&1 || useradd --system --user-group --no-create-home \
        --home-dir /nonexistent --shell /usr/sbin/nologin radarmap
    save_state
    echo "→ Юниты стоп, замки cron, базы свободны…"
    stop_units
    lock_cron
    wait_free $(db_files "$API")
    echo "→ Базы → $DATA, на старом месте ссылки…"
    mkdir -p "$DATA"
    chown radarmap:radarmap "$DATA"; chmod 750 "$DATA"
    for db in $DBS; do
        if [ -L "$API/$db" ]; then say "$db: уже перенесена"; continue; fi
        if [ -e "$API/$db" ]; then
            python3 -c 'import sqlite3, sys
c = sqlite3.connect(sys.argv[1], timeout=10); c.execute("PRAGMA wal_checkpoint(TRUNCATE)"); c.close()' "$API/$db"
            for f in "$API/$db" "$API/$db-wal" "$API/$db-shm"; do [ -e "$f" ] && mv "$f" "$DATA/"; done
            say "$db: перенесена"
        else
            say "$db: нет — только ссылка"
        fi
        ln -s "$DATA/$db" "$API/$db"
    done
    find "$DATA" -maxdepth 1 -type f -exec chown radarmap:radarmap {} + -exec chmod 640 {} +
    echo "→ Права конфигов, каталога кода и бэкапов…"
    [ -e "$R/admin.conf" ] && { chown radarmap:radarmap "$R/admin.conf"; chmod 600 "$R/admin.conf"; }
    [ -e "$R/telegram_bot.conf" ] && { chown root:radarmap "$R/telegram_bot.conf"; chmod 640 "$R/telegram_bot.conf"; }
    chown root:radarmap "$API"; chmod 750 "$API"
    for f in "$API"/reports.db.before-*; do [ -e "$f" ] && chmod 600 "$f"; done
    if [ -d "$R/backups" ]; then
        chmod 700 "$R/backups"
        find "$R/backups" -maxdepth 1 -type f -exec chmod 600 {} +
    fi
    echo "→ drop-in user.conf…"
    for u in api admin bot; do
        mkdir -p "$UNITDIR/radarmap-$u.service.d"
        install -m 644 "$STAGE/systemd-radarmap-user-$u.conf" "$UNITDIR/radarmap-$u.service.d/user.conf"
    done
    systemctl daemon-reload
    release
    echo "→ Запуск и здоровье…"
    start_units
    if ! health radarmap "$SINCE" || ! probe_write; then
        echo "✗ Здоровье не сошлось — откатываю"
        do_rollback
        exit 1
    fi
    echo "→ Прогон traffic_build.py от root: -wal/-shm остаются у radarmap…"
    timeout 150 python3 "$API/traffic_build.py" >/dev/null 2>&1 || say "traffic_build.py вернул ошибку — смотреть /var/log/radarmap-traffic.log"
    foreign=""
    for f in "$DATA"/*; do
        [ -e "$f" ] && [ "$(stat -c %U "$f")" != radarmap ] && foreign="$foreign $f"
    done
    if [ -n "$foreign" ]; then
        echo "✗ в $DATA появились файлы не radarmap: $foreign — откатываю"
        do_rollback
        exit 1
    fi
    echo "✓ api, панель и бот — от radarmap; базы в $DATA; откат: bash server/migrate_api_user.sh --rollback"
    ;;
rollback)
    BOT_WAS=$(systemctl is-active radarmap-bot 2>/dev/null || true)
    do_rollback
    ;;
esac
REMOTE
