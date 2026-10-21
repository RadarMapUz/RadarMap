#!/usr/bin/env python3
"""bot_near.py — что бот ОТДАЁТ: «что рядом», метан, трансляция, перевалы,
город (план 23.2–23.6). Чистая логика и источники данных; сеть Telegram и
базы подписок — в telegram_bot.py и bot_subs.py.

ИСТОЧНИКИ — те же, что у приложения, своей базы у бота нет:
  * живые отметки — GET /api/mobile (с честным `confirmed`) и /api/road
    (перекрытия, ремонт) того же API на 127.0.0.1:8091;
  * метан — GET /api/cng (статус станции) + АГНКС из файлов заведений
    (telegram_bot.CngVenues — те же файлы, что качают телефоны);
  * стационарные камеры — cameras.json из webroot (его раздаёт deploy_db.sh)
    с решениями модератора поверх — подписанный overrides.json
    (publish_overrides.sh), по тем же правилам, что CameraOverrideEngine
    приложения: скрытая камера не показывается, перенесённая — на новой точке;
  * улица — адресные клетки road2_*_a.json (telegram_publish.nearest_in_cell);
  * перевалы — weather/roads.json (build_road_weather.py);
  * пульт — config.json из webroot, ключ features.bot.
Ответы API кэшируются на секунды (DataCache): трансляция шлёт правки
геопозиции часто, и каждая не должна стоить запроса.

ГЕОПОЗИЦИЯ НЕ ПИШЕТСЯ НИКУДА. Функции здесь получают точку аргументом и
возвращают текст; в журнал — только виды событий и числа (тест грепает).
Трансляция держит свои точки в памяти (LiveSession) — до её конца.

ЧЕСТНОСТЬ ТЕКСТОВ. Неподтверждённая отметка так и называется — «отметка
водителя, не подтверждена»: предупреждаем, но слух фактом не продаём (тот же
принцип, что у призрачных меток приложения). Нет данных — «нет данных», а
не «газ есть» и не тишина.
"""
import base64
import json
import math
import os
import sys
import time

import bot_texts
import telegram_publish

#: Радиусы «что рядом»: основной и кнопка «дальше».
NEAR_RADIUS = 5000
FAR_RADIUS = 15000
#: Строк живых отметок в одной карточке; остальные — «…и ещё N».
NEAR_MAX_LINES = 10
#: Метан: сколько станций в /metan и где искать.
METAN_COUNT = 5
METAN_RADIUS = 15000
#: Отметить статус можно у заправки: дальше — тот же «с дивана», от
#: которого приложение защищено вопросом только в 60 м (AppConfig.cngAskMeters).
CNG_MARK_MAX_METERS = 300.0
#: Станция /api/cng и заведение — одна, если ближе (ключ станции — 1e-4°).
CNG_MATCH_METERS = 25.0
#: Сколько живут ответы API в памяти бота и до какого возраста отдаются при сбое.
API_TTL = 15.0
API_STALE_MAX = 120.0
#: Адрес отметки — дом не дальше этого (как у канала).
ADDRESS_MAX_METERS = telegram_publish.ADDRESS_MAX_METERS
#: Текст из базы камер (поле location) — не длиннее.
LOCATION_MAX = 48
TASHKENT = 5 * 3600

#: Трансляция (23.4).
LIVE_GAP = 60.0                  # не чаще одного сообщения «впереди» в минуту
LIVE_MAX_SECONDS = 8 * 3600      # «бессрочная» трансляция Telegram — не дольше 8 ч
LIVE_COURSE_STEP = 30.0          # курс — по точкам не ближе этого
LIVE_REPORT_AHEAD = 5000.0       # отметки водителей — на 5 км вперёд
LIVE_CAMERA_AHEAD = 2000.0       # стационарные камеры — на 2 км
LIVE_MAX_ITEMS = 6
PASS_NEAR_METERS = 90.0          # = MobilePassWatch: проехал в 90 м…
PASS_LEFT_METERS = 180.0         # …и уехал на 180 — спросить «ещё стоит?»
PASS_ASK_TYPES = ("radar", "tripod", "post")
VOTE_WINDOW = 30 * 60            # ответ на вопрос принимается столько

#: Перевалы (23.5).
WEATHER_STALE = 2 * 3600         # = телефон: файл старше двух часов — данных нет
HAZARD_ORDER = ("ice", "snow", "fog", "wind")
#: Пульт перечитывается не чаще.
PULT_RECHECK = 300.0

#: Решения модератора (overrides.json) — те же пороги, что у приложения
#: (AppConfig.overrideMaxHiddenShare, overrideMaxMoveMeters, uzLatRange,
#: uzLonRange; тест сверяет). Файл, скрывающий больше этой доли базы, —
#: вероятнее опечатка в SQL, чем решение: не верим ему целиком.
OVERRIDE_MAX_HIDDEN_SHARE = 0.05
#: Поправка снапа — десятки метров; дальше — перепутанная камера или запятая.
OVERRIDE_MAX_MOVE_METERS = 500.0
UZ_LAT_RANGE = (37.0, 46.0)
UZ_LON_RANGE = (55.0, 74.0)
OVERRIDE_OPS = ("hide", "move", "retype")
#: Дорожный профиль камеры: снап мерил его у СТАРОЙ точки, а `road` хранится
#: дельтами от камеры и уехал бы вместе с ней — перенос его снимает
#: (Camera.moved в приложении).
PROFILE_KEYS = ("axis", "dir", "lanes", "cls", "bridge", "road", "split", "twin")

M_PER_DEG = 111_320.0


def log(text):
    """Только виды событий и числа — ни координат, ни id, ни текстов."""
    print(f"telegram_bot: {text}", file=sys.stderr, flush=True)


# --- геометрия ------------------------------------------------------------------

def haversine(lat1, lon1, lat2, lon2):
    r = 6371000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = math.radians(lat2 - lat1), math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def fast_distance(lat1, lon1, lat2, lon2):
    """Равнопромежуточное приближение — формула GeoMath.fastDistance
    приложения: граница переноса в 500 м должна резать там же, где на телефоне."""
    dlat = (lat2 - lat1) * M_PER_DEG
    dlon = (lon2 - lon1) * M_PER_DEG * math.cos(math.radians(lat1))
    return math.sqrt(dlat * dlat + dlon * dlon)


def bearing(lat1, lon1, lat2, lon2):
    """Азимут из первой точки во вторую, градусы 0…360 (0 — север)."""
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dl = math.radians(lon2 - lon1)
    x = math.sin(dl) * math.cos(p2)
    y = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return (math.degrees(math.atan2(x, y)) + 360.0) % 360.0


def along_lateral(origin, course, target):
    """(вдоль курса, вбок) от origin до target, метры. Вдоль < 0 — позади."""
    d = haversine(origin[0], origin[1], target[0], target[1])
    if d < 1e-6:
        return 0.0, 0.0
    delta = math.radians(bearing(origin[0], origin[1], target[0], target[1]) - course)
    return d * math.cos(delta), abs(d * math.sin(delta))


def is_ahead(origin, course, target, reach, wide):
    """Впереди по ходу: не дальше `reach` вдоль курса и в коридоре, который
    расширяется вдаль (дорога изгибается). `wide` — отметки водителей:
    коридор шире, чем у стационарных камер (их в городе по десятку на улицу,
    и соседняя параллельная — не наша)."""
    along, lateral = along_lateral(origin, course, target)
    if along < 30.0 or along > reach:
        return False
    return lateral <= (200.0 + 0.15 * along if wide else 80.0 + 0.05 * along)


# --- форматирование -------------------------------------------------------------

def fmt_distance(meters, lang):
    """«600 м», «1,2 км», «14 км» (uz — «m», «km»). Ближе километра — шагом
    50 м: не точнее, чем GPS и смысл."""
    m, km = ("м", "км") if lang != "uz" else ("m", "km")
    step = max(50, int(round(meters / 50.0)) * 50)
    if step < 1000:
        return f"{step} {m}"
    if meters < 9950:
        value = f"{meters / 1000.0:.1f}"
        return (value[:-2] if value.endswith(".0") else value.replace(".", ",")) + f" {km}"
    return f"{int(round(meters / 1000.0))} {km}"


def fmt_radius(meters, lang):
    km = "км" if lang != "uz" else "km"
    return f"{int(round(meters / 1000.0))} {km}"


def fmt_age(seconds, lang):
    """Возраст ступенью 5 минут вверх, минимум 5 — как api.cng_age: точного
    времени отметки не показываем ни телефону, ни здесь."""
    minutes = int(math.ceil(max(0.0, seconds) / 300.0)) * 5 or 5
    if minutes < 60:
        return bot_texts.text(lang, "ago_min", n=minutes)
    return bot_texts.text(lang, "ago_hours", h=minutes // 60, m=minutes % 60)


def clock(ts):
    return time.strftime("%H:%M", time.gmtime(ts + TASHKENT))


def until_text(expires, now, lang):
    """«до 18:00»; дальше суток — «до 25.10»."""
    when = clock(expires) if expires - now < 20 * 3600 else time.strftime("%d.%m", time.gmtime(expires + TASHKENT))
    return bot_texts.text(lang, "until", time=when)


def short(text, limit=LOCATION_MAX):
    text = " ".join(str(text or "").split())
    return text if len(text) <= limit else text[:limit - 1].rstrip() + "…"


def _number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


# --- подписанные файлы webroot -----------------------------------------------------

def default_verifier():
    """Тот же openssl-проверщик Ed25519, что у пульта состояния (status.py),
    с ключом AppConfig.otaPublicKeyB64. Нет модуля — проверить нечем (None):
    это не «подпись верна», и решения, требующие подписи, не применяются."""
    try:
        import status
    except ImportError:
        return lambda data, sig: None
    return status.verify_ed25519


def signed_payload(path, verify):
    """Байты полезной нагрузки конверта {payload, sig} (SignedPayload
    приложения: base64 ТОЧНЫХ подписанных байтов) или None, если подпись не
    подтверждена — не сошлась или проверить нечем. Порядок один: подпись ДО
    разбора JSON. Нет файла, битый конверт — исключение (OSError, ValueError,
    KeyError, TypeError): что это значит, решает вызывающий."""
    with open(path, "rb") as handle:
        envelope = json.loads(handle.read())
    payload = base64.b64decode(envelope["payload"], validate=True)
    sig = envelope["sig"]
    if not isinstance(sig, str) or not sig:
        return None                  # подписи нет — нечего и проверять
    return payload if verify(payload, sig) is True else None


# --- решения модератора (overrides.json) ----------------------------------------------

def parse_overrides(payload):
    """items снимка CameraOverrides или None — файл не по контракту.
    Строго, как Codable приложения: одна кривая строка (нет id, неизвестная
    операция, координата строкой) — и не разбирается весь файл, решений нет."""
    try:
        data = json.loads(payload)
    except ValueError:
        return None
    if not isinstance(data, dict) or not isinstance(data.get("version"), int) \
            or isinstance(data.get("version"), bool) or not isinstance(data.get("items"), list):
        return None
    items = []
    for item in data["items"]:
        if not isinstance(item, dict) or not isinstance(item.get("id"), int) or isinstance(item["id"], bool) \
                or item.get("op") not in OVERRIDE_OPS:
            return None
        for key in ("lat", "lon"):
            value = item.get(key)
            if value is not None and not (isinstance(value, (int, float)) and not isinstance(value, bool)):
                return None
        if item.get("type") is not None and not isinstance(item["type"], str):
            return None
        items.append(item)
    return items


def overrides_sane(items, base_count):
    """CameraOverrideEngine.isSane: скрытий не больше доли базы. Предохранитель
    от опечатки в админке, не от злоумышленника (от него — подпись)."""
    if base_count <= 0:
        return False
    hides = sum(1 for item in items if item["op"] == "hide")
    return hides <= base_count * OVERRIDE_MAX_HIDDEN_SHARE


def _plausible_move(camera, lat, lon):
    if not (_number(lat) and _number(lon)):
        return False
    if not (UZ_LAT_RANGE[0] <= lat <= UZ_LAT_RANGE[1] and UZ_LON_RANGE[0] <= lon <= UZ_LON_RANGE[1]):
        return False
    return fast_distance(camera["lat"], camera["lon"], lat, lon) <= OVERRIDE_MAX_MOVE_METERS


def apply_overrides(rows, items):
    """CameraOverrideEngine.apply: (новый список, счёт {hidden, moved,
    retyped, rejected}). Сомнительная правка (перенос дальше предела или вне
    Узбекистана, смена на пустой тип) отбрасывается — камера остаётся как в
    базе: лишнее предупреждение дешевле молчания. Последняя строка для id
    побеждает. Строки базы не меняются — правленая камера копируется."""
    counts = {"hidden": 0, "moved": 0, "retyped": 0, "rejected": 0}
    if not items:
        return list(rows), counts
    by_id = {item["id"]: item for item in items}
    out = []
    for camera in rows:
        item = by_id.get(camera.get("id"))
        if item is None:
            out.append(camera)
        elif item["op"] == "hide":
            counts["hidden"] += 1
        elif item["op"] == "move":
            lat, lon = item.get("lat"), item.get("lon")
            if not _plausible_move(camera, lat, lon):
                counts["rejected"] += 1
                out.append(camera)
                continue
            moved = {key: value for key, value in camera.items() if key not in PROFILE_KEYS}
            moved["lat"], moved["lon"] = float(lat), float(lon)
            out.append(moved)
            counts["moved"] += 1
        else:
            if not item.get("type"):
                counts["rejected"] += 1
                out.append(camera)
                continue
            # Нарушения в приложении выводятся из типа заново — старые не тянем.
            retyped = {key: value for key, value in camera.items() if key != "violations"}
            retyped["type"] = item["type"]
            out.append(retyped)
            counts["retyped"] += 1
    return out, counts


# --- источники ------------------------------------------------------------------

class DataCache:
    """Ответ GET API с кэшем: свежий — API_TTL, при сбое — последний удачный
    не старше API_STALE_MAX, иначе None («не загрузились» — честно)."""

    def __init__(self, get, path, key, clock=time.monotonic):
        self.get = get              # path -> (status, dict)
        self.path = path
        self.key = key
        self.clock = clock
        self._value = None
        self._at = None
        self._tried = None

    def value(self):
        now = self.clock()
        if self._tried is not None and now - self._tried < API_TTL:
            return self._fresh(now)
        self._tried = now
        try:
            status, body = self.get(self.path)
        except Exception as error:      # источник не роняет ответ человеку
            log(f"{self.path}: не загрузилось — {type(error).__name__}")
            status, body = 0, {}
        items = body.get(self.key) if status == 200 and isinstance(body, dict) else None
        if isinstance(items, list):
            self._value = [item for item in items if isinstance(item, dict)
                           and _number(item.get("lat")) and _number(item.get("lon"))]
            self._at = now
        return self._fresh(now)

    def _fresh(self, now):
        if self._at is None or now - self._at > API_STALE_MAX:
            return None
        return self._value


class CameraDb:
    """Стационарные камеры из cameras.json webroot с решениями модератора
    поверх (overrides.json, если путь задан). Оба файла перечитываются при
    смене mtime/размера любого из них (проверка не чаще раза в минуту; openssl
    — только на смене), в памяти — сетка 0,05° (~5,5 км), как CameraStore
    приложения: поиск не перебирает 3500.

    Решения — как у приложения (CameraOverrideEngine): только из файла с
    верной подписью Ed25519 ключом владельца. Нет файла, подпись не сошлась
    или проверить нечем, JSON не по контракту, скрыто больше доли базы — нет
    решений вовсе, камеры как в базе: эта сторона предупреждает больше, а
    скрытие камеры — единственное, что производит молчание там, где она стоит."""

    CELL = 0.05

    def __init__(self, path, overrides_path=None, verify=None, clock=time.monotonic):
        self.path = path
        self.overrides_path = overrides_path
        self.verify = verify
        self.clock = clock
        self._stamp = None
        self._checked = None
        self._grid = None
        self._failed = False
        #: Что сделали решения при последней загрузке — для журнала и тестов.
        self.applied = {"hidden": 0, "moved": 0, "retyped": 0, "rejected": 0}

    def _cell(self, lat, lon):
        return int(math.floor(lat / self.CELL)), int(math.floor(lon / self.CELL))

    def _overrides_stamp(self):
        if not self.overrides_path:
            return None
        try:
            info = os.stat(self.overrides_path)
        except OSError:
            return None              # не опубликован — решений нет, это не сбой
        return info.st_mtime_ns, info.st_size

    def _decisions(self, base_count):
        """Проверенные items или [] — с причиной в журнале (без координат)."""
        try:
            payload = signed_payload(self.overrides_path, self.verify or default_verifier())
        except (OSError, ValueError, KeyError, TypeError) as error:
            log(f"решения модератора: файл не читается ({type(error).__name__}) — камеры как в базе")
            return []
        if payload is None:
            log("решения модератора: подпись не подтверждена — камеры как в базе")
            return []
        items = parse_overrides(payload)
        if items is None:
            log("решения модератора: файл не по контракту — камеры как в базе")
            return []
        if not overrides_sane(items, base_count):
            log("решения модератора: скрывают больше доли базы — файл отвергнут целиком")
            return []
        return items

    def _load(self):
        now = self.clock()
        if self._checked is not None and now - self._checked < 60.0 and self._grid is not None:
            return self._grid
        self._checked = now
        try:
            info = os.stat(self.path)
            ov_stamp = self._overrides_stamp()
            stamp = ((info.st_mtime_ns, info.st_size), ov_stamp)
            if stamp != self._stamp or self._grid is None:
                with open(self.path, "rb") as handle:
                    rows = json.loads(handle.read())
                if isinstance(rows, dict):
                    rows = rows.get("cameras")
                if not isinstance(rows, list):
                    raise ValueError("не список камер")
                rows = [row for row in rows
                        if isinstance(row, dict) and _number(row.get("lat")) and _number(row.get("lon"))]
                items = self._decisions(len(rows)) if ov_stamp is not None else []
                rows, counts = apply_overrides(rows, items)
                if items:
                    log("решения модератора: скрыто {hidden}, перенесено {moved}, "
                        "сменён тип {retyped}, отброшено {rejected}".format(**counts))
                grid = {}
                for row in rows:
                    grid.setdefault(self._cell(row["lat"], row["lon"]), []).append(row)
                self._grid, self._stamp, self.applied = grid, stamp, counts
                self._failed = False
        except (OSError, ValueError) as error:
            if not self._failed:
                log(f"база камер не читается — {type(error).__name__}")
            self._failed = True
            self._grid = None
        return self._grid
        self._checked = now
        try:
            info = os.stat(self.path)
            stamp = (info.st_mtime_ns, info.st_size)
            if stamp != self._stamp or self._grid is None:
                with open(self.path, "rb") as handle:
                    rows = json.loads(handle.read())
                if isinstance(rows, dict):
                    rows = rows.get("cameras")
                if not isinstance(rows, list):
                    raise ValueError("не список камер")
                grid = {}
                for row in rows:
                    if isinstance(row, dict) and _number(row.get("lat")) and _number(row.get("lon")):
                        grid.setdefault(self._cell(row["lat"], row["lon"]), []).append(row)
                self._grid, self._stamp = grid, stamp
                self._failed = False
        except (OSError, ValueError) as error:
            if not self._failed:
                log(f"база камер не читается — {type(error).__name__}")
            self._failed = True
            self._grid = None
        return self._grid

    def around(self, lat, lon, meters):
        """[(метры, камера)] по возрастанию; None — базы нет."""
        grid = self._load()
        if grid is None:
            return None
        dlat = meters / M_PER_DEG
        dlon = meters / (M_PER_DEG * max(0.01, math.cos(math.radians(lat))))
        r0, c0 = self._cell(lat - dlat, lon - dlon)
        r1, c1 = self._cell(lat + dlat, lon + dlon)
        out = []
        for r in range(r0, r1 + 1):
            for c in range(c0, c1 + 1):
                for row in grid.get((r, c), ()):
                    d = haversine(lat, lon, row["lat"], row["lon"])
                    if d <= meters:
                        out.append((d, row))
        out.sort(key=lambda pair: pair[0])
        return out


class Addresses:
    """«ул. Шота Руставели, 12» для точки — по адресным клеткам webroot.
    Клетка читается один раз (и заново при смене файла): канал читает её на
    каждую строку раз в пять минут, боту адрес нужен на каждый ответ."""

    def __init__(self, directory):
        self.directory = directory
        self._cells = {}

    def nearest(self, lat, lon):
        if not self.directory:
            return None
        path = os.path.join(self.directory, f"road2_{telegram_publish.address_key(lat, lon)}_a.json")
        try:
            info = os.stat(path)
        except OSError:
            return None
        stamp = (info.st_mtime_ns, info.st_size)
        cached = self._cells.get(path)
        if cached is None or cached[0] != stamp:
            try:
                with open(path, encoding="utf-8") as handle:
                    cached = (stamp, json.load(handle))
            except (OSError, ValueError):
                return None
            self._cells[path] = cached
        return telegram_publish.nearest_in_cell(cached[1], lat, lon, ADDRESS_MAX_METERS)


class Pult:
    """features.bot из подписанного config.json webroot (publish_config.sh).
    Нет ключа — включено. Выключить может только ПОДПИСАННЫЙ файл: подпись
    не сошлась, проверить нечем, файл битый — всё включено (ARCHITECTURE.md,
    правило 19: любой дефект — значения сборки). Выключатель снимает только
    «не главное» — отметки работают всегда."""

    def __init__(self, path, verify=None, clock=time.monotonic):
        self.path = path
        self.verify = verify
        self.clock = clock
        self._checked = None
        self._stamp = None
        self._enabled = True

    def enabled(self):
        now = self.clock()
        if self._checked is not None and now - self._checked < PULT_RECHECK:
            return self._enabled
        self._checked = now
        try:
            info = os.stat(self.path)
            stamp = (info.st_mtime_ns, info.st_size)
            if stamp == self._stamp:
                return self._enabled
            payload = signed_payload(self.path, self.verify or default_verifier())
            config = json.loads(payload) if payload is not None else {}
            features = config.get("features") if isinstance(config, dict) else None
            value = features.get("bot") if isinstance(features, dict) else None
            self._enabled = value is not False
            self._stamp = stamp
        except (OSError, ValueError, KeyError, TypeError):
            self._enabled = True
            self._stamp = None
        return self._enabled


class Sources:
    """Всё, что бот показывает. Каждый источник может отсутствовать (None) —
    карточка честно скажет, чего нет, и покажет остальное."""

    def __init__(self, api_get=None, cameras=None, venues=None, addresses=None,
                 weather_path=None, clock=time.monotonic, wall=time.time):
        self.mobile = DataCache(api_get, "/api/mobile", "reports", clock) if api_get else None
        self.road = DataCache(api_get, "/api/road", "reports", clock) if api_get else None
        self.cng = DataCache(api_get, "/api/cng", "stations", clock) if api_get else None
        self.cameras = cameras
        self.venues = venues
        self.addresses = addresses
        self.weather_path = weather_path
        self.wall = wall

    def address(self, lat, lon):
        return self.addresses.nearest(lat, lon) if self.addresses is not None else None

    def weather(self):
        if not self.weather_path:
            return None
        try:
            with open(self.weather_path, "rb") as handle:
                body = json.loads(handle.read())
        except (OSError, ValueError):
            return None
        return body if isinstance(body, dict) and isinstance(body.get("points"), list) else None


# --- «что рядом» -------------------------------------------------------------------

def _kind(lang, rtype):
    return bot_texts.KIND_NAMES[lang].get(rtype, bot_texts.KIND_NAMES[lang]["radar"])


def report_line(lang, report, distance, now, street=None):
    """«📷 Тренога — 1,2 км, ул. Шота Руставели · подтверждена, 25 мин назад»."""
    where = fmt_distance(distance, lang) + (f", {street}" if street else "")
    rtype = report.get("type")
    if rtype in ("closure", "roadwork"):
        tail = until_text(report["expires"], now, lang) if _number(report.get("expires")) else ""
    else:
        trust = bot_texts.text(lang, "confirmed" if report.get("confirmed") else "unconfirmed")
        age = fmt_age(now - report["created"], lang) if _number(report.get("created")) else ""
        tail = trust + (f", {age}" if age else "")
    return f"{_kind(lang, rtype)} — {where}" + (f" · {tail}" if tail else "")


def camera_desc(lang, camera):
    """«радар, Amir Temur ko'chasi…, 60 км/ч» — тип, место из базы, предел."""
    parts = [bot_texts.CAMERA_NAMES[lang].get(camera.get("type"), bot_texts.CAMERA_NAMES[lang]["Стационар камера"])]
    if camera.get("location"):
        parts.append(short(camera["location"]))
    for key in ("limit", "speed"):
        if _number(camera.get(key)) and 0 < camera[key] <= 150:
            parts.append(bot_texts.text(lang, "speed", n=int(camera[key])))
            break
    return ", ".join(parts)


def cng_status_text(lang, station, now=None):
    """«газ есть, 15 мин назад · очередь ~30 мин» или «нет данных»."""
    if station is None or (station.get("status") is None and station.get("queue") is None):
        return bot_texts.text(lang, "cng_unknown")
    parts = []
    if station.get("status") in ("gas", "nogas"):
        part = bot_texts.text(lang, "cng_" + station["status"])
        if _number(station.get("status_age")):
            part += ", " + fmt_age(station["status_age"] * 60, lang)   # api.cng_age — минуты
        if not station.get("confirmed"):
            part += f" ({bot_texts.text(lang, 'cng_unconfirmed')})"
        parts.append(part)
    if _number(station.get("queue")):
        parts.append(bot_texts.text(lang, "cng_queue", n=int(station["queue"])))
    return " · ".join(parts) if parts else bot_texts.text(lang, "cng_unknown")


def match_station(stations, venue):
    """Статус /api/cng для АГНКС из файла: ключ станции сервер берёт по 1e-4°,
    а в ответе координата округлена до 1e-5 — сверяем по расстоянию."""
    best = None
    for station in stations or ():
        d = haversine(venue[0], venue[1], station["lat"], station["lon"])
        if d <= CNG_MATCH_METERS and (best is None or d < best[0]):
            best = (d, station)
    return best[1] if best else None


def live_within(sources, point, radius):
    """(отметки камер/постов, события дороги) в радиусе — [(метры, отметка)]
    по возрастанию; None — список не загрузился."""
    out = []
    for cache in (sources.mobile, sources.road):
        items = cache.value() if cache is not None else None
        if items is None:
            out.append(None)
            continue
        near = [(haversine(point[0], point[1], r["lat"], r["lon"]), r) for r in items]
        out.append(sorted((pair for pair in near if pair[0] <= radius), key=lambda pair: pair[0]))
    return out[0], out[1]


def cng_around(sources, point, radius, count):
    """[(метры, (lat, lon, имя), статус|None)] — АГНКС по возрастанию; None —
    источника заведений нет."""
    if sources.venues is None:
        return None
    try:
        venues = sources.venues.around(point[0], point[1], radius)
    except Exception as error:          # VenueSourceError и любой сбой файла — «недоступно»
        log(f"заведения не читаются — {type(error).__name__}")
        return None
    stations = sources.cng.value() if sources.cng is not None else None
    return [(d, venue, match_station(stations, venue)) for d, venue in venues[:count]]


def near_card(lang, sources, point, radius, now):
    """Одна карточка «что рядом» и id показанных живых отметок (для
    трансляции — чтобы не прислать их ещё раз как «новые»)."""
    lines = [bot_texts.text(lang, "near_head", radius=fmt_radius(radius, lang))]
    shown = set()
    mobile, road = live_within(sources, point, radius)
    if mobile is None and road is None:
        lines.append(bot_texts.text(lang, "near_live_down"))
    live = sorted((mobile or []) + (road or []), key=lambda pair: pair[0])
    for distance, report in live[:NEAR_MAX_LINES]:
        street = sources.address(report["lat"], report["lon"])
        lines.append(report_line(lang, report, distance, now, street))
        shown.add(report.get("id"))
    if len(live) > NEAR_MAX_LINES:
        lines.append(bot_texts.text(lang, "near_more", n=len(live) - NEAR_MAX_LINES))
    if not live and not (mobile is None and road is None):
        lines.append(bot_texts.text(lang, "near_none"))
    cameras = sources.cameras.around(point[0], point[1], radius) if sources.cameras is not None else None
    if cameras is None:
        lines.append(bot_texts.text(lang, "cameras_down"))
    elif not cameras:
        lines.append(bot_texts.text(lang, "cameras_none"))
    else:
        distance, camera = cameras[0]
        lines.append(bot_texts.text(lang, "cameras", n=len(cameras), dist=fmt_distance(distance, lang))
                     + f" ({camera_desc(lang, camera)})")
    stations = cng_around(sources, point, radius, 1)
    if stations:
        distance, venue, station = stations[0]
        lines.append(bot_texts.text(lang, "metan_line", name=venue[2] or bot_texts.text(lang, "cng_station"),
                                    dist=fmt_distance(distance, lang), status=cng_status_text(lang, station)))
    elif stations == []:
        lines.append(bot_texts.text(lang, "metan_none"))
    return "\n".join(lines), shown


def metan_list(lang, sources, point):
    """(текст, станции, к которым можно отметить статус — [(номер, станция)])
    или (текст, None) — источника нет."""
    stations = cng_around(sources, point, METAN_RADIUS, METAN_COUNT)
    if stations is None:
        return bot_texts.text(lang, "metan_down"), None
    if not stations:
        return bot_texts.text(lang, "metan_empty"), []
    lines = [bot_texts.text(lang, "metan_head")]
    markable = []
    for index, (distance, venue, station) in enumerate(stations, 1):
        name = venue[2] or bot_texts.text(lang, "cng_station")
        lines.append(f"{index}. «{name}» — {fmt_distance(distance, lang)} — {cng_status_text(lang, station)}")
        if distance <= CNG_MARK_MAX_METERS:
            markable.append((index - 1, venue))
    if not markable:
        lines.append(bot_texts.text(lang, "metan_hint"))
    return "\n".join(lines), markable


# --- трансляция (23.4) ----------------------------------------------------------------

class LiveSession:
    """Одна трансляция одного человека — только в памяти бота.

    Курс — по последовательным точкам (не ближе LIVE_COURSE_STEP); пока его
    нет, «впереди» не считаем вовсе. Раз в LIVE_GAP — только НОВОЕ впереди:
    живые отметки на 5 км, стационарные камеры на 2 км. Отдельно, на каждой
    точке, — петля доверия, как MobilePassWatch приложения: прошёл в 90 м от
    чужой живой отметки и уехал на 180 — один раз спросить «ещё стоит?»."""

    def __init__(self, now, live_period, own=()):
        period = live_period if _number(live_period) and live_period > 0 else LIVE_MAX_SECONDS
        self.until = now + min(float(period), LIVE_MAX_SECONDS)
        self.started = None         # дата сообщения трансляции у Telegram — её «имя»
        self.anchor = None
        self.course = None
        self.last_sent = now        # карточка «что рядом» ушла в момент начала
        self.announced = set()
        self.near = set()
        self.asked = {}             # id отметки → когда спросили
        self.own = set(own)         # свои отметки этого человека — не спрашивать

    def alive(self, now):
        return now < self.until

    def move(self, point):
        if self.anchor is None:
            self.anchor = point
            return
        if haversine(self.anchor[0], self.anchor[1], point[0], point[1]) >= LIVE_COURSE_STEP:
            self.course = bearing(self.anchor[0], self.anchor[1], point[0], point[1])
            self.anchor = point

    def ahead(self, point, now, reports, cameras):
        """Новое впереди: [(вдоль, вид, объект)] по возрастанию или []. Пусто
        до истечения LIVE_GAP и без курса."""
        if self.course is None or now - self.last_sent < LIVE_GAP:
            return []
        found = []
        for report in reports or ():
            key = ("r", report.get("id"))
            if key not in self.announced and is_ahead(point, self.course, (report["lat"], report["lon"]),
                                                      LIVE_REPORT_AHEAD, wide=True):
                found.append((along_lateral(point, self.course, (report["lat"], report["lon"]))[0], key, report))
        for _, camera in cameras or ():
            key = ("c", camera.get("id"))
            if key not in self.announced and is_ahead(point, self.course, (camera["lat"], camera["lon"]),
                                                      LIVE_CAMERA_AHEAD, wide=False):
                found.append((along_lateral(point, self.course, (camera["lat"], camera["lon"]))[0], key, camera))
        found.sort(key=lambda item: item[0])
        found = found[:LIVE_MAX_ITEMS]
        if found:
            self.last_sent = now
            self.announced.update(key for _, key, _ in found)
        return found

    def passed(self, point, now, reports):
        """Отметка, о которой пора спросить «ещё стоит?», или None — не
        больше одной на точку и не больше одного раза на отметку."""
        for report in reports or ():
            rid = report.get("id")
            if report.get("type") not in PASS_ASK_TYPES or rid in self.own or rid in self.asked:
                continue
            d = haversine(point[0], point[1], report["lat"], report["lon"])
            if d <= PASS_NEAR_METERS:
                self.near.add(rid)
            elif rid in self.near and d >= PASS_LEFT_METERS:
                self.asked[rid] = now
                return report
        return None

    def answerable(self, rid, now):
        """Ответ принимается только на заданный вопрос и не позже VOTE_WINDOW:
        callback_data присылает клиент — бот не голосует за что попало."""
        asked = self.asked.get(rid)
        return asked is not None and now - asked <= VOTE_WINDOW


def live_text(lang, found, point, now, sources):
    lines = [bot_texts.text(lang, "live_ahead")]
    for along, key, item in found:
        if key[0] == "r":
            lines.append(report_line(lang, item, along, now, sources.address(item["lat"], item["lon"])))
        else:
            lines.append(f"📷 {fmt_distance(along, lang)} — {camera_desc(lang, item)}")
    return "\n".join(lines)


# --- перевалы (23.5) ------------------------------------------------------------------

def pass_status(weather, now):
    """{группа: {"name": {ru, uz}, "hazards": […], "until": t|None, "t": °C|None,
    "stale": bool}} — только точки вида «pass», в порядке файла. Файла нет —
    {}. Свежесть — как у телефона: старше двух часов — «данных нет»."""
    if not isinstance(weather, dict) or not isinstance(weather.get("points"), list):
        return {}
    generated = weather.get("generated")
    stale = not _number(generated) or now - generated > WEATHER_STALE
    groups = {}
    for point in weather["points"]:
        if not isinstance(point, dict) or point.get("kind") != "pass":
            continue
        group = point.get("group") or point.get("id")
        name = point.get("name") if isinstance(point.get("name"), dict) else {}
        where = point.get("where") if isinstance(point.get("where"), dict) else {}
        item = groups.setdefault(group, {"name": name, "where": where, "hazards": [], "until": None,
                                         "t": None, "stale": stale})
        for hazard in point.get("hazards") or ():
            kind = hazard.get("k") if isinstance(hazard, dict) else None
            if kind in HAZARD_ORDER and kind not in item["hazards"]:
                item["hazards"].append(kind)
        if _number(point.get("until")):
            item["until"] = max(item["until"] or 0, point["until"])
        if _number(point.get("t")):
            item["t"] = point["t"] if item["t"] is None else min(item["t"], point["t"])
    for item in groups.values():
        item["hazards"].sort(key=HAZARD_ORDER.index)
    return groups


def pass_name(lang, item, group):
    name = item.get("name") or {}
    return name.get(lang) or name.get("ru") or str(group)


def _temp(lang, t):
    return bot_texts.text(lang, "pereval_temp", t=str(int(round(t))).replace("-", "−")) if _number(t) else ""


def pass_what(lang, item):
    """«туман, гололёд до 14:00, −2 °C» / «сейчас спокойно, 3 °C» / «свежих данных нет»."""
    if item["stale"]:
        return bot_texts.text(lang, "pereval_stale")
    temp = _temp(lang, item.get("t"))
    if item["hazards"]:
        names = ", ".join(bot_texts.HAZARD_NAMES[lang][k] for k in item["hazards"])
        what = (bot_texts.text(lang, "pereval_hazard", hazards=names, time=clock(item["until"]))
                if _number(item.get("until")) else names)
    else:
        what = bot_texts.text(lang, "pereval_calm")
    return what + (f", {temp}" if temp else "")


def pereval_text(lang, statuses):
    if not statuses:
        return bot_texts.text(lang, "pereval_down")
    lines = [bot_texts.text(lang, "pereval_head")]
    for group, item in statuses.items():
        lines.append(bot_texts.text(lang, "pereval_line", name=pass_name(lang, item, group),
                                    what=pass_what(lang, item)))
    return "\n".join(lines)


# --- город (23.6) ----------------------------------------------------------------------

def city_of(lat, lon):
    """Город отметки — как у канала; дальше CITY_RADIUS_KM — None (трасса)."""
    name, km = telegram_publish.nearest_city(lat, lon)
    return name if km <= telegram_publish.CITY_RADIUS_KM else None


def city_message(lang, city, reports, address_fn):
    """Сообщение подписчику города: те же правила, что у канала — время
    вниз до 5 минут, координаты до 4 знаков, ни устройства, ни адреса IP."""
    lines = [bot_texts.text(lang, "city_head", city=bot_texts.city_name(city, lang))]
    if not reports:
        return lines[0]
    digits = telegram_publish.COORD_DIGITS
    for report in reports:
        lat, lon = round(report["lat"], digits), round(report["lon"], digits)
        where = address_fn(report["lat"], report["lon"]) or f"{lat:.{digits}f}, {lon:.{digits}f}"
        lines.append(bot_texts.text(lang, "city_line", kind=_kind(lang, report["type"]), where=where,
                                    time=telegram_publish.local_time(report["created"]),
                                    link=telegram_publish.osm_link(lat, lon)))
    return lines[0] + "\n\n" + "\n\n".join(lines[1:])
