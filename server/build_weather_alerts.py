#!/usr/bin/env python3
"""build_weather_alerts.py — официальные погодные предупреждения Узгидромета.

ПРОТОТИП: без cron и без выкладки. Наш `build_road_weather.py` сам выводит
опасность из прогноза Open-Meteo по 13 точкам; здесь — то, что объявило
ведомство: гололёд, туман, пыль, ветер, сели, лавины, с областью (полигоном),
началом, концом и уровнем 1–3.

Источник: CAP-лента Узгидромета, зарегистрированная в реестре WMO Alerting
Authorities, — Atom со ссылками на CAP 1.2 XML. В самой ленте
`<rights>public domain</rights>`; указываем «Узгидромет» как источник.
Лента физически лежит на meteoalert.meteoinfo.ru (сервер Росгидромета) — это
внешняя зависимость, а не наш выбор; своя карта alert.meteo.uz с января 2026
не обновляется.

Правило 20 из ARCHITECTURE.md: это подсказка водителю с источником и сроком,
она никогда не трогает оповещения о камерах.

Что делает: читает Atom, берёт ссылки на CAP только с хоста ленты, разбирает
каждое предупреждение (русский блок `info`, иначе первый), относит событие к
нашему виду (ice/snow/fog/wind/dust/rain/mudflow/avalanche/heat/frost/storm/
other), прореживает полигоны, выбрасывает истёкшие и снятые (`Cancel` по
`references`) и пишет один JSON.

    python3 build_weather_alerts.py --out /tmp/weather_alerts.json
Тесты (без сети, на выгрузке 02.11.2026 из server/fixtures/):
    python3 test_build_weather_alerts.py
"""
import argparse
import datetime
import json
import os
import re
import sys
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ElementTree

FEED_URL = "https://meteoalert.meteoinfo.ru/uzbekistan/cap-feed/ru/atom.xml"
SOURCE = "Узгидромет"
USER_AGENT = "RadarMap-data-scout/1.0"
TIMEOUT = 30
MAX_BYTES = 2_000_000
#: Сколько CAP читать за один проход: лента — снимок действующих, обычно 0–10.
MAX_ALERTS = 60
ATOM = "{http://www.w3.org/2005/Atom}"
CAP = "{urn:oasis:names:tc:emergency:cap:1.2}"
UZ_BBOX = (37.15, 45.6, 55.95, 73.2)
MAX_POLYGON_POINTS = 200

LEVELS = {"Minor": 1, "Moderate": 1, "Severe": 2, "Extreme": 3}
#: Вид события по словам заголовка (ru/uz/en). Порядок важен: «сели и
#: паводки» — mudflow, а не rain; «гололёд» — ice раньше «снега».
KINDS = (
    ("ice", r"гололе|гололё|скольз|изморос|\bice\b|\bicy\b|slipper|muzla|yaxmalak"),
    ("avalanche", r"лавин|avalanche|ko.chki"),
    ("mudflow", r"\bсел[ьеия ]|паводк|mudflow|flood|\bsel\b|sel-|toshqin"),
    ("fog", r"туман|\bfog\b|tuman"),
    ("dust", r"пыл|\bdust|chang"),
    ("snow", r"снег|метел|\bsnow|blizzard|\bqor\b"),
    ("wind", r"ветер|ветр|\bwind|shamol"),
    ("storm", r"гроз|град|thunder|\bhail|momaqaldiroq|do.l\b"),
    ("rain", r"дожд|ливн|\brain|yomg"),
    ("heat", r"жар|зно|\bheat|issiq"),
    ("frost", r"замороз|мороз|холод|frost|\bcold|sovuq"),
)


class FeedError(ValueError):
    pass


def safe_xml(data):
    """Разбор недоверенного XML: без DOCTYPE/ENTITY (защита от раздувания
    сущностями) и не больше MAX_BYTES."""
    if len(data) > MAX_BYTES:
        raise FeedError("документ больше предела")
    head = data[:4096].decode("utf-8", "replace") if isinstance(data, bytes) else data[:4096]
    if "<!DOCTYPE" in head or "<!ENTITY" in head:
        raise FeedError("DOCTYPE/ENTITY в ленте")
    return ElementTree.fromstring(data)


def cap_links(atom_bytes, feed_url=FEED_URL):
    """Atom → ссылки на CAP, только с того же хоста, что и лента."""
    root = safe_xml(atom_bytes)
    host = urllib.parse.urlsplit(feed_url).netloc
    links = []
    for entry in root.findall(ATOM + "entry"):
        for link in entry.findall(ATOM + "link"):
            href = link.get("href") or ""
            if link.get("type") == "application/cap+xml" and urllib.parse.urlsplit(href).netloc == host:
                links.append(href)
    return links[:MAX_ALERTS]


def event_kind(*texts):
    text = " ".join(t for t in texts if t).lower()
    for kind, pattern in KINDS:
        if re.search(pattern, text):
            return kind
    return "other"


def parse_time(text):
    if not text:
        return None
    try:
        moment = datetime.datetime.fromisoformat(text.strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    if moment.tzinfo is None:
        return None
    return moment.astimezone(datetime.timezone.utc)


def parse_polygon(text):
    points = []
    for pair in (text or "").split():
        try:
            lat, lon = (float(value) for value in pair.split(","))
        except ValueError:
            continue
        points.append((lat, lon))
    if len(points) > MAX_POLYGON_POINTS:
        step = -(-len(points) // MAX_POLYGON_POINTS)
        points = points[::step] + [points[-1]]
    return [[round(lat, 3), round(lon, 3)] for lat, lon in points]


def in_uzbekistan(polygon):
    south, north, west, east = UZ_BBOX
    return any(south <= lat <= north and west <= lon <= east for lat, lon in polygon)


def parse_cap(cap_bytes, link=""):
    """CAP 1.2 → предупреждение или None (тест, учения, без срока, вне страны)."""
    root = safe_xml(cap_bytes)
    if root.tag != CAP + "alert":
        raise FeedError("не CAP 1.2")
    status = root.findtext(CAP + "status")
    if status != "Actual":
        return None
    infos = root.findall(CAP + "info")
    if not infos:
        return None
    info = next((i for i in infos if (i.findtext(CAP + "language") or "").lower().startswith("ru")), infos[0])
    english = next((i for i in infos if (i.findtext(CAP + "language") or "").lower().startswith("en")), None)
    expires = parse_time(info.findtext(CAP + "expires"))
    if expires is None:
        return None
    event = (info.findtext(CAP + "event") or "").strip()
    polygons, areas = [], []
    for area in info.findall(CAP + "area"):
        if area.findtext(CAP + "areaDesc"):
            areas.append(area.findtext(CAP + "areaDesc").strip())
        for polygon in area.findall(CAP + "polygon"):
            points = parse_polygon(polygon.text)
            if len(points) >= 3:
                polygons.append(points)
    if polygons and not any(in_uzbekistan(p) for p in polygons):
        return None
    onset = parse_time(info.findtext(CAP + "onset")) or parse_time(info.findtext(CAP + "effective"))
    references = [part.split(",")[1] for part in (root.findtext(CAP + "references") or "").split()
                  if part.count(",") >= 2]
    return {
        "id": (root.findtext(CAP + "identifier") or "").strip(),
        "msg": root.findtext(CAP + "msgType") or "Alert",
        "references": references,
        "kind": event_kind(event, english.findtext(CAP + "event") if english is not None else ""),
        "event": event,
        "level": LEVELS.get(info.findtext(CAP + "severity") or "", 1),
        "onset": onset.isoformat() if onset else None,
        "expires": expires.isoformat(),
        "area": ", ".join(areas),
        "polygons": polygons,
        "link": link,
    }


def assemble(alerts, now):
    """Снятые и заменённые — вон, истёкшие — вон, остальное по началу."""
    cancelled = {ref for alert in alerts if alert["msg"] in ("Cancel", "Update") for ref in alert["references"]}
    live = []
    for alert in alerts:
        if alert["msg"] == "Cancel" or alert["id"] in cancelled:
            continue
        if parse_time(alert["expires"]) <= now:
            continue
        item = {key: alert[key] for key in ("id", "kind", "event", "level", "onset", "expires",
                                            "area", "polygons", "link")}
        live.append(item)
    live.sort(key=lambda a: (a["onset"] or "", -a["level"]))
    return {"v": 1, "source": SOURCE, "license": "public domain (CAP-лента Узгидромета, реестр WMO)",
            "generated": now.isoformat(), "alerts": live}


def http_get(url):
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        data = response.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise FeedError("ответ больше предела")
    return data


def collect(feed_url=FEED_URL, now=None, fetch=http_get):
    now = now or datetime.datetime.now(datetime.timezone.utc)
    alerts, errors = [], []
    for link in cap_links(fetch(feed_url), feed_url):
        try:
            alert = parse_cap(fetch(link), link)
        except (OSError, FeedError, ElementTree.ParseError) as error:
            errors.append(f"{link}: {error}")
            continue
        if alert:
            alerts.append(alert)
    return assemble(alerts, now), errors


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--feed", default=FEED_URL)
    parser.add_argument("--out", required=True)
    args = parser.parse_args(argv)
    payload, errors = collect(args.feed)
    for error in errors:
        print("  ! " + error, file=sys.stderr)
    with open(args.out + ".tmp", "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, separators=(",", ":"))
    os.replace(args.out + ".tmp", args.out)
    print(f"предупреждений {len(payload['alerts'])}, ошибок {len(errors)}")


if __name__ == "__main__":
    main()
