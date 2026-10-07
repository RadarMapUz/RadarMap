"""Панели v2 для проверки глазами.

    python3 review2.py <каталог> n1,n2,…        — кадры истины по номерам
    python3 review2.py <каталог> --random N [seed] [trip,trip…]
                                               — N случайных окон на ходу

Случайные окна берутся из поездок проверочной половины по кадрам БД на
ходу (не из истины): ролик копируется с карты (clips.py), окно
вынимается, после панели ролик удаляется.
"""
import json
import os
import random
import sqlite3
import sys

from clips import WIN, extract_window
from framesdb import DB
from lanes import load_camera
import reflect
from truth import load
from window import analyze_window
from panel2 import render


def panels(rows, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    cam = load_camera()
    index = []
    for r in rows:
        res = analyze_window(r["id"], r["trip"], r["t"], cam, reflect.load(r["trip"]),
                             keep_debug=True)
        name = f"{r['n']:03d}_id{r['id']}.png"
        render(res, r, cam).save(os.path.join(out_dir, name))
        index.append({"n": r["n"], "id": r["id"], "file": name, "lanes": res["lanes"],
                      "own": res["own"], "share": res["share"],
                      "left_edge": res["left_edge"], "right_edge": res["right_edge"]})
        print(name, res["lanes"], res["own"], flush=True)
    with open(os.path.join(out_dir, "index.json"), "w") as f:
        json.dump(index, f, ensure_ascii=False, indent=1)


def random_rows(n, seed, trips):
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    q = ("select f.id, f.trip_key, f.clip_id, f.pos, f.t, f.kmh, c.path, c.duration"
         " from frames f join clips c on c.id = f.clip_id where f.trip_key = ?"
         " and f.kmh > 25 and f.pos >= 3 and f.pos <= c.duration - 3")
    pool = []
    for t in trips:
        pool += con.execute(q, (t,)).fetchall()
    taken = {r["id"] for r in load()}
    pool = [p for p in pool if p[0] not in taken]
    rnd = random.Random(seed)
    pick = rnd.sample(pool, n)
    return [{"n": 900 + i, "id": p[0], "trip": p[1], "clip": p[6], "pos": p[3], "t": p[4],
             "kmh": p[5], "lanes": None, "own": None, "left": None, "right": None,
             "judge": False, "conf": False, "note": "случайный"} for i, p in enumerate(pick)]


def ensure_windows(rows):
    """Окна для случайных кадров: ролик с карты → окно → ролик удалить."""
    import fat32
    from clips import DEVICE, TMP
    todo = [r for r in rows if not os.path.exists(os.path.join(WIN, str(r["id"]), "pts.json"))]
    if not todo:
        return
    os.makedirs(TMP, exist_ok=True)
    fs = fat32.FAT32(DEVICE)
    try:
        index = {p: (cl, size) for p, isdir, cl, size, _ in fs.walk() if not isdir}
        for r in todo:            # по одному ролику за раз
            src = r["clip"]
            tmp = None
            if src.startswith("card:"):
                name = src[len("card:"):]
                tmp = os.path.join(TMP, os.path.basename(name))
                cl, size = index[name]
                fs.copy(cl, size, tmp)
                src = tmp
            try:
                extract_window(src, r["pos"], os.path.join(WIN, str(r["id"])))
            finally:
                if tmp and os.path.exists(tmp):
                    os.remove(tmp)
    finally:
        fs.close()


def main():
    out_dir = sys.argv[1]
    if sys.argv[2] == "--random":
        n = int(sys.argv[3])
        seed = int(sys.argv[4]) if len(sys.argv) > 4 else 7
        trips = sys.argv[5].split(",") if len(sys.argv) > 5 else \
            sorted({r["trip"] for r in load() if r["half"] == "test"})
        rows = random_rows(n, seed, trips)
        ensure_windows(rows)
    else:
        want = {int(x) for x in sys.argv[2].split(",")}
        rows = [r for r in load() if r["n"] in want]
    panels(rows, out_dir)


if __name__ == "__main__":
    main()
