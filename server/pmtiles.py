#!/usr/bin/env python3
"""PMTiles v3: запись и чтение одного файла-архива тайлов (только stdlib).

Офлайн-регион — один файл на область (docs/plan_map_offline.md §2.3): движок
читает его локально (`pmtiles://file://…`), без сети и без тысяч мелких
файлов. Формат — спецификация PMTiles v3
(github.com/protomaps/PMTiles/blob/main/spec/v3/spec.md):

    заголовок 127 байт | корневой каталог | метаданные JSON | листовые
    каталоги | данные тайлов

Тайл адресуется TileID — номером на кривой Гильберта внутри своего зума плюс
число тайлов всех меньших зумов. Каталог — отсортированные записи
(tile_id, offset, length, run_length), сжатые varint'ами и дельтами; длинный
каталог раскладывается на листья, чтобы корень с заголовком влезал в первые
16 КБ (одно чтение с диска).

Одинаковые тайлы (пустая степь, вода) пишутся один раз: дубликаты ссылаются на
те же байты, а подряд идущие одинаковые сливаются в run_length.

Запись детерминированна: gzip с mtime=0, порядок по TileID — одинаковый вход
даёт байт в байт одинаковый файл, и sha256 региона повторяем.
"""

import gzip
import hashlib
import json
import struct

MAGIC = b"PMTiles"
VERSION = 3
HEADER_BYTES = 127
ROOT_LIMIT = 16384 - HEADER_BYTES

COMPRESSION_NONE = 1
COMPRESSION_GZIP = 2
TILE_TYPE_MVT = 1


# --- TileID на кривой Гильберта (как эталонная реализация PMTiles) ---

def _rotate(n, x, y, rx, ry):
    if ry == 0:
        if rx == 1:
            x = n - 1 - x
            y = n - 1 - y
        x, y = y, x
    return x, y


def zxy_to_tileid(z, x, y):
    if z > 31:
        raise ValueError("зум больше 31")
    n = 1 << z
    if not (0 <= x < n and 0 <= y < n):
        raise ValueError(f"тайл вне сетки: {z}/{x}/{y}")
    acc = ((1 << (2 * z)) - 1) // 3
    d = 0
    tx, ty = x, y
    s = n // 2
    while s > 0:
        rx = 1 if tx & s else 0
        ry = 1 if ty & s else 0
        d += s * s * ((3 * rx) ^ ry)
        tx, ty = _rotate(n, tx, ty, rx, ry)
        s //= 2
    return acc + d


def tileid_to_zxy(tile_id):
    acc = 0
    for z in range(32):
        count = 1 << (2 * z)
        if acc + count > tile_id:
            d = tile_id - acc
            n = 1 << z
            x = y = 0
            s = 1
            while s < n:
                rx = 1 & (d // 2)
                ry = 1 & (d ^ rx)
                x, y = _rotate(s, x, y, rx, ry)
                x += s * rx
                y += s * ry
                d //= 4
                s *= 2
            return z, x, y
        acc += count
    raise ValueError("tile_id вне диапазона")


# --- varint и каталоги ---

def _varint(value, out):
    while value >= 0x80:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)


def _read_varint(data, pos):
    shift = result = 0
    while True:
        byte = data[pos]
        pos += 1
        result |= (byte & 0x7F) << shift
        if byte < 0x80:
            return result, pos
        shift += 7


def serialize_directory(entries):
    """entries — [(tile_id, offset, length, run_length)] по возрастанию tile_id."""
    out = bytearray()
    _varint(len(entries), out)
    last = 0
    for tile_id, _, _, _ in entries:
        _varint(tile_id - last, out)
        last = tile_id
    for _, _, _, run in entries:
        _varint(run, out)
    for _, _, length, _ in entries:
        _varint(length, out)
    for i, (_, offset, _, _) in enumerate(entries):
        previous = entries[i - 1] if i else None
        if previous and offset == previous[1] + previous[2]:
            _varint(0, out)
        else:
            _varint(offset + 1, out)
    return bytes(out)


def deserialize_directory(data):
    count, pos = _read_varint(data, 0)
    ids, runs, lengths, offsets = [], [], [], []
    last = 0
    for _ in range(count):
        delta, pos = _read_varint(data, pos)
        last += delta
        ids.append(last)
    for _ in range(count):
        value, pos = _read_varint(data, pos)
        runs.append(value)
    for _ in range(count):
        value, pos = _read_varint(data, pos)
        lengths.append(value)
    for i in range(count):
        value, pos = _read_varint(data, pos)
        if value == 0 and i > 0:
            offsets.append(offsets[i - 1] + lengths[i - 1])
        else:
            offsets.append(value - 1)
    return list(zip(ids, offsets, lengths, runs))


def _gzip(data):
    return gzip.compress(data, compresslevel=9, mtime=0)


def _build_directories(entries):
    """Корень и листья. Возвращает (корень, листья) уже сжатыми."""
    root = _gzip(serialize_directory(entries))
    if len(root) <= ROOT_LIMIT:
        return root, b""
    leaf_size = 4096
    while True:
        leaves = bytearray()
        root_entries = []
        for start in range(0, len(entries), leaf_size):
            chunk = entries[start:start + leaf_size]
            blob = _gzip(serialize_directory(chunk))
            root_entries.append((chunk[0][0], len(leaves), len(blob), 0))
            leaves += blob
        root = _gzip(serialize_directory(root_entries))
        if len(root) <= ROOT_LIMIT:
            return root, bytes(leaves)
        leaf_size *= 2


# --- Запись ---

def write(path, tiles, metadata, tile_compression, bounds=None, center_zoom=None):
    """tiles — {(z, x, y): байты тайла (уже в tile_compression)}.

    bounds — (мин_долгота, мин_широта, макс_долгота, макс_широта); по умолчанию —
    рамка самих тайлов. Возвращает sha256 файла (hex) и сводку.
    """
    if not tiles:
        raise ValueError("пустой архив не пишется")
    by_id = sorted((zxy_to_tileid(z, x, y), data) for (z, x, y), data in tiles.items())
    entries = []
    seen = {}
    blob = bytearray()
    for tile_id, data in by_id:
        digest = hashlib.sha256(data).digest()
        if digest in seen:
            offset, length = seen[digest]
        else:
            offset, length = len(blob), len(data)
            seen[digest] = (offset, length)
            blob += data
        last = entries[-1] if entries else None
        if (last and last[1] == offset and last[2] == length
                and last[0] + last[3] == tile_id):
            entries[-1] = (last[0], last[1], last[2], last[3] + 1)
        else:
            entries.append((tile_id, offset, length, 1))

    root, leaves = _build_directories(entries)
    meta = _gzip(json.dumps(metadata, ensure_ascii=False, sort_keys=True,
                            separators=(",", ":")).encode())
    zooms = [z for z, _, _ in tiles]
    if bounds is None:
        bounds = _tiles_bounds(tiles)
    min_lon, min_lat, max_lon, max_lat = bounds
    cz = center_zoom if center_zoom is not None else min(max(zooms), max(min(zooms), 10))

    root_offset = HEADER_BYTES
    meta_offset = root_offset + len(root)
    leaf_offset = meta_offset + len(meta)
    data_offset = leaf_offset + len(leaves)
    header = struct.pack(
        "<7sBQQQQQQQQQQQBBBBBBiiiiBii",
        MAGIC, VERSION,
        root_offset, len(root), meta_offset, len(meta), leaf_offset, len(leaves),
        data_offset, len(blob),
        len(by_id), len(entries), len(seen),
        1, COMPRESSION_GZIP, tile_compression, TILE_TYPE_MVT,
        min(zooms), max(zooms),
        _e7(min_lon), _e7(min_lat), _e7(max_lon), _e7(max_lat),
        cz, _e7((min_lon + max_lon) / 2), _e7((min_lat + max_lat) / 2))
    assert len(header) == HEADER_BYTES
    sha = hashlib.sha256()
    with open(path, "wb") as handle:
        for part in (header, root, meta, leaves, bytes(blob)):
            handle.write(part)
            sha.update(part)
    return sha.hexdigest(), {"tiles": len(by_id), "entries": len(entries),
                             "contents": len(seen), "bytes": data_offset + len(blob),
                             "leaves": bool(leaves)}


def _e7(value):
    return int(round(value * 1e7))


def _tiles_bounds(tiles):
    import math
    lons, lats = [], []
    for z, x, y in tiles:
        n = 1 << z
        for tx, ty in ((x, y), (x + 1, y + 1)):
            lons.append(tx / n * 360.0 - 180.0)
            lats.append(math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * ty / n)))))
    return min(lons), min(lats), max(lons), max(lats)


# --- Чтение (самопроверка и тесты) ---

class Reader:
    def __init__(self, path):
        with open(path, "rb") as handle:
            self.data = handle.read()
        fields = struct.unpack_from("<7sBQQQQQQQQQQQBBBBBBiiiiBii", self.data, 0)
        if fields[0] != MAGIC or fields[1] != VERSION:
            raise ValueError("не PMTiles v3")
        (_, _, self.root_offset, self.root_len, self.meta_offset, self.meta_len,
         self.leaf_offset, self.leaf_len, self.data_offset, self.data_len,
         self.addressed, self.entries_count, self.contents, self.clustered,
         self.internal, self.tile_compression, self.tile_type,
         self.min_zoom, self.max_zoom, *_rest) = fields
        self.bounds = tuple(v / 1e7 for v in fields[19:23])

    def _dir(self, offset, length):
        return deserialize_directory(gzip.decompress(self.data[offset:offset + length]))

    @property
    def metadata(self):
        raw = self.data[self.meta_offset:self.meta_offset + self.meta_len]
        return json.loads(gzip.decompress(raw))

    def get(self, z, x, y):
        target = zxy_to_tileid(z, x, y)
        directory = self._dir(self.root_offset, self.root_len)
        for _ in range(4):
            entry = None
            for item in directory:
                if item[0] <= target:
                    entry = item
                else:
                    break
            if entry is None:
                return None
            tile_id, offset, length, run = entry
            if run == 0:
                directory = self._dir(self.leaf_offset + offset, length)
                continue
            if target < tile_id + run:
                start = self.data_offset + offset
                return self.data[start:start + length]
            return None
        raise ValueError("слишком глубокие каталоги")

    def all_tiles(self):
        """Генератор (z, x, y, байты) — для полной сверки архива."""
        def walk(directory):
            for tile_id, offset, length, run in directory:
                if run == 0:
                    yield from walk(self._dir(self.leaf_offset + offset, length))
                else:
                    start = self.data_offset + offset
                    for k in range(run):
                        yield (*tileid_to_zxy(tile_id + k), self.data[start:start + length])
        yield from walk(self._dir(self.root_offset, self.root_len))
