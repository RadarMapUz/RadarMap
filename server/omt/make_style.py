#!/usr/bin/env python3
"""Стиль карты RadarMap: OpenMapTiles (OSM, наша сборка Planetiler) + наши слои дороги.

Основа — OSM Bright (openmaptiles/osm-bright-gl-style, BSD; иконки CC-BY),
лежит рядом как osm-bright.json. Поверх — то, чего нет ни в одной открытой
схеме, а у нас есть: полотно по измеренной ширине, разметка полос,
разделительные, площади перекрёстков, зебры, стрелки, светофоры (build_mvt.py).

Две оси выбора:
* тема — light (с 22.10.2026 «чистый день»: дороги цветом по классу, 27.C) или dark
  («ночь-премиум»: для езды ночью — светлая карта в тёмной кабине слепит);
* режим — full (как у Яндекса: дома, POI, подписи всего) или roads («только
  дорога», просьба владельца 28.09.2026: дорога красиво, остальное не нужно —
  вода и зелень остаются приглушёнными только для ориентира).

С 15-го зума проезжую часть рисует НАШ слой: у него ширина лент подогнана по
измеренному расстоянию осей, и из той же геометрии посчитаны разметка, зебры и
разделительные. Две геометрии дороги на одном экране — пунктир мимо полотна.

    python3 server/omt/make_style.py https://soulmed.uz/radarmap [--theme dark] [--mode roads]
    python3 server/omt/make_style.py --app   # ресурсы приложения
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

# Палитра — «Ночь-премиум + чистый день» (27.C, выбор владельца 22.10.2026
# из пяти вариантов; прежняя — холодный серый асфальт днём и графит с
# тёмно-серыми домами ночью, «мрачно»). Числа контраста и правила —
# palette_check.py и test_palette_check.
#
# Иерархия дорог — ЦВЕТОМ на всех зумах, как у Яндекса, а не одним серым:
# магистраль (road_trunk), проспект (road), второй класс (road_secondary),
# третий (road_tertiary), прочие (minor). Днём магистраль абрикосовая,
# проспект жёлтый, остальные белые с серой кромкой на тёплой земле; ночью
# магистрали «подсвечены» светлым сланцем с золотой кромкой на глубоком
# сине-графитовом, улицы — тёмно-синие.
#
# Конфликты решены явно: «медленно» (#e8a100) темнее и насыщеннее абрикоса
# и жёлтого — пробка отделена светлотой (ΔE ≥ 36); линия маршрута лежит в
# своей тёмной кайме (≥ 4,5:1 к любой дороге днём). Ночью светлота асфальта
# держится вне полосы 0,083–0,133, где линия маршрута теряет 3:1 и телом, и
# каймой; подсвеченные магистрали — не светлее 0,18, иначе белое имя улицы
# на них падает ниже 4,5:1. Белая разметка на жёлтом проспекте — 1,3:1
# (на сером было 1,9:1): цена цвета класса.
PALETTES = {
    "light": {
        "bg": "#efece5", "park": "#c0e5a5", "wood": "#b0dc92", "water": "#92cff4",
        "road_trunk": "#ffcf9a", "road": "#ffe7a3", "road_secondary": "#ffffff", "road_tertiary": "#ffffff",
        "road_far": "#fff3c4", "edge": "#ecc44a",
        # Двор — белый с серой кромкой (как у Яндекса); дорожка — тёплая
        # бежевая, а не белая: с двором её не спутать (аудит 28.09.2026).
        "minor": "#ffffff", "minor_far": "#ffffff", "minor_edge": "#c6c0b5", "minor_edge_far": "#d2cdc3",
        "path": "#f3eee4", "path_edge": "#dcd5c7",
        # Обзор (до 15-го): иерархия цветом, а не одной жёлтой сеткой.
        "far_motorway": "#ffaa50", "far_motorway_edge": "#df8a2c",
        "far_trunk": "#ffbf6e", "far_trunk_edge": "#df9d48",
        "far_primary": "#ffdc85", "far_primary_edge": "#e0bb60",
        "far_secondary": "#ffffff", "far_secondary_edge": "#d6d1c7",
        "far_tertiary": "#ffffff", "far_tertiary_edge": "#dbd6cd",
        "median": "#dfe9d3", "concrete": "#e2ded6", "zebra_base": "#f2cf3b", "paint": "#ffffff",
        # Дома светлее земли, но темнее белой улицы; стены темнее крыши —
        # свет сбоку-сверху (06.10.2026), тёплый.
        "building": "#f5f3ee", "building_wall": "#cbc4b8", "landuse": "#ebe8e0",
        # Свой тон у вида землепользования (слой основы → цвет); жилое —
        # земля (landuse-residential), прочее — landuse.
        "landuse_kind": {"landuse-commercial": "#f9ede5", "landuse-industrial": "#eeecf2",
                         "landuse-hospital": "#f8e9eb", "landuse-school": "#f8f2dc",
                         "landuse-cemetery": "#e2e9dd"},
        "boundary": "#cfc6d6", "building_shadow": "rgba(90,85,75,0.22)",
        "underpass": "#b9a8e8", "underpass_edge": "#8f7cc9",
        "footbridge": "#ffffff", "footbridge_edge": "#b4ada1", "steps": "#d6cfc1",
        "light": {"anchor": "viewport", "color": "#fff6ea", "intensity": 0.45,
                  "position": [1.3, 200, 35]},
        # Кайма НАШИХ лент — нейтральная: жёлтая у каждой ленты давала «нитки»
        # внутри асфальта там, где две ленты лежат рядом (Фурката, 28.09.2026).
        "casing": "#cdc8be",
        # Кромка магистрали — своя, оранжевая; у проспекта и второго класса —
        # золотая (как у Яндекса, снимок 05.10.2026).
        "kerb": "#e3b54a", "kerb_trunk": "#e8a052", "trees": "trees", "asphalt": "asphalt", "gutter": "#cbbfa8",
        # Парковка — бледная площадка без жёлтой кромки: залитая асфальтом
        # проспекта и обведённая его кромкой, она читалась дорогой (Чорсу).
        "parking": "#ecebe6", "parking_edge": "#d9d5cc",
        "sidewalk": "#f0ece4", "sidewalk_edge": "#ddd6ca", "barrier": "#efece6",
        # Мост: светлый край-ограждение и тень под пролётом; тоннель —
        # полупрозрачный асфальт с пунктирной кромкой (как у Яндекса).
        "bridge_edge": "#ffffff", "bridge_shadow": "rgba(40,48,60,0.22)", "tunnel": "#dcd8d0",
        "tree_crown": "#a0d47f", "tree_crown_low": "#7fbd62", "tree_crown_high": "#bfe5a2", "tree_light": "#c2e6a7", "tree_trunk": "#9b8a76", "tree_edge": "#8fca70",
        "tree_shadow": "rgba(60,100,40,0.28)",
        "label": "#2f2c29", "street_label": "#2b2e33", "halo": "#ffffff", "oneway_opacity": 0.55, "housenumber": "#7a7166", "signal": "#3b3b3b", "signal_ring": "#f5d547",
    },
    "dark": {
        "bg": "#0f1420", "park": "#123426", "wood": "#103022", "water": "#143f7a",
        # Подсвеченные магистрали (светлота 0,15–0,18) — над тёмно-синими
        # улицами (≤ 0,083): дорога главного класса видна издалека.
        "road_trunk": "#647090", "road": "#5f6b86", "road_secondary": "#46526b", "road_tertiary": "#36435f",
        "road_far": "#4b4536", "edge": "#b8923a",
        # Ночью улица СВЕТЛЕЕ домов: двор темнее домов пропадал, а кварталы
        # выступали сильнее улиц (07.10.2026).
        "minor": "#36435f", "minor_far": "#36435f", "minor_edge": "#202a40", "minor_edge_far": "#18203a",
        "path": "#1c2538", "path_edge": "#172031",
        "far_motorway": "#d08a3a", "far_motorway_edge": "#8f5d22",
        "far_trunk": "#b47d3e", "far_trunk_edge": "#7c5429",
        "far_primary": "#9a8550", "far_primary_edge": "#695a35",
        "far_secondary": "#56688a", "far_secondary_edge": "#3a4862",
        "far_tertiary": "#34405a", "far_tertiary_edge": "#232d44",
        "median": "#132b22", "concrete": "#36425a", "zebra_base": "#8c7a2c", "paint": "#d9dee6",
        # Дома — синие объёмы светлее земли и темнее любой улицы; холодный
        # свет — крыша светлее стен.
        "building": "#252f46", "building_wall": "#151c2e", "landuse": "#121826",
        "landuse_kind": {"landuse-commercial": "#1d1a26", "landuse-industrial": "#171a28",
                         "landuse-hospital": "#201a27", "landuse-school": "#1c1e2e",
                         "landuse-cemetery": "#132222"},
        "boundary": "#35405c", "building_shadow": "rgba(0,0,0,0.5)",
        "underpass": "#5b4f8a", "underpass_edge": "#7d6fb8",
        "footbridge": "#34405a", "footbridge_edge": "#525f78", "steps": "#232c42",
        "light": {"anchor": "viewport", "color": "#b9cbff", "intensity": 0.42,
                  "position": [1.3, 200, 35]},
        "casing": "#202a40",
        "kerb": "#e8c070", "kerb_trunk": "#ffd27a", "trees": "trees-dark", "asphalt": "asphalt-dark", "gutter": "#3a4258",
        "parking": "#1f293e", "parking_edge": "#2a354d",
        "sidewalk": "#1a2234", "sidewalk_edge": "#252f45", "barrier": "#46526c",
        "bridge_edge": "#69707c", "bridge_shadow": "rgba(0,0,0,0.45)", "tunnel": "#212b40",
        "tree_crown": "#1b4632", "tree_crown_low": "#123425", "tree_crown_high": "#2a5d45", "tree_light": "#28563f", "tree_trunk": "#3a332b", "tree_edge": "#28563f",
        "tree_shadow": "rgba(0,0,0,0.5)",
        "label": "#cad4e6", "street_label": "#f4f7fb", "halo": "#0f1420", "oneway_opacity": 0.7, "housenumber": "#8f9bb2", "signal": "#101318", "signal_ring": "#f0c64a",
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

# Разметка полос — с 17-го: на 16-м пунктиры многополосной улицы сливались в
# рябь (Амира Темура, 07.10.2026). Осевая сплошная видна раньше.
LANE_MARKINGS_FROM = 17

# Имя на ОДНОМ языке. Было «{name:latin}\n{name:nonlatin}»: две строки на
# каждый объект, а латиница русских названий — автотранслитерация
# («Stolovaâ», «Hlebnye râdy»). По умолчанию — русское имя, иначе местное;
# узбекская версия приложения при загрузке меняет name:ru на name:uz
# (EngineModernStyle), а без узбекского имени остаётся местное.
NAME = ["coalesce", ["get", "name:ru"], ["get", "name"], ""]


# «Фуркат улица» → «ул. Фуркат», как у Яндекса. В OSM Ташкента русское имя
# почти всегда записано с типом в конце; движок режет строку сам (index-of /
# slice есть и на телефоне, и в превью), тайлы пересобирать не нужно.
STREET_TYPES = (("улица", "ул."), ("проспект", "просп."), ("проезд", "пр-д"), ("переулок", "пер."),
                ("тупик", "туп."), ("шоссе", "ш."), ("бульвар", "бул."), ("площадь", "пл."))


def street_name():
    """Имя улицы с сокращённым типом впереди. Узбекское имя не трогается.

    Длины — только через ["length", …] самого движка: нативный MapLibre
    считает строку в байтах UTF-8 (кириллица — два на букву), веб — в
    символах. Длина слова, посчитанная здесь, разошлась бы с телефоном.
    """
    n = ["var", "n"]
    rules = ["case"]
    for word, short in STREET_TYPES:
        tail = " " + word
        at = ["index-of", tail, n]
        rules += [["all", [">", at, 0], ["==", ["+", at, ["length", tail]], ["length", n]]],
                  ["concat", short, " ", ["slice", n, 0, at]]]
        head = word + " "
        rules += [["==", ["index-of", head, n], 0],
                  ["concat", short, " ", ["slice", n, ["length", head]]]]
    rules.append(n)
    # to-string: slice и index-of требуют строку, а coalesce даёт значение.
    return ["let", "n", ["to-string", NAME], rules]


# Цвет подписи места по виду, как у Яндекса: еда — оранжевая, магазины —
# синие, медицина — красная, культура — фиолетовая. Серые подписи всех мест
# одного цвета сливались в «шум» и не отвечали на вопрос «что это».
POI_KINDS = {
    "food": ("restaurant", "fast_food", "cafe", "bar", "beer", "ice_cream", "bakery"),
    "shop": ("shop", "grocery", "clothing_store", "supermarket", "department_store", "mall",
             "jewelry", "electronics", "furniture", "hardware", "mobile_phone", "books", "gift",
             "alcohol_shop", "convenience", "shoe", "florist", "optician", "cosmetics", "bank",
             "atm", "car", "car_repair", "laundry", "hairdresser", "beauty"),
    "health": ("hospital", "pharmacy", "doctors", "dentist", "clinic", "veterinary"),
    "culture": ("museum", "theatre", "cinema", "art_gallery", "arts_centre", "library",
                "attraction", "monument", "castle", "college", "school", "university",
                "kindergarten", "place_of_worship"),
}
POI_COLOURS = {
    "light": {"food": "#d9690a", "shop": "#2f63c9", "health": "#c8322a", "culture": "#7b48c8"},
    "dark": {"food": "#f0a24f", "shop": "#7aa5f2", "health": "#f08078", "culture": "#b694f0"},
}


# Значок стрелки полосы — 18 pt в ширину при размере 1 (make_arrows.W). Ширина
# значка — эта доля ширины полосы: составная стрелка («прямо и налево») рисуется
# во всю ширину значка, и при значке шире полосы крайние стрелки ложились на
# бордюр и за кромку (снимок CarPlay 13.10.2026). Полосу в метрах тайл несёт в
# свойстве lw; у тайлов до этой сборки его нет — прежний размер.
ARROW_ICON_POINTS = 18
ARROW_LANE_SHARE = 0.9


def arrow_size():
    def stop(z, legacy):
        fit = ["*", ["get", "lw"], ARROW_LANE_SHARE * (2 ** z) * M / ARROW_ICON_POINTS]
        return ["case", ["has", "lw"], fit, legacy]
    return ["interpolate", ["exponential", 2], ["zoom"], 17, stop(17, 0.55), 20, stop(20, 2.2)]


def street_halo(p):
    """Ореол подписи улицы — цветом асфальта под ней.

    Был цветом фона (#0f1216 ночью): на сером полотне подпись лежала чёрной
    наклейкой поверх штрихов разметки и стрелок (снимок CarPlay 13.10.2026).
    Ореол цвета асфальта прячет разметку под буквами, и имя читается
    напечатанным на дороге, как у Яндекса. До нашего полотна (15-й) дорога
    тонкая, имя лежит на фоне — ореол фоновый. Асфальт — по классу, как
    само полотно (class_asphalt).
    """
    return ["interpolate", ["linear"], ["zoom"], 14.5, p["halo"], 15.5, class_asphalt(p, "class")]


def poi_colour(p, theme):
    expression = ["match", ["get", "class"]]
    for kind, classes in POI_KINDS.items():
        expression += [list(classes), POI_COLOURS[theme][kind]]
    expression.append(p["label"])
    return expression


def _far(p, part):
    """Цвет дороги на обзоре по классу OpenMapTiles: магистраль насыщеннее,
    улица бледнее. Одна жёлтая сетка на 13-м зуме не говорила, где кольцо."""
    suffix = "_edge" if part == "edge" else ""
    return ["match", ["get", "class"],
            "motorway", p["far_motorway" + suffix], "trunk", p["far_trunk" + suffix],
            "primary", p["far_primary" + suffix], "secondary", p["far_secondary" + suffix],
            p["far_tertiary" + suffix]]


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
# Кайма ленты: полотно шире на столько пикселей (по половине с каждой
# стороны) — жёлтый бордюр магистрали. Бордюр угла перекрёстка — та же
# половина, чтобы кромка шла по углу без ступеньки.
ROAD_KERB_EXTRA_PX = 2.4
KERB_LINE_PX = ROAD_KERB_EXTRA_PX / 2


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


def _base_layer(layer, p, mode, theme):
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
        paint["fill-color"] = p["landuse_kind"].get(i, p["landuse"])
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
                paint["line-color"] = _far(p, "edge") if major else \
                    ["interpolate", ["linear"], ["zoom"], 13, p["minor_edge_far"], 15, p["minor_edge"]]
            else:
                # Вдали — цвет класса (магистраль оранжевее, улица белее), вблизи —
                # асфальт, на котором видна разметка. Как у Яндекса.
                paint["line-color"] = ["interpolate", ["linear"], ["zoom"], 13, _far(p, "fill"),
                                       14.5, _far(p, "fill"),
                                       15.5, class_asphalt(p, "class")] \
                    if major else ["interpolate", ["linear"], ["zoom"], 14.5, p["minor_far"], 15.5, p["minor"]]
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
        if "ref" not in json.dumps(lay.get("text-field")):
            lay["text-field"] = street_name()
        # Обычным регистром: «ул. Фуркат», а не «УЛ. ФУРКАТ». Капс с разрядкой
        # был длиннее на треть, чаще не помещался и читался криком; Яндекс,
        # Apple и 2ГИС пишут имя улицы обычными буквами (13.10.2026).
        street = i.startswith("highway-name")
        lay.update({"text-transform": "none" if street else "uppercase",
                    "text-letter-spacing": 0.02 if street else 0.1,
                    # Реже и не впритык: каждая встречная лента подписана своей
                    # строкой, и при шаге по умолчанию одно имя стояло восемь раз.
                    # Каждая лента проспекта подписана отдельно: на Зарканаре
                    # одно имя стояло шесть раз на экран (05.10.2026). Шаг и
                    # отступ — чтобы улица читалась один-два раза.
                    "symbol-spacing": 900, "text-padding": 50, "text-font": ["Noto Sans Bold"],
                    # Крупнее вблизи: на асфальте в 11 px имя терялось.
                    "text-size": ["interpolate", ["linear"], ["zoom"], 13, 10.5, 16, 12, 18, 14, 20, 16]
                    if street else ["interpolate", ["linear"], ["zoom"], 13, 10, 16, 11.5, 18, 13.5, 20, 15]})
        if street:
            paint.update({"text-color": p["street_label"], "text-halo-color": street_halo(p),
                          "text-halo-width": 1.8, "text-halo-blur": 0.2})
        else:
            # Номер трассы лежит на своём щите — ореол фоновый, как был.
            paint.update({"text-color": p["label"], "text-halo-color": p["halo"],
                          "text-halo-width": 2.0, "text-halo-blur": 0.6})
    elif l["type"] == "symbol":
        lay = l.setdefault("layout", {})
        if i == "waterway-name":
            # Арык в трубе под дорогой не виден, а его имя ложилось наискось
            # поперёк проспекта («Калькауз» у Нурафшон, снимок CarPlay
            # 13.10.2026). Подписываем только открытую воду.
            l["filter"] = _with(["!=", "brunnel", "tunnel"], l.get("filter"))
        if "name:latin" in json.dumps(lay.get("text-field", "")):
            lay["text-field"] = NAME
        paint["text-halo-color"] = p["halo"]
        if "text-color" in paint and mode == "full" and theme == "dark":
            paint["text-color"] = p["label"]
        if src == "poi" and i.startswith("poi-level"):
            paint["text-color"] = poi_colour(p, theme)
            paint["text-halo-width"] = 1.4
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
    """Асфальт нашего полотна — по классу на всех зумах (27.C): иерархия
    читается цветом, а не только шириной."""
    return class_asphalt(p)


def class_asphalt(p, key="cls"):
    """Магистраль, проспект, улица второго и третьего класса, прочие — каждая
    своим тоном. До 27.C вблизи был один серый асфальт: светлые дворы рядом
    с тёмным узлом давали лоскутную карту (Кумарик, 07.10.2026) — у белых
    дворов теперь серая кромка, а площадь узла — тона проспекта.
    key — свойство класса: cls (наш тайл, число) или class (основа, строка)."""
    if key == "cls":
        return ["match", ["get", "cls"], [1, 2], p["road_trunk"], 3, p["road"], 4, p["road_secondary"],
                5, p["road_tertiary"], p["minor"]]
    return ["match", ["get", "class"], ["motorway", "trunk"], p["road_trunk"], "primary", p["road"],
            "secondary", p["road_secondary"], "tertiary", p["road_tertiary"], p["minor"]]


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
         "minzoom": 17.5, "filter": ["==", ["get", "kind"], "stall"],
         "layout": {"line-cap": "butt"},
         "paint": {"line-color": p["paint"],
                   "line-width": ["interpolate", ["exponential", 2], ["zoom"], 17, 0.5, 20, 1.8],
                   "line-opacity": ["interpolate", ["linear"], ["zoom"], 17.5, 0, 18, 0.85]}},
        {"id": "radar-median", "type": "fill", "source": "radar", "source-layer": "surface", "minzoom": 15.5,
         "filter": ["all", ["==", ["geometry-type"], "Polygon"], ["==", ["get", "kind"], 9],
                    ["!", ["has", "strip"]], ["!", ["has", "island"]]],
         # Островок на съезде — асфальт с белой штриховкой поверх.
         "paint": {"fill-color": p["road"], "fill-outline-color": p["paint"]}},
        # Островок на съезде — асфальт со штриховкой (разметка 1.16), как у
        # Яндекса, а не серая заплатка.
        {"id": "radar-island-hatch", "type": "fill", "source": "radar", "source-layer": "surface",
         "minzoom": 16.5,
         "filter": ["all", ["==", ["geometry-type"], "Polygon"], ["==", ["get", "kind"], 9],
                    ["!", ["has", "strip"]], ["!", ["has", "island"]]],
         "paint": {"fill-pattern": "hatch",
                   "fill-opacity": ["interpolate", ["linear"], ["zoom"], 16.5, 0, 17.2, 0.9]}},
        # Тоннель — ПОД наземными дорогами: полупрозрачный асфальт и
        # пунктирная кромка. Раньше он рисовался обычной дорогой поверх всего,
        # и на Кичик Халка йули не понять было, что дорога уходит под землю.
        {"id": "radar-tunnel-case", "type": "line", "source": "radar", "source-layer": "roads",
         "minzoom": OUR_ROADS_FROM, "filter": ["all", ["<=", ["get", "cls"], 7], ["has", "tunnel"]],
         "layout": {"line-join": "round", "line-cap": "butt"},
         # Пунктир — только тонкие края по обеим сторонам (линия с зазором
         # шириной в полотно). Пунктир на всю ширину давал блоки-зебру.
         "paint": {"line-color": p["casing"], "line-width": 1.0, "line-gap-width": measured(),
                   "line-dasharray": [3, 2], "line-opacity": 0.45}},
        {"id": "radar-tunnel", "type": "line", "source": "radar", "source-layer": "roads",
         "minzoom": OUR_ROADS_FROM, "filter": ["all", ["<=", ["get", "cls"], 7], ["has", "tunnel"]],
         "layout": {"line-join": "round", "line-cap": "butt"},
         # Едва видная полоса, как у Яндекса: плотный «призрак» тоннеля Фурката
         # поверх перекрёстка Навои читался второй дорогой (07.10.2026).
         "paint": {"line-color": p["tunnel"], "line-width": measured(), "line-opacity": 0.3}},
        {"id": "radar-roads-case", "type": "line", "source": "radar", "source-layer": "roads",
         "minzoom": OUR_ROADS_FROM, "filter": ["all", ["!", ["has", "tunnel"]], ["<=", ["get", "cls"], 7],
                                              ["!", ["has", "stub"]], ["!", ["has", "inner"]]],
         "layout": {"line-cap": "round", "line-join": "round", "line-sort-key": ["-", 0, ["get", "cls"]]},
         # Кромка: у магистралей (trunk…secondary) — жёлтая, как у Яндекса;
         # у tertiary — нейтральная, у мелких — цвет края мелкой улицы.
         "paint": {"line-color": ["case", ["<=", ["get", "cls"], 2], p["kerb_trunk"],
                                  ["<=", ["get", "cls"], 4], p["kerb"],
                                  ["<=", ["get", "cls"], 5], p["casing"], p["minor_edge"]],
                   "line-width": measured(ROAD_KERB_EXTRA_PX)}},
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
         # Только у магистралей: мелкие скругления дворовых углов (1–5 м²)
         # торчали серыми треугольниками у каждого примыкания (07.10.2026);
         # там угол закрывает круглое соединение самих линий.
         "filter": ["all", ["==", ["geometry-type"], "Polygon"], ["==", ["get", "kind"], 13],
                    ["==", ["get", "major"], True]],
         # Скругление угла — тем же асфальтом, что дороги вблизи: светлый
         # «дворовый» треугольник у примыкания читался заплаткой (07.10.2026).
         "paint": {"fill-color": ["interpolate", ["linear"], ["zoom"], 15,
                                  ["case", ["get", "major"], p["road"], p["minor"]], 16.5, p["road"]],
                   "fill-antialias": True}},
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
        # Бордюр угла перекрёстка (вид 16): продолжение кромки полотна по дуге
        # от устья подхода к устью соседа. Кромка лент под площадью узла не
        # видна, и бордюр проспекта обрывался, не дойдя до угла (18.10.2026).
        # Асфальт по ходу линии слева: сдвиг вправо кладёт бордюр снаружи,
        # ровно как кайму ленты (на 1,2 px за кромкой).
        {"id": "radar-junction-kerb", "type": "line", "source": "radar", "source-layer": "surface",
         "minzoom": OUR_ROADS_FROM,
         "filter": ["all", ["==", ["geometry-type"], "LineString"], ["==", ["get", "kind"], 16]],
         "layout": {"line-join": "round", "line-cap": "butt"},
         "paint": {"line-color": ["case", ["get", "major"], p["kerb"], p["casing"]],
                   "line-width": KERB_LINE_PX, "line-offset": KERB_LINE_PX / 2}},
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
                   # Вблизи (z19–20) тише: на площади перекрёстка зерно читалось
                   # грязью поверх асфальта (18.10.2026).
                   "fill-opacity": ["interpolate", ["linear"], ["zoom"], 16.5, 0, 17.5, 0.18, 19, 0.16, 20, 0.14]}},
        # Сплошная перед перекрёстком (последние 25 м подхода) — без штриха.
        {"id": "radar-markings-solid", "type": "line", "source": "radar", "source-layer": "markings",
         "minzoom": LANE_MARKINGS_FROM, "filter": ["all", ["!", ["has", "centre"]], ["has", "solid"]],
         "layout": {"line-cap": "butt"},
         "paint": {"line-color": p["paint"],
                   "line-width": ["interpolate", ["exponential", 2], ["zoom"], 16, 0.8, 20, 3],
                   "line-opacity": ["interpolate", ["linear"], ["zoom"], LANE_MARKINGS_FROM, 0,
                                    LANE_MARKINGS_FROM + 0.4, 1]}},
        {"id": "radar-markings", "type": "line", "source": "radar", "source-layer": "markings",
         "minzoom": LANE_MARKINGS_FROM,
         "filter": ["all", ["!", ["has", "centre"]], ["!", ["has", "solid"]]],
         "layout": {"line-cap": "butt"},
         # Реже, как у Яндекса: частый пунктир на многополосной улице рябил.
         "paint": {"line-color": p["paint"], "line-dasharray": [3, 7],
                   "line-width": ["interpolate", ["exponential", 2], ["zoom"], 16, 0.8, 20, 3],
                   "line-opacity": ["interpolate", ["linear"], ["zoom"], LANE_MARKINGS_FROM, 0,
                                    LANE_MARKINGS_FROM + 0.4, 1]}},
        # Осевая двусторонней дороги (build_mvt.centre_lines): прерывистая с
        # длинным штрихом (1.5 ПДД) или сплошная при подтверждённых 4+ полосах
        # (1.1). Штрих длиннее, чем у разделителя полос, — осевая читается осевой.
        {"id": "radar-centre-dashed", "type": "line", "source": "radar", "source-layer": "markings",
         "minzoom": 16.3, "filter": ["==", ["get", "centre"], 1],
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
        # Одностороннее движение — стрелки вдоль улицы, как у Яндекса. Только
        # на улицах (tertiary и мельче): проспект с разделительной — это две
        # односторонние ленты, и стрелки на каждой были бы шумом. Геометрия
        # в тайле уже по ходу движения (build_roads разворачивает oneway=-1).
        {"id": "radar-oneway", "type": "symbol", "source": "radar", "source-layer": "roads", "minzoom": 16,
         "filter": ["all", ["has", "oneway"], [">=", ["get", "cls"], 5], ["!", ["has", "tunnel"]]],
         "layout": {"symbol-placement": "line", "symbol-spacing": 110, "icon-image": "oneway",
                    "icon-rotate": 90, "icon-rotation-alignment": "map", "icon-pitch-alignment": "map",
                    "icon-padding": 2, "icon-ignore-placement": True,
                    "icon-size": ["interpolate", ["linear"], ["zoom"], 16, 0.55, 19, 1.0]},
         "paint": {"icon-opacity": ["interpolate", ["linear"], ["zoom"], 16, 0, 16.4, p["oneway_opacity"]]}},
        # Стрелки полос перед стоп-линией: одна на полосу (build_mvt.lane_arrows).
        {"id": "radar-arrows", "type": "symbol", "source": "radar", "source-layer": "arrows", "minzoom": 17,
         "layout": {"icon-image": ["match", ["get", "turn"], 1, "lane-through", 2, "lane-left", 3, "lane-right",
                                   4, "lane-slight_left", 5, "lane-slight_right", 6, "lane-uturn",
                                   7, "lane-through_left", 8, "lane-through_right", 9, "lane-left_right", ""],
                    "icon-rotate": ["get", "bearing"], "icon-rotation-alignment": "map",
                    "icon-pitch-alignment": "map", "icon-allow-overlap": True, "icon-ignore-placement": True,
                    "icon-size": arrow_size()}},
        # Светофоры как у Яндекса: по значку на каждый подход, ромбом вокруг
        # центра регулируемого перекрёстка (build_mvt.approach_lights, вид 14).
        # Жёлтой «вафли» больше нет — у Яндекса её нет (снимок 05.10.2026).
        {"id": "radar-signal-icon", "type": "symbol", "source": "radar", "source-layer": "surface", "minzoom": 16,
         "filter": ["all", ["==", ["geometry-type"], "Point"], ["==", ["get", "kind"], 14]],
         # Минималистично и не поверх камеры (владелец, 12.10): светофор
         # обходит значки камер и подписи (allow-overlap false), но сам никого
         # не выталкивает (ignore-placement true).
         "layout": {"icon-image": "traffic-light", "icon-allow-overlap": False,
                    "icon-ignore-placement": True, "icon-padding": 1,
                    "icon-size": ["interpolate", ["linear"], ["zoom"], 16, 0.7, 19, 1.0]}},
    ]


# Профиль приложения: стиль вшивается в бандл (docs/plan_map_offline.md §2.1),
# адрес сервера и номер выпуска тайлов подставляет телефон. Тайлы — только из
# выпуска v/<N>/ (кэш на год, корзины индекса), иначе сторож их не пропустит.
APP_BASE = "{{BASE}}"
APP_TILESET = "{{TILESET}}"
APP_STYLE_DIR = os.path.join(HERE, "..", "..", "RadarMap", "Resources", "MapStyle")


def build(base, theme="light", mode="full", tileset=None):
    """tileset — номер выпуска (или плейсхолдер): тайлы из /v/<N>/, а не из
    старых адресов без версии."""
    if theme not in PALETTES or mode not in ("full", "roads"):
        raise ValueError(f"тема {theme!r} / режим {mode!r}")
    p = PALETTES[theme]
    base = base.rstrip("/")
    tiles_root = base if tileset is None else f"{base}/v/{tileset}"
    with open(os.path.join(HERE, "osm-bright.json")) as handle:
        s = json.load(handle)
    s["sources"] = {
        "openmaptiles": {"type": "vector", "tiles": [tiles_root + "/omt/{z}/{x}/{y}.pbf"],
                         "minzoom": 0, "maxzoom": 14,
                         "attribution": "© OpenMapTiles © OpenStreetMap contributors"},
        "radar": {"type": "vector", "tiles": [tiles_root + "/mvt/{z}/{x}/{y}.mvt"],
                  "minzoom": 15, "maxzoom": 15},
    }
    s["glyphs"] = base + "/glyphs/{fontstack}/{range}.pbf"
    s["sprite"] = base + "/sprite/sprite"
    out = [l for l in (_base_layer(layer, p, mode, theme) for layer in s["layers"]) if l is not None]
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
        # Плоские дома — только на горячем телефоне: там приложение гасит
        # объём (EngineMapView.hotHiddenLayers) и включает этот слой, чтобы
        # город не опустел. По умолчанию выключен — объёмный рисует то же.
        out.insert(first_symbol, {"id": "building-flat", "type": "fill", "source": "openmaptiles",
                                  "source-layer": "building", "minzoom": 14,
                                  "layout": {"visibility": "none"},
                                  "paint": {"fill-color": p["building"],
                                            "fill-outline-color": p["building_wall"]}})
        first_symbol += 1
        # Объём (25.D, «у Яндекса дома объёмом под наклоном»): высота из
        # тайла (render_height OpenMapTiles: height, иначе этажи × 3,66, иначе
        # 5 м); без неё — 10 м, средний дом Ташкента. Дома «вырастают» с z15
        # до z16 — на виде района кубики шумят, а в пути (z16–18, наклон)
        # стоят в полный рост.
        out.insert(first_symbol, {"id": "building-3d", "type": "fill-extrusion", "source": "openmaptiles",
                                  "source-layer": "building", "minzoom": 14,
                                  "paint": {"fill-extrusion-color": p["building"],
                                            "fill-extrusion-vertical-gradient": True,
                                            "fill-extrusion-height": ["interpolate", ["linear"], ["zoom"], 15, 0, 16,
                                                                      ["coalesce", ["get", "render_height"], 10]],
                                            "fill-extrusion-base": ["interpolate", ["linear"], ["zoom"], 15, 0, 16,
                                                                    ["coalesce", ["get", "render_min_height"], 0]],
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
    # Объём моста: ограждение в метр по кромкам пролёта. Среди объёмных
    # слоёв, рядом с домами.
    out.insert(after, {"id": "radar-barrier-3d", "type": "fill-extrusion", "source": "radar",
                       "source-layer": "barriers", "minzoom": 16,
                       "paint": {"fill-extrusion-color": p["barrier"], "fill-extrusion-base": 0,
                                 "fill-extrusion-height": ["interpolate", ["linear"], ["zoom"], 16, 0, 16.6, 1.1],
                                 "fill-extrusion-vertical-gradient": True, "fill-extrusion-opacity": 1.0}})
    if mode == "full":
        _driver_pois(out, p, theme)
        # Номера домов — как у Яндекса, вблизи и ниже всех подписей по
        # важности: место для имени заведения важнее номера. В тайлах основы
        # слой есть всегда, в стиле его не было.
        first_poi = next(k for k, l in enumerate(out) if l.get("source-layer") == "poi")
        out.insert(first_poi, {
            "id": "housenumber", "type": "symbol", "source": "openmaptiles", "source-layer": "housenumber",
            "minzoom": 17,
            "layout": {"text-field": ["get", "housenumber"], "text-font": ["Noto Sans Regular"],
                       "text-size": ["interpolate", ["linear"], ["zoom"], 17, 10, 19, 12],
                       "text-padding": 3, "text-max-width": 4},
            "paint": {"text-color": p["housenumber"], "text-halo-color": p["building"],
                      "text-halo-width": 1}})
    s["layers"] = out
    s["light"] = p["light"]
    s["name"] = f"RadarMap — {'светлая' if theme == 'light' else 'тёмная'}, {'полная' if mode == 'full' else 'только дорога'}"
    return s


# Заправки и парковки — то, что водитель ищет на карте. Общие POI отбираются
# по рангу и требуют имя, и заправка без названия или безымянная парковка у
# торгового центра не попадали на карту вовсе. Отдельные слои: видны раньше
# прочих POI (заправка с z13), заметнее, и не двоятся с общими.
DRIVER_POI = ("fuel", "parking")


def _driver_pois(out, p, theme):
    for layer in out:
        if layer.get("source-layer") == "poi" and layer["id"].startswith("poi-level"):
            layer["filter"] = ["all", layer.get("filter", ["all"]), ["!in", "class", *DRIVER_POI]]
    last_poi = max((k for k, l in enumerate(out) if l.get("source-layer") == "poi"), default=len(out) - 1)
    fuel = {"id": "radar-poi-fuel", "type": "symbol", "source": "openmaptiles", "source-layer": "poi",
            "minzoom": 13, "filter": ["all", ["==", "$type", "Point"], ["==", "class", "fuel"]],
            "layout": {"icon-image": "fuel_11", "icon-size": ["interpolate", ["linear"], ["zoom"], 13, 1.0, 17, 1.4],
                       "icon-allow-overlap": False, "icon-padding": 4, "symbol-sort-key": 1,
                       "text-field": ["step", ["zoom"], "", 15, NAME],
                       "text-font": ["Noto Sans Regular"], "text-size": 11, "text-offset": [0, 1.3],
                       "text-anchor": "top", "text-optional": True, "text-max-width": 8},
            "paint": {"text-color": p["label"], "text-halo-color": p["halo"], "text-halo-width": 1.4}}
    # Значка «P» в спрайте нет — буква на синем ореоле, как дорожный знак;
    # спрайт на сервере ради этого перевыпускать не нужно.
    parking = {"id": "radar-poi-parking", "type": "symbol", "source": "openmaptiles", "source-layer": "poi",
               "minzoom": 14.5, "filter": ["all", ["==", "$type", "Point"], ["==", "class", "parking"]],
               "layout": {"text-field": "P", "text-font": ["Noto Sans Bold"],
                          "text-size": ["interpolate", ["linear"], ["zoom"], 14.5, 11, 17, 15],
                          "text-allow-overlap": False, "text-padding": 4, "symbol-sort-key": 2},
               "paint": {"text-color": "#FFFFFF",
                         "text-halo-color": "#2563D9" if theme == "light" else "#3B6FD6",
                         "text-halo-width": 4.5}}
    out[last_poi + 1:last_poi + 1] = [fuel, parking]


def app_styles():
    """{имя файла: текст} — стили для бандла приложения, светлый и тёмный."""
    return {f"map_style_{theme}.json": json.dumps(build(APP_BASE, theme, "full", tileset=APP_TILESET),
                                                  ensure_ascii=False, sort_keys=True, indent=1) + "\n"
            for theme in ("light", "dark")}


def main(argv):
    if "--app" in argv:
        # python3 server/omt/make_style.py --app — перегенерировать ресурсы
        # приложения; test_make_style сверяет, что в репо лежит ровно это.
        os.makedirs(APP_STYLE_DIR, exist_ok=True)
        for name, text in app_styles().items():
            with open(os.path.join(APP_STYLE_DIR, name), "w", encoding="utf-8") as handle:
                handle.write(text)
            print(f"{name}: {len(text) // 1024} КБ")
        return
    base = next((a for a in argv[1:] if not a.startswith("--")), "https://soulmed.uz/radarmap")
    theme = argv[argv.index("--theme") + 1] if "--theme" in argv else "light"
    mode = argv[argv.index("--mode") + 1] if "--mode" in argv else "full"
    json.dump(build(base, theme, mode), sys.stdout, ensure_ascii=False, separators=(",", ":"))


if __name__ == "__main__":
    main(sys.argv)
