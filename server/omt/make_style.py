#!/usr/bin/env python3
"""Стиль карты «как у Яндекса»: OpenMapTiles (OSM, наша сборка Planetiler) + наши слои.

Основа — OSM Bright (openmaptiles/osm-bright-gl-style, BSD; иконки CC-BY),
лежит рядом как osm-bright.json. Палитра снята со скриншота Яндекс.Карт
(28.09.2026): светлый фон, серо-голубой асфальт с жёлтой кромкой у магистралей,
белые дворовые проезды, светло-зелёные парки, голубая вода, объёмные дома,
подписи улиц прописными. Поверх — то, чего нет ни в одной открытой схеме, а у
нас есть: разметка полос, зебры и светофоры из нашего MVT (build_mvt.py).

Почему не своя картография целиком: самописная поверхность дорог месяц давала
кляксы, иглы и «шахматку» (docs/plan_map_geometry.md), а OpenMapTiles — схема,
на которой работают MapTiler, Stadia, Protomaps. Своё — только там, где оно лучше.

    python3 server/omt/make_style.py https://soulmed.uz/radarmap > style.json
"""
import copy
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


# Ширина ОДНОЙ ленты проспекта с раздельными направлениями — чуть больше
# половины ширины класса. Иначе две встречные ленты по 24 м накрывают
# разделительную, и проспект сливается в одну серую полосу (Навои × Рашидов).
ONEWAY_SHARE = 0.55


def width(metres, extra=0.0, low=0.6):
    """Ширина линии в пикселях по ширине дороги в метрах (тайл 512, широта Ташкента);
    у односторонней ленты — доля ONEWAY_SHARE."""
    def stop(z):
        full = max(low + extra, metres * (2 ** z) * M + extra)
        half = max(low + extra, metres * ONEWAY_SHARE * (2 ** z) * M + extra)
        return ["case", ["==", ["get", "oneway"], 1], half, full]
    return ["interpolate", ["exponential", 2], ["zoom"], 10, stop(10), 13, stop(13), 16, stop(16), 20, stop(20)]


OUR_ROADS_FROM = 15


def measured(extra=0.0, low=1.0):
    """Ширина нашей ленты: свойство width (м) из тайла, как в EngineMapStyle.roadWidth."""
    def stop(z):
        return ["max", ["+", ["*", ["coalesce", ["get", "width"], 8], (2 ** z) * M], extra], low + extra]
    return ["interpolate", ["exponential", 2], ["zoom"], 15, stop(15), 18, stop(18), 20, stop(20)]


M = 1.7e-5   # метров → пикселей: px = m · 2^z · M


def build(base):
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
    BG, PARK, WOOD, WATER = "#f5f4f1", "#cfe9b8", "#c3e3a6", "#9fd2f5"
    ROAD, EDGE, MINOR, MINOR_EDGE, PATH = "#b9c0cc", "#efcb4a", "#ffffff", "#c9ced6", "#ffffff"
    BUILD, BUILD_SIDE = "#e7e2de", "#d9d3cf"
    LABEL = "#4a4a4a"
    M = 1.7e-5   # метров → пикселей: px = m · 2^z · M (тайл 512, широта Ташкента)

    def width(metres, extra=0.0, low=0.6):
        stop = lambda z: max(low + extra, metres * (2 ** z) * M + extra)
        return ["interpolate", ["exponential", 2], ["zoom"], 10, stop(10), 13, stop(13), 16, stop(16), 20, stop(20)]

    CLASS_M = {"motorway": 32, "trunk": 30, "primary": 24, "secondary-tertiary": 16, "link": 8,
               "motorway-link": 9, "minor": 9, "service-track": 5.5, "path": 2.5, "path-steps": 2.5}

    out = []
    for layer in s["layers"]:
        l = copy.deepcopy(layer); i = l["id"]; paint = l.setdefault("paint", {})
        if i == "background": paint["background-color"] = BG
        elif i.startswith("landuse-residential") or i == "landuse-railway": paint["fill-color"] = BG
        elif i in ("landcover-grass", "landcover-grass-park"): paint["fill-color"] = PARK; paint["fill-opacity"] = 1
        elif i == "landcover-wood": paint["fill-color"] = WOOD; paint["fill-opacity"] = 1
        elif i in ("water", "water-intermittent", "water-offset"): paint["fill-color"] = WATER
        elif i == "water-pattern": continue
        elif i.startswith("road_oneway"): continue   # стрелки вдоль всей улицы — шум; у Яндекса только у перекрёстков
        elif i.startswith("waterway") and l["type"] == "line": paint["line-color"] = WATER
        elif i in ("building", "building-top"): continue      # заменим объёмными
        elif l.get("source-layer") == "transportation" and l["type"] == "line":
            kind = next((k for k in sorted(CLASS_M, key=len, reverse=True) if i.endswith(k) or i.endswith(k + "-casing")), None)
            if kind and not i.startswith("railway") and "construction" not in i:
                casing = i.endswith("-casing")
                major = kind in ("motorway", "trunk", "primary", "secondary-tertiary", "link", "motorway-link")
                metres = CLASS_M[kind]
                if kind.startswith("path"):
                    paint["line-color"] = MINOR_EDGE if casing else PATH
                    paint["line-width"] = width(metres, 1.2 if casing else 0, 0.4)
                    paint.pop("line-dasharray", None)
                else:
                    if casing:
                        paint["line-color"] = EDGE if major else ["interpolate", ["linear"], ["zoom"], 13, "#e6e6e3", 15, MINOR_EDGE]
                    else:
                        # Вдали магистраль светлая с жёлтой каймой (читается как «главная»),
                        # вблизи — асфальт, на котором видна разметка. Как у Яндекса.
                        paint["line-color"] = ["interpolate", ["linear"], ["zoom"], 13, "#fdf3cf", 15.5, ROAD] if major else MINOR
                    paint["line-width"] = width(metres, (2.0 if major else 1.4) if casing else 0.0)
                    paint["line-opacity"] = 1 if major else ["interpolate", ["linear"], ["zoom"], 12.5, 0, 13.5, 1]
                l.setdefault("layout", {}).update({"line-cap": "round", "line-join": "round"})
                if not kind.startswith("path"):
                    # С 15-го зума проезжую часть рисует НАШ слой (radar-roads): у
                    # него ширина лент подогнана по измеренному расстоянию осей, и
                    # из той же геометрии посчитаны разметка, зебры, разделительные.
                    # Две геометрии дороги на одном экране — пунктир мимо полотна.
                    l["maxzoom"] = OUR_ROADS_FROM
        elif l["type"] == "symbol" and l.get("source-layer") == "transportation_name":
            lay = l.setdefault("layout", {}); lay["text-transform"] = "uppercase"; lay["text-letter-spacing"] = 0.08
            # Реже и не впритык: каждая встречная лента подписана своей строкой, и
            # при шаге по умолчанию одно имя стояло на перекрёстке восемь раз.
            lay["symbol-spacing"] = 520; lay["text-padding"] = 24
            lay["text-font"] = ["Noto Sans Bold"]
            paint.update({"text-color": LABEL, "text-halo-color": "#ffffff", "text-halo-width": 1.6})
        out.append(l)

    # Объёмные дома — перед подписями
    first_symbol = next(k for k, l in enumerate(out) if l["type"] == "symbol")
    out.insert(first_symbol, {"id": "building-3d", "type": "fill-extrusion", "source": "openmaptiles",
        "source-layer": "building", "minzoom": 14,
        "paint": {"fill-extrusion-color": BUILD,
                  "fill-extrusion-height": ["interpolate", ["linear"], ["zoom"], 14, 0, 15.5, ["coalesce", ["get", "render_height"], 8]],
                  "fill-extrusion-base": ["coalesce", ["get", "render_min_height"], 0],
                  "fill-extrusion-opacity": 0.92}})
    # Наши слои, снизу вверх: полотно (каймы, затем полотна — иначе кайма
    # соседней ленты режет перекрёсток швом), разделительная, разметка, зебры,
    # светофоры. Всё — над подложкой, под подписями.
    #
    # Проезжая часть с 15-го зума — наша: ширина лент подогнана по измеренному
    # расстоянию осей, и из той же геометрии посчитаны разметка, зебры и
    # разделительные. Две геометрии дороги на одном экране — пунктир мимо полотна.
    ours = [
        {"id": "radar-roads-case", "type": "line", "source": "radar", "source-layer": "roads",
         "minzoom": OUR_ROADS_FROM, "filter": ["<=", ["get", "cls"], 7],
         "layout": {"line-cap": "round", "line-join": "round", "line-sort-key": ["-", 0, ["get", "cls"]]},
         "paint": {"line-color": ["case", ["<=", ["get", "cls"], 5], EDGE, MINOR_EDGE], "line-width": measured(2.0)}},
        {"id": "radar-roads", "type": "line", "source": "radar", "source-layer": "roads",
         "minzoom": OUR_ROADS_FROM, "filter": ["<=", ["get", "cls"], 7],
         "layout": {"line-cap": "round", "line-join": "round", "line-sort-key": ["-", 0, ["get", "cls"]]},
         "paint": {"line-color": ["case", ["<=", ["get", "cls"], 5], ROAD, MINOR], "line-width": measured()}},
        # Площадь перекрёстка: скругляет углы между подходами (бордюр у Яндекса).
        # Узлы строятся только там, где сходится дорога шире 9 м, и обрезаны
        # кругом досягаемости — поэтому цвет магистрального асфальта им честен.
        {"id": "radar-junction", "type": "fill", "source": "radar", "source-layer": "surface",
         "minzoom": OUR_ROADS_FROM,
         "filter": ["all", ["==", ["geometry-type"], "Polygon"], ["==", ["get", "kind"], 8]],
         "paint": {"fill-color": ROAD, "fill-antialias": False}},
        # Разделительная проспекта — из нашей поверхности (полоса между внутренними
        # кромками встречных лент). В OpenMapTiles её нет вовсе.
        {"id": "radar-median", "type": "fill", "source": "radar", "source-layer": "surface", "minzoom": 15.5,
         "filter": ["all", ["==", ["geometry-type"], "Polygon"], ["==", ["get", "kind"], 9]],
         "paint": {"fill-color": "#dfe5d6", "fill-outline-color": "#c9ced6"}},
        {"id": "radar-markings", "type": "line", "source": "radar", "source-layer": "markings", "minzoom": 16,
         "layout": {"line-cap": "butt"},
         "paint": {"line-color": "#ffffff", "line-dasharray": [4, 5],
                   "line-width": ["interpolate", ["exponential", 2], ["zoom"], 16, 0.8, 20, 3]}},
        {"id": "radar-crossing", "type": "line", "source": "radar", "source-layer": "paint", "minzoom": 16.5,
         "paint": {"line-color": "#ffffff",
                   "line-width": ["interpolate", ["exponential", 2], ["zoom"], 16.5, 2, 20, 10]}},
        # Стрелки полос перед стоп-линией: одна на полосу (build_mvt.lane_arrows),
        # иконка по коду поворота, повёрнута по направлению движения.
        {"id": "radar-arrows", "type": "symbol", "source": "radar", "source-layer": "arrows", "minzoom": 17,
         "layout": {"icon-image": ["match", ["get", "turn"], 1, "lane-through", 2, "lane-left", 3, "lane-right",
                                   4, "lane-slight_left", 5, "lane-slight_right", 6, "lane-uturn",
                                   7, "lane-through_left", 8, "lane-through_right", 9, "lane-left_right", ""],
                    "icon-rotate": ["get", "bearing"], "icon-rotation-alignment": "map",
                    "icon-pitch-alignment": "map", "icon-allow-overlap": True, "icon-ignore-placement": True,
                    "icon-size": ["interpolate", ["exponential", 2], ["zoom"], 17, 0.55, 20, 2.2]}},
        {"id": "radar-signals", "type": "circle", "source": "radar", "source-layer": "points", "minzoom": 16,
         "filter": ["==", ["get", "kind"], 1],
         "paint": {"circle-radius": ["interpolate", ["linear"], ["zoom"], 16, 3, 19, 6], "circle-color": "#3b3b3b",
                   "circle-stroke-color": "#f5d547", "circle-stroke-width": 1.5}},
    ]
    first_symbol = next(k for k, l in enumerate(out) if l["type"] == "symbol")
    out[first_symbol:first_symbol] = ours
    s["layers"] = out


    s["name"] = "RadarMap — светлая"
    return s


if __name__ == "__main__":
    json.dump(build(sys.argv[1] if len(sys.argv) > 1 else "https://soulmed.uz/radarmap"),
              sys.stdout, ensure_ascii=False, separators=(",", ":"))
