#!/usr/bin/env python3
"""Индекс тайлов корзинами: подписанный корень + бинарная корзина на клетку z10.

Зачем. Один индекс на страну — `mvt_index.json` 23,6 МБ и `omt_index.json`
27,2 МБ — телефон разбирал целиком: около сотни мегабайт транзиентно, и
телеметрия показала отстрелы по памяти. Корзина — это тот же индекс, но только
своего района: 16–55 КБ, и качается она по мере движения.

Устройство (docs/plan_map_offline.md §2.2):

    tiles_root.json  — SignedPayload: {"version": N, "bucketZoom": 10,
                        "sets": {"mvt": {...}, "omt": {...}}}
                        в каждом наборе — sha256 каждой корзины;
    v/N/idx/<набор>/<bx>_<by>.bin — корзина: тайлы набора, чей предок на z10
                        равен (bx, by); тайлы мельче z10 — в «low.bin».

Корзина — ровно формат RMTI v1 из `TileDigestIndex.swift`: магия «RMTI»,
формат 1, версия (int64 LE), число записей (uint32 LE), ключи (uint64 LE,
по возрастанию), затем sha256 по 32 байта в том же порядке. Ключ —
`z << 48 | x << 24 | y`, как `TileDigestIndex.packed`. Телефон разбирает
корзину тем же кодом, что сегодня разбирает свой кэш, — второго парсера нет.

Доверие по цепочке: подпись корня → sha корзины → sha тайла. Подделать тайл
нельзя, не подделав корзину, а корзину — не подделав подпись корня.

Только stdlib. Детерминированно: одинаковый вход — байт в байт одинаковый выход.
"""

import hashlib
import json
import os
import struct
import sys

BUCKET_ZOOM = 10
MAGIC = b"RMTI"
FORMAT = 1
LOW = "low"


def packed(z, x, y):
    """Ключ тайла — как TileDigestIndex.packed(z:x:y:)."""
    if not (0 <= z <= 24 and 0 <= x < (1 << 24) and 0 <= y < (1 << 24)):
        raise ValueError(f"тайл вне диапазона: {z}/{x}/{y}")
    return (z << 48) | (x << 24) | y


def parse_key(key):
    z, x, y = (int(part) for part in key.split("/"))
    return z, x, y


def bucket_of(z, x, y):
    """Имя корзины тайла: предок на BUCKET_ZOOM либо LOW для мелких зумов."""
    if z < BUCKET_ZOOM:
        return LOW
    shift = z - BUCKET_ZOOM
    return f"{x >> shift}_{y >> shift}"


def serialize(version, entries):
    """RMTI v1. entries — [(ключ uint64, sha256 bytes)]; сортируются здесь."""
    entries = sorted(entries)
    keys = [key for key, _ in entries]
    if len(set(keys)) != len(keys):
        raise ValueError("повтор ключа в корзине")
    out = bytearray(MAGIC)
    out.append(FORMAT)
    out += struct.pack("<qI", version, len(entries))
    for key in keys:
        out += struct.pack("<Q", key)
    for _, digest in entries:
        if len(digest) != 32:
            raise ValueError("sha256 должен быть 32 байта")
        out += digest
    return bytes(out)


def parse(data):
    """Обратный разбор (для тестов и самопроверки) → (версия, {ключ: sha})."""
    if data[:4] != MAGIC or data[4] != FORMAT:
        raise ValueError("не RMTI v1")
    version, count = struct.unpack_from("<qI", data, 5)
    head = 17
    if len(data) != head + count * 40:
        raise ValueError("длина не сходится")
    keys = struct.unpack_from(f"<{count}Q", data, head)
    digests = data[head + count * 8:]
    if list(keys) != sorted(set(keys)):
        raise ValueError("ключи не по возрастанию")
    return version, {key: digests[i * 32:(i + 1) * 32] for i, key in enumerate(keys)}


def buckets_for(tiles, version):
    """tiles — {"z/x/y": "sha256 hex"} → {имя корзины: байты RMTI}."""
    grouped = {}
    for key, digest_hex in tiles.items():
        z, x, y = parse_key(key)
        digest = bytes.fromhex(digest_hex)
        grouped.setdefault(bucket_of(z, x, y), []).append((packed(z, x, y), digest))
    return {name: serialize(version, entries) for name, entries in grouped.items()}


def tiles_from_payload(payload):
    """Индекс публикации (как mvt_index_payload.json) → {"z/x/y": sha hex}."""
    tiles = payload["tiles"]
    return {key: (meta["sha256"] if isinstance(meta, dict) else meta)
            for key, meta in tiles.items()}


def build(version, sets, out_dir):
    """sets — {имя набора: {"path": каталог тайлов, "ext": расширение,
    "tiles": {ключ: sha}}}. Пишет корзины в out_dir/idx/<набор>/ и
    возвращает полезную нагрузку корня (её подписывают снаружи)."""
    root = {"version": version, "bucketZoom": BUCKET_ZOOM, "sets": {}}
    for name in sorted(sets):
        spec = sets[name]
        target = os.path.join(out_dir, "idx", name)
        os.makedirs(target, exist_ok=True)
        hashes = {}
        for bucket, blob in sorted(buckets_for(spec["tiles"], version).items()):
            with open(os.path.join(target, bucket + ".bin"), "wb") as handle:
                handle.write(blob)
            hashes[bucket] = hashlib.sha256(blob).hexdigest()
        root["sets"][name] = {"path": spec["path"], "ext": spec["ext"],
                              "tiles": len(spec["tiles"]), "buckets": hashes}
    return root


def main(argv):
    """tile_buckets.py <версия> <каталог-выход> <набор>=<payload.json>:<путь>:<ext> ...

    Пишет <выход>/idx/... и <выход>/tiles_root_payload.json."""
    if len(argv) < 4:
        print(main.__doc__)
        return 2
    version = int(argv[1])
    out_dir = argv[2]
    sets = {}
    for spec in argv[3:]:
        name, rest = spec.split("=", 1)
        payload_path, path, ext = rest.split(":")
        with open(payload_path, encoding="utf-8") as handle:
            sets[name] = {"path": path, "ext": ext,
                          "tiles": tiles_from_payload(json.load(handle))}
    root = build(version, sets, out_dir)
    with open(os.path.join(out_dir, "tiles_root_payload.json"), "w", encoding="utf-8") as handle:
        json.dump(root, handle, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    for name, spec in root["sets"].items():
        sizes = [os.path.getsize(os.path.join(out_dir, "idx", name, b + ".bin"))
                 for b in spec["buckets"]]
        sizes.sort()
        print(f"{name}: тайлов {spec['tiles']}, корзин {len(sizes)}, "
              f"медиана {sizes[len(sizes) // 2] / 1024:.1f} КБ, максимум {sizes[-1] / 1024:.1f} КБ")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
