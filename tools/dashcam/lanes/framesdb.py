"""Кадры поездки из общей dashcam.db — строго только чтение."""
import os
import sqlite3

DB = os.path.expanduser("~/RadarMapBuild/dashcam/dashcam.db")
OUT = os.path.expanduser("~/RadarMapBuild/dashcam/lanes")
MORNING = "2026-10-07-08-05-10"


def frames(trip=MORNING, db=DB):
    """[(id, t, kmh, lat, lon, course, path)] по времени."""
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    try:
        return con.execute(
            "select id, t, kmh, lat, lon, course, path from frames "
            "where trip_key=? order by t", (trip,)).fetchall()
    finally:
        con.close()


def course_diff(a, b):
    d = (a - b + 180) % 360 - 180
    return abs(d)


def straight_ids(rows, span=3, max_turn=3.0, min_kmh=25):
    """Кадры на прямой: курс соседей ±span не отличается больше max_turn."""
    out = []
    for i, r in enumerate(rows):
        if r[2] is None or r[2] < min_kmh or r[5] is None:
            continue
        lo, hi = max(0, i - span), min(len(rows), i + span + 1)
        ok = all(rows[j][5] is not None and course_diff(rows[j][5], r[5]) <= max_turn
                 for j in range(lo, hi))
        if ok:
            out.append(r)
    return out
