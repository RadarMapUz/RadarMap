"""Обученная модель числа полос: признаки из графа и применение весов.

Зачем. Голосование соседей (lane_inference) угадывает полосы только там, где
у той же улицы или района есть размеченные куски, и только по ним. Модель
видит больше: класс, длину, связность, плотность сети, голоса своей улицы и
района вместе, полосы прямого продолжения — и учится, как эти признаки
связаны с тегом lanes, на всей размеченной сети страны.

Обучение — на маке (train_lane_model.py, scikit-learn, градиентный бустинг),
веса — файл lane_model.json в репо. Здесь только признаки и проход по
деревьям: чистый stdlib, на сервере обучение не нужно.

Признаки считаются ОДНОЙ функцией и при обучении, и при применении — иначе
модель учится на одном, а применяется к другому.

Куда идёт ответ — как и у голосования, только в разметку (пунктир полос).
Принимается ответ с вероятностью не ниже порога из файла модели: порог
подобран при обучении под точность ≥ 95 % на спрятанных тегах.
"""
import json
import math
import os
from collections import Counter, defaultdict

from lane_inference import INFER_CLASSES, NEIGHBOUR_METERS, _CELL_METERS, _key, _length_metres

MAX_LANES = 6
FEATURES = ("code", "oneway", "length", "named", "sinuosity", "links",
            "own_lanes", "own_conf", "own_weight", "own_second",
            "near_lanes", "near_conf", "near_weight",
            "next_lanes", "density", "tagged_share", "class_mean", "bridge")
MODEL_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lane_model.json")


def _xy(point):
    kx = 111_320 * math.cos(math.radians(point[1]))
    return point[0] * kx, point[1] * 111_320


def features(roads, lanes_of, is_tagged, is_oneway, is_bridge=lambda flags: False, hidden=()):
    """{id(дороги): [признаки]} и {id: полосы по тегу или 0} для классов INFER_CLASSES.

    hidden — id дорог, чей тег считается неизвестным (проверка на спрятанных):
    их полосы не голосуют и не попадают в ответ как известные.
    """
    hidden = set(hidden)
    items = []
    degree = Counter()
    for road in roads:
        if len(road[2]) >= 2:
            degree[_key(road[2][0])] += 1
            degree[_key(road[2][-1])] += 1
    for road in roads:
        code, flags, points = road[0], road[1], road[2]
        if code not in INFER_CLASSES or len(points) < 2:
            continue
        length = _length_metres(points)
        x0, y0 = _xy(points[0])
        x1, y1 = _xy(points[-1])
        x, y = _xy(points[len(points) // 2])
        tagged = bool(is_tagged(flags)) and id(road) not in hidden
        items.append({
            "id": id(road), "code": code, "name": (road[3] if len(road) > 3 else "") or "",
            "oneway": bool(is_oneway(flags)), "bridge": bool(is_bridge(flags)),
            "lanes": min(lanes_of(flags), MAX_LANES) if tagged else 0,
            "truth": min(lanes_of(flags), MAX_LANES) if is_tagged(flags) else 0,
            "length": length, "x": x, "y": y,
            "sinuosity": length / max(1.0, math.hypot(x1 - x0, y1 - y0)),
            "links": degree[_key(points[0])] + degree[_key(points[-1])] - 2,
            "ends": {_key(points[0]), _key(points[-1])},
        })
    grid_all = defaultdict(list)
    grid_tagged = defaultdict(list)
    for index, item in enumerate(items):
        cell = (int(item["x"] // _CELL_METERS), int(item["y"] // _CELL_METERS))
        grid_all[cell].append(index)
        if item["lanes"]:
            grid_tagged[cell].append(index)
    reach = int(math.ceil(NEIGHBOUR_METERS / _CELL_METERS))
    out, truth = {}, {}
    for index, item in enumerate(items):
        cx, cy = int(item["x"] // _CELL_METERS), int(item["y"] // _CELL_METERS)
        own, near, same_class = Counter(), Counter(), []
        next_lanes = 0
        for dx in range(-reach, reach + 1):
            for dy in range(-reach, reach + 1):
                for j in grid_tagged.get((cx + dx, cy + dy), ()):
                    if j == index:
                        continue
                    other = items[j]
                    distance = math.hypot(other["x"] - item["x"], other["y"] - item["y"])
                    if distance > NEIGHBOUR_METERS:
                        continue
                    if other["code"] == item["code"]:
                        same_class.append(other["lanes"])
                    if other["oneway"] != item["oneway"]:
                        continue
                    weight = other["length"] / (1.0 + distance / 100.0)
                    same = bool(item["name"]) and other["name"] == item["name"]
                    if same:
                        own[other["lanes"]] += weight
                        if item["ends"] & other["ends"]:
                            next_lanes = max(next_lanes, other["lanes"])
                    elif other["code"] == item["code"]:
                        near[other["lanes"]] += weight
        density = tagged_here = 0
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                density += len(grid_all.get((cx + dx, cy + dy), ()))
                tagged_here += len(grid_tagged.get((cx + dx, cy + dy), ()))
        own_top = own.most_common(2)
        near_top = near.most_common(1)
        own_total, near_total = sum(own.values()), sum(near.values())
        out[item["id"]] = [
            item["code"], int(item["oneway"]), round(item["length"], 1), int(bool(item["name"])),
            round(item["sinuosity"], 3), item["links"],
            own_top[0][0] if own_top else 0,
            round(own_top[0][1] / own_total, 3) if own_top else 0.0,
            round(math.log1p(own_total), 3),
            own_top[1][0] if len(own_top) > 1 else 0,
            near_top[0][0] if near_top else 0,
            round(near_top[0][1] / near_total, 3) if near_top else 0.0,
            round(math.log1p(near_total), 3),
            next_lanes, density, round(tagged_here / density, 3) if density else 0.0,
            round(sum(same_class) / len(same_class), 3) if same_class else 0.0,
            int(item["bridge"]),
        ]
        truth[item["id"]] = item["truth"]
    return out, truth


def load_model(path=MODEL_PATH):
    """Модель из файла или None: нет файла или он битый — работает голосование."""
    try:
        with open(path, encoding="utf-8") as handle:
            model = json.load(handle)
    except (OSError, ValueError):
        return None
    if model.get("features") != list(FEATURES):
        return None
    return model


def _tree_value(tree, row):
    """Дерево — плоские списки sklearn: left, right, feature, threshold, value."""
    node = 0
    left, right = tree["left"], tree["right"]
    while left[node] != -1:
        node = left[node] if row[tree["feature"][node]] <= tree["threshold"][node] else right[node]
    return tree["value"][node]


def predict(model, row):
    """(полос, вероятность) по строке признаков."""
    scores = list(model["init"])
    rate = model["learning_rate"]
    for stage in model["stages"]:
        for k, tree in enumerate(stage):
            scores[k] += rate * _tree_value(tree, row)
    top = max(scores)
    exps = [math.exp(s - top) for s in scores]
    total = sum(exps)
    best = max(range(len(scores)), key=lambda k: scores[k])
    return model["classes"][best], exps[best] / total


def infer(model, roads, lanes_of, is_tagged, is_oneway, is_bridge=lambda flags: False):
    """{id(дороги): (полос, вероятность)} для неразмеченных — где модель уверена."""
    rows, truth = features(roads, lanes_of, is_tagged, is_oneway, is_bridge)
    threshold = model["threshold"]
    out = {}
    for key, row in rows.items():
        if truth[key]:
            continue
        lanes, probability = predict(model, row)
        if probability >= threshold:
            out[key] = (lanes, round(probability, 3))
    return out
