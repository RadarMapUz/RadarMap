"""Автоподбор параметров правил карты по нашим метрикам качества.

    python3 tools/autotune/autotune.py ~/RadarMapBuild/tash --rounds 1 --out tune.json

«Сам сравнивает и подгоняет» — но сравнивает с НАШИМИ метриками брака
(server/road_metrics.py: зебры за кромкой, стрелки за стоп-линией, пунктир в
узле, разделительные на узле, островки под асфальтом, раздутые узлы…), а не
с чужой картой: снимки Яндекса и Google нельзя ни скачивать, ни использовать
как данные.

Как: покоординатный спуск. Для каждого параметра по очереди пробуем значения
из сетки: сборка вырезки (build_roads + MVT с подменёнными константами) →
метрики → балл. Балл — взвешенная сумма метрик, каждая поделена на свою
величину у исходной сборки (1.0 = как сейчас; меньше — лучше). Значение,
улучшившее балл, остаётся; в конце — отчёт с лучшими значениями. В код их
переносит человек, после взгляда на эталонные места: метрика не видит всего.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "..", "..", "server")

# Параметр → (модуль, сетка значений). Только правила геометрии, не данные.
SPACE = {
    "CARRIAGEWAY_GAP_QUANTILE": ("build_roads", [5, 10, 20]),
    "MEDIAN_STOP_MARGIN_METERS": ("build_roads", [1.5, 3.0, 5.0]),
    "JUNCTION_CLUSTER_MAX_SPAN": ("build_roads", [60.0, 90.0, 120.0]),
    "FILLET_WIDTH_SHARE": ("build_roads", [0.4, 0.6, 0.8]),
    "BIG_JUNCTION_M2": ("build_mvt", [400.0, 600.0, 900.0]),
    "STRIP_IN_JUNCTION_SHARE": ("build_mvt", [0.3, 0.4, 0.6]),
}
# Вес метрики в балле: что сильнее режет глаз — тяжелее.
WEIGHTS = {
    "dashes_in_junction": 2.0, "medians_on_asphalt": 2.0, "zebra_overhang": 1.5,
    "arrows_after_stop": 1.5, "islands_under_asphalt": 1.0, "junction_spikes": 1.0,
    "junction_bloat": 1.5, "zebra_duplicates": 1.0, "dashes_through_medians": 1.0,
}
# Сколько пунктира/стрелок должно остаться: подбор не вправе «улучшить» карту,
# стерев разметку (меньше пунктира — меньше пунктира в узле).
KEEP = {"markings_km": 0.97, "arrows": 0.95, "medians": 0.95}

RUNNER = r'''
import json, sys
sys.path.insert(0, %(server)r)
import build_roads, build_mvt
for name, (module, value) in json.loads(%(overrides)r).items():
    setattr(build_roads if module == "build_roads" else build_mvt, name, value)
sys.argv = ["build_roads.py"] + json.loads(%(argv)r)
sys.exit(build_roads.main())
'''


def build_and_measure(crop, overrides, work):
    tiles = os.path.join(work, "out")
    subprocess.run(["rm", "-rf", tiles], check=True)
    argv = ["--in", "roads.geojsonl", "--areas", "areas.geojsonl", "--points", "points.geojsonl",
            "--houses", "houses.geojsonl", "--places", "places.geojsonl", "--trees", "trees.geojsonl",
            "--addresses", "addresses.geojsonl", "--edits", "edits.json", "--mvt", "--tiles", tiles]
    code = RUNNER % {"server": os.path.abspath(SERVER), "overrides": json.dumps(overrides),
                     "argv": json.dumps(argv)}
    subprocess.run([sys.executable, "-c", code], cwd=crop, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    out = os.path.join(work, "metrics.json")
    islands = os.path.join(crop, "area_highway.geojsonl")
    cmd = [sys.executable, os.path.join(SERVER, "road_metrics.py"), tiles, "--json", out]
    if os.path.exists(islands):
        cmd += ["--islands", islands]
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with open(out, encoding="utf-8") as handle:
        return json.load(handle)


def score(metrics, base):
    """Балл относительно исходной сборки; None — подбор стёр разметку."""
    for key, share in KEEP.items():
        if metrics["_counts"].get(key, 0) < share * base["_counts"].get(key, 0):
            return None
    total = weight = 0.0
    for key, w in WEIGHTS.items():
        b, m = base.get(key), metrics.get(key)
        if b is None or m is None:
            continue
        total += w * ((m + 0.05) / (b + 0.05))      # 0.05 — чтобы ноль не делил
        weight += w
    return round(total / weight, 4) if weight else None


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("crop", help="каталог вырезки (roads.geojsonl, areas.geojsonl, …)")
    parser.add_argument("--rounds", type=int, default=1)
    parser.add_argument("--only", nargs="*", help="подбирать только эти параметры")
    parser.add_argument("--out", default="tune.json")
    args = parser.parse_args()
    space = {k: v for k, v in SPACE.items() if not args.only or k in args.only}
    work = tempfile.mkdtemp(prefix="autotune-")
    log = []

    started = time.time()
    base = build_and_measure(args.crop, {}, work)
    best_params, best_score = {}, 1.0
    log.append({"params": {}, "score": 1.0, "metrics": base})
    print(f"исходная сборка: балл 1.000 ({time.time() - started:.0f} с)")
    for _round in range(args.rounds):
        for name, (module, grid) in space.items():
            for value in grid:
                trial = dict(best_params)
                trial[name] = (module, value)
                started = time.time()
                metrics = build_and_measure(args.crop, trial, work)
                s = score(metrics, base)
                log.append({"params": {k: v[1] for k, v in trial.items()}, "score": s, "metrics": metrics})
                mark = ""
                if s is not None and s < best_score - 0.005:
                    best_params, best_score, mark = trial, s, "  ← лучше"
                print(f"{name} = {value}: балл {s} ({time.time() - started:.0f} с){mark}")
    report = {"best": {k: v[1] for k, v in best_params.items()}, "score": best_score,
              "base": base, "trials": log}
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(report, handle, ensure_ascii=False, indent=1)
    print(f"лучшее: {report['best']} — балл {best_score} (1.0 = как сейчас); отчёт {args.out}")


if __name__ == "__main__":
    main()
