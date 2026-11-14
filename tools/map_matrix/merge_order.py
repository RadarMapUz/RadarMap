#!/usr/bin/env python3
"""Проверка слитых слоёв основы (make_style.MERGED_LAYERS) на сборке тайлов OMT.

Слитый слой рисует объекты в порядке тайла, прежние слои — по очереди. Картинка
та же, если каждая пара перекрывающихся объектов РАЗНЫХ прежних слоёв с разным
цветом лежит в тайле в порядке этих слоёв. Перекрытие — по ширинам из стиля
(+2 px сглаживания) на любом зуме, где виден слой; цвет — во всех палитрах
(обычная, поездка, машина, «Вождение 3D»). Перепроверять после сборки основы.

    python3 tools/map_matrix/merge_order.py --repo . [--omt ~/RadarMapBuild/omt/publish/omt]
"""
import argparse
import itertools
import json
import math
import os
import struct
import sys
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import matrix  # noqa: E402


def varint(b, i):
    out = shift = 0
    while True:
        c = b[i]
        i += 1
        out |= (c & 0x7f) << shift
        if c < 0x80:
            return out, i
        shift += 7


def fields(b, i, end):
    while i < end:
        key, i = varint(b, i)
        kind = key & 7
        if kind == 0:
            v, i = varint(b, i)
            yield key >> 3, v
        elif kind == 2:
            n, i = varint(b, i)
            yield key >> 3, (i, i + n)
            i += n
        elif kind in (1, 5):
            size = 8 if kind == 1 else 4
            yield key >> 3, b[i:i + size]
            i += size
        else:
            raise ValueError(f"тип поля {kind}")


def zigzag(n):
    return (n >> 1) ^ -(n & 1)


def packed(b, span):
    out, i = [], span[0]
    while i < span[1]:
        v, i = varint(b, i)
        out.append(v)
    return out


def tag_value(b, span):
    for field, v in fields(b, *span):
        if field == 1:
            return b[v[0]:v[1]].decode()
        if field in (2, 3):
            return struct.unpack("<f" if field == 2 else "<d", v)[0]
        if field in (4, 5):
            return v
        if field == 6:
            return zigzag(v)
        if field == 7:
            return bool(v)
    return None


def lines(cmds):
    out, x, y, i = [], 0, 0, 0
    while i < len(cmds):
        cmd, count = cmds[i] & 7, cmds[i] >> 3
        i += 1
        for _ in range(count if cmd in (1, 2) else 0):
            x, y = x + zigzag(cmds[i]), y + zigzag(cmds[i + 1])
            i += 2
            if cmd == 1:
                out.append([(x, y)])
            else:
                out[-1].append((x, y))
    return out


def features(b, name):
    """[(свойства, линии)] слоя name тайла в порядке тайла."""
    for field, span in fields(b, 0, len(b)):
        if field != 3:
            continue
        layer_name, keys, values, raw = None, [], [], []
        for f2, v2 in fields(b, *span):
            if f2 == 1:
                layer_name = b[v2[0]:v2[1]].decode()
            elif f2 == 3:
                keys.append(b[v2[0]:v2[1]].decode())
            elif f2 == 4:
                values.append(v2)
            elif f2 == 2:
                raw.append(v2)
        if layer_name != name:
            continue
        values = [tag_value(b, v) for v in values]
        out = []
        for feature in raw:
            props, geom = {}, []
            for f3, v3 in fields(b, *feature):
                if f3 == 2:
                    tags = packed(b, v3)
                    props.update((keys[tags[k]], values[tags[k + 1]]) for k in range(0, len(tags), 2))
                elif f3 == 3:
                    props["$type"] = {1: "Point", 2: "LineString", 3: "Polygon"}.get(v3)
                elif f3 == 4:
                    geom = packed(b, v3)
            out.append((props, lines(geom)))
        return out
    return []


def legacy(flt, props):
    op = flt[0]
    if op in ("all", "any"):
        return (all if op == "all" else any)(legacy(f, props) for f in flt[1:])
    if op in ("has", "!has"):
        return (flt[1] in props) == (op == "has")
    if op in ("==", "!="):
        return (flt[1] in props and props[flt[1]] == flt[2]) == (op == "==")
    if op in ("in", "!in"):
        return (flt[1] in props and props[flt[1]] in flt[2:]) == (op == "in")
    raise ValueError(flt)


def colour(value):
    if isinstance(value, str) and value.startswith("#"):
        h = value[1:] if len(value) == 7 else "".join(c * 2 for c in value[1:])
        return tuple(int(h[k:k + 2], 16) for k in (0, 2, 4))
    return value


def mix(a, b, t):
    return tuple(x + (y - x) * t for x, y in zip(a, b)) if isinstance(a, tuple) else a + (b - a) * t


def factor(interp, lo, hi, z):
    base = interp[1] if interp[0] == "exponential" else 1
    return (z - lo) / (hi - lo) if base == 1 else (base ** (z - lo) - 1) / (base ** (hi - lo) - 1)


def ev(e, z, props):
    """Значение выражения стиля (подмножество make_style) на зуме z."""
    if isinstance(e, dict):
        e = ["interpolate", ["exponential", e.get("base", 1)], ["zoom"], *[x for s in e["stops"] for x in s]]
    if not isinstance(e, list):
        return colour(e)
    op = e[0]
    if op == "get":
        return props.get(e[1])
    if op == "geometry-type":
        return props["$type"]
    if op in ("==", "!="):
        return (ev(e[1], z, props) == ev(e[2], z, props)) == (op == "==")
    if op in ("all", "any"):
        return (all if op == "all" else any)(ev(x, z, props) for x in e[1:])
    if op == "!":
        return not ev(e[1], z, props)
    if op == "has":
        return e[1] in props
    if op == "coalesce":
        return next((v for v in (ev(x, z, props) for x in e[1:]) if v is not None), None)
    if op == "case":
        for k in range(1, len(e) - 1, 2):
            if ev(e[k], z, props):
                return ev(e[k + 1], z, props)
        return ev(e[-1], z, props)
    if op == "match":
        value = ev(e[1], z, props)
        for k in range(2, len(e) - 1, 2):
            if value is not None and value in (e[k] if isinstance(e[k], list) else [e[k]]):
                return ev(e[k + 1], z, props)
        return ev(e[-1], z, props)
    if op in ("*", "+", "max", "min"):
        args = [ev(x, z, props) for x in e[1:]]
        return {"*": math.prod, "+": sum, "max": max, "min": min}[op](args)
    if op == "interpolate":
        zooms, outs = e[3::2], e[4::2]
        if z <= zooms[0] or z >= zooms[-1]:
            return ev(outs[0] if z <= zooms[0] else outs[-1], z, props)
        k = max(i for i, s in enumerate(zooms) if s <= z)
        return mix(ev(outs[k], z, props), ev(outs[k + 1], z, props), factor(e[1], zooms[k], zooms[k + 1], z))
    if op == "step":
        out = e[2]
        for k in range(3, len(e), 2):
            if z >= e[k]:
                out = e[k + 1]
        return ev(out, z, props)
    raise ValueError(f"оператор {op!r}")


def on_gpu(e, z, props):
    """«Зум + данные» MapLibre считает смесью значений на целых зумах Z и Z+1."""
    if isinstance(e, list) and e[:1] == ["interpolate"] and '"get"' in json.dumps(e):
        lo = math.floor(z)
        return mix(ev(e, lo, props), ev(e, lo + 1, props), max(0.0, min(1.0, factor(e[1], lo, lo + 1, z))))
    return ev(e, z, props)


def seg_distance(p, q, r, s):
    def to_segment(a, b, c):
        dx, dy = c[0] - b[0], c[1] - b[1]
        length = dx * dx + dy * dy
        t = 0 if length == 0 else max(0, min(1, ((a[0] - b[0]) * dx + (a[1] - b[1]) * dy) / length))
        return math.hypot(a[0] - b[0] - t * dx, a[1] - b[1] - t * dy)

    def side(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
    d1, d2, d3, d4 = side(r, s, p), side(r, s, q), side(p, q, r), side(p, q, s)
    if d1 * d2 < 0 and d3 * d4 < 0:
        return 0
    return min(to_segment(p, r, s), to_segment(q, r, s), to_segment(r, p, q), to_segment(s, p, q))


def near(a_lines, b_lines, limit):
    for a in a_lines:
        for b in b_lines:
            ax, ay, bx, by = [p[0] for p in a], [p[1] for p in a], [p[0] for p in b], [p[1] for p in b]
            if min(ax) - limit > max(bx) or min(bx) - limit > max(ax) or \
                    min(ay) - limit > max(by) or min(by) - limit > max(ay):
                continue
            if len(a) == 1 or len(b) == 1:
                return True
            if any(seg_distance(a[i], a[i + 1], b[j], b[j + 1]) <= limit
                   for i in range(len(a) - 1) for j in range(len(b) - 1)):
                return True
    return False


def needles(flt):
    """Строки, хотя бы одна из каждого набора которых обязана быть в тайле, чтобы фильтр что-то нашёл."""
    parts = flt[1:] if flt[0] == "all" else [flt]
    return [{v.encode() for v in part[2:] if isinstance(v, str)} for part in parts
            if part[0] in ("==", "in") and part[1] != "$type" and all(isinstance(v, str) for v in part[2:])]


def possible(member, data):
    return all(any(n in data for n in group) for group in needles(member["filter"]))


def palettes(make_style):
    """Слои без слияния во всех палитрах: [{id: слой}]."""
    out = []
    with mock.patch.dict(make_style.MERGED_LAYERS, clear=True):
        app = make_style.app_styles()
        for theme in ("light", "dark"):
            base = make_style.build("local://", theme, "full")
            diffs = [None] + [json.loads(text) for name, text in app.items()
                              if not name.startswith("map_style") and theme in name]
            for diff in diffs:
                style = json.loads(json.dumps(base))
                if diff:
                    matrix.apply_diff(style, diff)
                out.append({layer["id"]: layer for layer in style["layers"]})
    return out


def check(make_style, omt):
    styles = palettes(make_style)
    groups = {merged: [styles[0][m] for m in members] for merged, members in make_style.MERGED_LAYERS.items()}
    grid = [k / 20 for k in range(24 * 20)]
    report = {merged: {"пар": 0, "не в том порядке": []} for merged in groups}
    for zoom in sorted(os.listdir(omt), key=int):
        tile_zoom = int(zoom)
        shown = [z for z in grid if tile_zoom <= z < tile_zoom + 1 or (tile_zoom == 14 and z >= 14)]
        for x in os.listdir(os.path.join(omt, zoom)):
            for name in os.listdir(os.path.join(omt, zoom, x)):
                path = os.path.join(omt, zoom, x, name)
                with open(path, "rb") as handle:
                    data = handle.read()
                cache = {}
                for merged, members in groups.items():
                    layer_name = members[0]["source-layer"]
                    if layer_name.encode() not in data or sum(possible(m, data) for m in members) < 2:
                        continue
                    if layer_name not in cache:
                        cache[layer_name] = features(data, layer_name)
                    zooms = [z for z in shown if members[0].get("minzoom", 0) <= z < members[0].get("maxzoom", 24)]
                    found = []
                    for props, geometry in cache[layer_name]:
                        hits = [k for k, m in enumerate(members) if legacy(m["filter"], props)]
                        if len(hits) > 1:
                            raise SystemExit(f"{merged}: фильтры {hits} пересекаются ({path})")
                        if hits:
                            found.append((hits[0], props, geometry))
                    for (ka, pa, ga), (kb, pb, gb) in itertools.combinations(found, 2):
                        if ka == kb:
                            continue
                        ma, mb = members[ka], members[kb]
                        if all(on_gpu(s[ma["id"]]["paint"].get("line-color"), z, pa)
                               == on_gpu(s[mb["id"]]["paint"].get("line-color"), z, pb)
                               for s in styles for z in zooms):
                            continue
                        limit = max(((on_gpu(ma["paint"]["line-width"], z, pa) + on_gpu(mb["paint"]["line-width"], z, pb))
                                     / 2 + 2) * 8 / 2 ** (z - tile_zoom) for z in zooms)
                        if not near(ga, gb, limit):
                            continue
                        report[merged]["пар"] += 1
                        if ka > kb:
                            report[merged]["не в том порядке"].append([path, ma["id"], mb["id"]])
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=".")
    parser.add_argument("--omt", default=os.path.join(matrix.BUILD, "omt", "publish", "omt"))
    args = parser.parse_args()
    report = check(matrix.load_make_style(os.path.abspath(args.repo)), args.omt)
    print(json.dumps(report, ensure_ascii=False, indent=1))
    bad = sum(len(r["не в том порядке"]) for r in report.values())
    print("порядок сохранён" if not bad else f"пар не в том порядке: {bad} — слияние меняет картинку")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
