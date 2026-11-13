#!/usr/bin/env python3
"""Обзорная основа в бандл приложения: PMTiles с OMT страны z0–9 и Ташкента z10–12.

План 13.11, решение 5: на первом запуске карта 15–30 секунд белая, пока не
придут тайлы. Основа из бандла рисуется под сетевой (EngineModernStyle,
источник «seed») — вода, зелень и дороги есть с первого кадра, растянутые с
z12; сетевые тайлы ложатся поверх, как только придут.

    python3 server/omt/build_seed.py <uz.mbtiles> RadarMap/Resources/MapSeed/omt_seed.pmtiles

Предел — SEED_MAX_BYTES: больше — сборка падает, а не раздувает приложение.
"""
import math
import os
import sqlite3
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import pmtiles  # noqa: E402

COUNTRY_MAX_ZOOM = 9
CITY_ZOOMS = (10, 11, 12)
# Ташкент с кольцевой и пригородами: юг — Сергели, север — Юнусабад,
# запад — Чиланзар, восток — Куйлюк.
CITY_BBOX = (69.05, 41.15, 69.50, 41.45)   # мин. долгота, мин. широта, макс. долгота, макс. широта
SEED_MAX_BYTES = 10 * 1024 * 1024


def tile_range(bbox, zoom):
    """Тайлы XYZ, накрывающие рамку, включительно: (x0, y0, x1, y1)."""
    west, south, east, north = bbox
    n = 1 << zoom

    def x_of(lon):
        return min(n - 1, int((lon + 180.0) / 360.0 * n))

    def y_of(lat):
        rad = math.radians(lat)
        return min(n - 1, int((1 - math.log(math.tan(rad) + 1 / math.cos(rad)) / math.pi) / 2 * n))

    return x_of(west), y_of(north), x_of(east), y_of(south)


def wanted(z, x, y):
    if z <= COUNTRY_MAX_ZOOM:
        return True
    if z in CITY_ZOOMS:
        x0, y0, x1, y1 = tile_range(CITY_BBOX, z)
        return x0 <= x <= x1 and y0 <= y <= y1
    return False


def select(connection):
    tiles = {}
    rows = connection.execute("SELECT zoom_level, tile_column, tile_row, tile_data FROM tiles "
                              "WHERE zoom_level <= ?", (max(CITY_ZOOMS),))
    for z, x, row, data in rows:
        y = (1 << z) - 1 - row          # TMS → XYZ
        if wanted(z, x, y):
            tiles[(z, x, y)] = bytes(data)
    return tiles


def main(argv):
    if len(argv) != 3:
        print(__doc__)
        return 2
    source, out = argv[1], argv[2]
    connection = sqlite3.connect(source)
    meta = dict(connection.execute("SELECT name, value FROM metadata"))
    if meta.get("compression", "gzip") != "gzip":
        raise SystemExit("ожидались тайлы в gzip")
    tiles = select(connection)
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    sha, info = pmtiles.write(out, tiles, {"name": "RadarMap seed", "format": "pbf",
                                           "attribution": meta.get("attribution", ""),
                                           "json": meta.get("json", "")},
                              pmtiles.COMPRESSION_GZIP)
    if info["bytes"] > SEED_MAX_BYTES:
        os.remove(out)
        raise SystemExit(f"основа {info['bytes'] / 1e6:.1f} МБ больше предела {SEED_MAX_BYTES / 1e6:.1f} МБ")
    print(f"{out}: {info['tiles']} тайлов, {info['bytes'] / 1e6:.2f} МБ, sha256 {sha[:16]}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
