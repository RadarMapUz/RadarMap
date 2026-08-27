"""Кандидаты от нейросети: обводки зданий по спутнику.

Зачем. Обводить руками то, что уже обвели, — самая дорогая ошибка в этой
работе. Microsoft выложил контуры зданий, распознанные по снимкам, специально
для картографов: редактор показывает такую линию КАНДИДАТОМ, человек жмёт — и
она становится настоящей. Лицензия совместима с OSM, потому что для OSM набор
и сделан.

Три правила, от которых здесь ничего не отступает.

**Кандидат — не данные.** Он не едет в тайлы, не попадает в подписанный индекс
и не виден на телефоне. Он лежит своими файлами рядом и виден только панели.
Принятый кандидат становится обычной правкой и проходит ту же проверку, что
нарисованное мышью, — иначе мы публикуем на телефоны догадку машины.

**Показываем только то, чего нет.** В центре Ташкента OSM знает 54 094 дома, а
нейросеть находит 82 418 контуров: если показать все, модератор будет разбирать
кучу, на девять десятых состоящую из уже нарисованного. Кандидат, накрывающий
существующий дом, отбрасывается на сборке.

**Ни высоты, ни адреса у кандидата нет.** Замерено по самому набору: поля
height и confidence приходят равными -1. Дом без адреса отвечает лишь на
«сюда ли сворачивать» — адрес всё равно ставит человек.
"""
import gzip
import json
import os

from build_roads import (MIN_HOUSE_METERS, HOUSE_SIMPLIFY_METERS, SCALE,
                         TILE_DEGREES_V2, extent_meters, simplify, tile_key)

# Клетка сверки с OSM. Двадцать метров — типовой дом по фасаду: контур, чей
# центр лёг в занятую клетку, почти наверняка тот же дом, обведённый иначе.
SEEN_CELL_METERS = 20.0
SEEN_CELL_DEGREES = SEEN_CELL_METERS / 111_320.0


def _centre(points):
    return (sum(p[0] for p in points) / len(points),
            sum(p[1] for p in points) / len(points))


def _cell(point):
    return (int(point[0] / SEEN_CELL_DEGREES), int(point[1] / SEEN_CELL_DEGREES))


def _near_taken(taken, point):
    """Занята ли клетка ИЛИ соседняя.

    Только своя клетка — недостаточно, и это замерено: дом OSM и контур
    нейросети описывают одно здание с разницей в несколько метров, и граница
    клетки проходит между ними примерно в двух случаях из трёх. Со сверкой по
    одной клетке отсеивалось 35 % кандидатов там, где OSM знает почти все
    дома, — то есть модератор разбирал бы кучу уже нарисованного.
    """
    x, y = _cell(point)
    for dx in (-1, 0, 1):
        for dy in (-1, 0, 1):
            if (x + dx, y + dy) in taken:
                return True
    return False


def occupied_cells(houses_path):
    """Клетки, где дом уже есть. Вход — экстракт зданий OSM (geojsonl)."""
    taken = set()
    if not houses_path or not os.path.exists(houses_path):
        return taken
    with open(houses_path, encoding="utf-8") as source:
        for line in source:
            line = line.lstrip("\x1e").strip()
            if not line:
                continue
            try:
                feature = json.loads(line)
            except ValueError:
                continue
            rings = (feature.get("geometry") or {}).get("coordinates") or []
            points = rings[0] if rings else []
            if len(points) < 4:
                continue
            taken.add(_cell(_centre(points)))
    return taken


def _rows(source_path):
    opener = gzip.open if source_path.endswith(".gz") else open
    with opener(source_path, "rt", encoding="utf-8") as source:
        for line in source:
            line = line.strip()
            if not line:
                continue
            # В наборе Microsoft строка — это GeoJSON, иногда завёрнутый в CSV
            # с одной колонкой. Разбираем оба вида, а не гадаем по имени файла.
            if not line.startswith("{"):
                comma = line.find(",{")
                if comma < 0:
                    continue
                line = line[comma + 1:]
            try:
                yield json.loads(line)
            except ValueError:
                continue


def encode_ring(points):
    """Дельты, как в тайле: первая точка целиком, дальше приращения."""
    out, lat, lon = [], 0, 0
    for index, (x, y) in enumerate(points):
        ry, rx = round(y * SCALE), round(x * SCALE)
        if index == 0:
            out.extend([ry, rx])
        else:
            out.extend([ry - lat, rx - lon])
        lat, lon = ry, rx
    return out


def build_candidates(source_path, target_dir, houses_path=None,
                     degrees=TILE_DEGREES_V2, floor=MIN_HOUSE_METERS,
                     tolerance_deg=None, bbox=None):
    """Разложить кандидатов по клеткам. Возвращает {ключ: сколько}.

    Файлы называются cand_<ключ>.json и в индекс НЕ попадают: индекс подписан
    и описывает то, что едет на телефоны, а кандидат — предложение машины,
    которое ещё никто не смотрел.
    """
    if tolerance_deg is None:
        tolerance_deg = HOUSE_SIMPLIFY_METERS / 111_320.0
    if not source_path or not os.path.exists(source_path):
        return {}
    taken = occupied_cells(houses_path)
    by_key = {}
    for feature in _rows(source_path):
        geometry = feature.get("geometry") or {}
        if geometry.get("type") != "Polygon":
            continue
        rings = geometry.get("coordinates") or []
        points = rings[0] if rings else []
        if len(points) < 4:
            continue
        centre = _centre(points)
        if bbox and not (bbox[0] <= centre[1] <= bbox[2]
                         and bbox[1] <= centre[0] <= bbox[3]):
            continue
        if _near_taken(taken, centre):
            continue
        points = simplify(points, tolerance_deg)
        if len(points) < 4 or extent_meters(points) < floor:
            continue
        by_key.setdefault(tile_key(centre[1], centre[0], degrees),
                          []).append(encode_ring(points))

    os.makedirs(target_dir, exist_ok=True)
    written = {}
    for key, rings in sorted(by_key.items()):
        # Порядок устойчивый: панель кэширует файлы по времени правки, и
        # перетасованный список выглядел бы новыми кандидатами.
        rings.sort(key=lambda ring: (ring[0], ring[1], len(ring)))
        path = os.path.join(target_dir, f"cand_{key}.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump({"version": 1, "houses": rings}, handle,
                      separators=(",", ":"))
        written[key] = len(rings)
    return written


def main():
    import argparse

    parser = argparse.ArgumentParser(
        description="Кандидаты от нейросети: обводки зданий по спутнику")
    parser.add_argument("--in", dest="source", required=True,
                        help="csv.gz или geojsonl из набора Microsoft")
    parser.add_argument("--tiles", dest="tiles_dir", required=True,
                        help="каталог тайлов: рядом лягут cand_*.json")
    parser.add_argument("--houses", dest="houses", default=None,
                        help="экстракт зданий OSM — чтобы не предлагать то, "
                             "что уже обведено")
    parser.add_argument("--bbox", dest="bbox", default=None,
                        help="юг,запад,север,восток — только эта рамка")
    args = parser.parse_args()

    box = None
    if args.bbox:
        parts = [float(x) for x in args.bbox.split(",")]
        if len(parts) != 4:
            raise SystemExit("рамка задаётся четырьмя числами: юг,запад,север,восток")
        box = tuple(parts)

    made = build_candidates(args.source, args.tiles_dir,
                            houses_path=args.houses, bbox=box)
    total = sum(made.values())
    print(f"кандидатов: {total} в {len(made)} клетках")
    if args.houses:
        print("сверено с OSM: то, что уже обведено, не предлагается")
    else:
        print("ВНИМАНИЕ: без --houses предлагается всё подряд, включая "
              "уже обведённое")
    weight = sum(os.path.getsize(os.path.join(args.tiles_dir, f"cand_{key}.json"))
                 for key in made)
    print(f"вес: {weight / 1e6:.1f} МБ (в индекс НЕ входит, на телефон не едет)")


if __name__ == "__main__":
    main()
