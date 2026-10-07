#!/usr/bin/env python3
"""Офлайн-регионы: по два файла PMTiles на область (наш MVT и основа OMT).

docs/plan_map_offline.md §2.3. Регион — НЕ рамка и не произвольный полигон,
а набор клеток z12 (~7,5 км). Клетка отдаётся области, в чей полигон (OSM
admin_level=4) попал её центр, и лежит ровно в одном регионе: границы не
дублируются и не теряются. Тайлы крупнее клетки (z0–z11) кладутся в каждый
регион, который они накрывают, — это мегабайты, а не десятки.

Почему z12, а не z10 корзин индекса: клетка z10 — ~30 км, и Ташкент-город
(~20 км) не забирал ни одной — его центр не попадал в полигон города, и
главный регион страны пропадал из списка.

Почему клетками. Полигоны областей в выгрузке Geofabrik замкнуты не у всех:
Ферганская область и Каракалпакстан обрезаны краем выгрузки и как
многоугольники не собираются. Клетки, не попавшие ни в один полигон, решаются
по порядку: рамка Ферганы, рамка Каракалпакстана, ближайшая уже размеченная
клетка не дальше FRINGE_CELLS (кромка у границы страны). Дальше — чужая
территория, она остаётся только онлайн.

Почему два файла на регион. Основа OMT кончается на z14 и растягивается
движком дальше, наш MVT — это z11 и z15. В одном архиве на z15 основа
пропала бы; в стиле это и так два источника.

    python3 build_regions.py --mvt <cand/mvt> --omt <uz.mbtiles> \
        --adm4 <adm4.geojsonl> --out <каталог> --version <N>

Пишет <out>/<код>.mvt.pmtiles, <код>.omt.pmtiles и regions_payload.json
(его подписывает publish_regions.sh). Только stdlib.
"""

import argparse
import gzip
import json
import math
import os
import sqlite3
import sys

import pmtiles

CELL_ZOOM = 12
FRINGE_CELLS = 8          # ~60 км кромки у границы страны

# У этих двух полигоны в выгрузке не собираются (см. выше): рамка решает
# только клетки, которые не забрал ни один настоящий полигон.
FALLBACK = {
    "UZ-FA": {"bbox": (70.3, 39.9, 72.25, 40.85),
              "name": {"uz": "Fargʻona viloyati", "ru": "Ферганская область"}},
    "UZ-QR": {"bbox": (55.9, 41.0, 62.6, 45.65),
              "name": {"uz": "Qoraqalpogʻiston Respublikasi", "ru": "Республика Каракалпакстан"}},
}


def cell_center(cx, cy):
    n = 1 << CELL_ZOOM
    lon = (cx + 0.5) / n * 360.0 - 180.0
    lat = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * (cy + 0.5) / n))))
    return lon, lat


def cell_bounds(cells):
    n = 1 << CELL_ZOOM
    xs = [x for x, _ in cells]
    ys = [y for _, y in cells]
    def lat(ty):
        return math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * ty / n))))
    return (min(xs) / n * 360 - 180, lat(max(ys) + 1), (max(xs) + 1) / n * 360 - 180, lat(min(ys)))


def _in_ring(lon, lat, ring):
    inside = False
    j = len(ring) - 1
    for i in range(len(ring)):
        xi, yi = ring[i][0], ring[i][1]
        xj, yj = ring[j][0], ring[j][1]
        if (yi > lat) != (yj > lat) and lon < (xj - xi) * (lat - yi) / (yj - yi) + xi:
            inside = not inside
        j = i
    return inside


def in_geometry(lon, lat, geometry):
    polygons = geometry["coordinates"] if geometry["type"] == "MultiPolygon" else [geometry["coordinates"]]
    for polygon in polygons:
        if _in_ring(lon, lat, polygon[0]) and not any(_in_ring(lon, lat, hole) for hole in polygon[1:]):
            return True
    return False


def load_regions(path):
    regions = {}
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            feature = json.loads(line.lstrip("\x1e"))
            props = feature["properties"]
            code = props["ISO3166-2"]
            regions[code] = {"geometry": feature["geometry"],
                             "name": {"uz": props.get("name:uz") or props.get("name"),
                                      "ru": props.get("name:ru") or props.get("name")}}
    return regions


def assign_cells(cells, regions):
    """{(cx, cy): код региона}. Порядок решений — в описании модуля."""
    owner = {}
    boxes = {code: _bbox(r["geometry"]) for code, r in regions.items()}
    for cell in sorted(cells):
        lon, lat = cell_center(*cell)
        for code in sorted(regions):
            box = boxes[code]
            if box[0] <= lon <= box[2] and box[1] <= lat <= box[3] \
                    and in_geometry(lon, lat, regions[code]["geometry"]):
                owner[cell] = code
                break
    for cell in sorted(cells):
        if cell in owner:
            continue
        lon, lat = cell_center(*cell)
        for code, spec in sorted(FALLBACK.items()):
            west, south, east, north = spec["bbox"]
            if west <= lon <= east and south <= lat <= north:
                owner[cell] = code
                break
    assigned = dict(owner)
    for cell in sorted(cells):
        if cell in owner:
            continue
        best = None
        for (x, y), code in assigned.items():
            dist = max(abs(x - cell[0]), abs(y - cell[1]))
            if dist <= FRINGE_CELLS and (best is None or (dist, code) < best):
                best = (dist, code)
        if best:
            owner[cell] = best[1]
    return owner


def _bbox(geometry):
    polygons = geometry["coordinates"] if geometry["type"] == "MultiPolygon" else [geometry["coordinates"]]
    lons = [p[0] for poly in polygons for p in poly[0]]
    lats = [p[1] for poly in polygons for p in poly[0]]
    return min(lons), min(lats), max(lons), max(lats)


def cell_of(z, x, y):
    if z < CELL_ZOOM:
        return None
    shift = z - CELL_ZOOM
    return x >> shift, y >> shift


def cell_rows(cells):
    """Клетки региона строками [y, x_от, x_до] — по ним телефон узнаёт, в каком
    регионе точка (дом, работа), без полигонов: несколько килобайт на страну."""
    rows = []
    for y in sorted({cy for _, cy in cells}):
        xs = sorted(cx for cx, cy in cells if cy == y)
        start = prev = xs[0]
        for x in xs[1:]:
            if x != prev + 1:
                rows.append([y, start, prev])
                start = x
            prev = x
        rows.append([y, start, prev])
    return rows


def ancestors(cells):
    """Все тайлы мельче клетки, покрывающие хотя бы одну клетку."""
    out = set()
    for cx, cy in cells:
        for z in range(CELL_ZOOM):
            shift = CELL_ZOOM - z
            out.add((z, cx >> shift, cy >> shift))
    return out


def mvt_tiles(root):
    for zoom in sorted(os.listdir(root)):
        if not zoom.isdigit():
            continue
        for x in os.listdir(os.path.join(root, zoom)):
            for name in os.listdir(os.path.join(root, zoom, x)):
                if name.endswith(".mvt"):
                    yield int(zoom), int(x), int(name[:-4]), os.path.join(root, zoom, x, name)


def omt_index(connection):
    rows = connection.execute("SELECT zoom_level, tile_column, tile_row FROM tiles")
    for z, x, row in rows:
        yield z, x, (1 << z) - 1 - row          # TMS → XYZ


def omt_tile(connection, z, x, y):
    row = connection.execute("SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=?",
                             (z, x, (1 << z) - 1 - y)).fetchone()
    return row[0] if row else None


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--mvt", required=True)
    parser.add_argument("--omt", required=True)
    parser.add_argument("--adm4", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--version", type=int, required=True)
    args = parser.parse_args(argv[1:])
    os.makedirs(args.out, exist_ok=True)

    regions = load_regions(args.adm4)
    for code, spec in FALLBACK.items():
        regions.setdefault(code, {"geometry": None, "name": spec["name"]})
    polygons = {code: r for code, r in regions.items() if r["geometry"]}

    mvt = list(mvt_tiles(args.mvt))
    connection = sqlite3.connect(f"file:{args.omt}?mode=ro", uri=True)
    omt = list(omt_index(connection))
    meta = dict(connection.execute("SELECT name, value FROM metadata"))
    cells = {cell_of(z, x, y) for z, x, y, _ in mvt if z >= CELL_ZOOM}
    cells |= {cell_of(z, x, y) for z, x, y in omt if z >= CELL_ZOOM}
    owner = assign_cells(cells, polygons)
    dropped = len(cells) - len(owner)
    print(f"клеток z{CELL_ZOOM}: {len(cells)}, в регионах {len(owner)}, вне страны {dropped}")

    by_region = {}
    for cell, code in owner.items():
        by_region.setdefault(code, set()).add(cell)

    payload = {"version": args.version, "cellZoom": CELL_ZOOM, "regions": []}
    for code in sorted(by_region):
        region_cells = by_region[code]
        low = ancestors(region_cells)
        mvt_part = {}
        for z, x, y, path in mvt:
            if cell_of(z, x, y) in region_cells or (z, x, y) in low:
                with open(path, "rb") as handle:
                    mvt_part[(z, x, y)] = gzip.compress(handle.read(), compresslevel=6, mtime=0)
        omt_part = {}
        for z, x, y in omt:
            if (z < CELL_ZOOM and (z, x, y) in low) or cell_of(z, x, y) in region_cells:
                omt_part[(z, x, y)] = omt_tile(connection, z, x, y)
        bounds = cell_bounds(region_cells)
        files = {}
        for kind, tiles, metadata in (
                ("mvt", mvt_part, {"name": f"RadarMap {code}", "format": "pbf",
                                   "attribution": "© OpenStreetMap contributors"}),
                ("omt", omt_part, {"name": f"OpenMapTiles {code}", "format": "pbf",
                                   "attribution": meta.get("attribution", ""),
                                   "json": meta.get("json", "")})):
            if not tiles:
                continue
            name = f"{code}.{kind}.pmtiles"
            sha, info = pmtiles.write(os.path.join(args.out, name), tiles, metadata,
                                      pmtiles.COMPRESSION_GZIP, bounds=bounds)
            files[kind] = {"file": name, "bytes": info["bytes"], "sha256": sha, "tiles": info["tiles"]}
        payload["regions"].append({
            "id": code, "name": regions[code]["name"],
            "bbox": [round(v, 5) for v in bounds], "cells": len(region_cells),
            "rows": cell_rows(region_cells),
            "files": files})
        total = sum(f["bytes"] for f in files.values())
        print(f"{code}: клеток {len(region_cells)}, {total / 1e6:.1f} МБ "
              f"(MVT {files.get('mvt', {}).get('bytes', 0) / 1e6:.1f}, OMT {files.get('omt', {}).get('bytes', 0) / 1e6:.1f})"
              f" — {regions[code]['name']['ru']}")

    with open(os.path.join(args.out, "regions_payload.json"), "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    total = sum(f["bytes"] for r in payload["regions"] for f in r["files"].values())
    print(f"регионов {len(payload['regions'])}, вся страна {total / 1e6:.0f} МБ")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
