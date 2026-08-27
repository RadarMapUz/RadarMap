# Runbook: что где лежит и что делать, когда сломалось

Составлен 7 августа 2026 по фактическому состоянию VPS, а не по намерениям.
Читается в панике, поэтому короткий.

## Карта сервера (45.130.148.94)

VPS **общий** — рядом живут Dentalor (pm2: `MedicalNode`, `dentalor-bot`),
postgres, minio, prometheus, outline. Всё, что мы делаем, должно их не касаться:
конфиг только `/etc/nginx/conf.d/radarmap.conf`, юниты только `radarmap-*`.

| Что | Где |
|---|---|
| Публичный API | `radarmap-api.service` → `127.0.0.1:8091` |
| Панель модератора | `radarmap-admin.service` → `127.0.0.1:8093` (наружу НЕ выставлена) |
| OSRM (Docker) | `127.0.0.1:8092` — не 5000, контейнер проброшен docker-proxy |
| nginx | `:8090` → `/api/`, `/osrm/`, статика из `/opt/radarmap/www` |
| Код | `/opt/radarmap/api/{api.py,admin.py}` (рядом `.bak.<дата>`) |
| БД | `/opt/radarmap/api/reports.db` (WAL) |
| Раздача | `/opt/radarmap/www` — **только** файлы приложения, 5.5 МБ |
| Рабочие файлы снапа | `/opt/radarmap/work` — 225 МБ, наружу не отдаются |
| Бэкапы | `/opt/radarmap/backups`, 7 последних, cron 03:17 |
| Сторож | `/opt/radarmap/healthcheck.sh`, cron каждые 5 мин |
| Дороги, кандидат | `/opt/radarmap/update_roads.sh`, cron вс 04:17 — свежий OSM, сборка, отчёт; НЕ публикует |
| Установка конвейера | `bash server/install_roads_pipeline.sh [--run] [--swap] [--status]` — сборщик, недельный скрипт, крон, подкачка |
| Кандидаты нейросети | `bash server/fetch_candidates.sh` — руками и редко; в панели клавиша `C`. В индекс НЕ входят |
| Дороги, публикация | `publish_roads.sh --auto` на маке владельца, launchd вс 10:00 — ворота, подпись, выкладка |
| Дороги, откат | `bash server/rollback_roads.sh` — вернуть прошлый набор из `roads_prev` |
| Логи | `/var/log/radarmap-{backup,health}.log`, `journalctl -u radarmap-api` |

## Панель модератора

Наружу не выставлена намеренно: basic auth по открытому HTTP — это пароль
администратора, отданный любому Wi-Fi по дороге. До сертификата — туннель:

```bash
ssh -L 8093:127.0.0.1:8093 root@45.130.148.94
```

Дальше открыть `http://127.0.0.1:8093/` в браузере. После выпуска сертификата
раскомментировать `location /admin/` в `nginx-radarmap.conf` и завести
`/etc/nginx/.radarmap_admin`.

## Публикация (только с машины владельца — ключ подписи здесь)

```bash
bash server/deploy_api.sh              # api.py + admin.py, рестарт, смоук
bash server/deploy_db.sh <версия>      # база камер: подпись → scp → OTA
bash server/publish_config.sh '{…}'    # пульт; --reset вернуть к дефолтам
bash server/publish_overrides.sh <n>   # решения модератора; --dry-run проверить
```

Номер версии базы: приложение качает, только если `version > своей`. Прод и
бандл сейчас оба **v10** — публиковать v11 без новых данных значит заставить
всех скачать тот же мегабайт заново.

## Когда сломалось

**Не работают маршруты.** Проверить OSRM: `curl -s
'http://127.0.0.1:8090/osrm/route/v1/driving/69.24,41.31;69.28,41.33?overview=false'`.
Не отвечает — `docker ps | grep osrm`, перезапустить контейнер. Пока чинится:

```bash
bash server/publish_config.sh '{"features": {"routing": false}, "message": {"title": "Чиним маршруты", "body": "Оповещения о камерах работают как обычно"}}'
```

Починили — `bash server/publish_config.sh --reset`.

**API отдаёт 500 / «database is locked».** `journalctl -u radarmap-api -n 100`.
Проверить WAL: должно быть `wal`, не `delete`:
`python3 -c "import sqlite3;print(sqlite3.connect('/opt/radarmap/api/reports.db').execute('PRAGMA journal_mode').fetchone())"`.

**Откат кода.** Рядом лежат `api.py.bak.<дата>`: `cp api.py.bak.… api.py &&
systemctl restart radarmap-api`.

**Волна фейковых отметок.** Точечно — в панели, вкладка «Передвижные»,
«Убрать с карты». Массово — `publish_config.sh '{"features":
{"mobileReports": false}}'`, потом разобрать и вернуть.

**Скрыли живую камеру.** Панель → «Камеры» → «Вернуть камеру» →
`publish_overrides.sh <n+1>`. Доедет за 3 часа, на холодном старте сразу.

**Кончилось место.** `du -sh /opt/radarmap/*`. Кандидаты на чистку:
`/opt/radarmap/work` (рабочие файлы снапа), старые `.bak` в `api/`.

## Проверить, что всё живо

```bash
ssh root@45.130.148.94 /opt/radarmap/healthcheck.sh
```

Код 0 — всё хорошо. Сторож молчит, пока состояние не изменилось, поэтому
тишина в логе — это норма, а не «он не работает».

Уведомления в телеграм включаются двумя переменными в cron-строке:
`RADARMAP_TG_TOKEN=… RADARMAP_TG_CHAT=… /opt/radarmap/healthcheck.sh`.

## Долги

- **HTTPS с доменом** — блокер App Store и предусловие панели наружу
  (`HTTPS.md`).
- **Пароль root ходит по рукам.** Ставится SSH-ключ, пароль отключается
  (`PasswordAuthentication no`) — до публичного запуска обязательно.
