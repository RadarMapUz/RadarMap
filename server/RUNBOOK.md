# Runbook: что где лежит и что делать, когда сломалось

Составлен 7 августа 2026 по фактическому состоянию VPS, а не по намерениям.
Читается в панике, поэтому короткий.

## Карта сервера (45.130.148.94)

VPS **общий** — рядом живут Dentalor (pm2: `MedicalNode`, `dentalor-bot`),
postgres (и в Docker `medicalnode_db_1`), minio, wg-easy, xray, openvpn. Outline снесён 27.09.2026. Всё, что мы делаем, должно их не касаться:
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
| Бэкапы | `/opt/radarmap/backups`, 7 последних, cron 03:17; копия на мак владельца — `pull_backup.sh`, launchd 11:00 → `~/RadarMapBackups` |
| Пульт состояния | `/opt/radarmap/api/status.py`, cron каждые 5 мин (заменил `healthcheck.sh`); страница `/status` в панели, цвета наружу — `/radarmap/status.json` |
| Сверка с репо | `bash server/drift.sh` — md5 всего, что лежит на VPS; `deploy_api.sh` зовёт её сам |
| Реестр МВД | `update_cameras.py`, cron пн 05:00 — только замечает изменение, базу сливает владелец |
| Защита | SSH только по ключу (`sshd-00-hardening.conf`); `docker-user-firewall.service` закрывает :51821; песочница API/панели — `systemd-radarmap-sandbox.conf` |
| Дороги, кандидат | `/opt/radarmap/update_roads.sh`, cron вс 04:17 — свежий OSM, сборка, отчёт; НЕ публикует |
| Установка конвейера | `bash server/install_roads_pipeline.sh [--run] [--swap] [--status]` — сборщик, недельный скрипт, крон, подкачка |
| Кандидаты нейросети | `bash server/fetch_candidates.sh` — руками и редко; в панели клавиша `C`. В индекс НЕ входят |
| Дороги, публикация | `publish_roads.sh --auto` на маке владельца, launchd вс 10:00 — ворота, подпись, выкладка |
| Дороги, откат | `bash server/rollback_roads.sh` — вернуть прошлый набор из `roads_prev` |
| Логи | `/var/log/radarmap-{backup,status,roads}.log` (ротация еженедельно), `journalctl -u radarmap-api` |

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

Номер версии базы: приложение качает, только если `version > своей`. Бандл
сейчас **v12** (3511 камер). Публиковать новую версию без новых данных значит
заставить всех скачать тот же мегабайт заново.

### Пополнение базы камер из реестра МВД

```bash
python3 server/merge_cameras.py --base RadarMap/Resources/cameras.json \
                                --source свежий_реестр.json          # показать
python3 server/merge_cameras.py … --apply                            # записать
```

Реестр берётся открытым API портала (ключ не нужен):

```
https://data.egov.uz/apiData/MainData/GetByFile?id=62735473d44f5eea297cef3d&fileType=1&tableType=2
```

**Почему не `update_cameras.py`.** Тот собирает кандидата с нуля и раздаёт id
заново по алфавиту, а ещё возвращает только семь полей из тринадцати. Слить его
поверх боевой базы значит одновременно переклеить чужие проезды в истории на
чужие камеры и стереть геометрию снапа у 3463 записей. `merge_cameras.py`
устроен наоборот: истина по id и геометрии — боевая база, реестр только
дописывает в конец то, чего в ней нет, а перед записью проверяет инвариант
«ни один прежний id не сдвинулся».

Порядок после слияния — все три шага обязательны:

1. поднять `AppConfig.bundledDBVersion`: без этого телефон с уже скачанной
   базой прежней версии новых камер не увидит вовсе;
2. `snap_cameras.py` **по всей базе**, а не по срезу из новых — `twin` и поиск
   дублей считаются глобально и на срезе молча соврут. До снапа новые камеры
   помечены `needsReview`, и приложение честно показывает «координата
   приблизительная». Результат принимать **выборочно**:

   ```bash
   python3 server/adopt_snap.py --base RadarMap/Resources/cameras.json \
                                --snapped cameras.snapped.json --from-id <первый новый> --apply
   ```

   Снап пересчитывает профиль ВСЕЙ базе, и это не безобидно: на прогоне
   01.09.2026 из 3475 старых камер 116 сменили ось, 45 из них больше чем на
   30°, шесть ровно на 90° — то есть уехали на поперечную улицу. При
   `cameraAxisMaxAngle` 55° такая камера перестаёт считаться «нашей дорогой» и
   ЗАМОЛКАЕТ. Изменения разнородны: id=2747 уехал с footway на trunk (явное
   исправление), id=3440 — с trunk на living_street (явная поломка). Их надо
   смотреть глазами по `snap_moves.geojson` на geojson.io, и до тех пор старые
   камеры не трогать;
3. `deploy_db.sh <версия>` — подпись ключом владельца.

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

Панель → вкладка **«Пульт»** (`/status`). Одна строка на функцию, у
несработавшей — что это значит для водителя. Руками:

```bash
ssh radarmap-vps 'python3 /opt/radarmap/api/status.py; echo $?'   # 0 — нет красного
```

Проверки идут путём телефона (gzip, подпись, sha тайлов), не по диску.
Тревога в Telegram (`notify.py`, токен в `admin.conf`) — только на смену
цвета, поэтому тишина — норма. Пульт «не обновляется» больше 15 минут —
смотреть крон и `/var/log/radarmap-status.log`.

## Долги

- **HTTPS с доменом** — блокер App Store и предусловие панели наружу
  (`HTTPS.md`).
- ~~Пароль root ходит по рукам~~ — 27.09.2026 вход только по ключу. Сам
  пароль ещё сменить (`passwd`): он побывал в переписке.
- Остальное — `docs/plan_vps.md`.
