#!/usr/bin/env python3
"""Стиль карты RadarMap: OpenMapTiles (OSM, наша сборка Planetiler) + наши слои дороги.

Основа — OSM Bright (openmaptiles/osm-bright-gl-style, BSD; иконки CC-BY),
лежит рядом как osm-bright.json. Поверх — то, чего нет ни в одной открытой
схеме, а у нас есть: полотно по измеренной ширине, разметка полос,
разделительные, площади перекрёстков, зебры, стрелки, светофоры (build_mvt.py).

Две оси выбора:
* тема — light (палитра снята со скриншота Яндекс.Карт 28.09.2026) или dark
  (для езды ночью: светлая карта в тёмной кабине слепит);
* режим — full (как у Яндекса: дома, POI, подписи всего) или roads («только
  дорога», просьба владельца 28.09.2026: дорога красиво, остальное не нужно —
  вода и зелень остаются приглушёнными только для ориентира).

С 15-го зума проезжую часть рисует НАШ слой: у него ширина лент подогнана по
измеренному расстоянию осей, и из той же геометрии посчитаны разметка, зебры и
разделительные. Две геометрии дороги на одном экране — пунктир мимо полотна.

    python3 server/omt/make_style.py https://soulmed.uz/radarmap [--theme dark] [--mode roads]
"""
import copy
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
M = 1.7e-5            # метров → пикселей: px = m · 2^z · M (тайл 512, широта Ташкента)
OUR_ROADS_FROM = 15   # с этого зума полотно — наше
# Ширина ОДНОЙ ленты проспекта с раздельными направлениями — чуть больше
# половины ширины класса. Иначе две встречные ленты накрывают разделительную,
# и проспект сливается в одну серую полосу (Навои × Рашидов).
ONEWAY_SHARE = 0.55
# Ширина по классу OpenMapTiles, метры (до 15-го зума — там наших лент нет).
CLASS_M = {"motorway": 32, "trunk": 30, "primary": 24, "secondary-tertiary": 16, "link": 8,
           "motorway-link": 9, "minor": 9, "service-track": 5.5, "path": 2.5, "path-steps": 2.5}
MAJOR = {"motorway", "trunk", "primary", "secondary-tertiary", "link", "motorway-link"}

PALETTES = {
    "light": {
        "bg": "#f5f4f1", "park": "#cfe9b8", "wood": "#c3e3a6", "water": "#9fd2f5",
        "road": "#b9c0cc", "road_far": "#fdf3cf", "edge": "#efcb4a",
        "minor": "#ffffff", "minor_edge": "#c9ced6", "minor_edge_far": "#e6e6e3", "path": "#ffffff",
        "median": "#dfe5d6", "paint": "#ffffff", "building": "#e7e2de", "landuse": None,
        # Кайма НАШИХ лент — нейтральная: жёлтая у каждой ленты давала «нитки»
        # внутри асфальта там, где две ленты лежат рядом (Фурката, 28.09.2026).
        "casing": "#aab2bf",
        "label": "#4a4a4a", "halo": "#ffffff", "signal": "#3b3b3b", "signal_ring": "#f5d547",
    },
    "dark": {
        "bg": "#0f1216", "park": "#16241b", "wood": "#14221a", "water": "#1b3348",
        "road": "#3b414b", "road_far": "#4b4536", "edge": "#b8923a",
        "minor": "#262b33", "minor_edge": "#1a1e24", "minor_edge_far": "#1a1e24", "path": "#20252c",
        "median": "#1c2a22", "paint": "#d9dee6", "building": "#1c2027", "landuse": "#151a21",
        "casing": "#2b3039",
        "label": "#c9ced6", "halo": "#0f1216", "signal": "#101318", "signal_ring": "#f0c64a",
    },
}

# «Только дорога»: что из основы остаётся. Остальные исходные слои OSM Bright
# (POI, дома, номера домов, аэродромы, границы, щиты, прочая застройка) — нет.
ROADS_KEEP_LAYERS = {"transportation", "transportation_name", "water", "waterway", "park"}
ROADS_KEEP_IDS = {"background", "landcover-grass", "landcover-grass-park", "landcover-wood"}


def class_width(metres, extra=0.0, low=0.6):
    """Ширина линии OpenMapTiles по классу; у односторонней ленты — доля ONEWAY_SHARE."""
    def stop(z):
        full = max(low + extra, metres * (2 ** z) * M + extra)
        half = max(low + extra, metres * ONEWAY_SHARE * (2 ** z) * M + extra)
        return ["case", ["==", ["get", "oneway"], 1], half, full]
    return ["interpolate", ["exponential", 2], ["zoom"], 10, stop(10), 13, stop(13), 16, stop(16), 20, stop(20)]


def measured(extra=0.0, low=1.0):
    """Ширина нашей ленты: свойство width (м) из тайла, как в EngineMapStyle.roadWidth."""
    def stop(z):
        return ["max", ["+", ["*", ["coalesce", ["get", "width"], 8], (2 ** z) * M], extra], low + extra]
    return ["interpolate", ["exponential", 2], ["zoom"], 15, stop(15), 18, stop(18), 20, stop(20)]


def _road_kind(layer_id):
    return next((k for k in sorted(CLASS_M, key=len, reverse=True)
                 if layer_id.endswith(k) or layer_id.endswith(k + "-casing")), None)


def _base_layer(layer, p, mode):
    """Слой OSM Bright, перекрашенный в палитру; None — слоя в этом режиме нет."""
    l = copy.deepcopy(layer)
    i = l["id"]
    src = l.get("source-layer")
    paint = l.setdefault("paint", {})
    if mode == "roads" and i not in ROADS_KEEP_IDS and src not in ROADS_KEEP_LAYERS:
        return None
    if i == "background":
        paint["background-color"] = p["bg"]
    elif i.startswith("landuse-residential") or i == "landuse-railway":
        paint["fill-color"] = p["bg"]
    elif i in ("landcover-grass", "landcover-grass-park"):
        paint["fill-color"] = p["park"]
        paint["fill-opacity"] = 0.55 if mode == "roads" else 1
    elif i == "landcover-wood":
        paint["fill-color"] = p["wood"]
        paint["fill-opacity"] = 0.55 if mode == "roads" else 1
    elif i in ("water", "water-intermittent", "water-offset"):
        paint["fill-color"] = p["water"]
    elif i == "water-pattern" or i.startswith("road_oneway"):
        return None      # волны и стрелки вдоль всей улицы — шум
    elif i.startswith("waterway") and l["type"] == "line":
        paint["line-color"] = p["water"]
    elif l["type"] == "fill" and (i.startswith("landuse-") or i.startswith("landcover-")) and p["landuse"]:
        # Прочая застройка и покров (кладбища, больницы, школы, промзоны, песок):
        # в OSM Bright — пастель, на тёмной теме каждая горела пятном.
        paint["fill-color"] = p["landuse"]
        paint.pop("fill-pattern", None)
    elif i in ("highway-area", "road_area_pier"):
        # Пешеходные площади и пирсы. В OSM Bright — светло-серая заливка, на
        # тёмной теме она горела пятном ярче проспекта (Аллея парадов).
        paint["fill-color"] = p["path"]
        paint["fill-opacity"] = 0.6
    elif i in ("building", "building-top"):
        return None      # заменяются объёмными (режим full)
    elif src == "transportation" and l["type"] == "line":
        kind = _road_kind(i)
        if not kind or i.startswith("railway") or "construction" in i:
            return l
        casing = i.endswith("-casing")
        major = kind in MAJOR
        metres = CLASS_M[kind]
        if kind.startswith("path"):
            paint["line-color"] = p["minor_edge"] if casing else p["path"]
            paint["line-width"] = class_width(metres, 1.2 if casing else 0, 0.4)
            paint.pop("line-dasharray", None)
            if mode == "roads":
                paint["line-opacity"] = 0.5
        else:
            if casing:
                paint["line-color"] = p["edge"] if major else \
                    ["interpolate", ["linear"], ["zoom"], 13, p["minor_edge_far"], 15, p["minor_edge"]]
            else:
                # Вдали магистраль светлая с жёлтой каймой (читается как «главная»),
                # вблизи — асфальт, на котором видна разметка. Как у Яндекса.
                paint["line-color"] = ["interpolate", ["linear"], ["zoom"], 13, p["road_far"], 15.5, p["road"]] \
                    if major else p["minor"]
            paint["line-width"] = class_width(metres, (2.0 if major else 1.4) if casing else 0.0)
            paint["line-opacity"] = 1 if major else ["interpolate", ["linear"], ["zoom"], 12.5, 0, 13.5, 1]
            l["maxzoom"] = OUR_ROADS_FROM
        l.setdefault("layout", {}).update({"line-cap": "round", "line-join": "round"})
    elif l["type"] == "symbol" and src == "transportation_name":
        lay = l.setdefault("layout", {})
        lay.update({"text-transform": "uppercase", "text-letter-spacing": 0.08,
                    # Реже и не впритык: каждая встречная лента подписана своей
                    # строкой, и при шаге по умолчанию одно имя стояло восемь раз.
                    "symbol-spacing": 520, "text-padding": 24, "text-font": ["Noto Sans Bold"]})
        paint.update({"text-color": p["label"], "text-halo-color": p["halo"], "text-halo-width": 1.6})
    elif l["type"] == "symbol":
        paint["text-halo-color"] = p["halo"]
        if "text-color" in paint and mode == "full" and p is PALETTES["dark"]:
            paint["text-color"] = p["label"]
    return l


def _our_layers(p):
    """Наши слои, снизу вверх: каймы, полотна, площади узлов, разделительные,
    разметка, зебры, стрелки, светофоры."""
    return [
        # Разделительные и островки — ПОД полотном. Они построены по осям и не
        # знают ширины лент: поверх полотна островок ложился бледным
        # треугольником на полосы (Навои × Абая, 28.09.2026). Под полотном он
        # остаётся землёй ровно в зазоре между лентами — как у Яндекса.
        {"id": "radar-median", "type": "fill", "source": "radar", "source-layer": "surface", "minzoom": 15.5,
         "filter": ["all", ["==", ["geometry-type"], "Polygon"], ["==", ["get", "kind"], 9]],
         "paint": {"fill-color": p["median"], "fill-outline-color": p["minor_edge"]}},
        {"id": "radar-roads-case", "type": "line", "source": "radar", "source-layer": "roads",
         "minzoom": OUR_ROADS_FROM, "filter": ["all", ["<=", ["get", "cls"], 7], ["!", ["has", "stub"]]],
         "layout": {"line-cap": "round", "line-join": "round", "line-sort-key": ["-", 0, ["get", "cls"]]},
         "paint": {"line-color": ["case", ["<=", ["get", "cls"], 5], p["casing"], p["minor_edge"]],
                   "line-width": measured(2.0)}},
        {"id": "radar-roads", "type": "line", "source": "radar", "source-layer": "roads",
         "minzoom": OUR_ROADS_FROM, "filter": ["all", ["<=", ["get", "cls"], 7], ["!", ["has", "stub"]]],
         "layout": {"line-cap": "round", "line-join": "round", "line-sort-key": ["-", 0, ["get", "cls"]]},
         "paint": {"line-color": ["case", ["<=", ["get", "cls"], 5], p["road"], p["minor"]],
                   "line-width": measured()}},
        # Короткие широкие куски (stub) — с прямыми концами: скругление делало
        # из них «шар» шире соседних лент. Стык закрывают концы соседей.
        {"id": "radar-roads-stub", "type": "line", "source": "radar", "source-layer": "roads",
         "minzoom": OUR_ROADS_FROM, "filter": ["all", ["<=", ["get", "cls"], 7], ["has", "stub"]],
         "layout": {"line-cap": "butt", "line-join": "round"},
         "paint": {"line-color": ["case", ["<=", ["get", "cls"], 5], p["road"], p["minor"]],
                   "line-width": measured()}},
        # Галтели (вид 13): скруглённый бордюр на углах перекрёстка — асфальт
        # между точкой встречи кромок и дугой, как у Яндекса.
        {"id": "radar-fillet", "type": "fill", "source": "radar", "source-layer": "surface",
         "minzoom": OUR_ROADS_FROM,
         "filter": ["all", ["==", ["geometry-type"], "Polygon"], ["==", ["get", "kind"], 13]],
         "paint": {"fill-color": ["case", ["get", "major"], p["road"], p["minor"]], "fill-antialias": True}},
        # Площадь перекрёстка: скругляет углы между подходами. Узлы строятся
        # только там, где сходится дорога шире 9 м, и обрезаны кругом
        # досягаемости — цвет магистрального асфальта им честен.
        {"id": "radar-junction", "type": "fill", "source": "radar", "source-layer": "surface",
         "minzoom": OUR_ROADS_FROM,
         "filter": ["all", ["==", ["geometry-type"], "Polygon"], ["in", ["get", "kind"], ["literal", [8, 10]]]],
         "paint": {"fill-color": p["road"], "fill-antialias": False}},
        # «Вафля» регулируемого перекрёстка (вид 11): зона между стоп-линиями,
        # очерченная светофорами подходов (build_mvt.waffle_zone). Как у Яндекса.
        {"id": "radar-waffle", "type": "fill", "source": "radar", "source-layer": "surface", "minzoom": 17,
         "filter": ["all", ["==", ["geometry-type"], "Polygon"], ["==", ["get", "kind"], 11]],
         "paint": {"fill-pattern": "waffle", "fill-opacity": 0.8}},
        {"id": "radar-waffle-edge", "type": "line", "source": "radar", "source-layer": "surface", "minzoom": 17,
         "filter": ["all", ["==", ["geometry-type"], "Polygon"], ["==", ["get", "kind"], 11]],
         "paint": {"line-color": "#f2c230", "line-width": 1.2, "line-opacity": 0.85}},
        # Зебры: штрихи вдоль движения, толщина — ширина полосы зебры.
        {"id": "radar-crossing", "type": "line", "source": "radar", "source-layer": "paint", "minzoom": 16.5,
         "filter": ["==", ["get", "kind"], 5],
         "paint": {"line-color": p["paint"],
                   "line-width": ["interpolate", ["exponential", 2], ["zoom"], 16.5, 2, 20, 10]}},
        # Мосты и эстакады — поверх всего полотна: иначе эстакада Фурката лежала
        # под перекрёстком Навои, будто её там нет.
        {"id": "radar-bridge-case", "type": "line", "source": "radar", "source-layer": "roads",
         "minzoom": OUR_ROADS_FROM, "filter": ["all", ["<=", ["get", "cls"], 7], ["==", ["get", "bridge"], True]],
         "layout": {"line-cap": "butt", "line-join": "round"},
         "paint": {"line-color": p["casing"], "line-width": measured(3.0)}},
        {"id": "radar-bridge", "type": "line", "source": "radar", "source-layer": "roads",
         "minzoom": OUR_ROADS_FROM, "filter": ["all", ["<=", ["get", "cls"], 7], ["==", ["get", "bridge"], True]],
         "layout": {"line-cap": "butt", "line-join": "round"},
         "paint": {"line-color": ["case", ["<=", ["get", "cls"], 5], p["road"], p["minor"]],
                   "line-width": measured()}},
        {"id": "radar-markings", "type": "line", "source": "radar", "source-layer": "markings", "minzoom": 16,
         "layout": {"line-cap": "butt"},
         "paint": {"line-color": p["paint"], "line-dasharray": [4, 5],
                   "line-width": ["interpolate", ["exponential", 2], ["zoom"], 16, 0.8, 20, 3]}},
        # Зебра линией перехода (вид 12): ширина линии — длина штриха зебры
        # (3 м), пунктир — сами штрихи поперёк; одним куском от кромки до кромки.
        {"id": "radar-zebra", "type": "line", "source": "radar", "source-layer": "paint", "minzoom": 16.5,
         "filter": ["==", ["get", "kind"], 12],
         "layout": {"line-cap": "butt"},
         "paint": {"line-color": p["paint"], "line-dasharray": [0.18, 0.18],
                   "line-width": ["interpolate", ["exponential", 2], ["zoom"],
                                  16.5, 3 * 2 ** 16.5 * M, 20, 3 * 2 ** 20 * M]}},
        # Стоп-линии (тег и у светофоров): сплошная, ~0,45 м.
        {"id": "radar-stop-line", "type": "line", "source": "radar", "source-layer": "paint", "minzoom": 16.5,
         "filter": ["in", ["get", "kind"], ["literal", [1, 3]]],
         "layout": {"line-cap": "butt"},
         "paint": {"line-color": p["paint"],
                   "line-width": ["interpolate", ["exponential", 2], ["zoom"],
                                  16.5, max(0.8, 0.45 * 2 ** 16.5 * M), 20, 0.45 * 2 ** 20 * M]}},
        # Стрелки полос перед стоп-линией: одна на полосу (build_mvt.lane_arrows).
        {"id": "radar-arrows", "type": "symbol", "source": "radar", "source-layer": "arrows", "minzoom": 17,
         "layout": {"icon-image": ["match", ["get", "turn"], 1, "lane-through", 2, "lane-left", 3, "lane-right",
                                   4, "lane-slight_left", 5, "lane-slight_right", 6, "lane-uturn",
                                   7, "lane-through_left", 8, "lane-through_right", 9, "lane-left_right", ""],
                    "icon-rotate": ["get", "bearing"], "icon-rotation-alignment": "map",
                    "icon-pitch-alignment": "map", "icon-allow-overlap": True, "icon-ignore-placement": True,
                    "icon-size": ["interpolate", ["exponential", 2], ["zoom"], 17, 0.55, 20, 2.2]}},
        # Светофор — один значок в центре регулируемого перекрёстка, как у
        # Яндекса; точки у каждого подъезда читались мусором посреди полос.
        {"id": "radar-signal-icon", "type": "symbol", "source": "radar", "source-layer": "surface", "minzoom": 16,
         "filter": ["all", ["==", ["geometry-type"], "Polygon"], ["==", ["get", "kind"], 11]],
         "layout": {"icon-image": "traffic-light", "icon-allow-overlap": True,
                    "icon-size": ["interpolate", ["linear"], ["zoom"], 16, 0.6, 19, 1.1]}},
    ]


def build(base, theme="light", mode="full"):
    if theme not in PALETTES or mode not in ("full", "roads"):
        raise ValueError(f"тема {theme!r} / режим {mode!r}")
    p = PALETTES[theme]
    base = base.rstrip("/")
    with open(os.path.join(HERE, "osm-bright.json")) as handle:
        s = json.load(handle)
    s["sources"] = {
        "openmaptiles": {"type": "vector", "tiles": [base + "/omt/{z}/{x}/{y}.pbf"],
                         "minzoom": 0, "maxzoom": 14,
                         "attribution": "© OpenMapTiles © OpenStreetMap contributors"},
        "radar": {"type": "vector", "tiles": [base + "/mvt/{z}/{x}/{y}.mvt"],
                  "minzoom": 15, "maxzoom": 15},
    }
    s["glyphs"] = base + "/glyphs/{fontstack}/{range}.pbf"
    s["sprite"] = base + "/sprite/sprite"
    out = [l for l in (_base_layer(layer, p, mode) for layer in s["layers"]) if l is not None]
    if mode == "full":
        first_symbol = next(k for k, l in enumerate(out) if l["type"] == "symbol")
        out.insert(first_symbol, {"id": "building-3d", "type": "fill-extrusion", "source": "openmaptiles",
                                  "source-layer": "building", "minzoom": 14,
                                  "paint": {"fill-extrusion-color": p["building"],
                                            "fill-extrusion-height": ["interpolate", ["linear"], ["zoom"], 14, 0, 15.5,
                                                                      ["coalesce", ["get", "render_height"], 8]],
                                            "fill-extrusion-base": ["coalesce", ["get", "render_min_height"], 0],
                                            "fill-extrusion-opacity": 0.92}})
    first_symbol = next((k for k, l in enumerate(out) if l["type"] == "symbol"), len(out))
    out[first_symbol:first_symbol] = _our_layers(p)
    s["layers"] = out
    s["name"] = f"RadarMap — {'светлая' if theme == 'light' else 'тёмная'}, {'полная' if mode == 'full' else 'только дорога'}"
    return s


def main(argv):
    base = next((a for a in argv[1:] if not a.startswith("--")), "https://soulmed.uz/radarmap")
    theme = argv[argv.index("--theme") + 1] if "--theme" in argv else "light"
    mode = argv[argv.index("--mode") + 1] if "--mode" in argv else "full"
    json.dump(build(base, theme, mode), sys.stdout, ensure_ascii=False, separators=(",", ":"))


if __name__ == "__main__":
    main(sys.argv)
