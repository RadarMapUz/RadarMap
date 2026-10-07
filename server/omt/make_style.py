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
           "motorway-link": 9, "minor": 9, "service-track": 5.5, "path": 1.8, "path-steps": 1.8}
MAJOR = {"motorway", "trunk", "primary", "secondary-tertiary", "link", "motorway-link"}

PALETTES = {
    "light": {
        "bg": "#f5f4f1", "park": "#cfe9b8", "wood": "#c3e3a6", "water": "#9fd2f5",
        "road": "#b9c0cc", "road_trunk": "#adb5c2", "road_tertiary": "#c6ccd5",
        "road_far": "#fff3c4", "edge": "#ecc44a",
        # Мелкие улицы — тот же асфальт, светлее магистрали. Белыми они
        # совпадали с пешеходными дорожками: двор читался тропинкой, а рядом с
        # серыми магистралями кадр выглядел двумя разными картами (аудит
        # 28.09.2026). Белое осталось только у дорожек — их с дорогой не спутать.
        "minor": "#d5dae2", "minor_edge": "#b4bbc6", "minor_edge_far": "#e6e6e3", "path": "#ffffff",
        "path_edge": "#e3e1db",
        "median": "#dfe5d6", "concrete": "#d5d9e0", "zebra_base": "#f2cf3b", "paint": "#ffffff", "building": "#eae7e3", "building_wall": "#d9d1c9", "landuse": "#f1eeea",
        "boundary": "#c9c2d6", "building_shadow": "rgba(90,95,110,0.22)",
        "underpass": "#b9a8e8", "underpass_edge": "#8f7cc9",
        "footbridge": "#ffffff", "footbridge_edge": "#a9b0bc", "steps": "#c7cbd3",
        # Свет для 3D: мягкий, тёплый, сбоку-сверху — стены светлые, с тенью,
        # а не плоские серые плиты (06.10.2026).
        "light": {"anchor": "viewport", "color": "#ffffff", "intensity": 0.3,
                  "position": [1.3, 200, 35]},
        # Кайма НАШИХ лент — нейтральная: жёлтая у каждой ленты давала «нитки»
        # внутри асфальта там, где две ленты лежат рядом (Фурката, 28.09.2026).
        "casing": "#aab2bf",
        # Жёлтая кромка магистрали — как у Яндекса (снимок 05.10.2026).
        "kerb": "#f0c93f", "trees": "trees", "asphalt": "asphalt", "gutter": "#9aa2af",
        "parking": "#c4cad4", "parking_edge": "#e6c75a",
        "sidewalk": "#ebe7e1", "sidewalk_edge": "#d6d0c7", "barrier": "#e9ebee",
        # Мост: светлый край-ограждение и тень под пролётом; тоннель —
        # полупрозрачный асфальт с пунктирной кромкой (как у Яндекса).
        "bridge_edge": "#ffffff", "bridge_shadow": "rgba(40,48,60,0.22)", "tunnel": "#c9ced8",
        "tree_crown": "#a3d184", "tree_crown_low": "#7fb565", "tree_crown_high": "#c2e3a2", "tree_light": "#c4e4a8", "tree_trunk": "#9b8a76", "tree_edge": "#94c676",
        "tree_shadow": "rgba(60,100,40,0.28)",
        "label": "#4a4a4a", "halo": "#ffffff", "signal": "#3b3b3b", "signal_ring": "#f5d547",
    },
    "dark": {
        "bg": "#0f1216", "park": "#16241b", "wood": "#14221a", "water": "#1b3348",
        "road": "#424955", "road_trunk": "#4a5260", "road_tertiary": "#3b414c",
        "road_far": "#4b4536", "edge": "#b8923a",
        "minor": "#262b33", "minor_edge": "#1a1e24", "minor_edge_far": "#1a1e24", "path": "#20252c",
        "path_edge": "#1b1f25",
        "median": "#1c2a22", "concrete": "#3a414c", "zebra_base": "#8c7a2c", "paint": "#d9dee6", "building": "#2b3038", "building_wall": "#1f242d", "landuse": "#13171d",
        "boundary": "#3a3f4c", "building_shadow": "rgba(0,0,0,0.45)",
        "underpass": "#5b4f8a", "underpass_edge": "#7d6fb8",
        "footbridge": "#3a404b", "footbridge_edge": "#596170", "steps": "#2a2f37",
        "light": {"anchor": "viewport", "color": "#ffffff", "intensity": 0.18,
                  "position": [1.3, 200, 35]},
        "casing": "#2b3039",
        "kerb": "#8c7033", "trees": "trees-dark", "asphalt": "asphalt-dark", "gutter": "#2f343c",
        "parking": "#363c46", "parking_edge": "#7a6532",
        "sidewalk": "#262a31", "sidewalk_edge": "#33383f", "barrier": "#4a515c",
        "bridge_edge": "#69707c", "bridge_shadow": "rgba(0,0,0,0.45)", "tunnel": "#2a2f37",
        "tree_crown": "#22402c", "tree_crown_low": "#18301f", "tree_crown_high": "#33593e", "tree_light": "#2e5238", "tree_trunk": "#3a332b", "tree_edge": "#2e5238",
        "tree_shadow": "rgba(0,0,0,0.5)",
        "label": "#c9ced6", "halo": "#0f1216", "signal": "#101318", "signal_ring": "#f0c64a",
    },
}

# «Только дорога»: что из основы остаётся. Остальные исходные слои OSM Bright
# (POI, дома, номера домов, аэродромы, границы, щиты, прочая застройка) — нет.
ROADS_KEEP_LAYERS = {"transportation", "transportation_name", "water", "waterway", "park"}
ROADS_KEEP_IDS = {"background", "landcover-grass", "landcover-grass-park", "landcover-wood"}


# Доля ширины запасной линии основы, когда полотно рисуем мы (с
# OUR_ROADS_FROM). Полной ширины она торчала зубцами из-под нашей ленты у
# съездов, где геометрия OpenMapTiles и наша расходятся (Беруни, 05.10.2026);
# узкая прячется под нашим полотном, а без нашего тайла дорога всё равно есть.
FALLBACK_SHARE = 0.45


def class_width(metres, extra=0.0, low=0.6, near_share=1.0):
    """Ширина линии OpenMapTiles по классу; у односторонней ленты — доля ONEWAY_SHARE.

    near_share — множитель с OUR_ROADS_FROM (запасная линия под нашей лентой).
    """
    def stop(z, share=1.0):
        full = max(low + extra, metres * share * (2 ** z) * M + extra)
        half = max(low + extra, metres * ONEWAY_SHARE * share * (2 ** z) * M + extra)
        return ["case", ["==", ["get", "oneway"], 1], half, full]
    if near_share == 1.0:
        return ["interpolate", ["exponential", 2], ["zoom"], 10, stop(10), 13, stop(13), 16, stop(16), 20, stop(20)]
    edge = OUR_ROADS_FROM
    return ["interpolate", ["exponential", 2], ["zoom"], 10, stop(10), 13, stop(13),
            edge - 0.1, stop(edge - 0.1), edge, stop(edge, near_share),
            16, stop(16, near_share), 20, stop(20, near_share)]


# Объёмные кроны деревьев OSM — с этого зума; ствол — TREE_TRUNK_METERS.
TREE_3D_FROM = 16.8


def tree_3d(p):
    """Объёмное дерево из тайла: ствол и ярусы кроны с высотами base/top в
    метрах (build_mvt.tree_tiers). Сверху — круг, в наклоне — округлая крона.
    Среди объёмных слоёв: дома и деревья закрывают друг друга по глубине."""
    return {"id": "radar-tree-3d", "type": "fill-extrusion", "source": "radar", "source-layer": "trees",
            "minzoom": TREE_3D_FROM, "filter": ["all", ["==", ["geometry-type"], "Polygon"], ["has", "crown"]],
            # Ярус кроны: низ темнее, верх светлее; размер дерева чуть меняет
            # оттенок — роща не одного цвета.
            "paint": {"fill-extrusion-color": ["case", ["has", "trunk"], p["tree_trunk"],
                                               ["interpolate", ["linear"],
                                                ["+", ["coalesce", ["get", "tier"], 3],
                                                 ["*", 0.4, ["coalesce", ["get", "size"], 1]]],
                                                0, p["tree_crown_low"], 3, p["tree_crown"],
                                                6.2, p["tree_crown_high"]]],
                      "fill-extrusion-base": ["get", "base"], "fill-extrusion-height": ["get", "top"],
                      # Без градиента по высоте: он затемнял низ КАЖДОГО яруса,
                      # и стыки ярусов читались тёмными зубцами (07.10.2026);
                      # тень кроны даёт тон яруса.
                      "fill-extrusion-vertical-gradient": False, "fill-extrusion-opacity": 1.0}}


# Подземный переход и пешеходный мост — ширина на карте, м.
UNDERPASS_METERS = 4.0
FOOTBRIDGE_METERS = 2.2

# Узор крон на газоне виден до TREE_PATTERN_OUT, затухает с TREE_PATTERN_FADE.
TREE_PATTERN_FADE = 17.5
TREE_PATTERN_OUT = 18.5
# Крона 2–3 м радиусом, четыре размера по свойству size из тайла: одинаковые
# круги в 3 м читались «мячиками» (Чорсу, 06.10.2026).
TREE_CROWN_METERS = 2.4
TREE_SIZE_SCALES = (0.8, 0.95, 1.1, 1.25)


def tree_radius(scale=1.0):
    """Радиус кроны в пикселях — по метрам, как ширина наших лент."""
    size = ["match", ["coalesce", ["get", "size"], 1]]
    for index, factor in enumerate(TREE_SIZE_SCALES):
        size += [index, factor]
    size.append(1.0)

    def stop(z):
        return ["max", 1.2, ["*", size, TREE_CROWN_METERS * scale * (2 ** z) * M]]
    return ["interpolate", ["exponential", 2], ["zoom"], 15, stop(15), 18, stop(18), 20, stop(20)]


GUTTER_SHARE = 0.07


def scaled_width(share):
    """Доля ширины ленты (свойство width, м) в пикселях."""
    def stop(z):
        return ["*", ["coalesce", ["get", "width"], 8], share * (2 ** z) * M]
    return ["interpolate", ["exponential", 2], ["zoom"], 15, stop(15), 18, stop(18), 20, stop(20)]


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
    elif i == "boundary-land-level-4":
        # Районные границы — тонкий бледный штрих только издали: жирная
        # серая пунктирная ломаная поверх города читалась дорогой (06.10.2026).
        paint["line-color"] = p["boundary"]
        paint["line-width"] = ["interpolate", ["linear"], ["zoom"], 10, 0.6, 14, 1.0]
        paint["line-opacity"] = ["interpolate", ["linear"], ["zoom"], 12, 0.8, 14.5, 0]
        l["maxzoom"] = 14.5
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
            # Тротуар тише дороги: уже и с бледной каймой — широкие белые
            # дорожки с серой обводкой спорили с проезжей частью (Чорсу).
            paint["line-color"] = p["path_edge"] if casing else p["path"]
            paint["line-width"] = class_width(metres, 0.6 if casing else 0, 0.4)
            paint.pop("line-dasharray", None)
            if i.startswith("tunnel-path"):
                # Подземный переход — полупрозрачная сиреневая полоса ПОВЕРХ
                # проезжей части с пунктирной кромкой: под асфальтом его не
                # было видно вовсе (342 перехода в Ташкенте, 06.10.2026).
                paint["line-color"] = p["underpass_edge"] if casing else p["underpass"]
                paint["line-width"] = class_width(UNDERPASS_METERS, 1.2 if casing else 0, 0.4)
                paint["line-opacity"] = 0.9 if casing else 0.55
                if casing:
                    paint["line-dasharray"] = [2, 1.5]
                l.setdefault("layout", {})["line-cap"] = "butt"
            elif i.startswith("bridge-path"):
                # Пешеходный мост — светлый настил с серой кромкой над дорогой.
                paint["line-color"] = p["footbridge_edge"] if casing else p["footbridge"]
                paint["line-width"] = class_width(FOOTBRIDGE_METERS, 1.0 if casing else 0, 0.4)
                l.setdefault("layout", {})["line-cap"] = "butt"
            if kind == "path-steps" and not casing:
                # Лестница — поперечные ступени, а не дорожка.
                paint["line-dasharray"] = [0.25, 0.25]
                paint["line-color"] = p["steps"]
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
            paint["line-width"] = class_width(metres, (2.0 if major else 1.4) if casing else 0.0,
                                              near_share=1.0 if casing else FALLBACK_SHARE)
            paint["line-opacity"] = 1 if major else ["interpolate", ["linear"], ["zoom"], 12.5, 0, 13.5, 1]
            # С OUR_ROADS_FROM полотно рисуем мы, но сама линия основы остаётся
            # ПОД нашими слоями как запасная: где нашего тайла нет (офлайн,
            # не докачан, отброшен проверкой sha, район вне сборки), дорога
            # иначе исчезала целиком при приближении (жалоба владельца
            # 28.09.2026). Наше полотно её накрывает. Кайма основы — жёлтая
            # у магистрали — выключается: из-под нашей ленты она торчала бы
            # нитками по краю.
            if casing:
                l["maxzoom"] = OUR_ROADS_FROM
        l.setdefault("layout", {}).update({"line-join": "round"})
        # Настил моста и переход — с прямыми торцами: круглые концы делали
        # из них «таблетки» (06.10.2026).
        l["layout"]["line-cap"] = "butt" if i.startswith(("tunnel-path", "bridge-path")) else "round"
    elif l["type"] == "symbol" and src == "transportation_name":
        lay = l.setdefault("layout", {})
        lay.update({"text-transform": "uppercase", "text-letter-spacing": 0.08,
                    # Реже и не впритык: каждая встречная лента подписана своей
                    # строкой, и при шаге по умолчанию одно имя стояло восемь раз.
                    # Каждая лента проспекта подписана отдельно: на Зарканаре
                    # одно имя стояло шесть раз на экран (05.10.2026). Шаг и
                    # отступ — чтобы улица читалась один-два раза.
                    "symbol-spacing": 1100, "text-padding": 60, "text-font": ["Noto Sans Bold"],
                    # Крупнее вблизи: на асфальте в 11 px имя терялось.
                    "text-size": ["interpolate", ["linear"], ["zoom"], 13, 10, 16, 12, 18, 14.5, 20, 16]})
        # Мягкий ореол с размытием: тонкая жёсткая обводка на сером асфальте
        # не отделяла буквы от разметки (06.10.2026).
        paint.update({"text-color": p["label"], "text-halo-color": p["halo"],
                      "text-halo-width": 2.0, "text-halo-blur": 0.6})
    elif l["type"] == "symbol":
        paint["text-halo-color"] = p["halo"]
        if "text-color" in paint and mode == "full" and p is PALETTES["dark"]:
            paint["text-color"] = p["label"]
    return l


# Краска земли — ПОД эстакадой, разметка самой эстакады — над ней. Раньше вся
# разметка лежала поверх мостов, и полосы, зебры и стоп-линии перекрёстка под
# эстакадой Бунёдкора у Чиланзара сеткой проступали сквозь пролёт (06.10.2026).
GROUND_PAINT = ("radar-asphalt-grain", "radar-markings-solid", "radar-markings", "radar-centre-dashed",
                "radar-centre-solid", "radar-zebra-base", "radar-zebra", "radar-stop-line", "radar-arrows")
# Ширина бетонной разделительной на карте, м.
DIVIDER_METERS = 1.6
BRIDGE_MARKINGS = ("radar-markings-solid", "radar-markings", "radar-centre-dashed",
                   "radar-centre-solid")


def _with(condition, existing):
    """Добавить условие в фильтр, не вкладывая «all» в «all»."""
    if existing and existing[0] == "all":
        return ["all", condition] + existing[1:]
    return ["all", condition, existing]


def _bridge_order(layers):
    by_id = {layer["id"]: layer for layer in layers}
    ground = []
    for layer_id in GROUND_PAINT:
        layer = copy.deepcopy(by_id[layer_id])
        if layer["source-layer"] == "markings":
            layer["filter"] = _with(["!", ["has", "bridge"]], layer["filter"])
        ground.append(layer)
    deck = []
    for layer_id in BRIDGE_MARKINGS:
        layer = copy.deepcopy(by_id[layer_id])
        layer["id"] = layer_id + "-bridge"
        layer["filter"] = _with(["has", "bridge"], layer["filter"])
        deck.append(layer)
    rest = [layer for layer in layers if layer["id"] not in GROUND_PAINT]
    shadow = next(i for i, layer in enumerate(rest) if layer["id"] == "radar-bridge-shadow")
    rest[shadow:shadow] = ground
    top = next(i for i, layer in enumerate(rest) if layer["id"] == "radar-bridge") + 1
    rest[top:top] = deck
    return rest


def road_color(p):
    """Асфальт по классу: магистраль темнее, проспект — основной тон,
    улица третьего класса светлее, двор — светлый. Иерархия читается сразу,
    а не только по ширине (06.10.2026)."""
    return ["match", ["get", "cls"], [1, 2], p["road_trunk"], [3, 4], p["road"],
            5, p["road_tertiary"], p["minor"]]


def _our_layers(p):
    """Наши слои, снизу вверх: каймы, полотна, площади узлов, разделительные,
    разметка, зебры, стрелки, мосты с их разметкой, светофоры."""
    return _bridge_order(_layers_in_draw_order(p))


def _layers_in_draw_order(p):
    return [
        # Разделительные и островки — ПОД полотном. Они построены по осям и не
        # знают ширины лент: поверх полотна островок ложился бледным
        # треугольником на полосы (Навои × Абая, 28.09.2026). Под полотном он
        # остаётся землёй ровно в зазоре между лентами — как у Яндекса.
        # Деревья из OSM (вид — крона кружком настоящего размера, ~3 м
        # радиусом) с мягкой тенью — как у Яндекса. Под дорогами: крона у
        # бордюра не ложится на асфальт.
        # Тем же приёмом, что кроны узора: тень, крона, блик слева сверху, без
        # обводки — обведённые круги рядом с узором читались наклейками.
        # Тень и блик сдвигаются в пикселях, растущих с зумом, как и крона.
        {"id": "radar-tree-shadow", "type": "circle", "source": "radar", "source-layer": "trees",
         "minzoom": 15.5, "filter": ["==", ["geometry-type"], "Point"],
         "paint": {"circle-color": p["tree_shadow"], "circle-radius": tree_radius(1.05),
                   "circle-blur": 0.5,
                   "circle-translate": ["interpolate", ["linear"], ["zoom"],
                                        16, ["literal", [0.5, 1]], 18, ["literal", [2, 3]],
                                        20, ["literal", [7, 11]]]}},
        # Плоская крона — только издали: с TREE_3D_FROM её сменяет объёмная.
        {"id": "radar-tree", "type": "circle", "source": "radar", "source-layer": "trees",
         "minzoom": 15.5, "maxzoom": TREE_3D_FROM + 0.3, "filter": ["==", ["geometry-type"], "Point"],
         "paint": {"circle-color": p["tree_crown"], "circle-radius": tree_radius(),
                   "circle-opacity": ["interpolate", ["linear"], ["zoom"], 15.5, 0, 16.2, 1,
                                      TREE_3D_FROM, 1, TREE_3D_FROM + 0.3, 0]}},
        {"id": "radar-tree-light", "type": "circle", "source": "radar", "source-layer": "trees",
         "minzoom": 16.5, "maxzoom": TREE_3D_FROM + 0.3, "filter": ["==", ["geometry-type"], "Point"],
         "paint": {"circle-color": p["tree_light"], "circle-radius": tree_radius(0.45),
                   "circle-blur": 0.4,
                   "circle-translate": ["interpolate", ["linear"], ["zoom"],
                                        16.5, ["literal", [-1, -1]], 18, ["literal", [-3, -3]],
                                        20, ["literal", [-11, -11]]],
                   "circle-opacity": ["interpolate", ["linear"], ["zoom"], 16.5, 0, 17.2, 0.8]}},
        # Тротуар полосой вдоль магистралей: светлая плитка с бордюрной
        # кромкой — дорога не висит в газоне (07.10.2026).
        {"id": "radar-sidewalk", "type": "fill", "source": "radar", "source-layer": "sidewalks",
         "minzoom": 15.5,
         "paint": {"fill-color": p["sidewalk"], "fill-antialias": True,
                   "fill-opacity": ["interpolate", ["linear"], ["zoom"], 15.5, 0, 16.2, 1]}},
        {"id": "radar-sidewalk-edge", "type": "line", "source": "radar", "source-layer": "sidewalks",
         "minzoom": 16.5, "layout": {"line-join": "round"},
         "paint": {"line-color": p["sidewalk_edge"],
                   "line-width": ["interpolate", ["linear"], ["zoom"], 16.5, 0.4, 19, 1.0]}},
        # Парковка: площадка асфальта с бордюром и белые черты мест (как у
        # Яндекса у аэропорта). Под дорогами — проезды площадки лежат сверху.
        {"id": "radar-parking", "type": "fill", "source": "radar", "source-layer": "parking",
         "minzoom": 15.5, "filter": ["==", ["get", "kind"], "lot"],
         "paint": {"fill-color": p["parking"], "fill-antialias": True,
                   "fill-opacity": ["interpolate", ["linear"], ["zoom"], 15.5, 0, 16, 1]}},
        {"id": "radar-parking-kerb", "type": "line", "source": "radar", "source-layer": "parking",
         "minzoom": 16, "filter": ["==", ["get", "kind"], "lot"],
         "layout": {"line-join": "round"},
         "paint": {"line-color": p["parking_edge"],
                   "line-width": ["interpolate", ["linear"], ["zoom"], 16, 0.6, 19, 1.6]}},
        {"id": "radar-parking-stall", "type": "line", "source": "radar", "source-layer": "parking",
         "minzoom": 17, "filter": ["==", ["get", "kind"], "stall"],
         "layout": {"line-cap": "butt"},
         "paint": {"line-color": p["paint"],
                   "line-width": ["interpolate", ["exponential", 2], ["zoom"], 17, 0.5, 20, 1.8],
                   "line-opacity": ["interpolate", ["linear"], ["zoom"], 17, 0, 17.6, 0.85]}},
        {"id": "radar-median", "type": "fill", "source": "radar", "source-layer": "surface", "minzoom": 15.5,
         "filter": ["all", ["==", ["geometry-type"], "Polygon"], ["==", ["get", "kind"], 9],
                    ["!", ["has", "strip"]], ["!", ["has", "island"]]],
         # Островок на съезде — бетон, как у Яндекса, а не газон.
         "paint": {"fill-color": p["concrete"], "fill-outline-color": p["minor_edge"]}},
        # Тоннель — ПОД наземными дорогами: полупрозрачный асфальт и
        # пунктирная кромка. Раньше он рисовался обычной дорогой поверх всего,
        # и на Кичик Халка йули не понять было, что дорога уходит под землю.
        {"id": "radar-tunnel-case", "type": "line", "source": "radar", "source-layer": "roads",
         "minzoom": OUR_ROADS_FROM, "filter": ["all", ["<=", ["get", "cls"], 7], ["has", "tunnel"]],
         "layout": {"line-join": "round", "line-cap": "butt"},
         # Пунктир — только тонкие края по обеим сторонам (линия с зазором
         # шириной в полотно). Пунктир на всю ширину давал блоки-зебру.
         "paint": {"line-color": p["casing"], "line-width": 1.4, "line-gap-width": measured(),
                   "line-dasharray": [3, 2], "line-opacity": 0.9}},
        {"id": "radar-tunnel", "type": "line", "source": "radar", "source-layer": "roads",
         "minzoom": OUR_ROADS_FROM, "filter": ["all", ["<=", ["get", "cls"], 7], ["has", "tunnel"]],
         "layout": {"line-join": "round", "line-cap": "butt"},
         "paint": {"line-color": p["tunnel"], "line-width": measured(), "line-opacity": 0.65}},
        {"id": "radar-roads-case", "type": "line", "source": "radar", "source-layer": "roads",
         "minzoom": OUR_ROADS_FROM, "filter": ["all", ["!", ["has", "tunnel"]], ["<=", ["get", "cls"], 7],
                                              ["!", ["has", "stub"]], ["!", ["has", "inner"]]],
         "layout": {"line-cap": "round", "line-join": "round", "line-sort-key": ["-", 0, ["get", "cls"]]},
         # Кромка: у магистралей (trunk…secondary) — жёлтая, как у Яндекса;
         # у tertiary — нейтральная, у мелких — цвет края мелкой улицы.
         "paint": {"line-color": ["case", ["<=", ["get", "cls"], 4], p["kerb"],
                                  ["<=", ["get", "cls"], 5], p["casing"], p["minor_edge"]],
                   "line-width": measured(2.4)}},
        {"id": "radar-roads", "type": "line", "source": "radar", "source-layer": "roads",
         "minzoom": OUR_ROADS_FROM, "filter": ["all", ["!", ["has", "tunnel"]], ["<=", ["get", "cls"], 7], ["!", ["has", "stub"]]],
         "layout": {"line-cap": "round", "line-join": "round", "line-sort-key": ["-", 0, ["get", "cls"]]},
         "paint": {"line-color": road_color(p),
                   "line-width": measured()}},
        # Короткие широкие куски (stub) — с прямыми концами: скругление делало
        # из них «шар» шире соседних лент. Стык закрывают концы соседей.
        {"id": "radar-roads-stub", "type": "line", "source": "radar", "source-layer": "roads",
         "minzoom": OUR_ROADS_FROM, "filter": ["all", ["!", ["has", "tunnel"]], ["<=", ["get", "cls"], 7], ["has", "stub"]],
         "layout": {"line-cap": "butt", "line-join": "round"},
         "paint": {"line-color": road_color(p),
                   "line-width": measured()}},
        # Галтели (вид 13): скруглённый бордюр на углах перекрёстка — асфальт
        # между точкой встречи кромок и дугой, как у Яндекса.
        # Потемнение у бордюра — под площадью узла: поперёк перекрёстка его нет.
        {"id": "radar-roads-gutter", "type": "line", "source": "radar", "source-layer": "roads",
         "minzoom": 16, "filter": ["all", ["!", ["has", "tunnel"]], ["<=", ["get", "cls"], 5], ["!", ["has", "inner"]]],
         "layout": {"line-cap": "butt", "line-join": "round"},
         # Две полосы по краям ВНУТРИ полотна: зазор между ними — 86 % ширины.
         "paint": {"line-color": p["gutter"], "line-width": scaled_width(GUTTER_SHARE),
                   "line-gap-width": scaled_width(1 - 2 * GUTTER_SHARE),
                   "line-blur": scaled_width(GUTTER_SHARE),
                   "line-opacity": ["interpolate", ["linear"], ["zoom"], 16, 0, 17, 0.35]}},
        {"id": "radar-fillet", "type": "fill", "source": "radar", "source-layer": "surface",
         "minzoom": OUR_ROADS_FROM,
         "filter": ["all", ["==", ["geometry-type"], "Polygon"], ["==", ["get", "kind"], 13]],
         "paint": {"fill-color": ["case", ["get", "major"], p["road"], p["minor"]], "fill-antialias": True}},
        # Двойная разделительная линия (вид 15): между встречными лентами, где
        # места под полосу нет, — как жёлтая двойная у Яндекса на Беруни.
        # Узкая разделительная (зазор меньше 2,5 м) — бетонная полоса с
        # бордюром, как у Яндекса на Навои: раньше — двойная жёлтая линия,
        # и проспект читался одной широкой дорогой (06.10.2026).
        {"id": "radar-divider-kerb", "type": "line", "source": "radar", "source-layer": "surface",
         "minzoom": 15.5, "filter": ["all", ["==", ["geometry-type"], "LineString"], ["==", ["get", "kind"], 15]],
         "layout": {"line-join": "round", "line-cap": "round"},
         "paint": {"line-color": p["kerb"],
                   "line-width": ["interpolate", ["exponential", 2], ["zoom"],
                                  15.5, 1.5, 20, DIVIDER_METERS * 2 ** 20 * M + 2.5]}},
        {"id": "radar-divider", "type": "line", "source": "radar", "source-layer": "surface",
         "minzoom": 15.5, "filter": ["all", ["==", ["geometry-type"], "LineString"], ["==", ["get", "kind"], 15]],
         "layout": {"line-join": "round", "line-cap": "round"},
         "paint": {"line-color": p["concrete"],
                   "line-width": ["interpolate", ["exponential", 2], ["zoom"],
                                  15.5, 0.8, 20, DIVIDER_METERS * 2 ** 20 * M]}},
        # Площадь перекрёстка: скругляет углы между подходами. Узлы строятся
        # только там, где сходится дорога шире 9 м, и обрезаны кругом
        # досягаемости — цвет магистрального асфальта им честен.
        {"id": "radar-junction", "type": "fill", "source": "radar", "source-layer": "surface",
         "minzoom": OUR_ROADS_FROM,
         "filter": ["all", ["==", ["geometry-type"], "Polygon"], ["in", ["get", "kind"], ["literal", [8, 10]]]],
         "paint": {"fill-color": p["road"], "fill-antialias": False}},
        # Разделительная ПОЛОСА между встречными лентами — поверх асфальта и площади узла: она
        # построена по тем же ширинам, что и полотно, а под полотном узкий
        # бетонный разделитель (Мукими: 2,5 м между лентами по 5 полос) целиком
        # тонул под каймой лент. Бордюр — линией, чтобы полоса читалась и в 2 м. Над площадью узла —
        # чтобы скруглённый нос у перехода лежал на асфальте, а не под ним.
        {"id": "radar-median-strip", "type": "fill", "source": "radar", "source-layer": "surface",
         "minzoom": 15.5,
         "filter": ["all", ["==", ["geometry-type"], "Polygon"], ["==", ["get", "kind"], 9],
                    ["any", ["has", "strip"], ["has", "island"]]],
         "paint": {"fill-color": ["case", ["has", "concrete"], p["concrete"], p["median"]],
                   "fill-antialias": True}},
        {"id": "radar-median-kerb", "type": "line", "source": "radar", "source-layer": "surface",
         "minzoom": 16,
         "filter": ["all", ["==", ["geometry-type"], "Polygon"], ["==", ["get", "kind"], 9],
                    ["any", ["has", "strip"], ["has", "island"]]],
         "layout": {"line-join": "round"},
         "paint": {"line-color": p["kerb"],
                   "line-width": ["interpolate", ["linear"], ["zoom"], 16, 0.6, 19, 1.6]}},
        # Зебры: штрихи вдоль движения, толщина — ширина полосы зебры.
        {"id": "radar-crossing", "type": "line", "source": "radar", "source-layer": "paint", "minzoom": 16.5,
         "filter": ["==", ["get", "kind"], 5],
         "paint": {"line-color": p["paint"],
                   "line-width": ["interpolate", ["exponential", 2], ["zoom"], 16.5, 2, 20, 10]}},
        # Мосты и эстакады — поверх всего полотна: иначе эстакада Фурката лежала
        # под перекрёстком Навои, будто её там нет.
        # Мост: мягкая тень под пролётом (чуть сдвинута вниз-вправо, как от
        # солнца) и светлый край-ограждение — пролёт читается над землёй.
        {"id": "radar-bridge-shadow", "type": "line", "source": "radar", "source-layer": "roads",
         "minzoom": OUR_ROADS_FROM, "filter": ["all", ["<=", ["get", "cls"], 7], ["==", ["get", "bridge"], True]],
         "layout": {"line-cap": "butt", "line-join": "round"},
         "paint": {"line-color": p["bridge_shadow"], "line-width": measured(9.0), "line-blur": 6,
                   "line-translate": [2, 4]}},
        {"id": "radar-bridge-case", "type": "line", "source": "radar", "source-layer": "roads",
         "minzoom": OUR_ROADS_FROM, "filter": ["all", ["<=", ["get", "cls"], 7], ["==", ["get", "bridge"], True]],
         "layout": {"line-cap": "butt", "line-join": "round"},
         "paint": {"line-color": p["bridge_edge"], "line-width": measured(4.0)}},
        {"id": "radar-bridge", "type": "line", "source": "radar", "source-layer": "roads",
         "minzoom": OUR_ROADS_FROM, "filter": ["all", ["<=", ["get", "cls"], 7], ["==", ["get", "bridge"], True]],
         "layout": {"line-cap": "butt", "line-join": "round"},
         "paint": {"line-color": road_color(p),
                   "line-width": measured()}},
        # Асфальт как асфальт: зерно поверх полотна (узор привязан к земле и
        # не растягивается с шириной ленты) и лёгкое потемнение у бордюра,
        # где копится пыль. Ровная серая лента читалась пластиком (07.10.2026).
        {"id": "radar-asphalt-grain", "type": "fill", "source": "radar", "source-layer": "surface",
         "minzoom": 16.5,
         "filter": ["all", ["==", ["geometry-type"], "Polygon"], ["in", ["get", "kind"], ["literal", [7, 8, 10, 13]]]],
         "paint": {"fill-pattern": p["asphalt"],
                   "fill-opacity": ["interpolate", ["linear"], ["zoom"], 16.5, 0, 17.5, 0.4, 20, 0.5]}},
        # Сплошная перед перекрёстком (последние 25 м подхода) — без штриха.
        {"id": "radar-markings-solid", "type": "line", "source": "radar", "source-layer": "markings",
         "minzoom": 16, "filter": ["all", ["!", ["has", "centre"]], ["has", "solid"]],
         "layout": {"line-cap": "butt"},
         "paint": {"line-color": p["paint"],
                   "line-width": ["interpolate", ["exponential", 2], ["zoom"], 16, 0.8, 20, 3]}},
        {"id": "radar-markings", "type": "line", "source": "radar", "source-layer": "markings", "minzoom": 16,
         "filter": ["all", ["!", ["has", "centre"]], ["!", ["has", "solid"]]],
         "layout": {"line-cap": "butt"},
         "paint": {"line-color": p["paint"], "line-dasharray": [4, 5],
                   "line-width": ["interpolate", ["exponential", 2], ["zoom"], 16, 0.8, 20, 3]}},
        # Осевая двусторонней дороги (build_mvt.centre_lines): прерывистая с
        # длинным штрихом (1.5 ПДД) или сплошная при подтверждённых 4+ полосах
        # (1.1). Штрих длиннее, чем у разделителя полос, — осевая читается осевой.
        {"id": "radar-centre-dashed", "type": "line", "source": "radar", "source-layer": "markings",
         "minzoom": 16, "filter": ["==", ["get", "centre"], 1],
         "layout": {"line-cap": "butt"},
         "paint": {"line-color": p["paint"], "line-dasharray": [6, 4],
                   "line-width": ["interpolate", ["exponential", 2], ["zoom"], 16, 0.8, 20, 3]}},
        {"id": "radar-centre-solid", "type": "line", "source": "radar", "source-layer": "markings",
         "minzoom": 15.5, "filter": ["==", ["get", "centre"], 2],
         "layout": {"line-cap": "butt"},
         "paint": {"line-color": p["paint"],
                   "line-width": ["interpolate", ["exponential", 2], ["zoom"], 15.5, 0.7, 20, 3.5]}},
        # Зебра линией перехода (вид 12): ширина линии — длина штриха зебры
        # (3 м), пунктир — сами штрихи поперёк; одним куском от кромки до кромки.
        # Жёлто-белая зебра, как на улицах Ташкента и у Яндекса: жёлтая
        # подложка, белые штрихи поверх.
        {"id": "radar-zebra-base", "type": "line", "source": "radar", "source-layer": "paint", "minzoom": 16.5,
         "filter": ["==", ["get", "kind"], 12],
         "layout": {"line-cap": "butt"},
         "paint": {"line-color": p["zebra_base"],
                   "line-width": ["interpolate", ["exponential", 2], ["zoom"],
                                  16.5, 3 * 2 ** 16.5 * M, 20, 3 * 2 ** 20 * M]}},
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
        # Светофоры как у Яндекса: по значку на каждый подход, ромбом вокруг
        # центра регулируемого перекрёстка (build_mvt.approach_lights, вид 14).
        # Жёлтой «вафли» больше нет — у Яндекса её нет (снимок 05.10.2026).
        {"id": "radar-signal-icon", "type": "symbol", "source": "radar", "source-layer": "surface", "minzoom": 16,
         "filter": ["all", ["==", ["geometry-type"], "Point"], ["==", ["get", "kind"], 14]],
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
        # Тень у подножия дома: мягкий тёмный контур, чуть сдвинутый от
        # света. Плоский слой — значит лёгкий для телефона; в наклоне дом
        # «стоит» на земле, а не висит над фоном (06.10.2026).
        out.insert(first_symbol, {"id": "building-ground-shadow", "type": "line", "source": "openmaptiles",
                                  "source-layer": "building", "minzoom": 15,
                                  "paint": {"line-color": p["building_shadow"],
                                            "line-width": ["interpolate", ["exponential", 2], ["zoom"],
                                                           15, 2, 18, 8, 20, 22],
                                            "line-blur": ["interpolate", ["exponential", 2], ["zoom"],
                                                          15, 2, 18, 8, 20, 22],
                                            "line-translate": [3, 4], "line-translate-anchor": "viewport",
                                            "line-opacity": ["interpolate", ["linear"], ["zoom"], 15, 0, 16, 1]}})
        first_symbol += 1
        out.insert(first_symbol, {"id": "building-3d", "type": "fill-extrusion", "source": "openmaptiles",
                                  "source-layer": "building", "minzoom": 14,
                                  "paint": {"fill-extrusion-color": p["building"],
                                            "fill-extrusion-vertical-gradient": True,
                                            "fill-extrusion-height": ["interpolate", ["linear"], ["zoom"], 14, 0, 15.5,
                                                                      ["coalesce", ["get", "render_height"], 8]],
                                            "fill-extrusion-base": ["coalesce", ["get", "render_min_height"], 0],
                                            # Непрозрачные: сквозь 0,92 на крышах
                                            # проступал узор крон газона под домом.
                                            "fill-extrusion-opacity": 1.0}})
    # Деревья поверх зелени (узор крон из спрайта), сразу над последним слоем
    # газона/парка/леса — под дорогами и домами. С 15-го зума: дальше кроны
    # сливаются в рябь.
    green = [k for k, l in enumerate(out) if l.get("source-layer") in ("landcover", "park")
             and l["type"] == "fill"]
    if green:
        out.insert(green[-1] + 1, {
            "id": "trees", "type": "fill", "source": "openmaptiles", "source-layer": "landcover",
            # Узор — пиксели спрайта, с картой он не растёт: на 16-м зуме это
            # деревья, а при приближении — мелкие бледные «призраки» (06.10.2026).
            # Поэтому после 17,5 он уходит, и ближе остаются ровный газон и
            # настоящие кроны из OSM, которые растут в метрах.
            "minzoom": 15, "maxzoom": TREE_PATTERN_OUT,
            "filter": ["in", ["get", "class"], ["literal", ["wood", "grass"]]],
            "paint": {"fill-pattern": p["trees"],
                      "fill-opacity": ["interpolate", ["linear"], ["zoom"], 15, 0, 15.6, 1,
                                       TREE_PATTERN_FADE, 1, TREE_PATTERN_OUT, 0]}})
    # Наши плоские слои — ДО объёмных домов. Плоский слой, нарисованный после
    # объёмного, ложится поверх стен: в наклоне дороги перекрывали здания
    # (Бунёдкор, 06.10.2026).
    extrusion = next((k for k, l in enumerate(out) if l["type"] == "fill-extrusion"), None)
    first_symbol = next((k for k, l in enumerate(out) if l["type"] == "symbol"), len(out))
    at = extrusion if extrusion is not None else first_symbol
    ours = _our_layers(p)
    out[at:at] = ours
    # Переходы и пешеходные мосты пересекают проспекты — рисуются ПОВЕРХ
    # нашего полотна, но под домами и подписями. Мост — с тенью.
    above = [l for l in out if l["id"].startswith(("tunnel-path", "bridge-path"))]
    out = [l for l in out if l not in above]
    at = next((k for k, l in enumerate(out) if l["type"] == "fill-extrusion"),
              next((k for k, l in enumerate(out) if l["type"] == "symbol"), len(out)))
    bridges = [l for l in above if l["id"].startswith("bridge-path")]
    shadows = []
    for layer in bridges:
        if layer["id"].endswith("-casing"):
            shadow = copy.deepcopy(layer)
            shadow["id"] = layer["id"].replace("-casing", "-shadow")
            shadow["paint"] = {"line-color": p["bridge_shadow"], "line-blur": 3,
                               "line-translate": [2, 3],
                               "line-width": class_width(FOOTBRIDGE_METERS, 2.0, 0.4)}
            shadows.append(shadow)
    out[at:at] = shadows + above
    # Объёмные кроны — рядом с объёмными домами: глубина между ними общая.
    after = next((k + 1 for k, l in enumerate(out) if l["type"] == "fill-extrusion"),
                 at + len(ours))
    out.insert(after, tree_3d(p))
    # Объём дороги: бордюр — тротуар приподнят на 18 см, у мостов —
    # ограждение в метр. Среди объёмных слоёв, рядом с домами.
    out.insert(after, {"id": "radar-barrier-3d", "type": "fill-extrusion", "source": "radar",
                       "source-layer": "barriers", "minzoom": 16,
                       "paint": {"fill-extrusion-color": p["barrier"], "fill-extrusion-base": 0,
                                 "fill-extrusion-height": ["interpolate", ["linear"], ["zoom"], 16, 0, 16.6, 1.1],
                                 "fill-extrusion-vertical-gradient": True, "fill-extrusion-opacity": 1.0}})
    out.insert(after, {"id": "radar-kerb-3d", "type": "fill-extrusion", "source": "radar",
                       "source-layer": "sidewalks", "minzoom": 16.5,
                       "paint": {"fill-extrusion-color": p["sidewalk"], "fill-extrusion-base": 0,
                                 "fill-extrusion-height": ["interpolate", ["linear"], ["zoom"], 16.5, 0, 17.2, 0.18],
                                 "fill-extrusion-vertical-gradient": False, "fill-extrusion-opacity": 1.0}})
    s["layers"] = out
    s["light"] = p["light"]
    s["name"] = f"RadarMap — {'светлая' if theme == 'light' else 'тёмная'}, {'полная' if mode == 'full' else 'только дорога'}"
    return s


def main(argv):
    base = next((a for a in argv[1:] if not a.startswith("--")), "https://soulmed.uz/radarmap")
    theme = argv[argv.index("--theme") + 1] if "--theme" in argv else "light"
    mode = argv[argv.index("--mode") + 1] if "--mode" in argv else "full"
    json.dump(build(base, theme, mode), sys.stdout, ensure_ascii=False, separators=(",", ":"))


if __name__ == "__main__":
    main(sys.argv)
