#!/usr/bin/env python3
"""Контролёр дороги: снимки главных перекрёстков и отчёт по дефектам.

Запускается на маке после сборки, ДО публикации (docs/plan_roads_quality.md,
этап Б). Сломанный перекрёсток должен быть виден в отчёте, а не на скриншоте
владельца.

    python3 server/road_review.py --roads ~/RadarMapBuild/tash/roads.geojsonl \\
        --viewer http://127.0.0.1:8770 --out ~/RadarMapBuild/review [--count 40]

Три шага:
  1. места — крупнейшие перекрёстки разных улиц (ядра build_mvt.crossing_cores);
  2. снимки — Chrome без окна (вкладка расширения бывает скрыта и не рисует),
     пустой кадр переснимается;
  3. проверка — если задан ANTHROPIC_API_KEY, каждый снимок смотрит модель по
     фиксированному чек-листу и отвечает JSON-ом; без ключа отчёт — для глаз.

Смотрит модель на НАШ рендер, а не на чужие снимки: это проверка алгоритма,
а не извлечение данных. Правится всегда алгоритм — одним исправлением на
класс дефекта, а не перекрёсток за перекрёстком.

Только stdlib, как весь server/.
"""
import argparse
import base64
import html
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
# Меньше этого — пустой кадр: карта не успела догрузиться.
BLANK_PNG_BYTES = 20_000
SHOT_ZOOM = 17.6
SHOT_SIZE = (1400, 900)
SHOT_ATTEMPTS = 3
SHOT_TIMEOUT_SECONDS = 90
# Два ядра ближе этого — один перекрёсток в отчёте.
PLACE_SEPARATION_METERS = 300.0

MODEL = os.environ.get("RADARMAP_REVIEW_MODEL", "claude-sonnet-5")
API_URL = "https://api.anthropic.com/v1/messages"

# Классы дефектов — те, что находились на снимках 28.09.2026. Новый класс
# добавляется сюда, а не в свободный текст ответа: иначе нечего считать.
DEFECTS = {
    "white_wedge": "белый клин или щель фона внутри асфальта или между лентами",
    "median_missing": "между встречными лентами проспекта нет разделительной там, где она явно должна быть",
    "median_in_junction": "зелёная/серая полоса разделительной заходит в середину перекрёстка",
    "markings_through_junction": "пунктир полос идёт сквозь площадь перекрёстка",
    "arrows_duplicated": "несколько рядов стрелок полос подряд на одном подходе",
    "road_gap": "разрыв или дыра в полотне дороги",
    "spike": "острый шип или клин асфальта, торчащий за кромку дороги",
    "waffle_offroad": "жёлтая сетка перекрёстка лежит вне асфальта (на воде, газоне, тротуаре)",
    "zebra_broken": "зебра веером, внахлёст или обрывком посреди полосы",
}
SEVERITIES = ("minor", "major")

PROMPT = """Ты проверяешь рендер карты дорог (наш собственный, не чужой) на дефекты геометрии.
На снимке перекрёсток крупным планом. Серое — асфальт, светло-зелёное — разделительные и
островки, белые линии — разметка, белые штрихи — зебры, жёлтая сетка — «вафля» перекрёстка.

Найди дефекты ТОЛЬКО из этого списка (ключ: описание):
{defects}

Ответь одним JSON без пояснений:
{{"defects": [{{"class": "<ключ>", "severity": "minor|major", "where": "<где на снимке, 3-8 слов>"}}]}}
Если дефектов нет — {{"defects": []}}. Не выдумывай: сомневаешься — не пиши."""


# --- 1. Места ---------------------------------------------------------------

def _area_m2(ring):
    kx = 111_320 * math.cos(math.radians(ring[0][1]))
    xy = [(x * kx, y * 111_320) for x, y in ring]
    return abs(sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(xy, xy[1:] + xy[:1]))) / 2


def pick_places(cores, count):
    """Крупнейшие ядра перекрёстков, по одному на место: [(lat, lon)]."""
    chosen = []
    for ring in sorted(cores, key=_area_m2, reverse=True):
        lon = sum(p[0] for p in ring) / len(ring)
        lat = sum(p[1] for p in ring) / len(ring)
        kx = 111_320 * math.cos(math.radians(lat))
        if any(math.hypot((lon - x) * kx, (lat - y) * 111_320) < PLACE_SEPARATION_METERS
               for y, x in chosen):
            continue
        chosen.append((lat, lon))
        if len(chosen) >= count:
            break
    return chosen


def places_from_roads(path, count):
    import build_mvt
    import build_roads
    raw = build_roads.collect(path)[0]
    roads = build_roads.generalise(raw, build_roads.SIMPLIFY_METERS / 111_320.0)
    major = [r for r in roads if r[0] <= 4]
    return pick_places(build_mvt.crossing_cores(major), count)


# --- 2. Снимки --------------------------------------------------------------

def shoot(viewer, style, lat, lon, target):
    """Снимок через Chrome без окна; True — кадр не пустой."""
    url = f"{viewer}/?style={style}#{SHOT_ZOOM}/{lat:.5f}/{lon:.5f}"
    for _attempt in range(SHOT_ATTEMPTS):
        profile = tempfile.mkdtemp(prefix="review-chrome-")
        try:
            if os.path.exists(target):
                os.remove(target)
            subprocess.run(
                [CHROME, "--headless=new", "--use-angle=swiftshader", "--enable-unsafe-swiftshader",
                 "--hide-scrollbars", f"--user-data-dir={profile}",
                 f"--window-size={SHOT_SIZE[0]},{SHOT_SIZE[1]}", "--virtual-time-budget=30000",
                 f"--screenshot={target}", url],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=SHOT_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            pass
        finally:
            shutil.rmtree(profile, ignore_errors=True)
        if os.path.exists(target) and os.path.getsize(target) > BLANK_PNG_BYTES:
            return True
    return False


# --- 3. Проверка ------------------------------------------------------------

def parse_review(text):
    """Ответ модели → список дефектов известных классов. Мусор — пусто, не ошибка
    всей проверки: один странный ответ не должен ронять отчёт по сорока местам."""
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end <= start:
        return None
    try:
        data = json.loads(text[start:end + 1])
    except ValueError:
        return None
    out = []
    for item in data.get("defects", []) if isinstance(data, dict) else []:
        if not isinstance(item, dict) or item.get("class") not in DEFECTS:
            continue
        severity = item.get("severity") if item.get("severity") in SEVERITIES else "minor"
        out.append({"class": item["class"], "severity": severity,
                    "where": str(item.get("where", ""))[:80]})
    return out


def review_image(path, key):
    with open(path, "rb") as handle:
        image = base64.b64encode(handle.read()).decode()
    prompt = PROMPT.format(defects="\n".join(f"- {k}: {v}" for k, v in DEFECTS.items()))
    body = {"model": MODEL, "max_tokens": 600,
            "messages": [{"role": "user", "content": [
                {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": image}},
                {"type": "text", "text": prompt}]}]}
    request = urllib.request.Request(
        API_URL, data=json.dumps(body).encode(),
        headers={"x-api-key": key, "anthropic-version": "2023-06-01",
                 "content-type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            answer = json.load(response)
    except urllib.error.HTTPError as error:
        # Текст ошибки API, а не голое «400»: «нет кредитов» и «битый запрос»
        # лечатся по-разному.
        detail = error.read().decode("utf-8", "replace")[:300]
        raise RuntimeError(f"HTTP {error.code}: {detail}") from error
    text = "".join(part.get("text", "") for part in answer.get("content", []))
    return parse_review(text)


def summarize(results):
    """{класс: [число major, число minor]} по всем местам."""
    counts = {key: [0, 0] for key in DEFECTS}
    for result in results:
        for defect in result.get("defects") or []:
            counts[defect["class"]][0 if defect["severity"] == "major" else 1] += 1
    return {key: value for key, value in counts.items() if any(value)}


# --- Отчёт ------------------------------------------------------------------

def write_report(out_dir, results, summary, reviewed):
    with open(os.path.join(out_dir, "report.json"), "w", encoding="utf-8") as handle:
        json.dump({"at": time.strftime("%Y-%m-%dT%H:%M:%S"), "reviewed": reviewed,
                   "summary": summary, "places": results}, handle, ensure_ascii=False, indent=1)
    rows = []
    for index, result in enumerate(results, 1):
        defects = result.get("defects")
        if defects is None:
            verdict = "не проверено" if not reviewed else "ответ не разобран"
        elif not defects:
            verdict = "дефектов нет"
        else:
            verdict = "<br>".join(f"<b>{html.escape(d['class'])}</b> ({d['severity']}): "
                                  f"{html.escape(d['where'])}" for d in defects)
        image = (f'<img src="{html.escape(result["image"])}" loading="lazy">'
                 if result.get("image") else "<div class=blank>кадр пустой</div>")
        rows.append(f'<figure>{image}<figcaption>{index}. {result["lat"]:.5f}, {result["lon"]:.5f}'
                    f' — {verdict}</figcaption></figure>')
    table = "".join(f"<tr><td>{html.escape(k)}</td><td>{html.escape(DEFECTS[k])}</td>"
                    f"<td>{v[0]}</td><td>{v[1]}</td></tr>" for k, v in summary.items())
    page = f"""<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Контролёр дороги</title>
<style>body{{font:14px -apple-system,sans-serif;margin:16px;background:#f6f6f4;color:#222}}
figure{{margin:0 0 16px;background:#fff;padding:8px;border-radius:8px}}
img{{width:100%;height:auto;display:block}}.blank{{padding:40px;text-align:center;color:#999}}
table{{border-collapse:collapse;margin:12px 0}}td,th{{border:1px solid #ccc;padding:4px 8px}}
.grid{{display:grid;grid-template-columns:repeat(auto-fill,minmax(420px,1fr));gap:12px}}</style></head>
<body><h1>Контролёр дороги</h1><p>Мест: {len(results)}. {'Проверено моделью ' + MODEL if reviewed else 'Без модели — отчёт для глаз.'}</p>
{'<table><tr><th>класс</th><th>что</th><th>major</th><th>minor</th></tr>' + table + '</table>' if reviewed else ''}
<div class=grid>{''.join(rows)}</div></body></html>"""
    with open(os.path.join(out_dir, "report.html"), "w", encoding="utf-8") as handle:
        handle.write(page)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--roads", required=True, help="экстракт дорог (geojsonl)")
    parser.add_argument("--viewer", default="http://127.0.0.1:8770", help="просмотрщик тайлов")
    parser.add_argument("--style", default="st_light_full.json")
    parser.add_argument("--out", required=True, help="каталог отчёта")
    parser.add_argument("--count", type=int, default=40)
    args = parser.parse_args()

    os.makedirs(args.out, exist_ok=True)
    places = places_from_roads(os.path.expanduser(args.roads), args.count)
    key = os.environ.get("ANTHROPIC_API_KEY", "")
    results = []
    for index, (lat, lon) in enumerate(places, 1):
        name = f"place_{index:03d}.png"
        ok = shoot(args.viewer, args.style, lat, lon, os.path.join(args.out, name))
        result = {"lat": lat, "lon": lon, "image": name if ok else None, "defects": None}
        if ok and key:
            try:
                result["defects"] = review_image(os.path.join(args.out, name), key)
            except Exception as error:     # одна сетевая ошибка не роняет отчёт
                print(f"  {index}: проверка не удалась: {error}", file=sys.stderr)
        results.append(result)
        found = ("не проверено" if result["defects"] is None
                 else f"{len(result['defects'])} дефектов")
        print(f"  {index}/{len(places)} {lat:.5f},{lon:.5f} "
              f"{'кадр' if ok else 'ПУСТО'}, {found}", flush=True)
    summary = summarize(results)
    write_report(args.out, results, summary, bool(key))
    print(f"отчёт: {os.path.join(args.out, 'report.html')}")
    for cls, (major, minor) in summary.items():
        print(f"  {cls}: major {major}, minor {minor}")


if __name__ == "__main__":
    main()
