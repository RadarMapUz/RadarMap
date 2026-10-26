#!/usr/bin/env python3
"""mbtiles (Planetiler, схема OpenMapTiles) → каталог z/x/y.pbf + индекс sha256.

Индекс той же формы, что mvt_index нашей карты — {"version": 1, "tiles":
{"z/x/y": {"sha256", "bytes"}}}, — и подписывается тем же ключом владельца:
телефон (EngineTileGuard) пропускает к движку только тайл, чей sha совпал с
подписанным индексом. Взломанный сервер не нарисует водителю своих дорог.

Тайлы пишутся РАСПАКОВАННЫМИ: sha считается по телу, которое видит телефон,
а URLSession распаковывает gzip сам. Сжимает при отдаче nginx.

Тайлам z14 по дороге дописывается назначение домов (building_use.py, 30.A):
больница, школа, магазин, промзона, храм — стиль красит их своим оттенком.
Экстракт домов (--houses, тот же houses.geojsonl, что у сборки дорог) даёт
назначение по тегам самого здания; без него — по заведениям и территориям
внутри тайла.

    python3 server/omt/export_mbtiles.py uz.mbtiles out_dir [--houses houses.geojsonl]
"""
import gzip
import hashlib
import json
import os
import sqlite3
import sys

import building_use


def export(mbtiles, out_dir, footprints=None):
    conn = sqlite3.connect(mbtiles)
    index = {}
    tagged = 0
    try:
        for zoom, column, row, data in conn.execute(
                "SELECT zoom_level, tile_column, tile_row, tile_data FROM tiles "
                "ORDER BY zoom_level, tile_column, tile_row"):
            y = (1 << zoom) - 1 - row           # mbtiles хранит TMS, наружу — XYZ
            body = gzip.decompress(data) if data[:2] == b"\x1f\x8b" else data
            if zoom == building_use.ZOOM:
                new = building_use.tag_tile(body, column, y, footprints)
                tagged += new != body
                body = new
            folder = os.path.join(out_dir, "omt", str(zoom), str(column))
            os.makedirs(folder, exist_ok=True)
            with open(os.path.join(folder, f"{y}.pbf"), "wb") as handle:
                handle.write(body)
            index[f"{zoom}/{column}/{y}"] = {"sha256": hashlib.sha256(body).hexdigest(),
                                            "bytes": len(body)}
        meta = dict(conn.execute("SELECT name, value FROM metadata"))
    finally:
        conn.close()
    payload = json.dumps({"version": 1, "tiles": index,
                          "minzoom": int(meta.get("minzoom", 0)),
                          "maxzoom": int(meta.get("maxzoom", 14))},
                         separators=(",", ":"), sort_keys=True).encode()
    with open(os.path.join(out_dir, "omt_index_payload.json"), "wb") as handle:
        handle.write(payload)
    export.tagged = tagged
    return index


if __name__ == "__main__":
    houses = sys.argv[sys.argv.index("--houses") + 1] if "--houses" in sys.argv else None
    footprints = building_use.load_footprints(houses)
    made = export(sys.argv[1], sys.argv[2], footprints)
    print(f"тайлов {len(made)}, {sum(m['bytes'] for m in made.values()) / 1e6:.1f} МБ; "
          f"дома по назначению: контуров OSM {footprints.count}, тайлов z{building_use.ZOOM} {export.tagged}")
