#!/usr/bin/env python3
"""Очередь разметки полос (lanes_gaps.py) на крошечной синтетической traffic.db.

Схема базы — настоящая (traffic_build.schema), данные — перекрёсток J:
подход с юга S2 → S1 → J, выезды на север, восток и запад, подход с севера.
Главное — что НЕ попадает в очередь: подход без выбора, редкое ребро, ребро
одного человека (нет в traffic_shared), уже покрытое слоем или OSM; и что в
выходе нет ничего личного.

    cd server && python3 -W ignore -m unittest test_lanes_gaps -v
"""
import contextlib
import csv
import datetime
import hashlib
import io
import json
import math
import os
import shutil
import sqlite3
import tempfile
import unittest

import build_lane_overlay as blo
import lanes_gaps as lg
import traffic_build as tb

NOW = 1_792_560_000.0
DAY = 86400.0
J = (41.30000, 69.28000)


def offset(point, north_m=0.0, east_m=0.0):
    lat, lon = point
    return (lat + north_m / blo.LAT_METERS,
            lon + east_m / (blo.LAT_METERS * math.cos(math.radians(lat))))


# Узлы: id → (lat, lon).
NODES = {1: J, 2: offset(J, north_m=-40), 3: offset(J, north_m=-120), 4: offset(J, north_m=60),
         5: offset(J, east_m=60), 6: offset(J, east_m=-60),
         # Подворотня на юге: S1 → двор (7). Поток крошечный.
         7: offset(offset(J, north_m=-40), east_m=30)}
# Эффективные куски по рёбрам (u, v).
FLOWS = {(3, 2): 60, (2, 1): 50, (2, 7): 1,          # с юга; во двор — единицы
         (1, 4): 30, (1, 5): 12, (1, 6): 8,          # выезды из J
         (4, 1): 20, (1, 2): 25,                     # с севера и обратно на юг
         (6, 1): 5,                                  # с запада — редкое
         (5, 1): 100}                                # с востока — много, но не «не один»
SHARED = {(3, 2), (2, 1), (4, 1), (6, 1), (1, 4), (1, 5), (1, 2)}


def make_db(path, epoch=NOW - 35 * DAY, shared=SHARED, flows=FLOWS, old_schema=False):
    conn = sqlite3.connect(path)
    if old_schema:
        # База до 8.8.16: ни pieces, ни traffic_shared, ни traffic_meta.
        conn.execute("CREATE TABLE traffic_nodes(id INTEGER PRIMARY KEY, lat REAL, lon REAL)")
        conn.execute("""CREATE TABLE traffic_profile(u INTEGER, v INTEGER, how INTEGER,
                        n INTEGER, sum_kmh REAL, PRIMARY KEY(u, v, how))""")
    else:
        tb.schema(conn)
    conn.executemany("INSERT INTO traffic_nodes(id, lat, lon) VALUES(?, ?, ?)",
                     [(node, lat, lon) for node, (lat, lon) in NODES.items()])
    scale = tb.decay_scale(epoch, NOW) if epoch is not None else 1.0
    for (u, v), flow in flows.items():
        # Поток размазан по двум часам недели — сумма по how обязана сложиться.
        for how, share in ((8, 0.6), (18, 0.4)):
            if old_schema:
                conn.execute("INSERT INTO traffic_profile(u, v, how, n, sum_kmh) VALUES(?, ?, ?, ?, ?)",
                             (u, v, how, flow * share * 3, 0.0))
            else:
                conn.execute("""INSERT INTO traffic_profile(u, v, how, n, sum_kmh, pieces, sum_pace)
                                VALUES(?, ?, ?, ?, ?, ?, ?)""",
                             (u, v, how, flow * share * 3 * scale, 0.0, flow * share * scale, 0.0))
    if not old_schema:
        conn.executemany("INSERT INTO traffic_shared(u, v, seen) VALUES(?, ?, ?)",
                         [(u, v, NOW - DAY) for u, v in shared])
        if epoch is not None:
            conn.execute("INSERT INTO traffic_meta(key, value) VALUES('profile_epoch', ?)", (epoch,))
    conn.commit()
    conn.close()


def osrm_route(*steps):
    """Ответ OSRM route с шагами (тип, модификатор, точка, курс до, полосы)."""
    out = [{"maneuver": {"type": "depart", "location": [69.0, 41.0], "bearing_before": 0},
            "intersections": [{}]}]
    for kind, modifier, (lat, lon), before, lanes in steps:
        intersection = {"location": [lon, lat]}
        if lanes:
            intersection["lanes"] = [{"valid": True, "indications": ["left"]},
                                     {"valid": False, "indications": ["straight"]}]
        out.append({"maneuver": {"type": kind, "modifier": modifier, "location": [lon, lat],
                                 "bearing_before": before}, "intersections": [intersection]})
    return {"code": "Ok", "routes": [{"legs": [{"steps": out}]}]}


class GapsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)
        self.db = os.path.join(self.tmp, "traffic.db")
        make_db(self.db)

    def approaches(self, **kwargs):
        conn = lg.open_readonly(self.db)
        try:
            return lg.traffic_approaches(conn, NOW, **kwargs)
        finally:
            conn.close()

    def write(self, name, payload):
        path = os.path.join(self.tmp, name)
        with open(path, "w", encoding="utf-8") as handle:
            if isinstance(payload, str):
                handle.write(payload)
            else:
                json.dump(payload, handle)
        return path

    def run_main(self, *argv):
        buffer = io.StringIO()
        code = lg.main(list(argv) + ["--now", str(NOW)], out=buffer)
        return code, buffer.getvalue()

    # --- Какие подходы — перекрёсток с выбором ---------------------------------

    def test_decision_approaches_ranked_by_flow(self):
        found = self.approaches()
        self.assertEqual([(a["lat"], a["lon"]) for a in found], [J, J],
                         "в очереди только подходы к J: с юга и с севера")
        south, north = found
        self.assertEqual(round(south["traffic"]), 50, "старение профиля снято: куски — эффективные")
        self.assertIn(south["bearing"], (0, 359, 1))
        self.assertEqual(south["turns"], 2, "север и восток; запад (8) ниже порога")
        self.assertEqual(north["bearing"], 180)

    def test_no_choice_rare_and_single_person_edges_stay_out(self):
        found = self.approaches()
        positions = {(a["lat"], a["lon"]) for a in found}
        # S2 → S1: в S1 выбора нет (двор — 1 кусок из 60, это не сторона).
        self.assertNotIn(tuple(round(c, 5) for c in NODES[2]), positions)
        bearings = {a["bearing"] for a in found}
        self.assertNotIn(90, bearings, "с запада — 5 кусков, ниже порога")
        self.assertNotIn(270, bearings, "с востока — 100 кусков, но ни разу не вдвоём: улица одного человека")

    def test_expired_shared_mark_does_not_count(self):
        conn = sqlite3.connect(self.db)
        conn.execute("UPDATE traffic_shared SET seen = ? WHERE u = 4 AND v = 1",
                     (NOW - tb.SHARED_TTL - DAY,))
        conn.commit()
        conn.close()
        self.assertEqual([a["bearing"] for a in self.approaches()], [0])

    def test_threshold_is_tunable(self):
        self.assertEqual(self.approaches(min_traffic=40), [],
                         "подход 50, но выездов по 40+ нет — выбора не видно")
        self.assertEqual(sorted(a["bearing"] for a in self.approaches(min_traffic=5)), [0, 90, 180],
                         "порог 5 пропускает и подход с запада")

    def test_old_schema_falls_back_to_segments(self):
        old = os.path.join(self.tmp, "old.db")
        make_db(old, epoch=None, old_schema=True)
        conn = lg.open_readonly(old)
        warnings = io.StringIO()
        try:
            with contextlib.redirect_stderr(warnings):
                found = lg.traffic_approaches(conn, NOW)
        finally:
            conn.close()
        self.assertIn("traffic_shared", warnings.getvalue(), "о снятой защите надо сказать вслух")
        # Без traffic_shared остаётся только порог, а отрезков (n) втрое больше
        # кусков: восток (300) — первым, и запад (15) тоже проходит порог 10.
        self.assertEqual([a["bearing"] for a in found], [270, 0, 180, 90])

    def test_database_is_never_written(self):
        # Без метки старения: traffic_build.profile_epoch на её месте вставил бы новую.
        conn = sqlite3.connect(self.db)
        conn.execute("DELETE FROM traffic_meta")
        conn.commit()
        conn.close()
        before = hashlib.sha256(open(self.db, "rb").read()).hexdigest()
        code, _ = self.run_main("--traffic-db", self.db, "--csv", os.path.join(self.tmp, "q.csv"))
        self.assertEqual(code, 0)
        self.assertEqual(hashlib.sha256(open(self.db, "rb").read()).hexdigest(), before,
                         "traffic_build.profile_epoch вставил бы метку — здесь её ставить нельзя")
        conn = lg.open_readonly(self.db)
        with self.assertRaises(sqlite3.OperationalError):
            conn.execute("DELETE FROM traffic_profile")
        conn.close()

    # --- Покрытие -------------------------------------------------------------

    def test_overlay_covers_by_phone_rule(self):
        csv_text = (",".join(blo.CSV_FIELDS) + "\n"
                    "s-1,%.5f,%.5f,10,30,left|straight,survey,2026-10-21\n" % J)
        overlay = lg.load_overlay([self.write("lanes.csv", csv_text)])
        items, excluded = lg.queue(lg.merge(self.approaches(), []), overlay)
        self.assertEqual([i["bearing"] for i in items], [180], "с юга покрыт (курс 0 в допуске 30 от 10)")
        self.assertEqual(excluded["overlay"], 1)
        # Та же точка, но курс 90 — подход с юга не покрыт.
        overlay = lg.load_overlay([self.write("east.csv", csv_text.replace(",10,30,", ",90,30,"))])
        items, _ = lg.queue(lg.merge(self.approaches(), []), overlay)
        self.assertEqual(len(items), 2)

    def test_osm_turn_lanes_cover(self):
        south = [offset(J, north_m=-120), J]
        features = [
            {"type": "Feature", "id": "w1", "geometry": {"type": "LineString",
             "coordinates": [[p[1], p[0]] for p in south]},
             "properties": {"highway": "primary", "oneway": "yes", "turn:lanes": "left|through"}},
            {"type": "Feature", "id": "w2", "geometry": {"type": "LineString",
             "coordinates": [[p[1], p[0]] for p in (offset(J, east_m=-100), J, offset(J, east_m=100))]},
             "properties": {"highway": "primary"}},
            {"type": "Feature", "id": "w3", "geometry": {"type": "LineString",
             "coordinates": [[p[1], p[0]] for p in (J, offset(J, north_m=100))]},
             "properties": {"highway": "primary"}}]
        extract = self.write("roads.geojsonl", "".join("\x1e" + json.dumps(f) + "\n" for f in features))
        code, text = self.run_main("--traffic-db", self.db, "--osm", extract,
                                   "--csv", os.path.join(self.tmp, "q.csv"))
        self.assertEqual(code, 0)
        self.assertIn("в turn:lanes OSM 1", text)
        rows = list(csv.DictReader(open(os.path.join(self.tmp, "q.csv"), encoding="utf-8")))
        self.assertEqual([r["bearing"] for r in rows], ["180"])
        self.assertEqual(rows[0]["osm_turn_lanes"], "нет")

    # --- Маршруты -------------------------------------------------------------

    def test_routes_merge_into_traffic_and_osrm_lanes_exclude(self):
        k = (41.35000, 69.30000)
        route = osrm_route(("turn", "left", J, 1, False), ("turn", "right", k, 270, True),
                           ("continue", "straight", offset(J, north_m=500), 0, False))
        first, second = self.write("r1.json", route), self.write("r2.json", [route])
        maneuvers = lg.route_maneuvers([first, second])
        self.assertEqual(sorted((m["routes"], m["osrm_lanes"]) for m in maneuvers),
                         [(2, False), (2, True)], "прямо — не кандидат; один поворот в двух маршрутах")
        merged = lg.merge(self.approaches(), maneuvers)
        south = next(m for m in merged if m["bearing"] in (0, 359, 1))
        self.assertEqual(south["routes"], 2, "поворот маршрута сел на подход пробок")
        items, excluded = lg.queue(merged)
        self.assertEqual(excluded["osrm"], 1, "у OSRM полосы есть — телефону слой не нужен")
        self.assertNotIn(k, [(i["lat"], i["lon"]) for i in items])

    def test_routes_only_without_traffic(self):
        route = osrm_route(("turn", "left", J, 0, False), ("end of road", "right", offset(J, north_m=800), 0, False))
        other = osrm_route(("turn", "left", J, 2, False))
        code, text = self.run_main("--routes", self.write("a.json", route), self.write("b.json", other),
                                   "--csv", os.path.join(self.tmp, "q.csv"))
        self.assertEqual(code, 0)
        rows = list(csv.DictReader(open(os.path.join(self.tmp, "q.csv"), encoding="utf-8")))
        self.assertEqual([r["routes"] for r in rows], ["2", "1"], "чаще встречающийся поворот — выше")

    # --- Выход ----------------------------------------------------------------

    def test_output_is_template_shaped_and_cannot_be_published_unfilled(self):
        out = os.path.join(self.tmp, "q.csv")
        geo = os.path.join(self.tmp, "q.geojson")
        code, _ = self.run_main("--traffic-db", self.db, "--csv", out, "--geojson", geo)
        self.assertEqual(code, 0)
        with open(out, encoding="utf-8") as handle:
            header = handle.readline().strip().split(",")
        self.assertEqual(tuple(header[:8]), blo.CSV_FIELDS)
        rows = blo.read_input(out)
        self.assertEqual(len(rows), 2)
        _, errors, _ = blo.assemble(rows, datetime.date(2026, 10, 21))
        self.assertEqual(len(errors), 2)
        self.assertTrue(all("lanes пусто" in reason for _w, _i, reason in errors),
                        "неразмеченная очередь не публикуется по ошибке")
        doc = json.load(open(geo, encoding="utf-8"))
        self.assertEqual(len(doc["features"]), 2)
        self.assertEqual(doc["features"][0]["properties"]["rank"], 1)

    def test_nothing_personal_in_output(self):
        out = os.path.join(self.tmp, "q.csv")
        geo = os.path.join(self.tmp, "q.geojson")
        self.run_main("--traffic-db", self.db, "--csv", out, "--geojson", geo)
        text = (open(out, encoding="utf-8").read() + open(geo, encoding="utf-8").read()).lower()
        for leak in ("how", "hour", "piece", "device", "seen", "timestamp", "kmh", "u\":", "\"v\""):
            self.assertNotIn(leak, text, leak)
        # Время ни в каком виде: ни unix-секунд, ни дат.
        self.assertNotIn(str(int(NOW))[:6], text)
        self.assertNotRegex(text, r"20\d\d-\d\d-\d\d")

    def test_ids_are_stable_between_runs(self):
        one, two = os.path.join(self.tmp, "1.csv"), os.path.join(self.tmp, "2.csv")
        self.run_main("--traffic-db", self.db, "--csv", one)
        self.run_main("--traffic-db", self.db, "--csv", two)
        self.assertEqual(open(one, encoding="utf-8").read(), open(two, encoding="utf-8").read())

    def test_refuses_privacy_unsafe_threshold_and_missing_input(self):
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                lg.main(["--traffic-db", self.db, "--min-traffic", "1"], out=io.StringIO())
            with self.assertRaises(SystemExit):
                lg.main([], out=io.StringIO())


if __name__ == "__main__":
    unittest.main()
