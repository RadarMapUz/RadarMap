"""Обучение модели числа полос (lane_model.py) — на маке, не на сервере.

    python3 -m venv ~/mlenv && ~/mlenv/bin/pip install scikit-learn
    ~/mlenv/bin/python server/train_lane_model.py roads.geojsonl

Данные — размеченные куски (тег lanes) классов trunk…tertiary всей страны.
Спрятанные теги: в каждом из двух проходов половина размеченных считается
неизвестной, признаки считаются так, как их увидит сборка у неразмеченного
куска, а ответ — спрятанный тег. Проверка — по РЕГИОНАМ (клетки 0,1°, чётные
против нечётных), чтобы модель не подглядывала в соседние куски той же улицы.
Порог вероятности подбирается на проверке под точность ≥ TARGET_PRECISION и
пишется в файл модели; там же — сравнение с голосованием на тех же кусках.
"""
import json
import random
import sys

import numpy as np
from sklearn.ensemble import GradientBoostingClassifier

import build_roads
import lane_inference
import lane_model

TARGET_PRECISION = 0.95
REGION_DEGREES = 0.1


def load_roads(path):
    raw = build_roads.collect(path)[0]
    return build_roads.generalise(raw, build_roads.SIMPLIFY_METERS / 111_320.0)


def region(road):
    lon, lat = road[2][len(road[2]) // 2]
    return (int(lon / REGION_DEGREES) + int(lat / REGION_DEGREES)) % 2


def dataset(roads, seed):
    tagged = [r for r in roads if r[0] in lane_inference.INFER_CLASSES and r[1] & build_roads.FLAG_LANES_TAGGED]
    rng = random.Random(seed)
    hidden = {id(r) for r in tagged if rng.random() < 0.5}
    rows, truth = lane_model.features(
        roads, build_roads.lanes_of,
        lambda flags: flags & build_roads.FLAG_LANES_TAGGED,
        lambda flags: flags & build_roads.FLAG_ONEWAY,
        lambda flags: flags & build_roads.FLAG_BRIDGE, hidden)
    by_id = {id(r): r for r in tagged}
    X, y, parts, ids = [], [], [], []
    for key in hidden:
        X.append(rows[key])
        y.append(truth[key])
        parts.append(region(by_id[key]))
        ids.append(key)
    # Голосование на тех же спрятанных — с чем сравниваем.
    cleared = []
    for r in roads:
        if id(r) in hidden:
            cleared.append((r[0], r[1] & ~build_roads.FLAG_LANES_TAGGED) + tuple(r[2:]))
        else:
            cleared.append(r)
    back = {id(c): id(r) for c, r in zip(cleared, roads)}
    voted = lane_inference.infer_lanes(
        cleared, build_roads.lanes_of,
        lambda flags: flags & build_roads.FLAG_LANES_TAGGED,
        lambda flags: flags & build_roads.FLAG_ONEWAY)
    votes = {back[key]: lanes for key, (lanes, _c) in voted.items() if key in back}
    return X, y, parts, ids, votes


def export(model, threshold, report):
    stages = []
    for stage in model.estimators_:
        trees = []
        for estimator in stage:
            t = estimator.tree_
            trees.append({"left": t.children_left.tolist(), "right": t.children_right.tolist(),
                          "feature": t.feature.tolist(),
                          "threshold": [round(v, 6) for v in t.threshold.tolist()],
                          "value": [round(v[0][0], 6) for v in t.value.tolist()]})
        stages.append(trees)
    init = model._raw_predict_init(np.zeros((1, len(lane_model.FEATURES))))[0].tolist()
    return {"features": list(lane_model.FEATURES), "classes": [int(c) for c in model.classes_],
            "init": [round(v, 6) for v in init], "learning_rate": model.learning_rate,
            "threshold": threshold, "stages": stages, "report": report}


def main():
    roads = load_roads(sys.argv[1])
    print(f"дорог: {len(roads)}")
    X, y, parts, ids, votes = [], [], [], [], {}
    for seed in (1, 2):
        a, b, c, d, v = dataset(roads, seed)
        # Второй проход прячет другую половину: у куска свои признаки в каждом.
        X += a; y += b; parts += c; ids += [(seed, k) for k in d]
        votes.update({(seed, k): lanes for k, lanes in v.items()})
    X, y, parts = np.array(X, dtype=float), np.array(y), np.array(parts)
    print(f"примеров: {len(y)}, классы: {dict(zip(*np.unique(y, return_counts=True)))}")
    train, test = parts == 0, parts == 1
    model = GradientBoostingClassifier(n_estimators=150, max_depth=4, learning_rate=0.1,
                                       subsample=0.8, random_state=7)
    model.fit(X[train], y[train])
    proba = model.predict_proba(X[test])
    best = proba.max(axis=1)
    guess = model.classes_[proba.argmax(axis=1)]
    truth = y[test]
    test_ids = [ids[i] for i in np.flatnonzero(test)]
    voted = [(i, votes[k]) for i, k in enumerate(test_ids) if k in votes]
    if voted:
        print("голосование: точность %.3f покрытие %.3f" % (
            sum(1 for i, lanes in voted if lanes == truth[i]) / len(voted), len(voted) / len(truth)))
    vote_of = dict(voted)
    agree = [i for i in vote_of if vote_of[i] == guess[i]]
    if agree:
        print("согласие с голосованием: точность %.3f покрытие %.3f" % (
            sum(1 for i in agree if guess[i] == truth[i]) / len(agree), len(agree) / len(truth)))
    alone = [i for i in range(len(truth)) if i not in vote_of and best[i] >= 0.9]
    if alone:
        print("модель там, где голосование молчит (≥0.9): точность %.3f покрытие %.3f" % (
            sum(1 for i in alone if guess[i] == truth[i]) / len(alone), len(alone) / len(truth)))
    for t in (0.5, 0.6, 0.7, 0.8, 0.9, 0.95):
        m = best >= t
        if m.sum():
            print("порог %.2f: точность %.3f покрытие %.3f" % (t, (guess[m] == truth[m]).mean(), m.mean()))
    threshold = None
    for t in np.arange(0.5, 0.99, 0.01):
        mask = best >= t
        if mask.sum() and (guess[mask] == truth[mask]).mean() >= TARGET_PRECISION:
            threshold = round(float(t), 2)
            break
    if threshold is None:
        sys.exit("модель не дотягивает до целевой точности ни при каком пороге")
    mask = best >= threshold
    vote_hits = sum(1 for i, lanes in voted if lanes == truth[i])
    report = {
        "examples": int(len(y)), "test": int(test.sum()),
        "model_precision": round(float((guess[mask] == truth[mask]).mean()), 4),
        "model_coverage": round(float(mask.mean()), 4),
        "vote_precision": round(vote_hits / len(voted), 4) if voted else None,
        "vote_coverage": round(len(voted) / int(test.sum()), 4),
        "importance": dict(sorted(zip(lane_model.FEATURES, [round(float(v), 3) for v in model.feature_importances_]),
                                  key=lambda kv: -kv[1])),
    }
    print(json.dumps(report, ensure_ascii=False, indent=1))
    # Финальная модель — на всех примерах, порог — с проверки.
    model.fit(X, y)
    with open(lane_model.MODEL_PATH, "w", encoding="utf-8") as handle:
        json.dump(export(model, threshold, report), handle, separators=(",", ":"))
    print(f"записано: {lane_model.MODEL_PATH}, порог {threshold}")


if __name__ == "__main__":
    main()
