#!/usr/bin/env python3
"""Замер палитры карты: контраст и различимость — числами, а не на глаз (27.C, 28.A).

Те же формулы, что RadarMapTests/PaletteTests: контраст WCAG по относительной
яркости, ΔE76 в CIELAB (D65), дейтеранопия — матрица Machado 2009 (как в
`deltaEDeutan`). Цвета приложения поверх карты (линия маршрута, пробки,
маркеры камер) живут в Swift — здесь их копия, и test_palette_check сверяет
её с Theme.swift и EngineMapView.swift, чтобы второй список не разошёлся с
первым молча.

    python3 server/omt/palette_check.py          # таблица чисел и нарушенные правила
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_style  # noqa: E402

# Поверх карты — из приложения (Theme.RouteColors, Theme.Types, MarkerLook).
ROUTE = {"light": {"body": "#0b62d0", "casing": "#0a3f8f",
                   "alternative": "#93b4ea", "alternativeCasing": "#46679f"},
         "dark": {"body": "#66a3ff", "casing": "#0e1a33",
                  "alternative": "#98acd2", "alternativeCasing": "#0e1a33"}}
# Пробки — «Сигнал» (TrafficPalette.active, 33H3): свободно, медленно,
# пробка, стоят.
TRAFFIC = {"light": {"free": "#7bac89", "slow": "#bb731e", "jam": "#993357", "stand": "#562353"},
           "dark": {"free": "#8ed3a0", "slow": "#fcbe62", "jam": "#d86691", "stand": "#b06aad"}}
# Заливки значков на карте (Theme.Types): с 29.C2 у всех камер один красный,
# свои — у поста ДПС и ДТП.
CAMERA_TYPES = {"camera": "#d93025", "post": "#46525e", "accident": "#c62828"}
CAMERA_RING = "#ffffff"
# Спокойная камера (вариант B «Спокойная карта»): заливка и кольцо по теме.
CALM = {"light": {"fill": "#3d4652", "ring": "#ffffff"},
        "dark": {"fill": "#aeb6c2", "ring": "#14181d"}}

# Пороги — правила 27.C (см. docs/plan_2026-10-22.md) и PaletteTests.
TEXT_MIN = 4.5          # подписи улиц и мест — текст (WCAG AA)
HOUSENUMBER_MIN = 3.0   # номер дома — второстепенная мелкая подпись на доме
POI_MIN = 3.0           # цветные подписи мест — на фоновом ореоле
GRAPHIC_MIN = 3.0       # линия маршрута, край маркера — графика (WCAG 1.4.11)
ALT_ROUTE_DE_MIN = 25   # другой вариант при выборе — не путается с выбранным (27.D)
CAMERA_DE_MIN = 30      # заливка камеры отличается от любой поверхности карты
CAMERA_DEUTAN_MIN = 15  # … и при дейтеранопии
TRAFFIC_DE_MIN = 30     # слой пробок читается на асфальте
SLOW_KERB_DE_MIN = 15   # «медленно» не путается с жёлтой кромкой магистрали
# Разметка (28.L): краска СВЕТЛЕЕ асфальта и отделяется от него не меньше
# чем на 1,4:1 по яркости на любом размеченном классе. Почему так, а не 3:1:
# разметка — фактура дороги, а не знак; 3:1 для белой краски значит асфальт
# темнее #959ba4, то есть тёмную карту днём. Почему не меньше: при 1,26:1
# (белое на обзорном #ffe2a8) и 1,30:1 (#dfe2e7) пунктир в 1–3 px на снимках
# растворялся; при 1,46 (#d2d6dd) он чёткий на z17–18 у Навои, Нурафшон и
# на Малой кольцевой. Знак — потому что серая краска на белом (1,66:1 до
# 28.L) читалась швом или трещиной, а не краской: краска на дороге светлее
# асфальта и у Apple, и у Amap, и на улице.
PAINT_MIN = 1.4
# Асфальт вблизи не сливается с крышами домов (дом #e4e6ea): серая лента
# в квартале остаётся лентой.
NEAR_HOUSE_DE_MIN = 5
# Альфа белой штриховки островка в спрайте (make_arrows.hatch: 235/255).
HATCH_ALPHA = 235 / 255
# Дома по назначению (30.A): оттенок виден рядом с обычным домом и отличает
# назначения друг от друга (ΔE76 ≥ 5 — заметно глазу рядом), но остаётся
# мягким — тише дороги и далеко от красного камеры.
USE_DE_MIN = 5
USE_CAMERA_DE_MIN = 40
# … и при дейтеранопии назначения не сливаются совсем (оттенок у них мягкий,
# различает в основном светлота).
USE_DEUTAN_MIN = 2


def rgb(colour):
    colour = colour.lstrip("#")
    return tuple(int(colour[k:k + 2], 16) / 255 for k in (0, 2, 4))


def _linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def luminance(colour):
    r, g, b = (_linear(c) for c in rgb(colour))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    la, lb = luminance(a), luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def _lab_from_linear(r, g, b):
    x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
    y = 0.2126 * r + 0.7152 * g + 0.0722 * b
    z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883

    def f(t):
        return t ** (1 / 3) if t > 0.008856 else 7.787 * t + 16 / 116
    return 116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z))


def lab(colour):
    return _lab_from_linear(*(_linear(c) for c in rgb(colour)))


DEUTAN = ((0.367322, 0.860646, -0.227968),
          (0.280085, 0.672501, 0.047413),
          (-0.011820, 0.042940, 0.968881))


def lab_deutan(colour):
    lin = [_linear(c) for c in rgb(colour)]
    out = [min(1, max(0, row[0] * lin[0] + row[1] * lin[1] + row[2] * lin[2])) for row in DEUTAN]
    return _lab_from_linear(*out)


def delta_e(a, b, deutan=False):
    conv = lab_deutan if deutan else lab
    return sum((p - q) ** 2 for p, q in zip(conv(a), conv(b))) ** 0.5


ASPHALT_KEYS = ("road", "road_trunk", "road_secondary", "road_tertiary", "minor",
                "near_primary", "near_trunk", "near_secondary", "near_tertiary", "near_minor")
# Полотно вблизи (28.L) у классов, где есть разметка полос и осевая: до
# tertiary (build_mvt.CENTRE_MAX_CLASS). Двор — без линий полос, он белый.
MARKED_KEYS = ("near_trunk", "near_primary", "near_secondary", "near_tertiary")
# Дороги обзора (до 15-го зума): линия маршрута лежит и на них.
FAR_KEYS = ("far_motorway", "far_trunk", "far_primary", "far_secondary", "far_tertiary")
TRUNK_PRIMARY_DE_MIN = 12   # магистраль видна издалека: отличается от проспекта
ROUTE_TRUNK_DE_MIN = 30     # линия маршрута не похожа на магистраль под ней


def _over(alpha, surface, top="#ffffff"):
    """Цвет полупрозрачного top поверх surface (смешение в sRGB, как у движка)."""
    mixed = (alpha * a + (1 - alpha) * b for a, b in zip(rgb(top), rgb(surface)))
    return "#" + "".join(f"{round(255 * c):02x}" for c in mixed)


def _edge(fill, surface):
    """Край маркера: заливка или белое кольцо — что контрастнее."""
    return max(contrast(fill, surface), contrast(CAMERA_RING, surface))


def _camera_visible(fill, surface):
    by_light = _edge(fill, surface) >= GRAPHIC_MIN
    return (by_light or delta_e(fill, surface) >= CAMERA_DE_MIN) and \
        (by_light or delta_e(fill, surface, True) >= CAMERA_DEUTAN_MIN)


def measure(theme, p=None):
    """Числа палитры: {имя: значение} и список нарушенных правил."""
    p = p or make_style.PALETTES[theme]
    route, traffic, calm = ROUTE[theme], TRAFFIC[theme], CALM[theme]
    asphalt = [p[k] for k in ASPHALT_KEYS]
    far = [p[k] for k in FAR_KEYS]
    uses = p["building_use"]
    ground = [p["bg"], p["landuse"], p["building"], p["park"], p["wood"], p["water"],
              *p["landuse_kind"].values(), *uses.values()]
    kerbs = [p["kerb"], p["kerb_trunk"]]
    surfaces = asphalt + ground
    m = {
        "подпись места / фон": contrast(p["label"], p["bg"]),
        # Подпись места читается на своём ореоле, но и без него (ореол узкий,
        # буквы ложатся на магистраль) — не ниже 4,5:1 к любому асфальту.
        "подпись места / асфальт (мин)": min(contrast(p["label"], a) for a in asphalt),
        "имя улицы / асфальт (мин)": min(contrast(p["street_label"], a) for a in asphalt),
        # До 15-го зума дорога тонкая, имя лежит на фоновом ореоле.
        "имя улицы / фон": contrast(p["street_label"], p["bg"]),
        "номер дома / дом": contrast(p["housenumber"], p["building"]),
        # Дома по назначению (30.A): подпись места и номер дома ложатся и на
        # цветной дом.
        "подпись места / дом по назначению (мин)": min(contrast(p["label"], c) for c in uses.values()),
        "номер дома / дом по назначению (мин)": min(contrast(p["housenumber"], c) for c in uses.values()),
        "ΔE дом по назначению / обычный дом (мин)": min(delta_e(c, p["building"]) for c in uses.values()),
        "ΔE назначения между собой (мин)": min(delta_e(a, b) for i, a in enumerate(uses.values())
                                               for b in list(uses.values())[i + 1:]),
        "ΔE назначения между собой, дейтеранопия (мин)": min(
            delta_e(a, b, True) for i, a in enumerate(uses.values()) for b in list(uses.values())[i + 1:]),
        "ΔE дом по назначению / красная камера (мин)": min(delta_e(c, CAMERA_TYPES["camera"])
                                                         for c in uses.values()),
        "ΔE дом по назначению / фон (макс)": max(delta_e(c, p["bg"]) for c in uses.values()),
        # Цветная подпись места лежит на своём ореоле (text-halo, ширина 1,4):
        # читается против ореола, а не против земли.
        "подписи мест цветом / ореол (мин)": min(contrast(c, p["halo"])
                                                for c in make_style.POI_COLOURS[theme].values()),
        "линия маршрута / асфальт и фон (мин)": min(max(contrast(route["body"], s), contrast(route["casing"], s))
                                                    for s in asphalt + far + [p["bg"]]),
        "ΔE линия маршрута / магистраль": min(delta_e(route["body"], p[k]) for k in ("road_trunk", "far_trunk",
                                                                                   "far_motorway")),
        # Другой вариант маршрута при выборе (27.D): бледнее, но на асфальте
        # любого класса читается телом или каймой — и отличим от выбранного.
        "другой вариант / асфальт и фон (мин)": min(max(contrast(route["alternative"], s),
                                                       contrast(route["alternativeCasing"], s))
                                                   for s in asphalt + [p["bg"]]),
        "ΔE другой вариант / выбранный": delta_e(route["alternative"], route["body"]),
        "ΔE другой вариант / выбранный, дейтеранопия": delta_e(route["alternative"], route["body"], True),
        # Маркер камеры виден, если отделяется от поверхности ЯРКОСТЬЮ
        # (заливка или белое кольцо ≥ 3:1) или ЦВЕТОМ — и при нормальном
        # зрении (ΔE ≥ 30), и при дейтеранопии (ΔE ≥ 15). Красная камера на
        # светлом асфальте — 2,5:1 по яркости у любой дневной палитры, её
        # несёт цвет; пурпурная передвижная на светлом ночном асфальте при
        # дейтеранопии сливается цветом, её несёт белое кольцо.
        "кромка камеры / поверхности (мин)": min(_edge(c, s) for c in CAMERA_TYPES.values() for s in surfaces),
        "ΔE камера / поверхности (мин)": min(delta_e(c, s) for c in CAMERA_TYPES.values() for s in surfaces),
        "ΔE камера / поверхности, дейтеранопия (мин)": min(delta_e(c, s, True) for c in CAMERA_TYPES.values()
                                                          for s in surfaces),
        "камера не видна (пар тип × поверхность)": float(sum(not _camera_visible(c, s)
                                                            for c in CAMERA_TYPES.values() for s in surfaces)),
        "спокойная камера / поверхности (мин)": min(max(contrast(calm["fill"], s), contrast(calm["ring"], s))
                                                   for s in surfaces),
        "ΔE пробки / асфальт (мин)": min(delta_e(c, a) for c in traffic.values() for a in asphalt),
        "ΔE «медленно» / жёлтая кромка": min(delta_e(traffic["slow"], k) for k in kerbs),
        "контраст дорога / фон": contrast(p["road"], p["bg"]),
        # Разметка вблизи: белая краска на сером асфальте (28.L), ночью —
        # приглушённо-светлая на графите. Зебра лежит на своей подложке.
        "разметка / асфальт вблизи (мин)": min(contrast(p["paint"], p[k]) for k in MARKED_KEYS),
        "разметка / подложка зебры": contrast(p["paint"], p["zebra_base"]),
        # Штриховка островка — белый узор спрайта (альфа HATCH_ALPHA) с
        # прозрачностью слоя на асфальте проспекта.
        "штриховка / асфальт вблизи": contrast(_over(HATCH_ALPHA * p["hatch_opacity"], p["near_primary"]),
                                              p["near_primary"]),
        "ΔE асфальт вблизи / дом (мин)": min(delta_e(p[k], p["building"]) for k in MARKED_KEYS),
        # Иерархия классов: магистраль отличается от проспекта и вблизи, и на
        # обзоре — цветом днём, светлотой ночью.
        "ΔE магистраль / проспект (мин)": min(delta_e(p["road_trunk"], p["road"]),
                                              delta_e(p["far_trunk"], p["far_primary"])),
        "ΔE магистраль / фон": delta_e(p["road_trunk"], p["bg"]),
        "контраст двор / фон": contrast(p["minor"], p["bg"]),
        "контраст дом / фон": contrast(p["building"], p["bg"]),
        "контраст зелень / фон": contrast(p["park"], p["bg"]),
        "контраст вода / фон": contrast(p["water"], p["bg"]),
        # Проспект виден полотном ИЛИ кромкой: днём (28.A) он белый на светлой
        # земле, и его несёт серая кромка — как у Apple.
        "ΔE дорога / фон": max(delta_e(p["road"], p["bg"]), delta_e(p["kerb"], p["bg"])),
        "ΔE дом / фон": delta_e(p["building"], p["bg"]),
        "ΔE зелень / фон": delta_e(p["park"], p["bg"]),
        "ΔE вода / фон": delta_e(p["water"], p["bg"]),
        "ΔE камера (красная) / фон": delta_e(CAMERA_TYPES["camera"], p["bg"]),
    }
    failures = []

    def need(ok, text):
        if not ok:
            failures.append(text)
    need(m["подпись места / фон"] >= TEXT_MIN, "подпись места на фоне < 4,5:1")
    need(m["подпись места / асфальт (мин)"] >= TEXT_MIN, "подпись места на асфальте < 4,5:1")
    need(m["имя улицы / асфальт (мин)"] >= TEXT_MIN, "имя улицы на асфальте < 4,5:1")
    need(m["имя улицы / фон"] >= TEXT_MIN, "имя улицы на фоне < 4,5:1")
    need(m["номер дома / дом"] >= HOUSENUMBER_MIN, "номер дома < 3:1")
    need(m["подпись места / дом по назначению (мин)"] >= TEXT_MIN, "подпись места на цветном доме < 4,5:1")
    need(m["номер дома / дом по назначению (мин)"] >= HOUSENUMBER_MIN, "номер дома на цветном доме < 3:1")
    need(m["ΔE дом по назначению / обычный дом (мин)"] >= USE_DE_MIN, "назначение дома не видно")
    need(m["ΔE назначения между собой (мин)"] >= USE_DE_MIN, "назначения домов не различить")
    need(m["ΔE назначения между собой, дейтеранопия (мин)"] >= USE_DEUTAN_MIN,
         "назначения домов не различить при дейтеранопии")
    need(m["ΔE дом по назначению / красная камера (мин)"] >= USE_CAMERA_DE_MIN, "дом по назначению похож на камеру")
    need(m["подписи мест цветом / ореол (мин)"] >= POI_MIN, "цветная подпись места < 3:1")
    need(m["линия маршрута / асфальт и фон (мин)"] >= GRAPHIC_MIN, "линия маршрута на асфальте < 3:1")
    need(m["ΔE линия маршрута / магистраль"] >= ROUTE_TRUNK_DE_MIN, "линия маршрута похожа на магистраль")
    need(m["ΔE магистраль / проспект (мин)"] >= TRUNK_PRIMARY_DE_MIN, "магистраль не отличить от проспекта")
    need(m["другой вариант / асфальт и фон (мин)"] >= GRAPHIC_MIN, "другой вариант маршрута на асфальте < 3:1")
    need(min(m["ΔE другой вариант / выбранный"], m["ΔE другой вариант / выбранный, дейтеранопия"])
         >= ALT_ROUTE_DE_MIN, "другой вариант похож на выбранный")
    need(m["камера не видна (пар тип × поверхность)"] == 0, "маркер камеры сливается с поверхностью")
    need(m["спокойная камера / поверхности (мин)"] >= GRAPHIC_MIN, "спокойная камера < 3:1")
    need(m["ΔE пробки / асфальт (мин)"] >= TRAFFIC_DE_MIN, "пробка сливается с асфальтом")
    need(m["ΔE «медленно» / жёлтая кромка"] >= SLOW_KERB_DE_MIN, "«медленно» похоже на кромку")
    need(all(luminance(p["paint"]) > luminance(p[k]) for k in MARKED_KEYS + ("zebra_base",)),
         "разметка темнее асфальта")
    need(min(m["разметка / асфальт вблизи (мин)"], m["разметка / подложка зебры"],
             m["штриховка / асфальт вблизи"]) >= PAINT_MIN,
         "разметка на асфальте < 1,4:1")
    need(m["ΔE асфальт вблизи / дом (мин)"] >= NEAR_HOUSE_DE_MIN, "асфальт вблизи сливается с домами")
    # Иерархия: дорога — главное на земле, дома тише неё (по яркости — её
    # видно и при дальтонизме), камера заметнее всего. С 28.A («Чистый»)
    # улицы и проспекты днём белые: полотно — САМОЕ СВЕТЛОЕ на земле, а
    # отделяет его кромка (у двора — своя, у проспекта темнее). С 28.L это
    # правило — для обзора и двора: вблизи размеченное полотно улиц сознательно
    # ТЕМНЕЕ земли (светло-серый асфальт под белой краской) и проверяется
    # своими правилами — краска и дома выше. Цвет на земле
    # только у зелени, воды и магистрали; зелень и вода могут быть сочнее
    # белой улицы, но не громче магистрали (≤ 1,25 её ΔE к фону) — как у Apple.
    m["контраст двора / фон (кромка или полотно)"] = max(contrast(p["minor_edge"], p["bg"]),
                                                       contrast(p["minor"], p["bg"]))
    need(m["контраст двора / фон (кромка или полотно)"] > m["контраст дом / фон"], "дом заметнее двора")
    need(m["ΔE дорога / фон"] > m["ΔE дом / фон"], "дом заметнее дороги")
    need(m["ΔE дорога / фон"] > m["ΔE дом по назначению / фон (макс)"], "цветной дом заметнее дороги")
    # Ночью дом по назначению, как и обычный, темнее любой улицы (двор —
    # самая тёмная): иначе кварталы спорят с дорогой.
    if theme == "dark":
        need(all(luminance(c) < luminance(p["minor"]) for c in uses.values()), "цветной дом светлее двора")
    ground_light = max(luminance(c) for c in ground)
    m["светлота двора / самая светлая земля"] = (luminance(p["minor"]) + 0.05) / (ground_light + 0.05)
    need(luminance(p["minor"]) > ground_light and luminance(p["near_minor"]) > ground_light,
         "земля светлее улицы")
    for key in ("ΔE зелень / фон", "ΔE вода / фон"):
        need(m[key] <= 1.25 * m["ΔE магистраль / фон"], f"{key.split(' / ')[0].split()[-1]} громче магистрали")
    for key in ("ΔE дорога / фон", "ΔE магистраль / фон", "ΔE дом / фон", "ΔE зелень / фон", "ΔE вода / фон"):
        need(m[key] < m["ΔE камера (красная) / фон"], f"{key} ≥ камеры — камера не самая заметная")
    return m, failures


# Асфальт поездки (29.B): тёмное полотно с белой разметкой. Ключи полотна
# поездки по классам — тех, где лежит линия маршрута и подпись улицы.
# Двор в поездке белый, как был (make_style: drive_minor) — его проверяет measure.
DRIVE_ASPHALT_KEYS = ("drive_trunk", "drive_primary", "drive_secondary", "drive_tertiary")
DRIVE_MARKED_KEYS = ("drive_trunk", "drive_primary", "drive_secondary", "drive_tertiary")
# Кромка поездки светлее полотна — край дороги читается и на светлой земле
# (там его несёт само тёмное полотно), и между полотном и разделительной.
DRIVE_KERB_MIN = 3.0
# В поездке линия маршрута — ночным набором в ОБЕИХ темах (EngineDriveAsphalt:
# RouteColors.night днём): светлое тело на тёмном полотне, тёмная кайма на
# светлом асфальте обзора и на земле.
DRIVE_ROUTE = ROUTE["dark"]


def measure_drive(theme, p=None):
    """Числа и нарушения асфальта поездки: имя улицы, разметка, маршрут,
    камеры и пробки на тёмном полотне. Линия маршрута проверяется и на
    обычных поверхностях (обзор, асфальт до 16-го, земля): её цвет в поездке
    один на все зумы."""
    p = p or make_style.PALETTES[theme]
    d = make_style.drive_palette(p)
    traffic, calm = TRAFFIC[theme], CALM[theme]
    drive = [p[k] for k in DRIVE_ASPHALT_KEYS]
    light = [p[k] for k in ASPHALT_KEYS + FAR_KEYS] + [p["bg"]]
    m = {
        "поездка: имя улицы / асфальт (мин)": min(contrast(d["street_label"], a) for a in drive),
        "поездка: разметка / асфальт (мин)": min(contrast(d["paint"], p[k]) for k in DRIVE_MARKED_KEYS),
        "поездка: разметка / подложка зебры": contrast(d["paint"], d["zebra_base"]),
        "поездка: кромка / асфальт (мин)": min(contrast(k, a) for k in (d["kerb"], d["kerb_trunk"])
                                               for a in drive),
        "поездка: линия маршрута / асфальт и земля (мин)": min(
            max(contrast(DRIVE_ROUTE["body"], s), contrast(DRIVE_ROUTE["casing"], s)) for s in drive + light),
        "поездка: камера не видна (пар тип × асфальт)": float(sum(not _camera_visible(c, a)
                                                                  for c in CAMERA_TYPES.values() for a in drive)),
        "поездка: спокойная камера / асфальт (мин)": min(max(contrast(calm["fill"], a), contrast(calm["ring"], a))
                                                       for a in drive),
        "поездка: ΔE пробки / асфальт (мин)": min(delta_e(c, a) for c in traffic.values() for a in drive),
        "поездка: ΔE «медленно» / жёлтая кромка": delta_e(traffic["slow"], d["kerb_trunk"]),
        # Дома по назначению в поездке (30.A) — спокойнее, но камера на них
        # видна, а подпись читается.
        "поездка: камера не видна на доме (пар)": float(sum(not _camera_visible(c, s)
                                                           for c in CAMERA_TYPES.values()
                                                           for s in d["building_use"].values())),
        "поездка: подпись места / дом по назначению (мин)": min(contrast(p["label"], c)
                                                               for c in d["building_use"].values()),
        "поездка: ΔE дом по назначению / дом (макс)": max(delta_e(c, d["building"])
                                                          for c in d["building_use"].values()),
    }
    failures = []

    def need(ok, text):
        if not ok:
            failures.append(text)
    need(m["поездка: имя улицы / асфальт (мин)"] >= TEXT_MIN, "поездка: имя улицы на асфальте < 4,5:1")
    need(all(luminance(d["paint"]) > luminance(p[k]) for k in DRIVE_MARKED_KEYS),
         "поездка: разметка темнее асфальта")
    need(min(m["поездка: разметка / асфальт (мин)"], m["поездка: разметка / подложка зебры"]) >= PAINT_MIN,
         "поездка: разметка на асфальте < 1,4:1")
    need(m["поездка: линия маршрута / асфальт и земля (мин)"] >= GRAPHIC_MIN, "поездка: линия маршрута < 3:1")
    need(m["поездка: камера не видна (пар тип × асфальт)"] == 0, "поездка: маркер камеры сливается с асфальтом")
    need(m["поездка: спокойная камера / асфальт (мин)"] >= GRAPHIC_MIN, "поездка: спокойная камера < 3:1")
    need(m["поездка: ΔE пробки / асфальт (мин)"] >= TRAFFIC_DE_MIN, "поездка: пробка сливается с асфальтом")
    need(m["поездка: ΔE «медленно» / жёлтая кромка"] >= SLOW_KERB_DE_MIN, "поездка: «медленно» похоже на кромку")
    need(m["поездка: камера не видна на доме (пар)"] == 0, "поездка: камера сливается с домом")
    need(m["поездка: подпись места / дом по назначению (мин)"] >= TEXT_MIN, "поездка: подпись на цветном доме < 4,5:1")
    # Спокойнее, чем вне поездки: оттенок дома в поездке не ярче обычного.
    plain = max(delta_e(c, p["building"]) for c in p["building_use"].values())
    need(m["поездка: ΔE дом по назначению / дом (макс)"] <= plain, "поездка: цветной дом ярче, чем вне поездки")
    if theme == "light":
        # Днём кромка — светлая линия края тёмного полотна (как у Amap).
        need(m["поездка: кромка / асфальт (мин)"] >= DRIVE_KERB_MIN, "поездка: кромка не светлее асфальта")
    return m, failures


# Карта машины (40J): вариант и тема → цвета на рабочем зуме машины (≥ 15).
# Ночь N1 «без засветки»: имя улицы и подпись места не ярче этой светлоты
# (было 0,90 и 0,81 — слепили в тёмной кабине).
CAR_NIGHT_STREET_MAX_L = 0.6
CAR_NIGHT_PLACE_MAX_L = 0.5
# Полоса светлоты асфальта, где линия маршрута ночным набором не держит 3:1
# ни телом, ни каймой.
ROUTE_DEAD_BAND = (0.083, 0.133)


def car_effective(theme, variant="A"):
    """Цвета машины на её рабочем зуме: асфальт классов, имена, разметка,
    кромки, земля и дома; набор линии маршрута и пробок."""
    static_p, drive_p = make_style.car_palettes(theme, variant)
    near = make_style.near_palette(drive_p or static_p)
    p = drive_p or static_p
    dark_asphalt = drive_p is not None or theme == "dark"
    set_name = "dark" if dark_asphalt else "light"
    return {
        "asphalt": {k: near[k] for k in ("road_trunk", "road", "road_secondary", "road_tertiary")},
        "minor": near["minor"], "minor_edge": p["minor_edge"],
        "street_label": p["street_label"], "minor_label": static_p["street_label"],
        "label": p["label"], "halo": p["halo"], "paint": p["paint"], "zebra_base": p["zebra_base"],
        "kerb": p["kerb"], "kerb_trunk": p["kerb_trunk"],
        "bg": p["bg"], "building": p["building"], "water": p["water"], "park": p["park"],
        "uses": p["building_use"],
        "route": ROUTE[set_name], "traffic": TRAFFIC[set_name], "dark_asphalt": dark_asphalt,
    }


def _car_new_colours(theme, variant):
    """Цвета, которые вводит палитра машины (без повторов обычной темы)."""
    base = set()
    for value in make_style.PALETTES[theme].values():
        if isinstance(value, str) and value.startswith("#"):
            base.add(value)
        elif isinstance(value, dict):
            base.update(v for v in value.values() if isinstance(v, str) and v.startswith("#"))
    out = set()
    for value in make_style.CAR_PALETTES[variant][theme].values():
        values = value.values() if isinstance(value, dict) else [value]
        out.update(v for v in values if isinstance(v, str) and v.startswith("#") and v not in base)
    return sorted(out)


def measure_car(theme, variant="A"):
    """Числа и нарушения карты машины (40J): имена ≥ 4,5:1, маршрут ≥ 3:1 к
    асфальту, магистраль ≠ проспект, пробки и камера на асфальте (и при
    дейтеранопии), красный — только камера, ночью — без засветки."""
    c = car_effective(theme, variant)
    asphalt = list(c["asphalt"].values())
    ground = [c["bg"], c["building"], c["water"], c["park"]]
    route, traffic = c["route"], c["traffic"]
    trunk, primary = c["asphalt"]["road_trunk"], c["asphalt"]["road"]
    new = _car_new_colours(theme, variant)
    m = {
        "машина: имя улицы / асфальт (мин)": min(contrast(c["street_label"], a) for a in asphalt),
        "машина: имя двора / двор": contrast(c["minor_label"], c["minor"]),
        "машина: подпись места / земля, дом, вода (мин)": min(contrast(c["label"], s) for s in
                                                             (c["bg"], c["building"], c["water"])),
        "машина: подпись места / ореол": contrast(c["label"], c["halo"]),
        "машина: линия маршрута / асфальт (мин)": min(max(contrast(route["body"], a), contrast(route["casing"], a))
                                                      for a in asphalt + [c["minor"]]),
        "машина: линия маршрута / земля": max(contrast(route["body"], c["bg"]), contrast(route["casing"], c["bg"])),
        "машина: ΔE магистраль / проспект": delta_e(trunk, primary),
        "машина: ΔE магистраль / проспект, дейтеранопия": delta_e(trunk, primary, True),
        "машина: ΔE маршрут / магистраль": delta_e(route["body"], trunk),
        "машина: ΔE пробки / асфальт (мин)": min(delta_e(t, a) for t in traffic.values() for a in asphalt),
        "машина: ΔE пробки / асфальт, дейтеранопия (мин)": min(delta_e(t, a, True)
                                                               for t in traffic.values() for a in asphalt),
        "машина: ΔE «медленно» / кромка магистрали": delta_e(traffic["slow"], c["kerb_trunk"]),
        # Спокойный графитовый значок (CameraMarkerLook) на тёмном асфальте
        # машины днём сливается заливкой (ΔE ≈ 2 к #3f4859): его несёт кант.
        "машина: спокойная камера / асфальт (мин)": min(
            max(contrast(CALM[theme]["fill"], a), contrast(CALM[theme]["ring"], a)) for a in asphalt + [c["minor"]]),
        "машина: камера не видна (пар тип × поверхность)": float(sum(
            not _camera_visible(t, s) for t in CAMERA_TYPES.values() for s in asphalt + ground)),
        "машина: разметка / асфальт (мин)": min(contrast(c["paint"], a) for a in asphalt),
        "машина: ΔE новый цвет / красная камера (мин)": min((delta_e(x, CAMERA_TYPES["camera"]) for x in new),
                                                            default=100.0),
        "машина: ΔE новый цвет / красная камера, дейтеранопия (мин)": min(
            (delta_e(x, CAMERA_TYPES["camera"], True) for x in new), default=100.0),
        "машина: светлота имени улицы": luminance(c["street_label"]),
        "машина: светлота подписи места": luminance(c["label"]),
    }
    failures = []

    def need(ok, text):
        if not ok:
            failures.append(text)
    need(m["машина: имя улицы / асфальт (мин)"] >= TEXT_MIN, "машина: имя улицы на асфальте < 4,5:1")
    need(m["машина: имя двора / двор"] >= TEXT_MIN, "машина: имя двора < 4,5:1")
    need(m["машина: подпись места / земля, дом, вода (мин)"] >= TEXT_MIN, "машина: подпись места < 4,5:1")
    need(m["машина: подпись места / ореол"] >= TEXT_MIN, "машина: подпись места на ореоле < 4,5:1")
    need(m["машина: линия маршрута / асфальт (мин)"] >= GRAPHIC_MIN, "машина: линия маршрута на асфальте < 3:1")
    need(m["машина: линия маршрута / земля"] >= GRAPHIC_MIN, "машина: линия маршрута на земле < 3:1")
    need(m["машина: ΔE магистраль / проспект"] >= TRUNK_PRIMARY_DE_MIN, "машина: магистраль не отличить от проспекта")
    need(m["машина: ΔE маршрут / магистраль"] >= ROUTE_TRUNK_DE_MIN, "машина: маршрут похож на магистраль")
    need(m["машина: ΔE пробки / асфальт (мин)"] >= TRAFFIC_DE_MIN, "машина: пробка сливается с асфальтом")
    need(m["машина: ΔE пробки / асфальт, дейтеранопия (мин)"] >= CAMERA_DEUTAN_MIN,
         "машина: пробка сливается с асфальтом при дейтеранопии")
    need(m["машина: ΔE «медленно» / кромка магистрали"] >= SLOW_KERB_DE_MIN, "машина: «медленно» похоже на кромку")
    need(m["машина: камера не видна (пар тип × поверхность)"] == 0, "машина: камера сливается с поверхностью")
    need(m["машина: спокойная камера / асфальт (мин)"] >= GRAPHIC_MIN, "машина: спокойная камера < 3:1")
    need(all(luminance(c["paint"]) > luminance(a) for a in asphalt), "машина: разметка темнее асфальта")
    need(m["машина: разметка / асфальт (мин)"] >= PAINT_MIN, "машина: разметка на асфальте < 1,4:1")
    need(m["машина: ΔE новый цвет / красная камера (мин)"] >= USE_CAMERA_DE_MIN, "машина: новый цвет похож на камеру")
    need(m["машина: ΔE новый цвет / красная камера, дейтеранопия (мин)"] >= CAMERA_DEUTAN_MIN,
         "машина: новый цвет похож на камеру при дейтеранопии")
    if c["dark_asphalt"]:
        low, high = ROUTE_DEAD_BAND
        need(all(not low <= luminance(a) <= high for a in asphalt), "машина: асфальт в мёртвой полосе маршрута")
    if theme == "dark":
        need(m["машина: светлота имени улицы"] <= CAR_NIGHT_STREET_MAX_L, "машина: имя улицы ночью слепит")
        need(m["машина: светлота подписи места"] <= CAR_NIGHT_PLACE_MAX_L, "машина: подпись места ночью слепит")
        need(luminance(trunk) <= luminance(make_style.PALETTES["dark"]["road_trunk"]),
             "машина: магистраль ночью светлее телефонной")
    if not c["dark_asphalt"]:
        # Светлая машина (B): двор и дома тише проспекта, проспект несёт кромка.
        need(contrast(c["kerb"], c["bg"]) >= 1.5, "машина: кромка проспекта не видна на земле")
    return m, failures


# «Вождение 3D» (43): лента маршрута отличается от асфальта оттенком, а не
# яркостью — ΔE при дейтеранопии ≥ ROUTE_TRUNK_DE_MIN и контраст ≥ 1,3;
# разметка лежит поверх ленты и читается на ней не хуже графики (≥ 3:1, ночью
# тоже — в 42 было 2,99); кант днём виден, ночью — еле заметен (без засветки).
D3_RIBBON_CONTRAST_MIN = 1.3
D3_EDGE_DAY_MIN = 1.5
D3_EDGE_NIGHT_MAX = 1.6
# Ночью лента — приглушённый синий: не светлее половины ночного тела линии
# маршрута (#66a3ff, 0,36) — без «прожектора».
D3_NIGHT_RIBBON_MAX_L = 0.18
D3_MARKED_KEYS = ("road_trunk", "road", "road_secondary", "road_tertiary")


def _mix(top, under, alpha):
    t, u = rgb(top), rgb(under)
    return "#" + "".join(f"{round((a * alpha + b * (1 - alpha)) * 255):02x}" for a, b in zip(t, u))


def _d3_new_colours(theme):
    base = set()
    for value in make_style.PALETTES[theme].values():
        values = value.values() if isinstance(value, dict) else [value]
        base.update(v for v in values if isinstance(v, str) and v.startswith("#"))
    out = set()
    for value in list(make_style.D3_PALETTES[theme].values()) + list(make_style.D3_RIBBON[theme].values()):
        values = value.values() if isinstance(value, dict) else [value]
        out.update(v for v in values if isinstance(v, str) and v.startswith("#") and v not in base)
    return sorted(out)


def measure_drive3d(theme, p=None, ribbon=None):
    """Числа и нарушения «Вождения 3D»: разметка на асфальте и на ленте,
    лента к асфальту по оттенку, кант, имена, камеры и пробки, красный —
    только камера, ночью — без засветки."""
    p = p or make_style.drive3d_palette(theme)
    ribbon = ribbon or make_style.D3_RIBBON[theme]
    fill = ribbon["fill"]
    edge = _mix(ribbon["edge"], fill, ribbon["edge_opacity"])
    asphalt = [p[k] for k in D3_MARKED_KEYS]
    every = asphalt + [p["minor"]]
    ground = [p["bg"], p["building"], p["water"], p["park"]]
    route = ROUTE[theme]
    traffic = TRAFFIC[theme]
    new = _d3_new_colours(theme)
    m = {
        "3D: разметка / асфальт (мин)": min(contrast(p["paint"], a) for a in asphalt),
        "3D: разметка / лента маршрута": contrast(p["paint"], fill),
        "3D: лента / асфальт (контраст, мин)": min(contrast(fill, a) for a in asphalt),
        "3D: лента / асфальт (ΔE дейт., мин)": min(delta_e(fill, a, True) for a in asphalt),
        "3D: кант / лента": contrast(edge, fill),
        "3D: имя улицы / асфальт (мин)": min(contrast(p["street_label"], a) for a in every),
        "3D: подпись места / земля, дом, вода (мин)": min(contrast(p["label"], s) for s in
                                                          (p["bg"], p["building"], p["water"])),
        "3D: асфальт / земля (мин)": min(contrast(a, p["bg"]) for a in asphalt),
        "3D: линия маршрута / земля": max(contrast(route["body"], p["bg"]), contrast(route["casing"], p["bg"])),
        "3D: камера не видна (пар тип × поверхность)": float(sum(
            not _camera_visible(c, s) for c in CAMERA_TYPES.values() for s in every + ground + [fill])),
        "3D: спокойная камера / асфальт (мин)": min(
            max(contrast(CALM[theme]["fill"], a), contrast(CALM[theme]["ring"], a)) for a in every),
        "3D: ΔE пробки / асфальт (мин)": min(delta_e(t, a) for t in traffic.values() for a in asphalt),
        "3D: ΔE пробки / асфальт, дейтеранопия (мин)": min(delta_e(t, a, True)
                                                           for t in traffic.values() for a in asphalt),
        "3D: ΔE пробки / лента (мин)": min(delta_e(t, fill) for t in traffic.values()),
        "3D: ΔE новый цвет / красная камера (мин)": min((delta_e(x, CAMERA_TYPES["camera"]) for x in new),
                                                        default=100.0),
        "3D: ΔE новый цвет / красная камера, дейтеранопия (мин)": min(
            (delta_e(x, CAMERA_TYPES["camera"], True) for x in new), default=100.0),
        "3D: светлота ленты": luminance(fill),
        "3D: светлота имени улицы": luminance(p["street_label"]),
        "3D: светлота подписи места": luminance(p["label"]),
    }
    failures = []

    def need(ok, text):
        if not ok:
            failures.append(text)
    need(all(luminance(p["paint"]) > luminance(a) for a in asphalt), "3D: разметка темнее асфальта")
    need(m["3D: разметка / асфальт (мин)"] >= GRAPHIC_MIN, "3D: разметка на асфальте < 3:1")
    need(m["3D: разметка / лента маршрута"] >= GRAPHIC_MIN, "3D: разметка на ленте < 3:1")
    need(m["3D: лента / асфальт (контраст, мин)"] >= D3_RIBBON_CONTRAST_MIN, "3D: лента сливается с асфальтом")
    need(m["3D: лента / асфальт (ΔE дейт., мин)"] >= ROUTE_TRUNK_DE_MIN,
         "3D: лента не отличается от асфальта оттенком при дейтеранопии")
    need(m["3D: имя улицы / асфальт (мин)"] >= TEXT_MIN, "3D: имя улицы на асфальте < 4,5:1")
    need(m["3D: подпись места / земля, дом, вода (мин)"] >= TEXT_MIN, "3D: подпись места < 4,5:1")
    need(m["3D: асфальт / земля (мин)"] >= 1.6, "3D: асфальт сливается с землёй")
    need(m["3D: линия маршрута / земля"] >= GRAPHIC_MIN, "3D: линия маршрута на земле < 3:1")
    need(m["3D: камера не видна (пар тип × поверхность)"] == 0, "3D: камера сливается с поверхностью")
    need(m["3D: спокойная камера / асфальт (мин)"] >= GRAPHIC_MIN, "3D: спокойная камера < 3:1")
    need(m["3D: ΔE пробки / асфальт (мин)"] >= TRAFFIC_DE_MIN, "3D: пробка сливается с асфальтом")
    need(m["3D: ΔE пробки / асфальт, дейтеранопия (мин)"] >= CAMERA_DEUTAN_MIN,
         "3D: пробка сливается с асфальтом при дейтеранопии")
    need(m["3D: ΔE пробки / лента (мин)"] >= ALT_ROUTE_DE_MIN, "3D: пробка похожа на ленту маршрута")
    need(m["3D: ΔE новый цвет / красная камера (мин)"] >= USE_CAMERA_DE_MIN, "3D: новый цвет похож на камеру")
    need(m["3D: ΔE новый цвет / красная камера, дейтеранопия (мин)"] >= CAMERA_DEUTAN_MIN,
         "3D: новый цвет похож на камеру при дейтеранопии")
    if theme == "light":
        need(m["3D: кант / лента"] >= D3_EDGE_DAY_MIN, "3D: кант ленты днём не виден")
    else:
        need(m["3D: кант / лента"] <= D3_EDGE_NIGHT_MAX, "3D: кант ленты ночью слепит")
        need(m["3D: светлота ленты"] <= D3_NIGHT_RIBBON_MAX_L, "3D: лента ночью слепит")
        need(m["3D: светлота имени улицы"] <= CAR_NIGHT_STREET_MAX_L, "3D: имя улицы ночью слепит")
        need(m["3D: светлота подписи места"] <= CAR_NIGHT_PLACE_MAX_L, "3D: подпись места ночью слепит")
    return m, failures


def table():
    rows = []
    for theme in ("light", "dark"):
        m, failures = measure(theme)
        drive, drive_failures = measure_drive(theme)
        m.update(drive)
        failures += drive_failures
        d3, d3_failures = measure_drive3d(theme)
        m.update(d3)
        failures += d3_failures
        for variant in ("A", "B"):
            car, car_failures = measure_car(theme, variant)
            m.update({f"{name} [{variant}]": value for name, value in car.items()})
            failures += [f"{text} [{variant}]" for text in car_failures]
        rows.append("день" if theme == "light" else "ночь")
        rows += [f"  {name}: {value:.2f}" for name, value in m.items()]
        rows.append("  " + ("все правила соблюдены" if not failures else "нарушено: " + "; ".join(failures)))
        rows.append("")
    return "\n".join(rows)


if __name__ == "__main__":
    print(table())
