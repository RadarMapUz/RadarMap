"""Панели для проверки глазами: N случайных принятых кадров.

    python3 review.py [N] [seed] [каталог] [id,id,...]

Принятый кадр — на ходу и своя полоса не закрыта (occluded ≤ OCC_MAX);
берём все принятые, а не только те, где полосы нашлись, — иначе оценка
точности завышена. Выборку настройки и выборку оценки делаем разными
seed, чтобы не подгонять пороги под проверочные кадры.
"""
import json
import os
import random
import sys

from framesdb import MORNING, OUT
from lanes import OCC_MAX, analyze, load_camera
from marking import load_rgb
from panel import render


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 30
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 2026
    out_dir = sys.argv[3] if len(sys.argv) > 3 else os.path.join(OUT, "review")
    os.makedirs(out_dir, exist_ok=True)
    rows = [json.loads(l) for l in open(os.path.join(OUT, f"frames_{MORNING}.jsonl"))]
    acc = [r for r in rows if "error" not in r and r["occluded"] <= OCC_MAX]
    if len(sys.argv) > 4:          # те же кадры, что смотрели раньше
        ids = {int(x) for x in sys.argv[4].split(",")}
        pick = sorted((r for r in rows if r["id"] in ids), key=lambda r: r["t"])
    else:
        random.seed(seed)
        pick = sorted(random.sample(acc, min(n, len(acc))), key=lambda r: r["t"])
    cam = load_camera()
    index = []
    for i, r in enumerate(pick, 1):
        rgb = load_rgb(r["path"])
        res = analyze(rgb, cam)
        # Рисуем итог после фильтра соседних кадров (run.py), а не сырой кадр.
        res["lines"] = [tuple(l) for l in r["lines"]]
        res["layout"] = r["layout"]
        res["side"] = r["side"]
        res["extent"] = (r["side"]["left_edge"], r["side"]["right_edge"])
        lay = res["layout"]
        name = f"{i:02d}_id{r['id']}.png"
        title = (f"#{i} кадр {r['id']} {os.path.basename(r['path'])}  "
                 f"{r['kmh']:.0f} км/ч  курс {r['course']:.0f}°")
        render(rgb, cam, res, title).save(os.path.join(out_dir, name))
        index.append({"n": i, "id": r["id"], "file": name,
                      "lanes": lay["lanes"] if lay else None,
                      "left": lay["left"] if lay else None,
                      "right": lay["right"] if lay else None})
    with open(os.path.join(out_dir, "index.json"), "w") as f:
        json.dump(index, f, ensure_ascii=False, indent=1)
    print(f"принятых кадров {len(acc)}, панелей {len(pick)} → {out_dir}")


if __name__ == "__main__":
    main()
