#!/usr/bin/env python3
"""Матрица кадров карты: эталонные места × масштабы × тема × режим — для сравнения «было / стало».

Стиль берётся из make_style.py указанной рабочей копии (--repo), рисует его
MapLibre Native (render.js), тайлы — локальная сборка. Режимы: free — карта без
поездки, drive — с разницей поездки (map_drive_<тема>), car — с разницей машины.

    python3 tools/map_matrix/matrix.py --repo . --out <dir> [--set ladder|places|all]
        [--node <node>] [--omt <dir>] [--mvt <dir>] [--glyphs <dir>] [--sprite <dir>]

Итог — PNG кадров в <dir>/frames и листы <dir>/sheet_*.png.
"""
import argparse
import importlib.util
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.expanduser("~/RadarMapBuild")

# Эталонные места (раздел 10 плана): имя, широта, долгота, масштабы.
LADDER = (6, 9, 11, 13, 14.6, 15.2, 15.8, 16.5, 17.2, 18, 19.5)
PLACES = {
    "navoi_rashidov": (41.3189, 69.2712, LADDER),
    "navoi_labzak": (41.3205, 69.2647, (15.8, 17.2, 18)),
    "anhor_bridge": (41.3198, 69.2678, (15.8, 17.2, 18)),
    "amir_temur": (41.3111, 69.2797, (13, 15.8, 17.2)),
    "tunnel_bunyodkor": (41.3116, 69.2412, (15.8, 17.2, 18)),
    "tunnel_ring": (41.2920, 69.2865, (15.8, 17.2)),
    "interchange_gavhar": (41.2560, 69.1930, (15.2, 16.5, 17.2)),
    "mahalla_chorsu": (41.3245, 69.2290, (15.8, 17.2, 18)),
    "outskirts_qibray": (41.3600, 69.3700, (13, 14.6, 15.8, 16.5)),
    "highway_m39": (40.4900, 68.7800, (9, 11, 13)),
    "samarkand": (39.6547, 66.9757, (11, 13, 15.8)),
    "country": (41.3, 64.5, (5, 6)),
}
SETS = {"ladder": ["navoi_rashidov"], "places": [k for k in PLACES if k != "navoi_rashidov"],
        "all": list(PLACES)}
MODES = ("free", "drive", "car", "seed", "seedboth")
# Копия EngineModernStyle.withSeed: режим seed — первый запуск без сети, только
# основа из бандла (OMT до z12), сетевые источники пусты.
SEED_GROUND = ("landcover-wood", "landcover-grass", "landcover-grass-park", "water",
               "waterway-river", "waterway-stream-canal")
SEED_ROADS = ("highway-motorway", "highway-trunk", "highway-primary", "highway-secondary-tertiary",
              "highway-minor")
SEED_MAX_ZOOM = 16.5


def with_seed(style, daylight, network=False):
    layers = style["layers"]
    casings = {l["id"][:-len("-casing")]: l.get("paint", {}).get("line-color")
               for l in layers if l["id"].endswith("-casing")}
    seeds = []
    for layer in layers:
        if layer.get("source") != "openmaptiles" or layer["id"] not in SEED_GROUND + SEED_ROADS:
            continue
        copy = json.loads(json.dumps(layer))
        copy["id"] = "seed-" + layer["id"]
        copy["source"] = "seed"
        copy["maxzoom"] = min(layer.get("maxzoom", SEED_MAX_ZOOM), SEED_MAX_ZOOM)
        if daylight and layer["id"] in SEED_ROADS and casings.get(layer["id"]) is not None:
            copy.setdefault("paint", {})["line-color"] = casings[layer["id"]]
        seeds.append(copy)
    at = next(k for k, l in enumerate(layers) if l["id"] == "background") + 1
    style["layers"] = layers[:at] + seeds + layers[at:]
    style["sources"]["seed"] = {"type": "vector", "tiles": ["local://omt/{z}/{x}/{y}.pbf"], "maxzoom": 12}
    if not network:
        for name in ("openmaptiles", "radar"):
            style["sources"][name]["tiles"] = ["local://none/{z}/{x}/{y}"]
    return style
CAR = {"light": "map_car_light.json", "dark": "map_car_dark.json"}

# Свойства раскладки символов: остальное в разнице — краска.
LAYOUT_EXACT = {"visibility", "line-cap", "line-join", "symbol-placement", "symbol-spacing",
                "symbol-sort-key", "symbol-z-order", "symbol-avoid-edges"}


def load_make_style(repo):
    path = os.path.join(repo, "server", "omt", "make_style.py")
    sys.path.insert(0, os.path.dirname(path))
    spec = importlib.util.spec_from_file_location(f"make_style_{abs(hash(repo))}", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    sys.path.pop(0)
    return module


def is_layout(key, layer):
    if key in layer.get("layout", {}):
        return True
    if key in layer.get("paint", {}):
        return False
    if key in LAYOUT_EXACT:
        return True
    if key.startswith(("text-", "icon-")):
        return not any(part in key for part in ("color", "opacity", "halo", "translate"))
    return False


def apply_diff(style, diff):
    layers = {layer["id"]: layer for layer in style["layers"]}
    for layer_id, props in diff.get("layers", {}).items():
        layer = layers.get(layer_id)
        if layer is None:
            continue
        for key, value in props.items():
            part = "layout" if is_layout(key, layer) else "paint"
            layer.setdefault(part, {})[key] = value
    if "light" in diff:
        style["light"] = diff["light"]
    return style


def styles(make_style, out):
    """{(тема, режим): файл стиля}."""
    files = {}
    app = make_style.app_styles()
    for theme in ("light", "dark"):
        base = make_style.build("local://", theme, "full")
        variants = {"free": None, "drive": json.loads(app[f"map_drive_{theme}.json"]),
                    "car": json.loads(app[CAR[theme]]) if CAR[theme] in app else None, "seed": None,
                    "seedboth": None}
        for mode, diff in variants.items():
            style = json.loads(json.dumps(base))
            if diff:
                apply_diff(style, diff)
            if mode in ("seed", "seedboth"):
                with_seed(style, theme == "light", network=mode == "seedboth")
            path = os.path.join(out, "styles", f"{theme}_{mode}.json")
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as handle:
                json.dump(style, handle, ensure_ascii=False)
            files[(theme, mode)] = path
    return files


def jobs(files, places, out, modes, size, ratio):
    w, h = size
    result = []
    for place in places:
        lat, lon, zooms = PLACES[place]
        for zoom in zooms:
            for theme in ("light", "dark"):
                for mode in modes:
                    if mode in ("drive", "car") and zoom < 14:
                        continue
                    if mode == "seedboth" and zoom > 16.5:
                        continue
                    frame = os.path.join(out, "frames", place, f"z{zoom}_{theme}_{mode}.png")
                    result.append({"style": files[(theme, mode)], "zoom": zoom, "lat": lat, "lon": lon,
                                   "w": w, "h": h, "ratio": ratio, "out": frame})
    return result


def sheet(out, place, modes, thumb=360):
    from PIL import Image, ImageDraw, ImageFont
    folder = os.path.join(out, "frames", place)
    if not os.path.isdir(folder):
        return None
    zooms = PLACES[place][2]
    cols = [(t, m) for t in ("light", "dark") for m in modes]
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 18)
    except OSError:
        font = ImageFont.load_default()
    cell_h = None
    tiles = {}
    for zoom in zooms:
        for col in cols:
            path = os.path.join(folder, f"z{zoom}_{col[0]}_{col[1]}.png")
            if os.path.exists(path):
                image = Image.open(path).convert("RGB")
                image.thumbnail((thumb, thumb * 2))
                tiles[(zoom, col)] = image
                cell_h = cell_h or image.height
    if not tiles:
        return None
    head = 28
    canvas = Image.new("RGB", (len(cols) * (thumb + 6) + 70, len(zooms) * (cell_h + 6) + head), "white")
    draw = ImageDraw.Draw(canvas)
    for c, (theme, mode) in enumerate(cols):
        draw.text((70 + c * (thumb + 6), 4), f"{theme} · {mode}", fill="black", font=font)
    for r, zoom in enumerate(zooms):
        y = head + r * (cell_h + 6)
        draw.text((6, y + cell_h // 2 - 10), f"z{zoom}", fill="black", font=font)
        for c, col in enumerate(cols):
            image = tiles.get((zoom, col))
            if image:
                canvas.paste(image, (70 + c * (thumb + 6), y))
    path = os.path.join(out, f"sheet_{place}.png")
    canvas.save(path)
    return path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=".")
    parser.add_argument("--out", required=True)
    parser.add_argument("--set", default="ladder", choices=list(SETS) + list(PLACES))
    parser.add_argument("--modes", default=",".join(MODES))
    parser.add_argument("--node", default="node")
    parser.add_argument("--omt", default=os.path.join(BUILD, "omt", "publish", "omt"))
    parser.add_argument("--mvt", default=os.path.join(BUILD, "cand_40c", "mvt"))
    parser.add_argument("--glyphs", default=os.path.join(BUILD, "omt", "publish", "glyphs"))
    parser.add_argument("--sprite", default=os.path.join(BUILD, "omt", "publish", "sprite"))
    parser.add_argument("--size", default="390x700")
    parser.add_argument("--ratio", type=float, default=2)
    args = parser.parse_args()

    out = os.path.abspath(args.out)
    modes = tuple(m for m in args.modes.split(",") if m in MODES)
    places = SETS.get(args.set, [args.set])
    make_style = load_make_style(os.path.abspath(args.repo))
    files = styles(make_style, out)
    size = tuple(int(v) for v in args.size.split("x"))
    spec = {"roots": {"omt": args.omt, "mvt": args.mvt, "glyphs": args.glyphs, "sprite": args.sprite},
            "jobs": jobs(files, places, out, modes, size, args.ratio)}
    spec_path = os.path.join(out, "jobs.json")
    with open(spec_path, "w", encoding="utf-8") as handle:
        json.dump(spec, handle)
    renderer = os.environ.get("MAP_MATRIX_MODULES")
    env = dict(os.environ, NODE_PATH=renderer) if renderer else None
    subprocess.run([args.node, os.path.join(HERE, "render.js"), spec_path], check=True, env=env)
    for place in places:
        path = sheet(out, place, modes)
        if path:
            print(path)


if __name__ == "__main__":
    main()
