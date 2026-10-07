"""Выбор кадров для истины: 100 кадров на ходу из разных дневных поездок.

    python3 truth_pick.py            → ~/RadarMapBuild/dashcam/lanes/truth_pick.json

Кадры берём из уже вынутых (frames/<поездка>/), не ближе MIN_SEP_S друг к
другу в поездке и не ближе EDGE_S к краю ролика — вокруг кадра потом
вынимается отрезок полного fps для отслеживания. Половины «настройка» и
«проверка» делятся ПО ПОЕЗДКАМ, а не по кадрам: соседние кадры одной
поездки похожи, и деление по кадрам подсказало бы ответ проверке.
"""
import json
import os
import random
import sqlite3

from framesdb import DB, OUT

# Дневные поездки с кадрами (09-29 — стоянка, на ходу нет кадров).
TUNE_TRIPS = ["2026-10-07-08-05-10", "2026-09-26-12-48-06", "2026-10-02-15-35-29",
              "2026-10-03-12-24-53", "2026-10-04-15-53-17", "2026-10-06-10-07-22",
              "2026-10-03-14-04-57"]
TEST_TRIPS = ["2026-09-23-08-11-45", "2026-09-28-08-11-44", "2026-10-02-12-52-30",
              "2026-10-03-09-53-42", "2026-10-05-15-56-12", "2026-10-06-08-55-27",
              "2026-10-03-14-30-59"]
PER_HALF = 50
MIN_KMH = 15.0
MIN_SEP_S = 45.0
EDGE_S = 3.0


def candidates(con, trip):
    return con.execute(
        "select f.id, f.trip_key, f.clip_id, f.pos, f.t, f.kmh, f.lat, f.lon, f.course,"
        " f.path, c.path, c.duration from frames f join clips c on c.id = f.clip_id"
        " where f.trip_key = ? and f.kmh > ?"
        " and f.pos >= ? and f.pos <= c.duration - ? order by f.t",
        (trip, MIN_KMH, EDGE_S, EDGE_S)).fetchall()


def pick_half(con, trips, n, seed):
    """По кругу по поездкам, по одному кадру за круг: короткая поездка
    (или почти вся в пробке) отдаёт сколько может, остальное добирают
    другие."""
    rnd = random.Random(seed)
    pools = {}
    for trip in trips:
        rows = candidates(con, trip)
        rnd.shuffle(rows)
        pools[trip] = rows
    got = {trip: [] for trip in trips}
    while sum(len(g) for g in got.values()) < n:
        moved = False
        for trip in trips:
            if sum(len(g) for g in got.values()) >= n:
                break
            pool, g = pools[trip], got[trip]
            while pool:
                r = pool.pop()
                if all(abs(r[4] - x[4]) >= MIN_SEP_S for x in g):
                    g.append(r)
                    moved = True
                    break
        if not moved:
            break
    out = [r for g in got.values() for r in g]
    keys = ("id", "trip", "clip_id", "pos", "t", "kmh", "lat", "lon", "course",
            "jpg", "clip", "clip_duration")
    return [dict(zip(keys, r)) for r in sorted(out, key=lambda r: r[4])]


def main():
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    tune = pick_half(con, TUNE_TRIPS, PER_HALF, 1)
    test = pick_half(con, TEST_TRIPS, PER_HALF, 2)
    for r in tune:
        r["half"] = "tune"
    for r in test:
        r["half"] = "test"
    path = os.path.join(OUT, "truth_pick.json")
    with open(path, "w") as f:
        json.dump(tune + test, f, ensure_ascii=False, indent=1)
    print(f"настройка {len(tune)}, проверка {len(test)} → {path}")


if __name__ == "__main__":
    main()
