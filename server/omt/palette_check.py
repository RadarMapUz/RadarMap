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
ROUTE = {"light": {"body": "#2a6ff0", "casing": "#1e4fb8",
                   "alternative": "#93b4ea", "alternativeCasing": "#46679f"},
         "dark": {"body": "#66a3ff", "casing": "#0e1a33",
                  "alternative": "#98acd2", "alternativeCasing": "#0e1a33"}}
TRAFFIC = {"light": {"free": "#2ba84a", "slow": "#e8a100", "jam": "#d93025"},
           "dark": {"free": "#3cc46b", "slow": "#ffb020", "jam": "#ff5a4e"}}
CAMERA_TYPES = {"camera": "#d93025", "radar": "#f2b200", "intelligent": "#6a3fd6",
                "mobile": "#c2409e", "post": "#46525e"}
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
    ground = [p["bg"], p["landuse"], p["building"], p["park"], p["wood"], p["water"],
              *p["landuse_kind"].values()]
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
    ground_light = max(luminance(c) for c in ground)
    m["светлота двора / самая светлая земля"] = (luminance(p["minor"]) + 0.05) / (ground_light + 0.05)
    need(luminance(p["minor"]) > ground_light and luminance(p["near_minor"]) > ground_light,
         "земля светлее улицы")
    for key in ("ΔE зелень / фон", "ΔE вода / фон"):
        need(m[key] <= 1.25 * m["ΔE магистраль / фон"], f"{key.split(' / ')[0].split()[-1]} громче магистрали")
    for key in ("ΔE дорога / фон", "ΔE магистраль / фон", "ΔE дом / фон", "ΔE зелень / фон", "ΔE вода / фон"):
        need(m[key] < m["ΔE камера (красная) / фон"], f"{key} ≥ камеры — камера не самая заметная")
    return m, failures


def table():
    rows = []
    for theme in ("light", "dark"):
        m, failures = measure(theme)
        rows.append("день" if theme == "light" else "ночь")
        rows += [f"  {name}: {value:.2f}" for name, value in m.items()]
        rows.append("  " + ("все правила соблюдены" if not failures else "нарушено: " + "; ".join(failures)))
        rows.append("")
    return "\n".join(rows)


if __name__ == "__main__":
    print(table())
