#!/usr/bin/env python3
"""Пульт состояния RadarMap: жива ли каждая функция — так, как её видит телефон.

ЗАЧЕМ. Осмотр 27.09.2026 нашёл четыре функции, умершие молча: лимиты скорости
месяц отдавались июльские (nginx раздавал старый .gz), горячие точки не
публиковались ни разу (404), сборка дорог четыре недели падала на md5, решения
модератора лежали неопубликованными. Прежний healthcheck.sh был зелёным всё
это время: он спрашивал «файл отвечает 200», а не «телефон получит свежее».
Приложение при сбое сервера fail closed к своему — водитель ошибки не видит,
и ровно поэтому её не видит и владелец.

ПРАВИЛА ПРОВЕРОК.
* Путём телефона: публичный адрес, Accept-Encoding: gzip (URLSession шлёт его
  всегда), подпись Ed25519 тем же ключом, что в AppConfig.otaPublicKeyB64, sha
  тайла против подписанного индекса. «Файл лежит на диске» — не проверка.
* У каждой проверки — порог свежести и фраза «что это значит для водителя».
* Тревога — только на СМЕНУ состояния (как в прежнем стороже): сообщение
  каждые пять минут перестают читать на второй день.

ЗАПУСК (cron, каждые 5 минут, заменяет healthcheck.sh):
    */5 * * * * /usr/bin/python3 /opt/radarmap/api/status.py >> /var/log/radarmap-status.log 2>&1

ВЫХОД.
* /opt/radarmap/api/status.json — полный отчёт; его рисует /status в панели.
* /opt/radarmap/www/status.json — только цвета, для внешнего мониторинга.
  Без подробностей: число неопубликованных решений и возраст бэкапа — не
  публичная информация.
* /opt/radarmap/api/status.db — история для полосок за неделю, 30 дней.

Только stdlib (как всё в server/). Ed25519 в stdlib нет — подпись проверяет
openssl, он на сервере есть (OpenSSL 3).
"""
import base64
import gzip
import hashlib
import json
import os
import random
import socket
import sqlite3
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

BASE = os.environ.get("RADARMAP_BASE", "https://soulmed.uz/radarmap").rstrip("/")
ROOT = os.environ.get("RADARMAP_ROOT", "/opt/radarmap")
OUT = os.environ.get("RADARMAP_STATUS", ROOT + "/api/status.json")
PUBLIC_OUT = os.environ.get("RADARMAP_STATUS_PUBLIC", ROOT + "/www/status.json")
HISTORY_DB = os.environ.get("RADARMAP_STATUS_DB", ROOT + "/api/status.db")
REPORTS_DB = os.environ.get("RADARMAP_REPORTS_DB", ROOT + "/api/reports.db")
ROADS_LOG = os.environ.get("RADARMAP_ROADS_LOG", "/var/log/radarmap-roads.log")

# Тот же ключ, что в AppConfig.otaPublicKeyB64. Если он разъедется с
# приложением, пульт покраснит всё подписанное — и это правильно: телефоны в
# этот момент тоже отвергнут всё подписанное.
PUBLIC_KEY_B64 = "hVUkkufZ7JEFX1RUS9gOYVOpZVYdjywZZW43rUMZYqs="

DAY = 86400
OK, WARN, BAD, IDLE = "ok", "warn", "bad", "idle"
RANK = {OK: 0, IDLE: 0, WARN: 1, BAD: 2}

# Пороги — в одном месте, и у каждого причина.
LIMITS = {
    # Лимиты пересчитываются 2-го числа каждого месяца. 45 дней — один
    # пропущенный прогон, 75 — два: так стояли июльские лимиты в сентябре.
    "limits_warn_days": 45, "limits_bad_days": 75,
    # Дороги собираются каждое воскресенье. 10 дней — одно пропущенное
    # воскресенье, 21 — три: столько стояла карта, пока падал md5.
    "roads_warn_days": 10, "roads_bad_days": 21,
    # Кандидат собран, но не подписан владельцем: публикация раз в неделю.
    "candidate_wait_days": 3,
    # Решения модератора: это ответы на жалобы водителей.
    "overrides_warn_days": 3, "overrides_bad_days": 14,
    # Горячие точки — раз в неделю.
    "hotspots_warn_days": 14, "hotspots_bad_days": 30,
    # Граф OSRM на сервере не пересобирается (не влезает в память) —
    # только напоминание, что его пора собрать на маке.
    "osrm_warn_days": 120,
    "backup_bad_days": 2,
    # Доля телефонов на свежих данных. Телефон тянет базу раз в сутки, лимиты и
    # дороги — раз в неделю, так что сразу после публикации доля честно низкая;
    # тревожно, когда она и через неделю ниже половины.
    "delivery_warn_share": 50,
    "delivery_settle_days": 7,
    # Реестр МВД опрашивается раз в неделю.
    "registry_warn_days": 10,
    # Копия на мак владельца — раз в сутки; мак бывает выключен на выходные.
    "offsite_warn_days": 4,
    "disk_warn_mb": 2000, "disk_bad_mb": 500,
    "cert_warn_days": 21, "cert_bad_days": 7,
    # Выборка тайлов на прогон. 20 × 12 прогонов в час покрывают индекс
    # дорог (~50 тыс.) за пару недель — подменённый тайл всплывёт раньше,
    # чем его заметит водитель, у которого он просто не нарисуется.
    "tile_sample": 20,
    # Основа карты пересобирается раз в неделю на маке владельца.
    "omt_warn_days": 10, "omt_bad_days": 30,
}


# --- Сеть и подпись -------------------------------------------------------

class Fetched:
    def __init__(self, code, body=b"", headers=None, ms=0, error=""):
        self.code, self.body, self.ms, self.error = code, body, ms, error
        self.headers = headers or {}

    @property
    def ok(self):
        return self.code == 200

    def age_days(self, now):
        """Возраст по Last-Modified: так же видит свежесть кэш телефона."""
        stamp = self.headers.get("Last-Modified")
        if not stamp:
            return None
        from email.utils import parsedate_to_datetime
        try:
            return (now - parsedate_to_datetime(stamp).timestamp()) / DAY
        except (TypeError, ValueError):
            return None


def fetch(path, gzip_ok=True, timeout=20):
    """GET как у телефона: с gzip по умолчанию, тело — уже распакованное."""
    headers = {"User-Agent": "RadarMap-status/1",
               "Accept-Encoding": "gzip" if gzip_ok else "identity"}
    request = urllib.request.Request(BASE + "/" + path, headers=headers)
    started = time.time()
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read()
            got = dict(response.headers.items())
            code = response.status
    except urllib.error.HTTPError as error:
        return Fetched(error.code, ms=int((time.time() - started) * 1000))
    except (urllib.error.URLError, socket.timeout, OSError) as error:
        return Fetched(0, ms=int((time.time() - started) * 1000), error=str(error))
    if got.get("Content-Encoding") == "gzip":
        try:
            raw = gzip.decompress(raw)
        except OSError as error:
            return Fetched(0, error="битый gzip: %s" % error)
    return Fetched(code, raw, got, int((time.time() - started) * 1000))


def verify_ed25519(data, sig_b64, key_b64=PUBLIC_KEY_B64):
    """Подпись Ed25519 через openssl. None — проверить нечем (не «неверна»)."""
    try:
        key = base64.b64decode(key_b64)
        sig = base64.b64decode(sig_b64)
    except (ValueError, TypeError):
        return False
    # SubjectPublicKeyInfo для Ed25519 — фиксированный 12-байтный префикс.
    der = bytes.fromhex("302a300506032b6570032100") + key
    pem = (b"-----BEGIN PUBLIC KEY-----\n" + base64.b64encode(der)
           + b"\n-----END PUBLIC KEY-----\n")
    with tempfile.TemporaryDirectory() as tmp:
        paths = {}
        for name, blob in (("key.pem", pem), ("data", data), ("sig", sig)):
            paths[name] = os.path.join(tmp, name)
            with open(paths[name], "wb") as f:
                f.write(blob)
        try:
            result = subprocess.run(
                ["openssl", "pkeyutl", "-verify", "-pubin", "-inkey", paths["key.pem"],
                 "-rawin", "-in", paths["data"], "-sigfile", paths["sig"]],
                capture_output=True, timeout=20)
        except (OSError, subprocess.TimeoutExpired):
            return None
    if result.returncode == 0:
        return True
    # LibreSSL на маке не знает -rawin: это «нечем проверить», не подделка.
    if b"rawin" in result.stderr or b"unknown option" in result.stderr.lower():
        return None
    return False


def open_envelope(body, verify=verify_ed25519):
    """{"payload": b64, "sig": b64} → (payload bytes | None, причина)."""
    try:
        envelope = json.loads(body)
        payload = base64.b64decode(envelope["payload"])
        sig = envelope["sig"]
    except (ValueError, KeyError, TypeError):
        return None, "конверт не читается"
    verdict = verify(payload, sig)
    if verdict is False:
        return None, "подпись не сходится — телефоны отвергнут"
    return payload, ("" if verdict else "подпись не проверена: нет openssl с Ed25519")


def grade_age(age, warn, bad):
    if age is None:
        return WARN
    if bad is not None and age >= bad:
        return BAD
    if warn is not None and age >= warn:
        return WARN
    return OK


def worst(*states):
    return max(states, key=lambda s: RANK[s]) if states else OK


def result(check_id, title, state, summary, meaning, details=(), ms=None):
    return {"id": check_id, "title": title, "state": state, "summary": summary,
            "meaning": meaning, "details": list(details), "ms": ms}


def days(value):
    return "—" if value is None else "%d дн." % int(value)


# --- Проверки -------------------------------------------------------------
#
# Каждая принимает ctx (сеть, подпись, время, пути) — тесты подменяют его,
# не трогая ни сеть, ни диск.

class Context:
    def __init__(self, now=None, fetcher=fetch, verify=verify_ed25519,
                 reports_db=REPORTS_DB, root=ROOT, roads_log=ROADS_LOG):
        self.now = now or time.time()
        self.fetch = fetcher
        self.verify = verify
        self.reports_db = reports_db
        self.root = root
        self.roads_log = roads_log
        # Опубликованные версии, как их считает телефон (api.DATA_VERSION_KEYS).
        # Заполняют проверки по ходу; check_delivery сравнивает с телефонами.
        self.published = {}
        self.published_age = {}   # ключ → дней с публикации

    def db(self):
        if not os.path.exists(self.reports_db):
            return None
        return sqlite3.connect("file:%s?mode=ro" % self.reports_db, uri=True, timeout=5)


def same_both_ways(ctx, path, zipped):
    """gzip и identity отдают одно и то же. Ровно этот класс держал июльские
    лимиты до телефонов: .json обновлялся, а nginx отдавал старый .gz."""
    plain = ctx.fetch(path, gzip_ok=False)
    return plain.ok and hashlib.sha256(plain.body).digest() == \
        hashlib.sha256(zipped.body).digest()


def check_api(ctx):
    got = ctx.fetch("api/health")
    alive = got.ok and b'"ok"' in got.body
    markers = None
    if alive:
        mobile = ctx.fetch("api/mobile")
        try:
            data = json.loads(mobile.body)
            markers = len(data.get("reports", []))
        except (ValueError, AttributeError):
            markers = None
    return result(
        "api", "API водителей", OK if alive else BAD,
        ("отвечает за %d мс" % got.ms if alive else "не отвечает: %s" % (got.error or got.code))
        + ("" if markers is None else " · меток на карте: %d" % markers),
        "Не принимаются отметки треног, голоса, жалобы на камеры и отзывы; "
        "метрики падений теряются. Предупреждения о камерах работают — база в телефоне.",
        ms=got.ms)


def check_crowd(ctx):
    conn = ctx.db()
    if conn is None:
        return result("crowd", "Народные данные", WARN, "reports.db не найдена",
                      "Не видно, пользуются ли отметками и жалобами.")
    with conn:
        month = ctx.now - 30 * DAY
        reports = conn.execute("SELECT COUNT(*) FROM reports WHERE created > ?", (month,)).fetchone()[0]
        complaints = conn.execute("SELECT COUNT(*) FROM camera_reports WHERE received > ?", (month,)).fetchone()[0]
        feedback = conn.execute("SELECT COUNT(*) FROM feedback WHERE received > ?", (month,)).fetchone()[0]
        devices = conn.execute("SELECT COUNT(DISTINCT device) FROM metrics WHERE received > ?", (month,)).fetchone()[0]
    conn.close()
    summary = "за 30 дней: отметок %d · жалоб %d · отзывов %d · устройств с метриками %d" % (
        reports, complaints, feedback, devices)
    # Ноль — не поломка, а отсутствие проверки: серым, не красным.
    state = IDLE if reports + complaints + feedback == 0 else OK
    return result("crowd", "Народные данные", state, summary,
                  "Серый — данных нет: функции живы, но проверить их на живых водителях нечем.")


def check_osrm(ctx):
    got = ctx.fetch("osrm/route/v1/driving/69.24,41.31;69.28,41.33?overview=false")
    routes = got.ok and b'"code":"Ok"' in got.body
    graph = os.path.join(ctx.root, "osrm", "uzbekistan-latest.osrm.hsgr")
    age = (ctx.now - os.path.getmtime(graph)) / DAY if os.path.exists(graph) else None
    state = BAD if not routes else (WARN if age is not None and age > LIMITS["osrm_warn_days"] else OK)
    return result(
        "osrm", "Маршруты", state,
        ("строит за %d мс" % got.ms if routes else "не строит: %s" % (got.error or got.code))
        + " · граф от %s" % days(age),
        "Маршрут внутри Узбекистана не строится (Apple Maps там не ведёт). "
        "Старый граф — новые дороги и развязки маршрут не знает.",
        ms=got.ms)


def check_cameras(ctx):
    meaning = ("Новая база камер не доедет до телефонов: водители едут по прежней. "
               "Подпись не сошлась — телефоны отвергнут обновление целиком.")
    manifest_got = ctx.fetch("version.json")
    try:
        manifest = json.loads(manifest_got.body)
    except ValueError:
        return result("cameras", "База камер", BAD, "version.json не читается", meaning)
    db = ctx.fetch("cameras.json")
    if not db.ok:
        return result("cameras", "База камер", BAD, "cameras.json: %s" % (db.error or db.code), meaning)
    problems = []
    if hashlib.sha256(db.body).hexdigest() != manifest.get("sha256"):
        problems.append("sha базы не совпадает с version.json")
    verdict = ctx.verify(db.body, manifest.get("sig", ""))
    if verdict is False:
        problems.append("подпись не сходится")
    if not same_both_ways(ctx, "cameras.json", db):
        problems.append("gzip и обычная отдача различаются")
    ctx.published["cameras"] = manifest.get("version")
    try:
        ctx.published_age["cameras"] = (ctx.now - time.mktime(
            time.strptime(manifest.get("updatedAt", ""), "%Y-%m-%d"))) / DAY
    except ValueError:
        pass
    summary = "v%s · %s точек · от %s" % (manifest.get("version"), manifest.get("count"),
                                           manifest.get("updatedAt", "?"))
    if problems:
        summary += " · " + "; ".join(problems)
    details = []
    try:
        details.append(camera_quality(json.loads(db.body)))
    except (ValueError, TypeError):
        details.append("база не разбирается как список камер")
    complaints = pending_wrong_location(ctx)
    state = BAD if problems else OK
    if complaints:
        details.append("жалоб «не там стоит» без ответа: %d → «Положение» в панели" % complaints)
        state = worst(state, WARN)
    return result("cameras", "База камер", state, summary, meaning, details)


# Те же классы, что RoadClass(.pedestrian) в RadarMap/Models/RoadShape.swift:
# снап, приземливший камеру сюда, ничего не знает о проезжей части.
PEDESTRIAN = {"footway", "path", "cycleway", "steps", "pedestrian", "platform", "bus_stop"}


def camera_quality(cameras):
    """Покрытие дорожным профилем — то, на чём работает конвейер предупреждений.

    Падение «с профилем» между выпусками = снап сломался; рост «на тротуаре» =
    камеры, которые приложение не может ни проверить по дороге, ни заглушить.
    Стороны доказаны — тот же расчёт, что Camera.allowsDirectionGate.
    """
    total = len(cameras) or 1
    road = sum(1 for c in cameras if c.get("road"))
    proven = sum(1 for c in cameras
                 if c.get("dir") is not None and c.get("cls") not in PEDESTRIAN
                 and c.get("cls") is not None and (c.get("twin") or c.get("split") is False))
    review = sum(1 for c in cameras if c.get("needsReview"))
    foot = sum(1 for c in cameras if c.get("cls") in PEDESTRIAN)
    return ("профиль дороги %d%% · стороны доказаны %d · координата приблизительная %d · "
            "на тротуаре/остановке %d" % (100 * road // total, proven, review, foot))


def pending_wrong_location(ctx):
    conn = ctx.db()
    if conn is None:
        return 0
    try:
        with conn:
            return conn.execute("SELECT COUNT(DISTINCT camera_id) FROM camera_reports "
                                "WHERE reason = 'wrong_location' AND resolved = 0").fetchone()[0]
    except sqlite3.Error:
        return 0
    finally:
        conn.close()


def check_registry(ctx):
    """Реестр МВД: опрашивается ли и не ждёт ли нас изменение.

    update_cameras.py по крону только ЗАМЕЧАЕТ, что открытый реестр
    изменился (пишет строку в update.log). Сливает новые адреса в базу
    владелец — merge_cameras.py → snap → deploy_db.sh, — потому что слияние
    сохраняет id и геометрию, а сборка с нуля их переклеивает.
    """
    meaning = ("МВД поставило новые камеры, а в нашей базе их нет: на этих местах "
               "приложение молчит.")
    path = os.path.join(ctx.root, "api", "update.log")
    try:
        with open(path, errors="replace") as f:
            lines = [line.strip() for line in f if line.strip()]
    except OSError:
        return result("registry", "Реестр МВД", WARN, "update.log нет — опрос не запускался", meaning)
    polls = [line for line in lines if any(w in line for w in
                                           ("UNCHANGED", "CANDIDATE UPDATED", "FETCH FAILED", "REFUSING"))]
    if not polls:
        return result("registry", "Реестр МВД", WARN, "опросов в логе нет", meaning)
    last = polls[-1]
    try:
        stamp = time.mktime(time.strptime(last[:19], "%Y-%m-%d %H:%M:%S"))
        age = (ctx.now - stamp) / DAY
    except ValueError:
        age = None
    state = grade_age(age, LIMITS["registry_warn_days"], None)
    if "FETCH FAILED" in last or "REFUSING" in last:
        state = worst(state, WARN)
    changed = [line for line in polls if "CANDIDATE UPDATED" in line]
    details = []
    if changed:
        details.append("последнее изменение реестра: %s" % changed[-1][:80])
    summary = "последний опрос %s назад: %s" % (days(age), last[20:90])
    return result("registry", "Реестр МВД", state, summary, meaning, details)


def check_config(ctx):
    got = ctx.fetch("config.json")
    payload, why = open_envelope(got.body, ctx.verify) if got.ok else (None, "нет файла")
    if payload is None:
        return result("config", "Пульт приложения", BAD, why,
                      "Телефоны живут на своих значениях: выключить маршруты или отметки "
                      "с сервера не выйдет.")
    try:
        content = json.loads(payload)
    except ValueError:
        content = None
    summary = "пустой — всё по умолчанию" if content == {} else "активен: %s" % ", ".join(sorted(content or {}))
    return result("config", "Пульт приложения", OK, summary + (" · " + why if why else ""),
                  "Удалённые выключатели маршрутов, отметок и метрик.")


def check_overrides(ctx):
    meaning = ("Решения по жалобам водителей приняты, но телефоны о них не знают: "
               "скрытая камера продолжает предупреждать, сдвинутая стоит на старом месте.")
    got = ctx.fetch("overrides.json")
    payload, why = open_envelope(got.body, ctx.verify) if got.ok else (None, "нет файла")
    if payload is None:
        return result("overrides", "Решения модератора", BAD, why, meaning)
    try:
        published = len(json.loads(payload).get("items", []))
    except (ValueError, AttributeError):
        published = 0
    pending, oldest = 0, None
    conn = ctx.db()
    if conn is not None:
        with conn:
            row = conn.execute("SELECT COUNT(*), MIN(decided_at) FROM overrides "
                               "WHERE published_at IS NULL").fetchone()
        conn.close()
        pending, oldest = row[0], row[1]
    age = (ctx.now - oldest) / DAY if oldest else None
    state = OK if not pending else grade_age(age, LIMITS["overrides_warn_days"],
                                             LIMITS["overrides_bad_days"])
    summary = "опубликовано %d" % published
    if pending:
        summary += " · ждут подписи %d, старшее %s → publish_overrides.sh" % (pending, days(age))
    return result("overrides", "Решения модератора", state, summary, meaning)


def check_hotspots(ctx):
    meaning = "Нет подсказок «здесь часто ставят треногу»: приложение молча живёт без них."
    got = ctx.fetch("hotspots.json")
    if got.code == 404:
        return result("hotspots", "Горячие точки треног", BAD,
                      "не опубликованы (404) → publish_hotspots.sh", meaning)
    payload, why = open_envelope(got.body, ctx.verify) if got.ok else (None, str(got.error or got.code))
    if payload is None:
        return result("hotspots", "Горячие точки треног", BAD, why, meaning)
    age = got.age_days(ctx.now)
    try:
        zones = len(json.loads(payload).get("spots", []))
    except (ValueError, AttributeError):
        zones = 0
    state = grade_age(age, LIMITS["hotspots_warn_days"], LIMITS["hotspots_bad_days"])
    return result("hotspots", "Горячие точки треног", state,
                  "зон: %d · опубликованы %s назад" % (zones, days(age)), meaning)


def check_limits(ctx):
    meaning = ("Лимиты скорости устарели: на переставленных знаках предупреждение о "
               "превышении идёт по старому лимиту.")
    problems, versions = [], []
    for path in ("speed_limits.json", "speed_limits_v2.json"):
        got = ctx.fetch(path)
        if not got.ok:
            problems.append("%s: %s" % (path, got.error or got.code))
            continue
        if not same_both_ways(ctx, path, got):
            problems.append("%s: gzip и обычная отдача различаются (старый .gz)" % path)
        try:
            versions.append(json.loads(got.body)["version"])
        except (ValueError, KeyError):
            problems.append("%s не читается" % path)
    age = (ctx.now - min(versions)) / DAY if versions else None
    if versions:
        ctx.published["limits"] = int(max(versions))
        ctx.published_age["limits"] = (ctx.now - max(versions)) / DAY
    state = BAD if problems else grade_age(age, LIMITS["limits_warn_days"], LIMITS["limits_bad_days"])
    summary = "v1 и v2 · собраны %s назад" % days(age)
    if problems:
        summary += " · " + "; ".join(problems)
    return result("limits", "Лимиты скорости", state, summary, meaning)


def index_fingerprint(payload):
    """Номер публикации индекса: первые 7 hex sha256 подписанного payload.

    Тот же расчёт делает приложение для dataVersions — у индексов дорог и MVT
    нет своего номера версии, кроме номера формата.
    """
    return int(hashlib.sha256(payload).hexdigest()[:7], 16)


def last_roads_run(log_path):
    """Итог последнего прогона update_roads.sh: (время, упал ли, строка причины)."""
    try:
        with open(log_path, errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return None, None, ""
    starts = [i for i, line in enumerate(lines) if line.startswith("=== ") and "обновление дорог" in line]
    if not starts:
        return None, None, ""
    run = lines[starts[-1]:]
    stamp = run[0].split()[1] if len(run[0].split()) > 1 else ""
    failed = [line for line in run if "FAILED" in line or "СТОП" in line
              or "Traceback" in line or "ОТМЕНЕН" in line]
    return stamp, bool(failed), (failed[0] if failed else "")


def sample_tiles(ctx, tiles, url_of, count):
    """Выборка тайлов против подписанного индекса — так проверяет телефон."""
    keys = random.sample(sorted(tiles), min(count, len(tiles)))
    bad = []
    for key in keys:
        got = ctx.fetch(url_of(key))
        if not got.ok or hashlib.sha256(got.body).hexdigest() != tiles[key]["sha256"]:
            bad.append(key)
    return len(keys), bad


# Метрики road_metrics.py опубликованной сборки, короткими словами.
METRIC_TITLES = {"houses_under_asphalt": "дома под асфальтом %",
                 "islands_under_asphalt": "островки под асфальтом %",
                 "arrows_after_stop": "стрелки за стоп-линией ‰",
                 "dashes_in_junction": "пунктир в узле м/км",
                 "dashes_on_zebra": "пунктир на зебре м/км",
                 "medians_on_asphalt": "разделительные на узле %",
                 "dashes_through_medians": "пунктир сквозь разделительную м/км"}


def check_roads(ctx):
    meaning = ("Набросок дороги на экране поездки рисуется по старой сети: новые "
               "дороги и правки конструктора до водителей не доезжают.")
    got = ctx.fetch("roads_index_v2.json")
    payload, why = open_envelope(got.body, ctx.verify) if got.ok else (None, str(got.error or got.code))
    if payload is None:
        return result("roads", "Дороги (набросок)", BAD, why, meaning)
    tiles = json.loads(payload).get("tiles", {})
    ctx.published["roads"] = index_fingerprint(payload)
    age = got.age_days(ctx.now)
    ctx.published_age["roads"] = age
    state = grade_age(age, LIMITS["roads_warn_days"], LIMITS["roads_bad_days"])
    details = []
    checked, broken = sample_tiles(ctx, tiles, lambda k: "roads/road2_%s.json" % k,
                                   LIMITS["tile_sample"])
    if broken:
        state = BAD
        details.append("тайлы не сходятся с индексом: %s" % ", ".join(broken[:5]))
    stamp, failed, reason = last_roads_run(ctx.roads_log)
    if failed:
        state = worst(state, WARN)
        details.append("последняя сборка %s упала: %s" % (stamp, reason))
    candidate = os.path.join(ctx.root, "work", "roads_tiles_candidate", "index_payload_v2.json")
    if os.path.exists(candidate) and age is not None:
        built = (ctx.now - os.path.getmtime(candidate)) / DAY
        if built < age and built >= LIMITS["candidate_wait_days"]:
            state = worst(state, WARN)
            details.append("кандидат собран %s назад и не опубликован → publish_roads.sh"
                           % days(built))
    metrics_path = os.path.join(ctx.root, "work", "roads_metrics_live.json")
    if os.path.exists(metrics_path):
        try:
            with open(metrics_path, encoding="utf-8") as handle:
                metrics = json.load(handle)
            details.append("качество (Ташкент): " + ", ".join(
                "%s %s" % (METRIC_TITLES[key], metrics[key])
                for key in METRIC_TITLES if metrics.get(key) is not None))
        except (OSError, ValueError) as error:
            details.append("метрики не читаются: %s" % error)
    summary = "тайлов %d · опубликованы %s назад · выборка %d/%d" % (
        len(tiles), days(age), checked - len(broken), checked)
    return result("roads", "Дороги (набросок)", state, summary, meaning, details)


def check_mvt(ctx):
    meaning = ("Своя карта на главном экране: без неё приложение рисует свой набросок; "
               "подменённый тайл телефон отбросит — на карте будет дыра.")
    got = ctx.fetch("mvt_index.json")
    payload, why = open_envelope(got.body, ctx.verify) if got.ok else (None, str(got.error or got.code))
    if payload is None:
        return result("mvt", "Своя карта (MVT)", BAD, why, meaning)
    tiles = json.loads(payload).get("tiles", {})
    ctx.published["mvt"] = index_fingerprint(payload)
    age = got.age_days(ctx.now)
    ctx.published_age["mvt"] = age
    state = grade_age(age, LIMITS["roads_warn_days"], LIMITS["roads_bad_days"])
    checked, broken = sample_tiles(ctx, tiles, lambda k: "mvt/%s.mvt" % k, LIMITS["tile_sample"])
    details = []
    if broken:
        state = BAD
        details.append("тайлы не сходятся с индексом: %s" % ", ".join(broken[:5]))
    summary = "тайлов %d · индекс %.1f МБ · опубликована %s назад · выборка %d/%d" % (
        len(tiles), len(got.body) / 1e6, days(age), checked - len(broken), checked)
    return result("mvt", "Своя карта (MVT)", state, summary, meaning, details)


def check_omt(ctx):
    """Основа карты (OpenMapTiles, server/omt/): подпись индекса, выборка тайлов, свежесть."""
    meaning = ("Светлая карта «как у Яндекса» без подложки: телефон отбросит тайл, "
               "чей sha не сошёлся с подписанным индексом, — на карте будет дыра.")
    got = ctx.fetch("omt_index.json")
    if got.code == 404:
        return result("omt", "Основа карты (OMT)", IDLE, "не опубликована", meaning)
    payload, why = open_envelope(got.body, ctx.verify) if got.ok else (None, str(got.error or got.code))
    if payload is None:
        return result("omt", "Основа карты (OMT)", BAD, why, meaning)
    tiles = json.loads(payload).get("tiles", {})
    age = got.age_days(ctx.now)
    state = grade_age(age, LIMITS["omt_warn_days"], LIMITS["omt_bad_days"])
    checked, broken = sample_tiles(ctx, tiles, lambda k: "omt/%s.pbf" % k, LIMITS["tile_sample"])
    details = []
    if broken:
        state = BAD
        details.append("тайлы не сходятся с индексом: %s" % ", ".join(broken[:5]))
    style = ctx.fetch("map_style.json")
    if not style.ok:
        state = worst(state, WARN)
        details.append("map_style.json: %s" % (style.error or style.code))
    summary = "тайлов %d · опубликована %s назад · выборка %d/%d" % (
        len(tiles), days(age), checked - len(broken), checked)
    return result("omt", "Основа карты (OMT)", state, summary, meaning, details)


def check_backup(ctx):
    folder = os.path.join(ctx.root, "backups")
    try:
        names = [n for n in os.listdir(folder) if n.startswith("reports-") and n.endswith(".db.gz")]
    except OSError:
        names = []
    newest = max((os.path.getmtime(os.path.join(folder, n)) for n in names), default=None)
    age = (ctx.now - newest) / DAY if newest else None
    state = BAD if age is None or age >= LIMITS["backup_bad_days"] else OK
    # Метку ставит pull_backup.sh на маке владельца после удачной копии.
    marker = os.path.join(folder, ".offsite")
    offsite = (ctx.now - os.path.getmtime(marker)) / DAY if os.path.exists(marker) else None
    if offsite is None or offsite >= LIMITS["offsite_warn_days"]:
        state = worst(state, WARN)
    where = "нет" if offsite is None else "%d ч назад" % int(offsite * 24)
    return result("backup", "Бэкап данных", state,
                  "последний %s назад · копий %d · копия вне VPS: %s" % (days(age), len(names), where),
                  "Умрёт диск — пропадут отметки, жалобы и решения модератора; "
                  "копия вне VPS — единственное, что переживёт сам сервер.")


def check_disk(ctx):
    stat = os.statvfs(ctx.root)
    free_mb = stat.f_bavail * stat.f_frsize // (1024 * 1024)
    state = BAD if free_mb < LIMITS["disk_bad_mb"] else (WARN if free_mb < LIMITS["disk_warn_mb"] else OK)
    return result("disk", "Диск", state, "свободно %d МБ" % free_mb,
                  "sqlite не пишет на полный диск: API начнёт терять отметки и жалобы.")


def cert_days_left(host, port=443):
    context = ssl.create_default_context()
    with socket.create_connection((host, port), timeout=10) as sock:
        with context.wrap_socket(sock, server_hostname=host) as tls:
            not_after = tls.getpeercert()["notAfter"]
    return (ssl.cert_time_to_seconds(not_after) - time.time()) / DAY


def check_cert(ctx, days_left=cert_days_left):
    host = BASE.split("//", 1)[-1].split("/", 1)[0]
    try:
        left = days_left(host)
    except (OSError, ssl.SSLError, KeyError) as error:
        return result("cert", "HTTPS-сертификат", BAD, "не читается: %s" % error,
                      "Истёк сертификат — телефоны не достучатся ни до чего.")
    state = BAD if left < LIMITS["cert_bad_days"] else (WARN if left < LIMITS["cert_warn_days"] else OK)
    return result("cert", "HTTPS-сертификат", state, "%s · осталось %d дн." % (host, left),
                  "Истёк сертификат — телефоны не достучатся ни до чего.")


DELIVERY_NAMES = {"cameras": "база камер", "limits": "лимиты", "roads": "дороги",
                  "mvt": "своя карта"}


def check_delivery(ctx):
    """Дошло ли опубликованное до телефонов — по суточным сводкам за 7 дней.

    Проверки выше отвечают «что сервер ОТДАЁТ»; эта — «что телефоны ИМЕЮТ».
    Разница между ними и есть те поломки, которые до 27.09.2026 никто не видел.
    """
    meaning = ("Опубликованное не доходит до телефонов: водители ездят на старых "
               "данных, хотя сервер отдаёт новые.")
    conn = ctx.db()
    if conn is None:
        return result("delivery", "Доставка до телефонов", IDLE, "нет reports.db", meaning)
    latest = {}
    try:
        with conn:
            rows = conn.execute("SELECT device, day, quality FROM usage_stats "
                                "WHERE received > ? ORDER BY day", (ctx.now - 7 * DAY,)).fetchall()
    except sqlite3.Error:
        rows = []
    finally:
        conn.close()
    for device, _day, quality in rows:
        try:
            versions = (json.loads(quality or "{}") or {}).get("dataVersions")
        except ValueError:
            versions = None
        if versions:
            latest[device] = versions
    if not latest:
        return result("delivery", "Доставка до телефонов", IDLE,
                      "телефоны ещё не присылают версии данных (нужна сборка с dataVersions)",
                      meaning)
    parts, state = [], OK
    for key, name in DELIVERY_NAMES.items():
        current = ctx.published.get(key)
        having = [v[key] for v in latest.values() if key in v]
        if current is None or not having:
            continue
        # Телефон может быть и НОВЕЕ (лимиты — по версии файла, база — по номеру):
        # отставанием считается только «меньше опубликованного» или «другой индекс».
        if key in ("roads", "mvt"):
            fresh = sum(1 for v in having if v == current)
        else:
            fresh = sum(1 for v in having if v >= current)
        share = 100 * fresh // len(having)
        parts.append("%s %d%%" % (name, share))
        settled = (ctx.published_age.get(key) or 0) >= LIMITS["delivery_settle_days"]
        if settled and share < LIMITS["delivery_warn_share"]:
            state = worst(state, WARN)
    summary = "устройств за неделю: %d · на свежем: %s" % (len(latest), ", ".join(parts) or "—")
    return result("delivery", "Доставка до телефонов", state, summary, meaning)


CHECKS = (check_api, check_cameras, check_registry, check_limits, check_roads, check_mvt, check_omt, check_overrides,
          check_hotspots, check_config, check_osrm, check_crowd, check_backup, check_disk,
          check_cert, check_delivery)


def run_all(ctx):
    results = []
    for check in CHECKS:
        try:
            results.append(check(ctx))
        except Exception as error:  # noqa: BLE001 — упавшая проверка тоже сигнал
            name = check.__name__.replace("check_", "")
            results.append(result(name, name, BAD, "проверка упала: %s: %s"
                                  % (type(error).__name__, error), "Пульт не знает состояния."))
    return {"at": int(ctx.now), "overall": worst(*[r["state"] for r in results]),
            "checks": results}


# --- История и тревоги ----------------------------------------------------

def open_history(path=HISTORY_DB):
    conn = sqlite3.connect(path, timeout=10)
    conn.execute("CREATE TABLE IF NOT EXISTS history("
                 "at INTEGER NOT NULL, check_id TEXT NOT NULL, state TEXT NOT NULL)")
    conn.execute("CREATE INDEX IF NOT EXISTS history_at ON history(at)")
    return conn


def previous_states(conn):
    at = conn.execute("SELECT MAX(at) FROM history").fetchone()[0]
    if at is None:
        return {}
    return dict(conn.execute("SELECT check_id, state FROM history WHERE at = ?", (at,)))


def record(conn, report):
    with conn:
        conn.executemany("INSERT INTO history(at, check_id, state) VALUES (?, ?, ?)",
                         [(report["at"], r["id"], r["state"]) for r in report["checks"]])
        conn.execute("DELETE FROM history WHERE at < ?", (report["at"] - 30 * DAY,))


def changes(before, report):
    """Сообщение о сменах цвета; None — менять нечего.

    idle и ok — одно и то же для тревоги: «пользователей нет» не будит владельца.
    """
    lines = []
    for r in report["checks"]:
        was = before.get(r["id"])
        now = r["state"]
        if was is None or RANK.get(was, 0) == RANK[now]:
            continue
        icon = {BAD: "🔴", WARN: "🟡"}.get(now, "🟢")
        lines.append("%s %s: %s" % (icon, r["title"], r["summary"]))
    return "RadarMap\n" + "\n".join(lines) if lines else None


def write_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, ensure_ascii=False, separators=(",", ":"))
    os.replace(tmp, path)


def main():
    report = run_all(Context())
    write_json(OUT, report)
    write_json(PUBLIC_OUT, {"at": report["at"], "overall": report["overall"],
                            "checks": {r["id"]: r["state"] for r in report["checks"]}})
    conn = open_history()
    message = changes(previous_states(conn), report)
    record(conn, report)
    conn.close()
    if message:
        print(time.strftime("%Y-%m-%d %H:%M ") + message.replace("\n", " | "))
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        try:
            import notify
            notify.send(message)
        except Exception as error:  # noqa: BLE001 — тревога не должна ронять пульт
            print("telegram: %s" % error)
    return 0 if report["overall"] != BAD else 1


if __name__ == "__main__":
    sys.exit(main())
