#!/usr/bin/env python3
"""mbtiles (Planetiler, схема OpenMapTiles) → каталог z/x/y.pbf + индекс sha256.

Индекс той же формы, что mvt_index нашей карты — {"version": 1, "tiles":
{"z/x/y": {"sha256", "bytes"}}}, — и подписывается тем же ключом владельца:
телефон (EngineTileGuard) пропускает к движку только тайл, чей sha совпал с
подписанным индексом. Взломанный сервер не нарисует водителю своих дорог.

Тайлы пишутся РАСПАКОВАННЫМИ: sha считается по телу, которое видит телефон,
а URLSession распаковывает gzip сам. Сжимает при отдаче nginx.

    python3 server/omt/export_mbtiles.py uz.mbtiles out_dir
"""
import gzip
import hashlib
import json
import os
import sqlite3
import sys


def export(mbtiles, out_dir):
    conn = sqlite3.connect(mbtiles)
    index = {}
    try:
        for zoom, column, row, data in conn.execute(
                "SELECT zoom_level, tile_column, tile_row, tile_data FROM tiles "
                "ORDER BY zoom_level, tile_column, tile_row"):
            y = (1 << zoom) - 1 - row           # mbtiles хранит TMS, наружу — XYZ
            body = gzip.decompress(data) if data[:2] == b"\x1f\x8b" else data
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
    return index


if __name__ == "__main__":
    made = export(sys.argv[1], sys.argv[2])
    print(f"тайлов {len(made)}, {sum(m['bytes'] for m in made.values()) / 1e6:.1f} МБ")
