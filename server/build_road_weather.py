#!/usr/bin/env python3
"""Погода на трассах (этап 19.1): open-meteo → weather/roads.json для телефонов.

Перевал Камчик (A373) и Тахтакарача (M39) — самые опасные места дальней
поездки: снег, гололёд и туман там бывают, когда в Ташкенте сухо и тепло.
Сборщик раз в 30 минут берёт прогноз для заданных точек
(road_weather_points.json, список проверяет владелец) и пишет, где сейчас или
в ближайшие 6 часов опасно.

Запуск — cron на VPS (stdlib, без pip):
    */30 * * * * python3 /opt/radarmap/api/build_road_weather.py >> /var/log/radarmap-weather.log 2>&1

Источник — Open-Meteo (https://open-meteo.com), данные по лицензии CC BY 4.0:
подпись «Weather data by Open-Meteo.com» стоит в «Источниках данных»
приложения и в server/ATTRIBUTION.md. Бесплатный API — для некоммерческого
использования, до 10 000 вызовов в сутки; у нас одна пачка из N точек раз в
30 минут — 48·N в сутки (13 точек — 624).

Один запрос на все точки: latitude и longitude — списки через запятую, ответ
— массив объектов в том же порядке (для одной точки — один объект). Часовые
ряды: temperature_2m (°C), precipitation (мм за час), snowfall (см за час),
visibility (м), wind_speed_10m (м/с — просим wind_speed_unit=ms; если вдруг
придут км/ч, переводим), weather_code (WMO). Время — unixtime в UTC.

Опасность — по каждому часу окна [текущий час, сейчас + 6 ч]:
  * snow — снегопад: snowfall ≥ 0,1 см/ч или код WMO снега (71–77, 85, 86);
  * ice  — гололёд: t ≤ 0 °C и осадки ≥ 0,1 мм/ч, или код ледяной мороси и
           дождя (56, 57, 66, 67);
  * fog  — туман: видимость < 200 м;
  * wind — сильный ветер: ≥ 15 м/с.
Пропуск значения (null) — не опасность: о чём не знаем, о том молчим. Это
обратное правилу камер, и так задумано: камера на месте — факт, а погода —
прогноз, и выдуманный «гололёд» стоит доверия ко всему приложению.

Выход — атомарно в webroot, только если что-то изменилось:
    {"v": 1, "generated": t, "points": [
      {"id", "group", "kind", "road", "lat", "lon", "r",
       "name": {"ru", "uz"}, "where": {"ru", "uz"},
       "hazards": [{"k": "fog", "from": t, "to": t}, …],
       "until": t | null, "t": °C | null, "vis": м | null}]}
Точка с координатами и названиями едет в файле, а не в приложении: телефон
решает сам, лежит ли она на его пути (место телефона сервер не узнаёт), а
список точек можно поправить без релиза. `until` — конец последнего опасного
часа в окне, `t` и `vis` — значения текущего часа. Файл переписывается, если
изменились точки, или раз в REWRITE_EVERY — чтобы `generated` не устарел:
телефон считает файл старше двух часов отсутствием данных. Когда open-meteo
не ответил, файл не трогается и сам стареет — это и есть «данных нет».

Погода — данные для показа и спокойной фразы; на оповещения о камерах не
влияет никак (ARCHITECTURE.md, правило 20), поэтому файл не подписывается.
"""
import argparse
import json
import math
import os
import sys
import time
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
POINTS_PATH = os.path.join(HERE, "road_weather_points.json")
OUT_PATH = "/opt/radarmap/www/weather/roads.json"

API = "https://api.open-meteo.com/v1/forecast"
HOURLY = ("temperature_2m", "precipitation", "snowfall", "visibility", "wind_speed_10m", "weather_code")
TIMEOUT = 20                  # секунд на ответ: cron раз в 30 минут, ждать дольше незачем
OUTPUT_VERSION = 1
HORIZON = 6 * 3600            # «сейчас и ближайшие 6 часов»
HOUR = 3600
REWRITE_EVERY = 3600          # неизменный файл всё равно обновляется раз в час (телефону — свежесть)

SNOW_CM = 0.1                 # см снега за час — уже снегопад
PRECIP_MM = 0.1               # мм осадков за час — уже мокро
ICE_MAX_C = 0.0               # t ≤ 0 °C и мокро — гололёд
FOG_VIS_M = 200.0             # видимость ниже — туман
WIND_MS = 15.0                # м/с у земли — сильный ветер
SNOW_CODES = {71, 73, 75, 77, 85, 86}
FREEZING_CODES = {56, 57, 66, 67}
HAZARDS = ("ice", "snow", "fog", "wind")   # по важности: телефон называет первые

KINDS = ("pass", "plain")
UZ_BBOX = (37.1, 45.6, 55.9, 73.2)         # широта мин/макс, долгота мин/макс
RADIUS_RANGE = (500, 30_000)


class FormatError(ValueError):
    """Ответ open-meteo или список точек не того вида — файл не пишем."""


# --- Точки ---------------------------------------------------------------

def load_points(path=POINTS_PATH):
    with open(path, encoding="utf-8") as f:
        body = json.load(f)
    return validate_points(body)


def validate_points(body):
    """Список точек — со строгой проверкой: ошибка в нём (точка в Казахстане,
    пустое название) уехала бы на все телефоны."""
    if not isinstance(body, dict) or body.get("v") != 1 or not isinstance(body.get("points"), list):
        raise FormatError("road_weather_points.json: ждали {\"v\": 1, \"points\": [...]}")
    points, seen = [], set()
    for raw in body["points"]:
        pid = raw.get("id")
        if not isinstance(pid, str) or not pid or pid in seen:
            raise FormatError(f"точка без id или повтор: {pid!r}")
        seen.add(pid)
        lat, lon, radius = raw.get("lat"), raw.get("lon"), raw.get("r")
        if not all(isinstance(v, (int, float)) for v in (lat, lon, radius)):
            raise FormatError(f"{pid}: lat/lon/r не числа")
        if not (UZ_BBOX[0] <= lat <= UZ_BBOX[1] and UZ_BBOX[2] <= lon <= UZ_BBOX[3]):
            raise FormatError(f"{pid}: точка вне Узбекистана")
        if not RADIUS_RANGE[0] <= radius <= RADIUS_RANGE[1]:
            raise FormatError(f"{pid}: r вне {RADIUS_RANGE}")
        if raw.get("kind") not in KINDS:
            raise FormatError(f"{pid}: kind не из {KINDS}")
        for field in ("name", "where"):
            text = raw.get(field)
            if not isinstance(text, dict) or not all(isinstance(text.get(k), str) and text[k].strip()
                                                     for k in ("ru", "uz")):
                raise FormatError(f"{pid}: {field} без ru или uz")
        group = raw.get("group", pid)
        if not isinstance(group, str) or not group:
            raise FormatError(f"{pid}: group пустой")
        points.append({
            "id": pid, "group": group, "kind": raw["kind"], "road": str(raw.get("road", "")),
            "lat": float(lat), "lon": float(lon), "r": int(radius),
            "name": {"ru": raw["name"]["ru"], "uz": raw["name"]["uz"]},
            "where": {"ru": raw["where"]["ru"], "uz": raw["where"]["uz"]},
        })
    if not points:
        raise FormatError("список точек пуст")
    return points


# --- Запрос ----------------------------------------------------------------

def forecast_url(points, base=API):
    query = {
        "latitude": ",".join(f"{p['lat']:.5f}" for p in points),
        "longitude": ",".join(f"{p['lon']:.5f}" for p in points),
        "hourly": ",".join(HOURLY),
        "wind_speed_unit": "ms",
        "timeformat": "unixtime",
        "timezone": "GMT",
        # Ряд начинается с текущего часа: 7 значений — сейчас и 6 часов вперёд.
        "forecast_hours": str(HORIZON // HOUR + 1),
    }
    return base + "?" + urllib.parse.urlencode(query, safe=",")


def fetch(points, base=API, timeout=TIMEOUT):
    request = urllib.request.Request(forecast_url(points, base),
                                     headers={"User-Agent": "RadarMap-road-weather/1"})
    with urllib.request.urlopen(request, timeout=timeout) as answer:
        return json.loads(answer.read().decode("utf-8"))


# --- Разбор ----------------------------------------------------------------

def _series(hourly, name, size):
    values = hourly.get(name)
    if values is None:
        return [None] * size
    if not isinstance(values, list) or len(values) != size:
        raise FormatError(f"ряд {name}: не той длины")
    return [v if isinstance(v, (int, float)) and math.isfinite(v) else None for v in values]


def wind_factor(units):
    """Множитель в м/с по единице ряда ветра; None — единица незнакома."""
    unit = (units or {}).get("wind_speed_10m", "m/s")
    return {"m/s": 1.0, "km/h": 1 / 3.6, "kn": 0.514444, "mp/h": 0.44704}.get(unit)


def hour_hazards(t, precip, snow, vis, wind, code):
    """Опасности одного часа (множество из HAZARDS)."""
    found = set()
    if (snow is not None and snow >= SNOW_CM) or code in SNOW_CODES:
        found.add("snow")
    if (t is not None and precip is not None and t <= ICE_MAX_C and precip >= PRECIP_MM) \
            or code in FREEZING_CODES:
        found.add("ice")
    if vis is not None and vis < FOG_VIS_M:
        found.add("fog")
    if wind is not None and wind >= WIND_MS:
        found.add("wind")
    return found


def assess(location, now):
    """Одна точка ответа → (окна опасностей, t сейчас, видимость сейчас).
    Окно — [начало первого часа, конец последнего] подряд идущих часов с той
    же опасностью; час — с отметки T до T + 1 ч."""
    if not isinstance(location, dict) or not isinstance(location.get("hourly"), dict):
        raise FormatError("точка ответа без hourly")
    hourly, units = location["hourly"], location.get("hourly_units") or {}
    times = hourly.get("time")
    if not isinstance(times, list) or not times or not all(isinstance(v, (int, float)) for v in times):
        raise FormatError("ряд time пуст или не unixtime")
    if units.get("time", "unixtime") != "unixtime":
        raise FormatError("время не unixtime")
    if units.get("temperature_2m", "°C") != "°C":
        raise FormatError("температура не в °C")
    size = len(times)
    temp = _series(hourly, "temperature_2m", size)
    precip = _series(hourly, "precipitation", size)
    snow = _series(hourly, "snowfall", size)
    vis = _series(hourly, "visibility", size)
    code = _series(hourly, "weather_code", size)
    factor = wind_factor(units)
    wind = [None if v is None or factor is None else v * factor
            for v in _series(hourly, "wind_speed_10m", size)]

    windows = {}
    current = None
    for i, start in enumerate(times):
        start = int(start)
        if start <= now:
            current = i   # последний начавшийся час — «сейчас»
        if start + HOUR <= now or start > now + HORIZON:
            continue
        hour_code = int(code[i]) if code[i] is not None else None
        for kind in hour_hazards(temp[i], precip[i], snow[i], vis[i], wind[i], hour_code):
            spans = windows.setdefault(kind, [])
            if spans and spans[-1][1] == start:
                spans[-1][1] = start + HOUR
            else:
                spans.append([start, start + HOUR])
    if current is None:
        current = 0
    hazards = [{"k": kind, "from": span[0], "to": span[1]}
               for kind in HAZARDS for span in windows.get(kind, [])]
    t_now = round(temp[current], 1) if temp[current] is not None else None
    vis_now = int(round(vis[current] / 10.0) * 10) if vis[current] is not None else None
    return hazards, t_now, vis_now


def build(points, response, now):
    """Ответ open-meteo → тело roads.json. Число точек ответа обязано совпасть:
    иначе мы приписали бы погоду Камчика Чиназу."""
    locations = response if isinstance(response, list) else [response]
    if len(locations) != len(points):
        raise FormatError(f"точек в ответе {len(locations)}, ждали {len(points)}")
    out = []
    for point, location in zip(points, locations):
        hazards, t_now, vis_now = assess(location, now)
        out.append({
            "id": point["id"], "group": point["group"], "kind": point["kind"], "road": point["road"],
            "lat": round(point["lat"], 5), "lon": round(point["lon"], 5), "r": point["r"],
            "name": point["name"], "where": point["where"],
            "hazards": hazards,
            "until": max((h["to"] for h in hazards), default=None),
            "t": t_now, "vis": vis_now,
        })
    return {"v": OUTPUT_VERSION, "generated": int(now), "points": out}


# --- Запись ----------------------------------------------------------------

def needs_write(path, body, now, rewrite_every=REWRITE_EVERY):
    """Писать ли: точки изменились, файла нет или он битый, или прошлой
    записи больше `rewrite_every` (иначе телефон счёл бы его устаревшим)."""
    try:
        with open(path, encoding="utf-8") as f:
            current = json.load(f)
    except FileNotFoundError:
        return True
    except (OSError, ValueError) as error:
        print(f"roads.json не прочитан ({error}) — перезапись", file=sys.stderr)
        return True
    if not isinstance(current, dict) or current.get("v") != body["v"] or current.get("points") != body["points"]:
        return True
    generated = current.get("generated")
    return not isinstance(generated, (int, float)) or now - generated >= rewrite_every


def write_atomic(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def run(points, response, now, out_path=OUT_PATH):
    """Один прогон без сети (main и тесты). Возвращает (тело, записан ли файл)."""
    body = build(points, response, now)
    written = needs_write(out_path, body, now)
    if written:
        write_atomic(out_path, json.dumps(body, ensure_ascii=False, separators=(",", ":")))
    return body, written


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--points", default=POINTS_PATH)
    parser.add_argument("--out", default=OUT_PATH)
    parser.add_argument("--response", help="ответ open-meteo из файла вместо запроса (проверка без сети)")
    parser.add_argument("--dry-run", action="store_true", help="напечатать тело, файл не писать")
    args = parser.parse_args(argv)
    stamp = time.strftime("%Y-%m-%dT%H:%M:%S")
    try:
        points = load_points(args.points)
    except (OSError, ValueError) as error:
        print(f"{stamp} список точек не прочитан: {error}", file=sys.stderr)
        return 1
    now = time.time()
    try:
        if args.response:
            with open(args.response, encoding="utf-8") as f:
                response = json.load(f)
        else:
            response = fetch(points)
    except (OSError, ValueError) as error:
        # Сеть, HTTP-ошибка, таймаут, не JSON. Файл не трогаем: он сам
        # состарится, и телефон замолчит через 2 часа — это и есть «нет данных».
        print(f"{stamp} open-meteo не ответил: {error}", file=sys.stderr)
        return 1
    # Замка, как у пробок, нет: прогон ограничен TIMEOUT (cron — раз в 30 мин),
    # а два прогона разом лишь дважды запишут одно и то же атомарной заменой.
    try:
        if args.dry_run:
            print(json.dumps(build(points, response, now), ensure_ascii=False, indent=1))
            return 0
        body, written = run(points, response, now, out_path=args.out)
    except FormatError as error:
        print(f"{stamp} ответ не того вида: {error} — файл не тронут", file=sys.stderr)
        return 1
    risky = [f"{p['id']}:{'+'.join(h['k'] for h in p['hazards'])}" for p in body["points"] if p["hazards"]]
    print(f"{stamp} точек {len(body['points'])}, опасно {len(risky)}"
          f"{' (' + ', '.join(risky) + ')' if risky else ''}, файл {'записан' if written else 'без изменений'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
