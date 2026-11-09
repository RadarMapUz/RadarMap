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
import datetime
import gzip
import hashlib
import json
import os
import random
import re
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
# Большие файлы — условным GET: 304 вместо десятков МБ каждые 5 минут. Раз в
# CACHE_FULL_EVERY тело качается целиком: ETag nginx — лишь mtime и размер.
CACHE_DIR = os.environ.get("RADARMAP_STATUS_CACHE", ROOT + "/api/status_cache")
CACHE_MIN_BYTES = 256 * 1024
CACHE_FULL_EVERY = 6 * 3600
REPORTS_DB = os.environ.get("RADARMAP_REPORTS_DB", ROOT + "/api/reports.db")
ROADS_LOG = os.environ.get("RADARMAP_ROADS_LOG", "/var/log/radarmap-roads.log")
NGINX_LOG = os.environ.get("RADARMAP_NGINX_LOG", "/var/log/nginx/access.log")

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
    # Запас мощности: канал замерен 09.11.2026, после смены тарифа — новое значение.
    "channel_mbit": int(os.environ.get("RADARMAP_CHANNEL_MBIT", "30")),
    "channel_warn_pct": 60, "channel_bad_pct": 85,
    "cpu_warn_pct": 70, "cpu_bad_pct": 90,
    "mem_warn_mb": 500, "mem_bad_mb": 200,
    "route_warn_ms": 500, "route_min_samples": 12,
    "http429_warn_pct": 1,
    "queue_warn_share": 0.5,
    "capacity_log_tail": 8 * 1024 * 1024,
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


def cache_base(path, gzip_ok):
    """gzip и identity — разные записи: их расхождение ищет same_both_ways."""
    name = hashlib.sha256(("%s|%d" % (path, gzip_ok)).encode()).hexdigest()
    return os.path.join(CACHE_DIR, name)


def read_cache(path, gzip_ok, now):
    """(тело, заголовки) или None: записи нет, она битая или пора качать целиком."""
    base = cache_base(path, gzip_ok)
    try:
        with open(base + ".meta", encoding="utf-8") as f:
            meta = json.load(f)
        if now - meta["full_at"] >= CACHE_FULL_EVERY or not meta["headers"].get("ETag"):
            return None
        with open(base, "rb") as f:
            return f.read(), meta["headers"]
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return None


def write_cache(path, gzip_ok, body, headers, now):
    if len(body) < CACHE_MIN_BYTES or not headers.get("ETag"):
        return
    base = cache_base(path, gzip_ok)
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        with open(base + ".tmp", "wb") as f:
            f.write(body)
        os.replace(base + ".tmp", base)
        with open(base + ".meta.tmp", "w", encoding="utf-8") as f:
            json.dump({"full_at": now, "headers": headers}, f)
        os.replace(base + ".meta.tmp", base + ".meta")
    except OSError as error:
        print("кэш пульта не записан: %s" % error, file=sys.stderr)


def fetch(path, gzip_ok=True, timeout=20):
    """GET как у телефона: с gzip по умолчанию, тело — уже распакованное."""
    headers = {"User-Agent": "RadarMap-status/1",
               "Accept-Encoding": "gzip" if gzip_ok else "identity"}
    started = time.time()
    hit = read_cache(path, gzip_ok, started)
    if hit:
        headers["If-None-Match"] = hit[1]["ETag"]
    request = urllib.request.Request(BASE + "/" + path, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read()
            got = dict(response.headers.items())
            code = response.status
    except urllib.error.HTTPError as error:
        ms = int((time.time() - started) * 1000)
        if error.code == 304 and hit:
            return Fetched(200, hit[0], {**hit[1], **dict(error.headers.items())}, ms)
        return Fetched(error.code, ms=ms)
    except (urllib.error.URLError, socket.timeout, OSError) as error:
        return Fetched(0, ms=int((time.time() - started) * 1000), error=str(error))
    if got.get("Content-Encoding") == "gzip":
        try:
            raw = gzip.decompress(raw)
        except OSError as error:
            return Fetched(0, error="битый gzip: %s" % error)
    if code == 200:
        write_cache(path, gzip_ok, raw, got, started)
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
                 reports_db=REPORTS_DB, root=ROOT, roads_log=ROADS_LOG,
                 history_db=None, proc="/proc", nginx_log=NGINX_LOG):
        self.now = now or time.time()
        self.fetch = fetcher
        self.verify = verify
        self.reports_db = reports_db
        self.root = root
        self.roads_log = roads_log
        self.history_db = history_db
        self.proc = proc
        self.nginx_log = nginx_log
        self.route_ms = None
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
    if routes:
        ctx.route_ms = got.ms
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


def signed_limits(ctx, cron_v2):
    """Подписанный набор лимитов (speed_limits_index.json) — путём телефона.

    (состояние, фраза). Индекс → подпись → файл формата 2 по имени из индекса
    → sha и размер против индекса: ровно то, что делает LimitsTrust.

    404 — WARN, а не BAD: пока владелец не подписал первый индекс, приложение
    живёт на старом неподписанном пути (храповик в LimitsTrust), и это
    незаконченный шаг, а не авария. Отставание от крона — тоже WARN: крон
    обновляет файлы для старых сборок раз в месяц, а сборки с подписью видят
    новый месяц только после publish_limits.sh. Без этой строки подписанный
    набор старел бы молча — приложение fail closed держит прошлый.
    """
    got = ctx.fetch("speed_limits_index.json")
    if got.code == 404:
        return WARN, "подписанного индекса нет → publish_limits.sh"
    if not got.ok:
        return BAD, "индекс: %s" % (got.error or got.code)
    payload, why = open_envelope(got.body, ctx.verify)
    if payload is None:
        return BAD, "индекс: " + why
    try:
        entry = {f["format"]: f for f in json.loads(payload)["files"]}[2]
        name, sha, size = entry["name"], entry["sha256"], entry["bytes"]
    except (ValueError, KeyError, TypeError):
        return BAD, "индекс не по контракту (нет файла формата 2)"
    data = ctx.fetch(name)
    if not data.ok:
        return BAD, "%s: %s — телефоны с подписью без обновления" % (name, data.error or data.code)
    if hashlib.sha256(data.body).hexdigest() != sha or len(data.body) != size:
        return BAD, "%s не сходится с подписью — телефоны отвергнут" % name
    if cron_v2 is not None and hashlib.sha256(cron_v2).hexdigest() != sha:
        return WARN, "новая сборка крона ждёт подписи → publish_limits.sh"
    return OK, "подписаны" + (" (%s)" % why if why else "")


def check_limits(ctx):
    meaning = ("Лимиты скорости устарели: на переставленных знаках предупреждение о "
               "превышении идёт по старому лимиту.")
    problems, versions = [], []
    cron_v2 = None
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
        if path == "speed_limits_v2.json":
            cron_v2 = got.body
    age = (ctx.now - min(versions)) / DAY if versions else None
    if versions:
        ctx.published["limits"] = int(max(versions))
        ctx.published_age["limits"] = (ctx.now - max(versions)) / DAY
    state = BAD if problems else grade_age(age, LIMITS["limits_warn_days"], LIMITS["limits_bad_days"])
    signed_state, signed_note = signed_limits(ctx, cron_v2)
    state = worst(state, signed_state)
    summary = "v1 и v2 · собраны %s назад · подпись: %s" % (days(age), signed_note)
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
                 "dashes_through_medians": "пунктир сквозь разделительную м/км",
                 "zebra_overhang": "зебры за кромкой %",
                 "zebra_duplicates": "зебры-дубли %",
                 "junction_bloat": "раздутые узлы %",
                 "junction_spikes": "иглы у фигур узла %",
                 "island_slivers": "островки-клинья %"}


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


# --- Пробки (33F, docs/spec_traffic_33.md) --------------------------------------
#
# Константы порогов — из traffic_config.py (лежит рядом на VPS после
# deploy_traffic.sh); нет файла — те же числа здесь, пульт не должен падать
# из-за порядка выкладки.
try:
    import traffic_config as _tc
except ImportError:  # pragma: no cover — старая выкладка без этапа 33
    _tc = None
TRAFFIC_STALE = getattr(_tc, "SPEEDS_STALE_SECONDS", 900)
TRAFFIC_MAP_MIN = getattr(_tc, "MAP_MIN_PIECES", 2)
TRAFFIC_ROUTE_MIN = getattr(_tc, "ROUTE_MIN_PIECES", 2)
TRAFFIC_SLOT_DAYS = getattr(_tc, "SLOT_MIN_DAYS", 3)
TRAFFIC_SLOT_PIECES = getattr(_tc, "SLOT_MIN_PIECES", 5)
TRAFFIC_KEEP_DAYS = getattr(_tc, "PROFILE_KEEP_DAYS", 56)
TRAFFIC_NOW_STALE = 10 * 60          # телефон считает now.json старше — «нет данных»
STAND_PROBE = "http://127.0.0.1:8094/route/v1/driving/69.19617,41.28151;69.28866,41.36612?overview=false"


def probe_stand(url=STAND_PROBE, timeout=10):
    """(отвечает ли стенд MLD, мс)."""
    started = time.time()
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            ok = b'"code":"Ok"' in resp.read()
    except (OSError, ValueError):
        ok = False
    return ok, int((time.time() - started) * 1000)


def traffic_counts(path, now):
    """Покрытие из traffic.db (только чтение, только счётчики)."""
    conn = sqlite3.connect("file:%s?mode=ro" % path, uri=True, timeout=5)
    out = {}
    try:
        out["pieces"] = conn.execute("SELECT COUNT(DISTINCT piece) FROM traffic_samples WHERE ts >= ?",
                                     (now - 3600,)).fetchone()[0]
        for key, minimum in (("map", TRAFFIC_MAP_MIN), ("route", TRAFFIC_ROUTE_MIN)):
            out[key] = conn.execute(
                "SELECT COUNT(*) FROM (SELECT 1 FROM traffic_samples WHERE ts >= ? AND passed = 1 "
                "GROUP BY u, v HAVING COUNT(DISTINCT piece) >= ?)", (now - 900, minimum)).fetchone()[0]
        local = time.gmtime(now + 5 * 3600)
        slot = local.tm_wday * 24 + local.tm_hour
        day = int((now + 5 * 3600) // DAY)
        try:
            out["typical"] = conn.execute(
                "SELECT COUNT(*) FROM (SELECT 1 FROM traffic_slot_obs WHERE slot = ? AND day >= ? "
                "GROUP BY u, v HAVING COUNT(DISTINCT day) >= ? AND COUNT(*) >= ?)",
                (slot, day - TRAFFIC_KEEP_DAYS, TRAFFIC_SLOT_DAYS, TRAFFIC_SLOT_PIECES)).fetchone()[0]
        except sqlite3.OperationalError:
            out["typical"] = None        # сборщик до этапа 33
        try:
            out["turns"] = conn.execute("SELECT COUNT(DISTINCT u || ',' || v || ',' || w) FROM traffic_turn_obs"
                                        ).fetchone()[0]
        except sqlite3.OperationalError:
            out["turns"] = None
    finally:
        conn.close()
    return out


def rows_in(path):
    try:
        with open(path, "rb") as f:
            return sum(1 for line in f if line.strip())
    except OSError:
        return None


def check_traffic(ctx, probe=probe_stand):
    """Пробки: покрытие данных, свежесть now.json и файла скоростей стенда,
    последний удачный customize, здоровье стенда (33F)."""
    meaning = ("Пробки — только показ и выбор пути: камеры не задеты. Устаревший файл "
               "скоростей — стенд держит прошлую пробку; now.json старше 10 минут — "
               "телефоны не видят пробок.")
    db = os.path.join(ctx.root, "api", "traffic.db")
    if not os.path.exists(db):
        return result("traffic", "Пробки", IDLE, "traffic.db нет — сборщик не выложен", meaning)
    state, parts, details = OK, [], []
    counts = traffic_counts(db, ctx.now)
    parts.append("кусков за час %d · рёбер: карта %d, путь %d, типичных %s, манёвров %s" % (
        counts["pieces"], counts["map"], counts["route"],
        "—" if counts["typical"] is None else counts["typical"],
        "—" if counts["turns"] is None else counts["turns"]))
    if counts["pieces"] == 0:
        state = IDLE
    now_json = os.path.join(ctx.root, "www", "traffic", "now.json")
    try:
        with open(now_json, encoding="utf-8") as f:
            generated = json.load(f).get("generated") or 0
        age = ctx.now - generated
        details.append("now.json: %d мин назад" % (age // 60))
        if age > TRAFFIC_NOW_STALE:
            state = worst(state, WARN)
            parts.append("now.json старше 10 мин — сборщик стоит")
    except (OSError, ValueError):
        state = worst(state, WARN)
        parts.append("now.json не читается")
    stand = os.path.join(ctx.root, "osrm-mld")
    if os.path.isdir(os.path.join(stand, "pristine")):
        stamp = os.path.join(stand, "cycle.stamp")
        ok_stamp = os.path.join(stand, "customize.ok")
        current = os.path.join(stand, "current")
        jam_rows = rows_in(os.path.join(current, "speeds.csv"))
        turn_rows = rows_in(os.path.join(current, "turns.csv"))
        sizes = ["%s %d КБ" % (name, os.path.getsize(os.path.join(stand, name)) // 1024)
                 for name in ("speeds.csv", "turns.csv") if os.path.exists(os.path.join(stand, name))]
        if os.path.exists(stamp):
            age = ctx.now - os.path.getmtime(stamp)
            parts.append("стенд: цикл %d мин назад, в слоте рёбер %s, манёвров %s" % (
                age // 60, "—" if jam_rows is None else jam_rows, "—" if turn_rows is None else turn_rows))
            if age > TRAFFIC_STALE:
                state = worst(state, WARN)
                parts.append("файл скоростей старше 15 мин%s" % (
                    " — стенд держит прошлую пробку" if jam_rows else ""))
        else:
            parts.append("стенд: цикл не включён")
        if os.path.exists(ok_stamp):
            details.append("последний удачный customize: %d мин назад" % ((ctx.now - os.path.getmtime(ok_stamp)) // 60))
        details.extend(sizes)
        alive, ms = probe()
        details.append("стенд 8094: %s за %d мс" % ("строит" if alive else "не отвечает", ms))
        if not alive:
            state = worst(state, WARN)
            parts.append("стенд не отвечает")
    return result("traffic", "Пробки", state, " · ".join(parts), meaning, details)


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


# --- Запас мощности: когда менять тариф -------------------------------------

def read_machine(proc):
    """Счётчики ядра: (отправлено байт, CPU всего, CPU простой, свободно МБ) или None."""
    try:
        with open(proc + "/net/route", encoding="ascii") as f:
            iface = next(line.split()[0] for line in f.readlines()[1:] if line.split()[1] == "00000000")
        with open(proc + "/net/dev", encoding="ascii") as f:
            stats = next(line.split(":", 1)[1].split() for line in f if line.strip().startswith(iface + ":"))
        with open(proc + "/stat", encoding="ascii") as f:
            cpu = [int(value) for value in f.readline().split()[1:9]]
        with open(proc + "/meminfo", encoding="ascii") as f:
            memory = next(int(line.split()[1]) // 1024 for line in f if line.startswith("MemAvailable:"))
        return int(stats[8]), sum(cpu), cpu[3] + cpu[4], memory
    except (OSError, ValueError, IndexError, StopIteration):
        return None


HTTP_LINE = re.compile(r'\[([^\]]+)\] "[^"]*" (\d{3}) ')


def count_http(path, since):
    """(запросов RadarMap, из них 429) после since; читается только хвост журнала."""
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            f.seek(max(0, f.tell() - LIMITS["capacity_log_tail"]))
            tail = f.read().decode("utf-8", "replace")
    except OSError:
        return 0, 0
    total = blocked = 0
    for line in tail.splitlines():
        if "/radarmap/" not in line or "RadarMap-status/" in line:
            continue
        found = HTTP_LINE.search(line)
        if not found:
            continue
        try:
            at = datetime.datetime.strptime(found.group(1), "%d/%b/%Y:%H:%M:%S %z").timestamp()
        except ValueError:
            continue
        if at > since:
            total += 1
            blocked += found.group(2) == "429"
    return total, blocked


def traffic_queue(root):
    """(кусков осталось после прогона сборки, пропущено насыщением)."""
    path = os.path.join(root, "api", "traffic.db")
    if not os.path.exists(path):
        return 0, 0
    try:
        conn = sqlite3.connect("file:%s?mode=ro" % path, uri=True, timeout=5)
        try:
            meta = dict(conn.execute("SELECT key, value FROM traffic_meta WHERE key IN ('last_left', 'last_skipped')"))
        finally:
            conn.close()
    except sqlite3.Error:
        return 0, 0
    return int(meta.get("last_left", 0)), int(meta.get("last_skipped", 0))


def capacity_intervals(rows):
    """Строки capacity → показатели между соседними замерами; сброс счётчиков пропускается."""
    out = []
    for a, b in zip(rows, rows[1:]):
        seconds, sent, cpu_total = b[0] - a[0], b[1] - a[1], b[2] - a[2]
        if seconds <= 0 or sent < 0 or cpu_total <= 0:
            continue
        out.append({"mbit": sent * 8 / seconds / 1e6, "cpu": 100 * (1 - (b[3] - a[3]) / cpu_total), "mem": b[4],
                    "route_ms": b[5], "http": b[6], "blocked": b[7], "left": b[8], "skipped": b[9]})
    return out


def capacity_verdict(intervals, channel_mbit):
    """(состояние, сводка, советы) по замерам за сутки: важен пик, а не среднее."""
    if not intervals:
        return IDLE, "копим замеры", []
    mbit = max(i["mbit"] for i in intervals)
    cpu = max(i["cpu"] for i in intervals)
    mem = min(i["mem"] for i in intervals)
    routes = sorted(i["route_ms"] for i in intervals if i["route_ms"])
    route_p95 = routes[int(len(routes) * 0.95)] if len(routes) >= LIMITS["route_min_samples"] else None
    http = sum(i["http"] for i in intervals)
    blocked_pct = 100 * sum(i["blocked"] for i in intervals) / http if http else 0
    recent = intervals[-12:]
    lagging = sum(1 for i in recent if i["left"] > 0) / len(recent)
    skipped = sum(i["skipped"] for i in recent)
    channel_pct = 100 * mbit / channel_mbit

    states, advice = [OK], []

    def rate(state, text):
        states.append(state)
        advice.append(text)

    if channel_pct >= LIMITS["channel_warn_pct"]:
        rate(BAD if channel_pct >= LIMITS["channel_bad_pct"] else WARN,
             "канал занят на %d %% в пик → тариф с большим каналом или edge" % channel_pct)
    if cpu >= LIMITS["cpu_warn_pct"]:
        rate(BAD if cpu >= LIMITS["cpu_bad_pct"] else WARN, "CPU %d %% в пик → больше ядер" % cpu)
    if mem < LIMITS["mem_warn_mb"]:
        rate(BAD if mem < LIMITS["mem_bad_mb"] else WARN, "свободно %d МБ в худший момент → больше памяти" % mem)
    if route_p95 is not None and route_p95 > LIMITS["route_warn_ms"]:
        rate(WARN, "маршрут p95 %d мс → реплика OSRM" % route_p95)
    if blocked_pct > LIMITS["http429_warn_pct"]:
        rate(WARN, "ответов 429: %.1f %% → лимиты nginx под CGNAT" % blocked_pct)
    if lagging >= LIMITS["queue_warn_share"]:
        rate(WARN, "сборка не успевает за очередью кусков → больше ядер")
    if skipped:
        advice.append("насыщение за час: без OSRM %d кусков" % skipped)

    summary = "канал %.1f/%d Мбит/с · CPU %d %% · свободно %d МБ · маршрут p95 %s · 429: %.1f %%" % (
        mbit, channel_mbit, cpu, mem, "%d мс" % route_p95 if route_p95 is not None else "—", blocked_pct)
    return worst(*states), summary, advice


def check_capacity(ctx):
    meaning = ("Сервер подходит к пределу: водители получат устаревшие пробки и медленные "
               "маршруты. В деталях — что именно менять в тарифе.")
    machine = read_machine(ctx.proc) if ctx.history_db else None
    if machine is None:
        return result("capacity", "Запас мощности", IDLE, "нет счётчиков машины", meaning)
    conn = sqlite3.connect(ctx.history_db, timeout=10)
    try:
        conn.execute("CREATE TABLE IF NOT EXISTS capacity(at INTEGER PRIMARY KEY, tx_bytes INTEGER, "
                     "cpu_total INTEGER, cpu_idle INTEGER, mem_mb INTEGER, route_ms INTEGER, "
                     "http_all INTEGER, http_429 INTEGER, queue_left INTEGER, skipped INTEGER)")
        last = conn.execute("SELECT MAX(at) FROM capacity").fetchone()[0]
        http, blocked = count_http(ctx.nginx_log, last if last is not None else ctx.now - 300)
        left, skipped = traffic_queue(ctx.root)
        with conn:
            conn.execute("INSERT OR REPLACE INTO capacity VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                         (int(ctx.now),) + machine + (ctx.route_ms, http, blocked, left, skipped))
            conn.execute("DELETE FROM capacity WHERE at < ?", (ctx.now - 30 * DAY,))
        rows = conn.execute("SELECT * FROM capacity WHERE at >= ? ORDER BY at", (ctx.now - DAY,)).fetchall()
    finally:
        conn.close()
    state, summary, advice = capacity_verdict(capacity_intervals(rows), LIMITS["channel_mbit"])
    details = list(advice)
    if getattr(_tc, "capacity", None):
        plan = _tc.capacity()
        details.append("настройки этой машины: потоков к OSRM %d · насыщение от %d кусков · customize %d яд., %d МБ"
                       % (plan["match_workers"], plan["saturate_from"], plan["customize_cpus"],
                          plan["customize_memory_mb"]))
    return result("capacity", "Запас мощности", state, summary, meaning, details)


CHECKS = (check_api, check_cameras, check_registry, check_limits, check_roads, check_mvt, check_omt, check_overrides,
          check_hotspots, check_config, check_osrm, check_traffic, check_crowd, check_backup, check_disk,
          check_cert, check_delivery, check_capacity)


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
    report = run_all(Context(history_db=HISTORY_DB))
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
