"""Тайлы MVT рядом с нашим форматом.

Наш JSON остаётся: его читают телефон и панель, и переход идёт параллельно, а
не заменой. MVT пишется из ТЕХ ЖЕ данных одним лишним шагом кодирования — это
не вторая копия карты, а второй вывод одной сборки.

Раскладка потоком, а не списком, и это не запас прочности: сборка страны уже
дважды была убита ядром по памяти, и оба слоя, которые её убивали, теперь
пишут файл сразу. Здесь тот же приём с самого начала.
"""
import hashlib
import json
import os
import shutil
from collections import OrderedDict

import mvt
from build_roads import (AREA_HOUSE, AREA_JUNCTION, AREA_MEDIAN, AREA_ROAD,
                         FLAG_BRIDGE,
                         FLAG_LANES_TAGGED, FLAG_ONEWAY, FLAG_TUNNEL,
                         SURFACE_CLASS_MASK, SURFACE_CLASS_SHIFT, lanes_of,
                         road_width_meters)

# Зумы. Два, а не десять.
#
# Детальный — 15: в нём тайл около полутора километров по широте Ташкента, то
# есть примерно то, что видно на рабочем экране конструктора. Обзорный — 11:
# на нём рисуется костяк района, и подробная сеть там не нужна ни глазу, ни
# каналу. Промежуточные зумы клиент берёт растягиванием — так делают все, и
# писать их значило бы платить местом за то, что и так получается.
ZOOM_DETAIL = 15
ZOOM_FAR = 11

LAYER_ROADS = "roads"
LAYER_SURFACE = "surface"
LAYER_LAND = "land"
LAYER_HOUSES = "houses"
LAYER_POINTS = "points"

# Кому какой зум. Слой, невидимый на обзоре, туда и не едет — тот же закон,
# по которому телефон не качает дворовые проезды на охвате района.
FAR_LAYERS = {LAYER_ROADS}


def _road_props(road):
    code, flags = road[0], road[1]
    name = road[3] if len(road) > 3 else ""
    lanes = lanes_of(flags)
    props = {"cls": code, "width": round(road_width_meters(code, lanes), 1)}
    if name:
        props["name"] = name
    if flags & FLAG_ONEWAY:
        props["oneway"] = True
    if flags & FLAG_BRIDGE:
        props["bridge"] = True
    if flags & FLAG_TUNNEL:
        props["tunnel"] = True
    if flags & FLAG_LANES_TAGGED:
        props["lanes"] = lanes
        props["measured"] = True
    return props


def _area_props(kind, flags):
    props = {"kind": kind}
    if kind == AREA_ROAD:
        props["cls"] = (flags >> SURFACE_CLASS_SHIFT) & SURFACE_CLASS_MASK
    return props


def _layer_of(kind):
    if kind in (AREA_ROAD, AREA_JUNCTION, AREA_MEDIAN):
        return LAYER_SURFACE
    if kind == AREA_HOUSE:
        return LAYER_HOUSES
    return LAYER_LAND


class _Buckets:
    """Черновики тайлов на диске. В памяти — один объект и до `handles` файлов."""

    def __init__(self, work, handles=64):
        self.work = work
        self.handles = handles
        self.open = OrderedDict()
        self.keys = set()
        shutil.rmtree(work, ignore_errors=True)
        os.makedirs(work, exist_ok=True)

    def sink(self, key):
        handle = self.open.get(key)
        if handle is not None:
            self.open.move_to_end(key)
            return handle
        while len(self.open) >= self.handles:
            self.open.popitem(last=False)[1].close()
        handle = open(os.path.join(self.work, key + ".jsonl"), "a",
                      encoding="utf-8")
        self.open[key] = handle
        self.keys.add(key)
        return handle

    def close(self):
        for handle in self.open.values():
            handle.close()
        self.open.clear()


def _put(buckets, zoom, layer, geom_kind, points, props):
    """Разложить одну фигуру по тайлам зума.

    Фигура, задевшая несколько тайлов, попадает в каждый ЦЕЛИКОМ — как у нас в
    JSON. Резать её по границе было бы правильнее по трафику и опаснее по
    смыслу: обрезанная улица теряет имя и направление на стыке, а координаты
    за пределами тайла спецификация разрешает, и клиент режет их сам.
    """
    seen = set()
    for lon, lat in points:
        seen.add(mvt.tile_of(lat, lon, zoom))
    for tile_x, tile_y in sorted(seen):
        shape = [mvt.project(lat, lon, zoom, tile_x, tile_y)
                 for lon, lat in points]
        row = json.dumps([layer, geom_kind, shape, props], separators=(",", ":"))
        buckets.sink(f"{zoom}_{tile_x}_{tile_y}").write(row + "\n")


SCALE = 1e5   # шаг координат в тайле, тот же что в build_roads


def written_areas(target_dir, set_name):
    """Читать обратно то, что уже написано в тайлы: дома и поверхность.

    Оба слоя пишутся ПОТОКОМ, прямо в файлы тайлов, и в списке `areas` их нет
    вовсе — иначе сборка страны не поместилась бы в память. Значит и в MVT их
    неоткуда взять, кроме как перечитав написанное.

    Это не обходной путь, а следствие: слой, который не влезает в память при
    записи, не влезет в неё и при перекодировании. Читаем по одному тайлу.
    """
    if not os.path.isdir(target_dir):
        return
    tail = f"_{set_name}.json"
    for name in sorted(os.listdir(target_dir)):
        if not name.startswith("road2_") or not name.endswith(tail):
            continue
        try:
            with open(os.path.join(target_dir, name), encoding="utf-8") as handle:
                payload = json.load(handle)
        except (OSError, ValueError):
            continue
        for entry in payload.get("roads") or []:
            if len(entry) < 3:
                continue
            kind, flags, flat = entry[0], entry[1], entry[2]
            if len(flat) < 4 or len(flat) % 2:
                continue
            points, lat, lon = [], 0, 0
            for i in range(0, len(flat), 2):
                if i == 0:
                    lat, lon = flat[0], flat[1]
                else:
                    lat += flat[i]
                    lon += flat[i + 1]
                points.append((lon / SCALE, lat / SCALE))
            yield kind, flags, points


def build_mvt(roads, target_dir, areas=(), points=(), far=(),
              zoom=ZOOM_DETAIL, far_zoom=ZOOM_FAR, handles=64,
              written_sets=("h", "d")):
    """Написать .mvt под target_dir/mvt/<z>/<x>/<y>.mvt. Возвращает {путь: байты}."""
    work = os.path.join(target_dir, "_mvt")
    buckets = _Buckets(work, handles)
    try:
        for road in roads:
            _put(buckets, zoom, LAYER_ROADS, mvt.LINESTRING, road[2],
                 _road_props(road))
        for road in far:
            _put(buckets, far_zoom, LAYER_ROADS, mvt.LINESTRING, road[2],
                 _road_props(road))
        def lay(kind, flags, shape):
            _put(buckets, zoom, _layer_of(kind),
                 mvt.POLYGON if flags & 1 else mvt.LINESTRING,
                 shape, _area_props(kind, flags))

        for kind, flags, shape in areas:
            lay(kind, flags, shape)
        # Дома и поверхность — из уже написанных тайлов: в памяти их нет.
        for set_name in written_sets:
            for kind, flags, shape in written_areas(target_dir, set_name):
                lay(kind, flags, shape)
        for point in points:
            code, flags, spot = point[0], point[1], point[2]
            _put(buckets, zoom, LAYER_POINTS, mvt.POINT, list(spot),
                 {"kind": code, "flags": flags})
    finally:
        buckets.close()

    written = {}
    root = os.path.join(target_dir, "mvt")
    for key in sorted(buckets.keys):
        zoom_at, tile_x, tile_y = key.split("_")
        layers = OrderedDict()
        with open(os.path.join(work, key + ".jsonl"), encoding="utf-8") as handle:
            rows = [json.loads(line) for line in handle if line.strip()]
        # Порядок внутри тайла УСТОЙЧИВЫЙ: иначе те же данные дают разные
        # байты каждую неделю, и всё, что кэшируется по хэшу, качается заново.
        rows.sort(key=lambda row: (row[0], row[1], row[2][0], len(row[2])))
        for layer_name, geom_kind, shape, props in rows:
            layer = layers.get(layer_name)
            if layer is None:
                layer = layers[layer_name] = mvt.Layer(layer_name)
            layer.add(geom_kind, [[tuple(p) for p in shape]], props)
        blob = mvt.tile_bytes(list(layers.values()))
        if not blob:
            continue
        folder = os.path.join(root, zoom_at, tile_x)
        os.makedirs(folder, exist_ok=True)
        path = os.path.join(folder, f"{tile_y}.mvt")
        with open(path, "wb") as out:
            out.write(blob)
        written[f"{zoom_at}/{tile_x}/{tile_y}"] = {
            "sha256": hashlib.sha256(blob).hexdigest(),
            "bytes": len(blob),
        }
    shutil.rmtree(work, ignore_errors=True)
    # Индекс MVT — рядом с тайлами и по той же форме, что у нашего формата.
    #
    # Раньше дерево MVT ехало без подписи, и это было записано осознанно:
    # «MVT читает панель, а она за входом». В день, когда его начинает читать
    # ТЕЛЕФОН, посылка становится ложной: геометрия дорог у водителя обязана
    # приходить только от владельца ключа, иначе взломанный сервер рисует
    # человеку свои дороги. Правило 19 из ARCHITECTURE.md не смягчается —
    # подпись накрывает все тайлы разом через их sha256.
    payload = json.dumps({"version": 1, "tiles": written},
                         separators=(",", ":")).encode()
    with open(os.path.join(target_dir, "mvt_index_payload.json"), "wb") as handle:
        handle.write(payload)
    return written
