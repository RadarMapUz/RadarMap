#!/usr/bin/env python3
"""Стиль карты RadarMap: OpenMapTiles (OSM, наша сборка Planetiler) + наши слои дороги.

Основа — OSM Bright (openmaptiles/osm-bright-gl-style, BSD; иконки CC-BY),
лежит рядом как osm-bright.json. Поверх — то, чего нет ни в одной открытой
схеме, а у нас есть: полотно по измеренной ширине, разметка полос,
разделительные, площади перекрёстков, зебры, стрелки, светофоры (build_mvt.py).

Две оси выбора:
* тема — light или dark (с 23.10.2026 палитра «Б — Чистый», 28.A: днём белые
  улицы на холодной светлой земле и тёплая только магистраль, ночью
  нейтральный графит панелей интерфейса — светлая карта в тёмной кабине слепит);
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
# Primary — 30, а не 24 (аудит 23.10, №4): на обзоре проспект шире улицы, а
# у 15-го зума две его ленты по ONEWAY_SHARE (16,5 м) — как наши измеренные
# ленты проспектов (Навои — 17–18 м), без скачка ширины на смене основы (№5).
CLASS_M = {"motorway": 32, "trunk": 30, "primary": 30, "secondary-tertiary": 16, "link": 8,
           "motorway-link": 9, "minor": 9, "service-track": 5.5, "path": 1.8, "path-steps": 1.8}
MAJOR = {"motorway", "trunk", "primary", "secondary-tertiary", "link", "motorway-link"}

# Палитра — «Б — Чистый» (28.A, выбор владельца 23.10.2026: «красивее, как
# Apple Maps / Amap, меньше цвета»). Прежняя — «ночь-премиум + чистый день»
# (27.C): жёлтый проспект и абрикосовая магистраль на тёплой земле, ночью
# сине-графитовая. Жёлтые дороги спорили с янтарным радаром и красной камерой,
# а синева ночи — с синим маршрутом. Числа контраста и правила —
# palette_check.py и test_palette_check.
#
# День: холодная светлая нейтральная земля, улицы и проспекты БЕЛЫЕ — их
# несёт серая кромка (у проспекта темнее, чем у двора), тёплый цвет остался
# только у магистрали (trunk/motorway). Дома — светло-серые объёмом: крыша
# светлее стен, свет и тень, а не цветная заливка. Зелень и вода — два
# единственных «цвета земли», как у Apple.
#
# Ночь: нейтральный графит без синевы — тот же тон, что панели интерфейса
# (Theme.background #111418 … surface #1e232a): карта и шторка над ней — одна
# ночь. Иерархия — светлотой: двор, проспект, магистраль светлее с каждым
# классом; у магистрали — приглушённая тёплая кромка.
#
# Ограничения, которые держат числа. Ночью светлота асфальта вне полосы
# 0,083–0,133: там линия маршрута теряет 3:1 и телом, и каймой — поэтому
# магистраль #626874 (0,138), а не #5a606c (0,116) со схемы. На ней же
# белое имя улицы и подпись места — не ниже 4,5:1, отсюда потолок её
# светлоты.
#
# Разметка днём (28.L, жалобы владельца: «разметку не видно»). На белой улице
# разметка была серой (#c4c9d1) — и читалась швом или трещиной, а не краской;
# белые стрелки полос и штриховку островков держала только тень. Как у Apple
# Maps и Amap: на обзоре улицы белые, а с того зума, где появляется наше
# полотно с разметкой (ASPHALT_NEAR), полотно улиц и проспектов плавно
# становится светло-серым асфальтом (near_*), магистраль — тёплым, но темнее
# обзорного, и вся разметка — БЕЛАЯ. Порог — белая краска к асфальту
# любого размеченного класса не ниже PAINT_MIN по яркости (palette_check).
# Двор остаётся белым: разметки полос на нём нет (осевая — только до
# tertiary, build_mvt.CENTRE_MAX_CLASS), а светло-серый двор сливался бы с
# крышами домов (#e4e6ea) и землёй кварталов. Зебра лежит на подложке тона
# проспекта — на белом дворе и на магистрали она остаётся зеброй.
PALETTES = {
    "light": {
        "bg": "#f2f3f5", "park": "#cdeac0", "wood": "#c1e3b0", "water": "#a9d5f7",
        "road_trunk": "#ffe2a8", "road": "#ffffff", "road_secondary": "#ffffff", "road_tertiary": "#ffffff",
        # Двор — белый с серой кромкой (как у Яндекса и Apple); дорожка —
        # серее земли, а не белая: с двором её не спутать (аудит 28.09.2026).
        "minor": "#ffffff", "minor_far": "#ffffff", "minor_edge": "#d9dce1", "minor_edge_far": "#e1e3e7",
        "path": "#e8eaee", "path_edge": "#d6d9de",
        # Обзор (до 15-го): та же иерархия, спокойнее — тёплая только
        # магистраль, проспекты белые с кромкой темнее улиц.
        "far_motorway": "#ffd896", "far_motorway_edge": "#e9ab55",
        "far_trunk": "#ffe2a8", "far_trunk_edge": "#eeb65e",
        # Кайма проспекта и второго класса темнее (аудит 23.10, №4): белую
        # дорогу на земле #f2f3f5 (1,11:1) несёт только кайма, и при светлой
        # кайме проспект не отличался от улицы третьего класса.
        "far_primary": "#ffffff", "far_primary_edge": "#9aa3b0",
        "far_secondary": "#ffffff", "far_secondary_edge": "#adb4be",
        "far_tertiary": "#ffffff", "far_tertiary_edge": "#d6d9de",
        # Полотно вблизи (28.L, с ASPHALT_NEAR): светло-серый асфальт под
        # белой разметкой; магистраль тёплая, но темнее обзорной; двор белый.
        "near_trunk": "#ecd096", "near_primary": "#d2d6dd", "near_secondary": "#d2d6dd",
        "near_tertiary": "#d2d6dd", "near_minor": "#ffffff",
        # Разметка белая — краска на сером асфальте. Зебра — белые штрихи на
        # подложке тона проспекта. Черты парковочных мест — серые: площадка
        # парковки светлая, белое на ней не видно.
        "median": "#d8e8cf", "concrete": "#e1e4e8", "zebra_base": "#d2d6dd", "paint": "#ffffff",
        "stall": "#c4c9d1",
        # Штриховка островка из спрайта — белая с альфой 0,92; при 0,9 слоя на
        # сером асфальте она давала 1,37:1, в полную силу — 1,42 (≥ PAINT_MIN).
        "hatch_opacity": 1.0,
        # Дома светлее земли не бывают: крыша чуть темнее фона, стены темнее
        # крыши — свет сбоку-сверху, нейтральный.
        "building": "#e4e6ea", "building_wall": "#cfd3da", "landuse": "#eceef1",
        # Свой тон у вида землепользования (слой основы → цвет) — едва заметный
        # оттенок на нейтральном; жилое — земля (landuse-residential).
        "landuse_kind": {"landuse-commercial": "#f1edef", "landuse-industrial": "#e9ebef",
                         "landuse-hospital": "#f4ebed", "landuse-school": "#f1efe6",
                         "landuse-cemetery": "#e0e9dc"},
        "boundary": "#ccd0d8", "building_shadow": "rgba(60,68,84,0.20)",
        # Подземный переход — сиреневый, но приглушённый: виден, не кричит.
        "underpass": "#c6c0ea", "underpass_edge": "#9a91cc",
        "footbridge": "#ffffff", "footbridge_edge": "#b6bcc6", "steps": "#d2d6dc",
        # Свет на объём (29.F): сильнее и чуть выше — стены теневой стороны
        # заметно темнее крыш, дом читается кубом со светом сбоку-сверху, а
        # не молочной коробкой (при 0,45 стена и крыша почти сливались).
        "light": {"anchor": "viewport", "color": "#f8fafd", "intensity": 0.62,
                  "position": [1.25, 210, 40]},
        # Высотки (≥ BUILDING_TALL_METERS) — свой тон; днём тот же, что у
        # остальных: город светлый и спокойный.
        "building_tall": "#e4e6ea",
        # Свечение магистрали — только ночью (29.F); днём его нет.
        "trunk_glow": None,
        # Кайма НАШИХ лент — нейтральная (Фурката, 28.09.2026: цветная у
        # каждой ленты давала «нитки» внутри асфальта).
        "casing": "#cfd3d9",
        # Кромка магистрали — тёплая; у проспекта и второго класса — серая,
        # темнее дворовой.
        "kerb": "#b9bfc8", "kerb_trunk": "#eeb65e", "trees": "trees", "asphalt": "asphalt", "gutter": "#c8cdd5",
        # Парковка — бледная площадка без кромки проспекта (Чорсу).
        "parking": "#e8eaee", "parking_edge": "#d5d9df", "barrier": "#eceef1",
        # Мост: светлый край-ограждение и тень под пролётом; тоннель —
        # полупрозрачный асфальт с пунктирной кромкой (как у Яндекса).
        "bridge_edge": "#ffffff", "bridge_shadow": "rgba(40,48,60,0.22)", "tunnel": "#dcdfe4",
        "tree_crown": "#b3db9c", "tree_crown_low": "#93c77c", "tree_crown_high": "#c9e8b6",
        "tree_light": "#d0ecbf", "tree_trunk": "#9a948c", "tree_shadow": "rgba(55,85,45,0.24)",
        "label": "#2d3036", "street_label": "#2b2e33", "halo": "#ffffff", "oneway_opacity": 0.55,
        "housenumber": "#707681", "water_label": "#3b78b8",
        # Рельсы и аэродром — нейтральные: белое поле аэропорта ночью слепило.
        "rail": "#b6bbc4", "aeroway": "#e6e8ec", "aeroway_edge": "#c5cad2",
        # Асфальт поездки (29.B, как у Amap): в поездке с DRIVE_ASPHALT полотно
        # тёмное серо-синее, разметка белая, кромки светлые. Светлота асфальта —
        # не выше 0,087: маршрут в поездке берёт ночной набор (RouteColors
        # .night), и его светлое тело держит 3:1 только на тёмном полотне;
        # в полосе 0,087–0,137 линия теряет 3:1 и телом, и каймой. Магистраль
        # — чуть теплее и светлее улиц. Двор остаётся белым с серой кромкой:
        # тёмная паутина дворов поперёк кварталов спорила с улицами, по
        # которым едут, а разметки на дворе нет. Имя улицы — светлое, ореол —
        # цвета асфальта (street_halo); имя двора — прежнее (DRIVE_KEEP_LAYERS).
        "drive_trunk": "#4b4f5a", "drive_primary": "#3f4859", "drive_secondary": "#3f4859",
        "drive_tertiary": "#434c5e", "drive_minor": "#ffffff",
        "drive_kerb": "#e4e8ee", "drive_kerb_trunk": "#f0c46e", "drive_minor_edge": "#d9dce1",
        "drive_casing": "#d7dce3", "drive_gutter": "#363e4d", "drive_zebra_base": "#3f4859",
        "drive_paint": "#ffffff", "drive_street_label": "#f2f4f7",
        # Дома в поездке (29.F) — чуть светлее и холоднее: на тёмном асфальте
        # светлые объёмы как у Amap, без прозрачности (она просвечивала стены).
        "drive_building": "#e9ecf1",
    },
    "dark": {
        "bg": "#16181c", "park": "#16271e", "wood": "#14241b", "water": "#172a40",
        # Светлота растёт с классом: двор 0,03, проспект 0,06, магистраль 0,14.
        "road_trunk": "#626874", "road": "#40454f", "road_secondary": "#383c45", "road_tertiary": "#33373f",
        # Ночью улица СВЕТЛЕЕ домов: двор темнее домов пропадал (07.10.2026).
        "minor": "#30343c", "minor_far": "#30343c", "minor_edge": "#1f2227", "minor_edge_far": "#1c1e22",
        "path": "#24272c", "path_edge": "#1e2025",
        "far_motorway": "#6b717d", "far_motorway_edge": "#a88c55",
        "far_trunk": "#636975", "far_trunk_edge": "#9a8352",
        "far_primary": "#464b55", "far_primary_edge": "#2a2d33",
        "far_secondary": "#3a3e47", "far_secondary_edge": "#25282d",
        "far_tertiary": "#32363e", "far_tertiary_edge": "#212328",
        # Ночью полотно вблизи — то же, что на 15-м: светлая разметка на
        # графите и так читается (3,7:1 на проспекте).
        "near_trunk": "#626874", "near_primary": "#40454f", "near_secondary": "#383c45",
        "near_tertiary": "#33373f", "near_minor": "#30343c",
        # Разметка ночью — приглушённо-светлая: белая во весь экран слепит.
        "median": "#1a2a20", "concrete": "#3b3f47", "zebra_base": "#2e3137", "paint": "#9aa0aa",
        "stall": "#9aa0aa", "hatch_opacity": 0.9,
        # Дома — графитовые объёмы светлее земли и темнее любой улицы;
        # крыша светлее стен.
        "building": "#24272e", "building_wall": "#1b1d22", "landuse": "#1a1c20",
        "landuse_kind": {"landuse-commercial": "#1e1c21", "landuse-industrial": "#1b1d21",
                         "landuse-hospital": "#201c20", "landuse-school": "#1e1e1d",
                         "landuse-cemetery": "#17211b"},
        "boundary": "#3a3e47", "building_shadow": "rgba(0,0,0,0.5)",
        "underpass": "#4d4870", "underpass_edge": "#7870a8",
        "footbridge": "#3b3f47", "footbridge_edge": "#5a5f69", "steps": "#2a2d33",
        "light": {"anchor": "viewport", "color": "#d8dde6", "intensity": 0.5,
                  "position": [1.25, 210, 40]},
        # Ночью высотки чуть теплее и светлее (подсвеченные крыши Tashkent
        # City), умеренно: акцент на карте — маршрут, камеры и машина.
        "building_tall": "#34322f",
        # Магистраль ночью чуть светится тёплым, как под фонарями (29.F):
        # широкая размытая полоса под кромкой, слабая — акцент остаётся за
        # маршрутом, камерами и машиной.
        "trunk_glow": "#c9a35a",
        "casing": "#25282e",
        "kerb": "#575c66", "kerb_trunk": "#9a8352", "trees": "trees-dark", "asphalt": "asphalt-dark",
        "gutter": "#1d2025",
        "parking": "#212429", "parking_edge": "#2c2f36", "barrier": "#4a4f58",
        "bridge_edge": "#6b717c", "bridge_shadow": "rgba(0,0,0,0.45)", "tunnel": "#262a30",
        "tree_crown": "#1d3628", "tree_crown_low": "#152a1f", "tree_crown_high": "#2a4a37",
        "tree_light": "#284634", "tree_trunk": "#3a3632", "tree_shadow": "rgba(0,0,0,0.5)",
        "label": "#e6e9ee", "street_label": "#f2f4f7", "halo": "#16181c", "oneway_opacity": 0.7,
        "housenumber": "#8b929d", "water_label": "#7fa6d1",
        "rail": "#4a4f59", "aeroway": "#2a2e35", "aeroway_edge": "#3d424b",
        # Ночью асфальт поездки — тот же графит: светлая разметка на нём и так
        # читается, а маршрут уже ночной. Ключи те же, что днём, — палитры
        # обязаны определять одни цвета (test_themes_define_the_same_colours).
        "drive_trunk": "#626874", "drive_primary": "#40454f", "drive_secondary": "#383c45",
        "drive_tertiary": "#33373f", "drive_minor": "#30343c",
        "drive_kerb": "#575c66", "drive_kerb_trunk": "#9a8352", "drive_minor_edge": "#1f2227",
        "drive_casing": "#25282e", "drive_gutter": "#1d2025", "drive_zebra_base": "#2e3137",
        "drive_paint": "#9aa0aa", "drive_street_label": "#f2f4f7",
        "drive_building": "#24272e",
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
    far, near = class_asphalt(p, "class"), class_asphalt(near_palette(p), "class")
    if far == near:
        return ["interpolate", ["linear"], ["zoom"], 14.5, p["halo"], 15.5, far]
    # Днём (28.L) полотно с ASPHALT_NEAR уходит к серому — ореол вместе с ним.
    return ["interpolate", ["linear"], ["zoom"], 14.5, p["halo"], ASPHALT_NEAR[0], far, ASPHALT_NEAR[1], near]


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


# Наибольший излом подписи улицы между соседними буквами, градусы.
STREET_LABEL_MAX_ANGLE = 15

# С этого зума кайма линий основы гаснет к OUR_ROADS_FROM.
CASING_FADE_FROM = 14.6

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
# стороны) — бордюр магистрали. Бордюр угла перекрёстка — та же
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
        if "fill-outline-color" in paint:
            paint["fill-outline-color"] = p["path_edge"]
    elif i == "road_pier":
        paint["line-color"] = p["path"]
    elif i == "boundary-land-level-4":
        # Районные границы — тонкий бледный штрих только издали: жирная
        # серая пунктирная ломаная поверх города читалась дорогой (06.10.2026).
        paint["line-color"] = p["boundary"]
        paint["line-width"] = ["interpolate", ["linear"], ["zoom"], 10, 0.6, 14, 1.0]
        paint["line-opacity"] = ["interpolate", ["linear"], ["zoom"], 12, 0.8, 14.5, 0]
        l["maxzoom"] = 14.5
    elif i in ("building", "building-top"):
        return None      # заменяются объёмными (режим full)
    elif l["type"] == "line" and ("railway" in i or i.startswith("cablecar")):
        # Рельсы и канатка — нейтральным тоном темы: светло-серые #bbb из
        # OSM Bright ночью горели ярче проспекта (28.A).
        paint["line-color"] = p["rail"]
    elif src == "aeroway":
        # Поле и полосы аэродрома: белое поле OSM Bright ночью слепило
        # пятном на полгорода (28.A). Полоса читается кромкой.
        key = "aeroway_edge" if i.endswith("-casing") else "aeroway"
        paint["line-color" if l["type"] == "line" else "fill-color"] = p[key]
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
                near = class_asphalt(near_palette(p), "class")
                if not major:
                    paint["line-color"] = ["interpolate", ["linear"], ["zoom"], 14.5, p["minor_far"], 15.5, p["minor"]]
                elif near == class_asphalt(p, "class"):
                    paint["line-color"] = ["interpolate", ["linear"], ["zoom"], 13, _far(p, "fill"),
                                           14.5, _far(p, "fill"), 15.5, class_asphalt(p, "class")]
                else:
                    # Днём запасная линия под нашей лентой уходит к асфальту
                    # вблизи вместе с ней (ASPHALT_NEAR): где нашего тайла нет,
                    # дорога того же тона, что соседние.
                    paint["line-color"] = ["interpolate", ["linear"], ["zoom"], 13, _far(p, "fill"),
                                           14.5, _far(p, "fill"), ASPHALT_NEAR[0], class_asphalt(p, "class"),
                                           ASPHALT_NEAR[1], near]
            paint["line-width"] = class_width(metres, (2.0 if major else 1.4) if casing else 0.0,
                                              near_share=1.0 if casing else FALLBACK_SHARE)
            paint["line-opacity"] = 1 if major else ["interpolate", ["linear"], ["zoom"], 12.5, 0, 13.5, 1]
            if casing:
                # Кайма основы гаснет к 15-му плавно (аудит 23.10, №5): обрыв
                # на OUR_ROADS_FROM делал дорогу на автозуме вдруг светлее. У
                # мелочи кайма появляется только с 13,5 (№4): на 12–13 дворы
                # с каймой рябили серой сеткой и спорили с проспектами.
                fade = [CASING_FADE_FROM, 1, OUR_ROADS_FROM, 0]
                paint["line-opacity"] = ["interpolate", ["linear"], ["zoom"], *fade] if major else \
                    ["interpolate", ["linear"], ["zoom"], 13.5, 0, 14.5, 1, *fade]
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
                    # Не гнуть подпись через узел (аудит 23.10, №14): при 45° по
                    # умолчанию «ул. Шарафа Рашидова» дугой лежала поперёк
                    # площади перекрёстка Навои. Замер на этом узле: при 25° и
                    # 20° дуга остаётся, при 15° подпись уходит на прямую.
                    "text-max-angle": STREET_LABEL_MAX_ANGLE,
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
        if "text-color" in paint and mode == "full":
            # Подписи мест — одним нейтральным тоном темы (днём OSM Bright
            # давал #333 и бурый #633 у районов: тёплое пятно на чистой
            # карте, 28.A); имена воды — своим синим.
            water = i.startswith(("water", "waterway"))
            paint["text-color"] = p["water_label"] if water else p["label"]
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


# Свечение магистрали ночью: на сколько пикселей шире полотна (на обе
# стороны) и сила. Размытие — на всю ширину ореола: края нет, только свет.
TRUNK_GLOW_EXTRA_PX = 16
TRUNK_GLOW_OPACITY = 0.16

# Высотка — с этой высоты (м) тон дома уходит к building_tall, к
# BUILDING_TALL_FULL — целиком: у Tashkent City и Ташкент-Сити Парка 60–150 м.
BUILDING_TALL_METERS = 35
BUILDING_TALL_FULL = 110


def building_colour(p):
    """Цвет дома: по высоте из тайла, если у темы свой тон высоток."""
    if p["building_tall"] == p["building"]:
        return p["building"]
    return ["interpolate", ["linear"], ["coalesce", ["get", "render_height"], 10],
            BUILDING_TALL_METERS, p["building"], BUILDING_TALL_FULL, p["building_tall"]]


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
    return _bridge_order(_near_asphalt(_layers_in_draw_order(p), _layers_in_draw_order(near_palette(p))))


# Полотно под разметкой (28.L): с ASPHALT_NEAR[0] асфальт цвета обзора, к
# ASPHALT_NEAR[1] — тон near_*. Начало — OUR_ROADS_FROM: наше полотно сменяет
# белую линию основы без скачка; конец — до первой разметки (зебры, стоп-линии
# и штриховка с 16,5, полосы и стрелки с LANE_MARKINGS_FROM).
ASPHALT_NEAR = (OUR_ROADS_FROM, 16)
# Ключ асфальта на 15-м → его тон вблизи.
NEAR_KEYS = {"road_trunk": "near_trunk", "road": "near_primary", "road_secondary": "near_secondary",
             "road_tertiary": "near_tertiary", "minor": "near_minor"}
COLOUR_PROPS = ("line-color", "fill-color")


def near_palette(p):
    """Палитра вблизи: асфальт классов заменён тоном near_*, остальное то же."""
    return dict(p, **{key: p[near] for key, near in NEAR_KEYS.items()})


def at_zoom_near(far, near):
    """Цвет, переходящий к асфальту вблизи на ASPHALT_NEAR; ночью (тон тот же) — как был."""
    if far == near:
        return far
    if "zoom" in json.dumps([far, near]):
        # Зум можно звать только на верхнем уровне выражения: вложенный
        # interpolate движок отвергнет вместе со всем стилем.
        raise ValueError("цвет асфальта уже зависит от зума — вложить нельзя")
    return ["interpolate", ["linear"], ["zoom"], ASPHALT_NEAR[0], far, ASPHALT_NEAR[1], near]


def _near_asphalt(layers, near_layers):
    """Слои, чей цвет зависит от асфальта, плавно уходят к тону вблизи.

    Те же слои, собранные по палитре вблизи, отличаются ровно цветом
    асфальта: где цвет разный — он переходит по зуму. Так и площадь узла,
    чьё выражение цвета правится отдельно (класс узла из тайла), следует за
    лентами без второго списка «кто асфальт».
    """
    for layer, near in zip(layers, near_layers):
        for prop in COLOUR_PROPS:
            if prop in layer.get("paint", {}):
                layer["paint"][prop] = at_zoom_near(layer["paint"][prop], near["paint"][prop])
    return layers


# Асфальт поездки (29.B): с DRIVE_ASPHALT[0] полотно, кромки, разметка и
# ореол имени улицы плавно уходят к тонам drive_* и к DRIVE_ASPHALT[1] стоят
# в них целиком. Стиль из-за этого не перезагружается: генератор пишет только
# РАЗНИЦУ — {слой: {свойство цвета: выражение}} (map_drive_<тема>.json), и
# приложение кладёт её свойствами слоёв на старте поездки и снимает на
# остановке (EngineDriveAsphalt). Вне поездки стиль тот же, что был.
# Окно — то же, что у серого асфальта вблизи (ASPHALT_NEAR), только к его
# концу полотно уже тёмное: камера поездки на телефоне стоит на z16–17,
# в машине — на z15,5–16,5 (DriveCamera), и при окне 16→17 асфальт всю
# поездку оставался серединой перехода — серым, а не тёмным (снимки 29.B).
DRIVE_ASPHALT = (OUR_ROADS_FROM, 16)
# Имя улицы меняет цвет ступенькой посередине: тёмное на светлеющем и
# светлое на темнеющем асфальте — плавный переход провёл бы его через серое
# на сером.
DRIVE_LABEL_STEP = 15.5
DRIVE_KEYS = {"near_trunk": "drive_trunk", "near_primary": "drive_primary",
              "near_secondary": "drive_secondary", "near_tertiary": "drive_tertiary",
              "near_minor": "drive_minor", "kerb": "drive_kerb", "kerb_trunk": "drive_kerb_trunk",
              "minor_edge": "drive_minor_edge", "casing": "drive_casing", "gutter": "drive_gutter",
              "zebra_base": "drive_zebra_base", "paint": "drive_paint",
              "street_label": "drive_street_label", "building": "drive_building"}
# Подписи дворов и дорожек: полотно под ними в поездке не темнеет, и имя
# остаётся тёмным на белом (общий ключ street_label перекрасил бы и их).
DRIVE_KEEP_LAYERS = ("highway-name-minor", "highway-name-path")
DRIVE_COLOUR_PROPS = ("line-color", "fill-color", "fill-outline-color", "text-color",
                      "text-halo-color", "circle-color", "icon-color", "fill-extrusion-color")


def drive_palette(p):
    """Палитра поездки: асфальт вблизи, кромки, разметка и имя улицы — drive_*."""
    out = dict(p, **{key: p[drive] for key, drive in DRIVE_KEYS.items()})
    # Тон высоток без своего цвета следует за домом поездки (иначе днём
    # высотки остались бы прежнего тона среди посветлевших домов).
    if p["building_tall"] == p["building"]:
        out["building_tall"] = out["building"]
    return out


def _zoom_stops(value):
    """Ступени линейной интерполяции по зуму верхнего уровня; None — не она."""
    if (isinstance(value, list) and len(value) >= 5 and value[0] == "interpolate"
            and value[1] == ["linear"] and value[2] == ["zoom"]):
        return value[3:]
    return None


def _zoom_free(value):
    return "zoom" not in json.dumps(value)


def drive_value(prop, normal, drive):
    """Цвет слоя в поездке: обычный до DRIVE_ASPHALT[0], цвет поездки с DRIVE_ASPHALT[1]."""
    stops = _zoom_stops(drive)
    high = stops[-1] if stops else drive
    if not _zoom_free(high):
        raise ValueError(f"{prop}: цвет поездки зависит от зума глубже верхнего уровня")
    if prop == "text-color":
        if not _zoom_free(normal):
            raise ValueError("цвет подписи уже зависит от зума — ступеньку не поставить")
        return ["step", ["zoom"], normal, DRIVE_LABEL_STEP, high]
    start, end = DRIVE_ASPHALT
    if _zoom_free(normal):
        return ["interpolate", ["linear"], ["zoom"], start, normal, end, high]
    own = _zoom_stops(normal)
    if own is None or not all(_zoom_free(v) for v in own[1::2]):
        raise ValueError(f"{prop}: обычный цвет — не простая интерполяция по зуму")
    # Ступени до начала окна — как были; дальше — цвет поездки. Ступень
    # внутри окна (серый асфальт вблизи у 16-го) заменяется поездкой.
    head = [x for z, v in zip(own[0::2], own[1::2]) if z <= start for x in (z, v)]
    if not head:
        raise ValueError(f"{prop}: обычный цвет начинается позже {start}-го")
    if head[-2] < start:
        later = [z for z in own[0::2] if z > start]
        if later:
            raise ValueError(f"{prop}: ступень обычного цвета внутри окна поездки")
        head += [start, head[-1]]
    return normal[:3] + head + [end, high]


def drive_overrides(theme):
    """{слой: {свойство: выражение}} — чем стиль поездки отличается от обычного."""
    normal = build(APP_BASE, theme, "full", tileset=APP_TILESET)["layers"]
    driven = build(APP_BASE, theme, "full", tileset=APP_TILESET,
                   palette=drive_palette(PALETTES[theme]))["layers"]
    if [l["id"] for l in normal] != [l["id"] for l in driven]:
        raise ValueError("палитра поездки поменяла состав слоёв")
    out = {}
    for a, b in zip(normal, driven):
        if a["id"] in DRIVE_KEEP_LAYERS:
            continue
        for prop in DRIVE_COLOUR_PROPS:
            was, now = a.get("paint", {}).get(prop), b.get("paint", {}).get(prop)
            if was != now:
                out.setdefault(a["id"], {})[prop] = drive_value(prop, was, now)
    return out


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
         "paint": {"line-color": p["stall"],
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
                   "fill-opacity": ["interpolate", ["linear"], ["zoom"], 16.5, 0, 17.2, p["hatch_opacity"]]}},
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
        # Кромка площади узла (аудит 23.10, №1): контур многоугольника узла
        # цветом кромки, под каймой лент. Внутреннюю половину закрывает
        # заливка узла, у подходов — сами ленты; остаётся бордюр по внешнему
        # краю. Крупные узлы с запасной оболочкой (610 из 2856 ≥ 300 м² в
        # Ташкенте, среди них Навои × Рашидов) кромки из тайла не имеют и
        # сливались с тротуаром.
        *([] if not p["trunk_glow"] else [
            {"id": "radar-trunk-glow", "type": "line", "source": "radar", "source-layer": "roads",
             "minzoom": OUR_ROADS_FROM, "filter": ["all", ["!", ["has", "tunnel"]], ["<=", ["get", "cls"], 2]],
             "layout": {"line-cap": "round", "line-join": "round"},
             "paint": {"line-color": p["trunk_glow"], "line-width": measured(TRUNK_GLOW_EXTRA_PX),
                       "line-blur": TRUNK_GLOW_EXTRA_PX, "line-opacity": TRUNK_GLOW_OPACITY}}]),
        {"id": "radar-roads-case", "type": "line", "source": "radar", "source-layer": "roads",
         "minzoom": OUR_ROADS_FROM, "filter": ["all", ["!", ["has", "tunnel"]], ["<=", ["get", "cls"], 7],
                                              ["!", ["has", "stub"]], ["!", ["has", "inner"]]],
         "layout": {"line-cap": "round", "line-join": "round", "line-sort-key": ["-", 0, ["get", "cls"]]},
         # Кромка по классу (28.A): у магистрали — тёплая, у проспекта и
         # второго класса — серая темнее дворовой, у tertiary — нейтральная,
         # у мелких — цвет края мелкой улицы.
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
         # Цвет — без зума: переход к асфальту вблизи добавляет _near_asphalt.
         "paint": {"fill-color": p["road"], "fill-antialias": True}},
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
        # Бордюр угла перекрёстка (вид 16): продолжение кромки полотна по дуге
        # от устья подхода к устью соседа. Кромка лент под площадью узла не
        # видна, и бордюр проспекта обрывался, не дойдя до угла (18.10.2026).
        # Асфальт по ходу линии слева: сдвиг вправо кладёт бордюр снаружи,
        # ровно как кайму ленты (на 1,2 px за кромкой).
        # ПОД площадью узла, а не над ней: в кластере на много подходов
        # (Дурмон йули × Зиёлилар, 23.10.2026) устье подхода лежит внутри узла,
        # и прямой отрезок бордюра от устья до дуги шёл через асфальт — серой
        # «паутиной» лучей по площади перекрёстка. Под заливкой видна только
        # та часть бордюра, что лежит за краем площади, — настоящий бордюр.
        {"id": "radar-junction-kerb", "type": "line", "source": "radar", "source-layer": "surface",
         "minzoom": OUR_ROADS_FROM,
         "filter": ["all", ["==", ["geometry-type"], "LineString"], ["==", ["get", "kind"], 16]],
         "layout": {"line-join": "round", "line-cap": "butt"},
         "paint": {"line-color": ["case", ["get", "major"], p["kerb"], p["casing"]],
                   "line-width": KERB_LINE_PX, "line-offset": KERB_LINE_PX / 2}},
        # Площадь перекрёстка: скругляет углы между подходами. Узлы строятся
        # только там, где сходится дорога шире 9 м, и обрезаны кругом
        # досягаемости — цвет магистрального асфальта им честен.
        {"id": "radar-junction", "type": "fill", "source": "radar", "source-layer": "surface",
         "minzoom": OUR_ROADS_FROM,
         "filter": ["all", ["==", ["geometry-type"], "Polygon"], ["in", ["get", "kind"], ["literal", [8, 10]]]],
         # Цвет — по классу старшего подхода (свойство cls узла, 28.G): узел
         # магистрали — цвета магистрали, без заплаток цвета проспекта у
         # торцов эстакад. Тайлы без cls — прежний цвет проспекта.
         "paint": {"fill-color": ["case", ["has", "cls"], class_asphalt(p), p["road"]],
                   "fill-antialias": False}},
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
        # Настил — с круглыми концами (аудит 23.10, №2): прямые торцы соседних
        # кусков под углом оставляли клин, сквозь который просвечивали тень и
        # ограждение, — эстакада читалась лоскутным одеялом с поперечными швами.
        {"id": "radar-bridge", "type": "line", "source": "radar", "source-layer": "roads",
         "minzoom": OUR_ROADS_FROM, "filter": ["all", ["<=", ["get", "cls"], 7], ["==", ["get", "bridge"], True]],
         "layout": {"line-cap": "round", "line-join": "round"},
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


def build(base, theme="light", mode="full", tileset=None, palette=None):
    """tileset — номер выпуска (или плейсхолдер): тайлы из /v/<N>/, а не из
    старых адресов без версии. palette — своя палитра темы (поездка, 29.B)."""
    if theme not in PALETTES or mode not in ("full", "roads"):
        raise ValueError(f"тема {theme!r} / режим {mode!r}")
    p = palette or PALETTES[theme]
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
                                  "paint": {"fill-color": building_colour(p),
                                            "fill-outline-color": p["building_wall"]}})
        first_symbol += 1
        # Объём (25.D, «у Яндекса дома объёмом под наклоном»): высота из
        # тайла (render_height OpenMapTiles: height, иначе этажи × 3,66, иначе
        # 5 м); без неё — 10 м, средний дом Ташкента. Дома «вырастают» с z15
        # до z16 — на виде района кубики шумят, а в пути (z16–18, наклон)
        # стоят в полный рост.
        out.insert(first_symbol, {"id": "building-3d", "type": "fill-extrusion", "source": "openmaptiles",
                                  "source-layer": "building", "minzoom": 14,
                                  "paint": {"fill-extrusion-color": building_colour(p),
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
    """{имя файла: текст} — стили для бандла приложения, светлый и тёмный, и
    разница поездки к каждому (map_drive_<тема>.json, 29.B)."""
    out = {f"map_style_{theme}.json": json.dumps(build(APP_BASE, theme, "full", tileset=APP_TILESET),
                                                 ensure_ascii=False, sort_keys=True, indent=1) + "\n"
           for theme in ("light", "dark")}
    for theme in ("light", "dark"):
        out[f"map_drive_{theme}.json"] = json.dumps({"layers": drive_overrides(theme)},
                                                    ensure_ascii=False, sort_keys=True, indent=1) + "\n"
    return out


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
