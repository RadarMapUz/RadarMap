#!/usr/bin/env python3
"""Тесты 33G — модель обычных пробок (traffic_model.py) и её слияние с
наблюдениями водителей (traffic_profile.py): кривые слотов, монотонность по
классу и плотности светофоров, границы, детерминизм, слияние при n = 0, 3 и
30, маршрутизатор с весом MODEL_W_ROUTE, profile.json для телефона, отказ =
граф, греп приватности.
Запуск: python3 server/test_traffic_model.py
"""
import calendar
import gzip
import json
import os
import random
import sqlite3
import tempfile
import unittest

import traffic_build as tb
import traffic_config as tc
import traffic_model as tm
import traffic_profile as tp
import traffic_speeds as ts

MONDAY = calendar.timegm((2026, 10, 25, 19, 0, 0))   # пн 26.10.2026 00:00 по Ташкенту
CENTRE = tc.MODEL_CENTRE


def at(day, hour, minute=0):
    return MONDAY + day * 86400 + hour * 3600 + minute * 60


def slot(day, hour):
    return day * 24 + hour


class CurveTest(unittest.TestCase):

    def test_peaks_and_night(self):
        for day in range(4):
            self.assertEqual(tm.day_curve(slot(day, 3)), 0, "ночь свободна")
            self.assertGreaterEqual(tm.day_curve(slot(day, 8)), 0.8, "утренний пик будней")
            self.assertGreaterEqual(tm.day_curve(slot(day, 18)), 0.95, "вечерний пик будней")
            self.assertLess(tm.day_curve(slot(day, 12)), tm.day_curve(slot(day, 18)), "днём легче пика")
        # Пик 7:30–10:00: к 7:30 смесь уже больше половины, к 10:00 — меньше.
        mon = [tm.day_curve(s) for s in range(24)]
        self.assertGreater((mon[7] + mon[8]) / 2, 0.5)
        self.assertLess(mon[10], 0.5)
        self.assertGreater(mon[17], 0.8)
        self.assertLess(mon[20], 0.5)

    def test_friday_weekday_saturday_sunday_order(self):
        for hour in range(24):
            mon, fri = tm.day_curve(slot(0, hour)), tm.day_curve(slot(4, hour))
            sat, sun = tm.day_curve(slot(5, hour)), tm.day_curve(slot(6, hour))
            self.assertGreaterEqual(fri, mon, f"пятница {hour}:00")
            self.assertGreaterEqual(mon, sat, f"суббота мягче будней {hour}:00")
            self.assertGreaterEqual(sat, sun, f"воскресенье {hour}:00")
        self.assertGreater(tm.day_curve(slot(4, 18)), tm.day_curve(slot(0, 18)), "пятница вечером сильнее")
        self.assertLessEqual(max(tm.day_curve(slot(6, h)) for h in range(24)), 0.25, "воскресенье почти свободно")
        self.assertEqual(tm.day_curve(slot(5, 8)) < tm.day_curve(slot(0, 8)), True, "у субботы нет утреннего пика")

    def test_week_wraps_and_holiday_is_sunday(self):
        self.assertEqual(tm.day_curve(168 + 18), tm.day_curve(18))
        navruz = calendar.timegm((2026, 3, 21, 13, 0, 0))   # 18:00 по Ташкенту, праздник
        self.assertEqual(tb.week_slot(navruz) // 24, 6, "праздник — воскресный слот")

    def test_direction_in_peaks_only(self):
        self.assertEqual(tm.direction_factor(slot(0, 8), 1.0), 1.0, "утром в центр — полная глубина")
        self.assertAlmostEqual(tm.direction_factor(slot(0, 8), -1.0), 1 - tc.MODEL_DIR_SPLIT, msg="утром из центра легче")
        self.assertAlmostEqual(tm.direction_factor(slot(0, 18), 1.0), 1 - tc.MODEL_DIR_SPLIT, msg="вечером в центр легче")
        self.assertEqual(tm.direction_factor(slot(0, 18), -1.0), 1.0)
        self.assertEqual(tm.direction_factor(slot(0, 13), -1.0), 1.0, "днём направления нет")
        self.assertEqual(tm.direction_factor(slot(5, 18), 1.0), 1.0, "в выходные направления нет")

    def test_slot_mix_by_minute(self):
        c = tm.curve(0.4)
        mix = tp.slot_mix(at(0, 18, 30))
        self.assertAlmostEqual(tm.mixed(c, mix), (c[18] + c[19]) / 200)


class DepthTest(unittest.TestCase):

    def test_reference_points(self):
        # Ориентир владельца: проспект в центре, светофоры чаще 3 на км, будний вечер — 0,45–0,6 графа.
        d = tm.depth("primary", 2, 3.5, 1.0, near_node=True)
        self.assertTrue(0.45 <= tm.multiplier(d, slot(0, 18)) <= 0.6, tm.multiplier(d, slot(0, 18)))
        d = tm.depth("primary", 2, 3.5, 1.0)
        self.assertTrue(0.45 <= tm.multiplier(d, slot(0, 18)) <= 0.6)
        # Трасса за городом — почти граф в любой час.
        d = tm.depth("trunk", 2, 0.0, 30.0, near_exit=True)
        self.assertEqual(d, 0.0)
        self.assertTrue(all(tm.multiplier(d, s) >= 0.99 for s in range(168)))
        # Жилая улица — вне модели.
        self.assertEqual(tm.depth("residential", 1, 5, 0.5, True, True), 0.0)

    def test_monotone_in_class_and_signals(self):
        for km in (1.0, 6.0, 14.0):
            depths = [tm.depth(cls, 2, 2.0, km) for cls in tc.MODEL_CLASS_ORDER] + [tm.depth("residential", 2, 2.0, km)]
            self.assertEqual(depths, sorted(depths, reverse=True), f"класс, {km} км")
            for cls in tc.MODEL_CLASS_ORDER:
                ladder = [tm.depth(cls, 2, rho, km) for rho in (0, 0.5, 1, 2, 3, 4, 8)]
                self.assertEqual(ladder, sorted(ladder), f"светофоры, {cls}, {km} км")
                mults = [tm.multiplier(d, slot(0, 18)) for d in ladder]
                self.assertEqual(mults, sorted(mults, reverse=True), "больше светофоров — не быстрее")
        far = [tm.depth("primary", 2, 3, km) for km in (0, 4, 8, 12, 16, 20, 25)]
        self.assertEqual(far, sorted(far, reverse=True), "дальше от центра — не глубже")

    def test_bounds(self):
        worst = tm.depth("primary", 1, 50, 0.0, True, True)
        self.assertLessEqual(worst, tc.MODEL_DEPTH_MAX)
        for d in (0, 0.1, worst, 5.0):
            for s in range(168):
                for rad in (-1, 0, 1):
                    m = tm.multiplier(min(d, tc.MODEL_DEPTH_MAX), s, rad)
                    self.assertTrue(tc.MODEL_FLOOR <= m <= 1.0)
        self.assertGreaterEqual(min(tm.curve(worst)), 100 * tc.MODEL_FLOOR, "нижняя граница — 0,35 графа")
        self.assertEqual(tc.MODEL_FLOOR, 0.35)

    def test_route_prior_is_half_way(self):
        self.assertAlmostEqual(tm.route_prior(60, 0.5), 60 * (1 - tc.MODEL_W_ROUTE * 0.5))
        self.assertEqual(tm.route_prior(60, 1.0), 60)
        self.assertEqual(tc.MODEL_W_ROUTE, 0.5)


def tiny_network():
    """Проспект через центр (primary, два направления, светофоры) и трасса
    за городом (trunk, одностороннее)."""
    coords, ways = {}, []
    lat0, lon0 = CENTRE
    nodes = []
    for i in range(12):
        coords[100 + i] = (lat0 + i * 0.0009, lon0)        # ~100 м шаг на север
        nodes.append(100 + i)
    ways.append((1, {"highway": "primary", "name": "Амир Темур", "lanes": "4"}, nodes))
    far = []
    for i in range(5):
        coords[500 + i] = (41.0 + i * 0.001, 69.0)
        far.append(500 + i)
    ways.append((2, {"highway": "trunk", "oneway": "yes", "name": "М-39"}, far))
    members = {}
    for way_id, tags, ns in ways:
        for n in ns:
            members.setdefault(n, set()).add((way_id, tags["highway"], tags["name"]))
    signals = [(coords[n][0], coords[n][1], n) for n in (101, 104, 107, 110)]
    return ways, coords, signals, members


class BuildTest(unittest.TestCase):

    def build(self, ways, coords, signals, members):
        majors, exits = tm.junctions(members, coords)
        lights = tm.signal_junctions(signals, members)
        features = tm.edge_features(ways, coords, lights, majors, exits)
        graph = {edge: 50.0 for edge in features}
        return tm.model_payload(features, coords, graph), features

    def test_features_and_payload(self):
        payload, features = self.build(*tiny_network())
        self.assertIn((100, 101), features)
        self.assertIn((101, 100), features, "двустороннее — оба направления")
        self.assertIn((500, 501), features)
        self.assertNotIn((501, 500), features, "одностороннее — только по ходу")
        cls, lanes, per_km, *_ = features[(105, 106)]
        self.assertEqual((cls, lanes), ("primary", 2))
        self.assertGreater(per_km, 2.0, "светофоры своей улицы")
        keys = {(e[0], e[1]) for e in payload["edges"]}
        self.assertIn((105, 106), keys)
        self.assertNotIn((500, 501), keys, "трасса за городом: модель о ней молчит")
        for row in payload["edges"]:
            self.assertEqual(len(payload["curves"][row[7]]), 168)

    def test_signals_of_another_street_do_not_count(self):
        ways, coords, signals, members = tiny_network()
        coords[900], coords[901] = (CENTRE[0] + 0.004, CENTRE[1] + 0.002), (CENTRE[0] + 0.004, CENTRE[1] + 0.003)
        ways.append((3, {"highway": "secondary", "name": "Соседняя"}, [900, 901]))
        members[900] = {(3, "secondary", "Соседняя")}
        members[901] = {(3, "secondary", "Соседняя")}
        _, before = self.build(ways, coords, signals, members)
        signals = signals + [(coords[900][0], coords[900][1], 900)]
        _, after = self.build(ways, coords, signals, members)
        self.assertEqual(before[(105, 106)][2], after[(105, 106)][2])

    def test_deterministic_bytes(self):
        ways, coords, signals, members = tiny_network()
        a, _ = self.build(ways, coords, signals, members)
        random.seed(7)
        shuffled = list(ways)
        random.shuffle(shuffled)
        b, _ = self.build(shuffled, coords, list(reversed(signals)), members)
        self.assertEqual(tm.model_bytes(a), tm.model_bytes(b))
        self.assertEqual(tm.model_bytes(a), tm.model_bytes(json.loads(json.dumps(a))))

    def test_cap_keeps_most_significant(self):
        payload, _ = self.build(*tiny_network())
        capped, trimmed = tm.cap_payload(payload, max_edges=3)
        self.assertEqual((len(capped["edges"]), trimmed), (3, len(payload["edges"]) - 3))
        self.assertEqual(capped["edges"], sorted(capped["edges"]))

    def test_load_fails_closed(self):
        tmp = tempfile.mkdtemp()
        path = os.path.join(tmp, "m.json.gz")
        self.assertEqual(tm.load_model(path, enabled=True), {}, "нет файла — нет модели")
        payload, _ = self.build(*tiny_network())
        with open(path, "wb") as f:
            f.write(tm.model_bytes(payload))
        self.assertTrue(tm.load_model(path, enabled=True))
        self.assertEqual(tm.load_model(path, enabled=False), {}, "выключатель слоя")
        for bad in (dict(payload, v=2), dict(payload, curves=[[10] * 168] * len(payload["curves"]))):
            with open(path, "wb") as f:
                f.write(tm.model_bytes(bad))
            os.utime(path, ns=(1, os.stat(path).st_mtime_ns + 10 ** 9))
            self.assertEqual(tm.load_model(path, enabled=True), {}, "чужая версия или кривая ниже пола")
        with open(path, "wb") as f:
            f.write(b"\x1f\x8b broken")
        os.utime(path, ns=(1, os.stat(path).st_mtime_ns + 2 * 10 ** 9))
        self.assertEqual(tm.load_model(path, enabled=True), {})


GRAPH = 50.0


def model_entry(d=0.5, rad=0.0, g=GRAPH):
    return (g, tuple(tm.curve(d, rad)), (41.3, 69.28, 41.301, 69.28))


class MergeTest(unittest.TestCase):
    """Слияние модели с наблюдениями: v_typ = (n·v_med + k·v_prior)/(n + k)."""

    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        self.conn = sqlite3.connect(self.tmp.name)
        tb.schema(self.conn)
        self.dir = tempfile.mkdtemp()

    def tearDown(self):
        self.conn.close()
        os.unlink(self.tmp.name)

    def observe(self, days, kmh=12.0, u=1, v=2, hour=18):
        self.conn.execute("INSERT OR REPLACE INTO traffic_edges(u, v, model_kmh) VALUES(?, ?, ?)", (u, v, GRAPH))
        self.conn.execute("INSERT OR REPLACE INTO traffic_nodes(id, lat, lon) VALUES(?, 41.3, 69.28)", (u,))
        self.conn.execute("INSERT OR REPLACE INTO traffic_nodes(id, lat, lon) VALUES(?, 41.301, 69.28)", (v,))
        self.conn.execute("INSERT OR REPLACE INTO traffic_shared(u, v, seen) VALUES(?, ?, ?)", (u, v, at(0, 18)))
        for k in range(days):
            day = tb.day_number(at(0, hour)) - 7 * (k % 8) - (k // 8)
            for _ in range(2):   # два куска в день: годен с трёх дней
                self.conn.execute("INSERT INTO traffic_slot_obs(u, v, slot, day, kmh) VALUES(?, ?, ?, ?, ?)",
                                  (u, v, hour, day, kmh))
        self.conn.commit()

    def test_n_0_3_30(self):
        prior = GRAPH * 0.5
        self.assertIsNone(tp.slot_typical([], GRAPH, prior), "n = 0 — слот не годен, итог — сама опора")
        three = [(d, 10.0) for d in range(3) for _ in range(2)]
        self.assertAlmostEqual(tp.slot_typical(three, GRAPH, prior), (3 * 10 + 3 * prior) / 6)
        thirty = [(d, 10.0) for d in range(30)]
        self.assertAlmostEqual(tp.slot_typical(thirty, GRAPH, prior), (30 * 10 + 3 * prior) / 33)
        self.assertLess(abs(tp.slot_typical(thirty, GRAPH, prior) - 10), abs(tp.slot_typical(three, GRAPH, prior) - 10),
                        "чем больше дней, тем меньше модели")
        self.assertAlmostEqual(tp.slot_typical(three, GRAPH), (30 + 150) / 6, msg="без модели опора — граф (33A)")

    def test_router_without_observations_takes_half_the_model(self):
        model = {(1, 2): model_entry(0.5)}
        self.observe(0)
        edges, graph, stats = tp.route_edges(self.conn, at(0, 18, 0), model=model)
        expect = tm.route_prior(GRAPH, tm.curve(0.5)[18] / 100)
        self.assertEqual(edges[(1, 2)], float(round(expect)))
        self.assertEqual(stats["model"], 1)
        self.assertEqual(graph[(1, 2)], GRAPH)
        edges, _, _ = tp.route_edges(self.conn, at(0, 3, 0), model=model)
        self.assertEqual(edges, {}, "ночью модель молчит — граф")
        edges, _, _ = tp.route_edges(self.conn, at(6, 12, 0), model=model)
        self.assertEqual(edges, {}, "воскресенье днём — почти граф, строки нет")

    def test_router_with_observations(self):
        model = {(1, 2): model_entry(0.5)}
        route_prior = tm.route_prior(GRAPH, tm.curve(0.5)[18] / 100)
        for days, expect in ((3, (3 * 12 + 3 * route_prior) / 6), (30, (30 * 12 + 3 * route_prior) / 33)):
            self.conn.execute("DELETE FROM traffic_slot_obs")
            self.observe(days)
            edges, _, stats = tp.route_edges(self.conn, at(0, 18, 0), model=model)
            self.assertEqual(edges[(1, 2)], float(round(expect)), f"n = {days}")
            self.assertEqual((stats["typical"], stats["model"]), (1, 0))

    def test_drivers_faster_than_model_win(self):
        model = {(1, 2): model_entry(0.6)}
        self.observe(30, kmh=GRAPH)          # водители месяц ездят как граф
        edges, _, _ = tp.route_edges(self.conn, at(0, 18, 0), model=model)
        self.assertNotIn((1, 2), edges, "данные вытеснили догадку")

    def test_only_slowdown_floor_and_graph(self):
        model = {(1, 2): model_entry(tc.MODEL_DEPTH_MAX), (3, 4): model_entry(0.02)}
        edges, graph, _ = tp.route_edges(self.conn, at(4, 18, 0), model=model)
        for edge, kmh in edges.items():
            self.assertTrue(tc.SPEED_FLOOR_KMH <= kmh < tc.WRITE_RATIO * graph[edge])
        self.assertNotIn((3, 4), edges, "мелкое замедление — не пишется")

    def test_speeds_file_and_log_with_model_file(self):
        model = {(1, 2): model_entry(0.5)}
        path = os.path.join(self.dir, "model.json.gz")
        payload = {"v": 1, "curves": [list(model[(1, 2)][1])],
                   "edges": [[1, 2, 41.3, 69.28, 41.301, 69.28, GRAPH, 0]]}
        with open(path, "wb") as f:
            f.write(tm.model_bytes(payload))
        out = os.path.join(self.dir, "speeds.csv")
        self.conn.commit()
        args = ["--source", "route", "--db", self.tmp.name, "--now", str(at(0, 18, 10)), "--out", out, "--model", path]
        import io
        from contextlib import redirect_stdout
        log = io.StringIO()
        with redirect_stdout(log):
            self.assertEqual(ts.main(args), 0)
        first = open(out).read()
        self.assertTrue(first.startswith("1,2,50.0,"))
        self.assertIn("модели 1", log.getvalue())
        os.remove(out)
        with redirect_stdout(io.StringIO()):
            ts.main(args)
        self.assertEqual(open(out).read(), first, "детерминизм")
        for word in ("device", "ip", "piece", "ts", "41.3"):
            self.assertNotIn(word, first)

    def test_profile_json_rows(self):
        a = model_entry(0.5)
        model = {(1, 2): a, (10, 11): (GRAPH, a[1], (41.31, 69.28, 41.3105, 69.28)),
                 (11, 12): (GRAPH, a[1], (41.3105, 69.28, 41.311, 69.28)),
                 (12, 13): (GRAPH, a[1], (41.311, 69.28, 41.3115, 69.28))}
        self.observe(3, kmh=48.0)           # ребро 1→2: водители — почти граф в слоте 18
        drivers, rows, curves = tp.profile_edges(self.conn, at(0, 18), model=model)
        [row] = drivers
        self.assertEqual(len(row), 7, "ребро модели у водителей несёт номер кривой")
        self.assertEqual(row[5], [[18, round((3 * 48 + 3 * GRAPH * a[1][18] / 100) / 6)]],
                         "годный слот пишется, даже если почти граф: иначе телефон взял бы модель")
        self.assertEqual(curves[row[6]], list(a[1]))
        [merged] = rows
        self.assertEqual(merged[:4], [41.31, 69.28, 41.3115, 69.28], "три ребра по прямой (167 м) — один отрезок")
        self.assertIsInstance(merged[5], int, "строка модели: шестой элемент — номер кривой, не список")
        body, count, _ = tp.profile_body(self.conn, at(0, 18), model=model)
        data = json.loads(body)
        self.assertEqual(data["sources"], {"drivers": 1, "model": 1})
        self.assertEqual(count, 2)
        for word in ("device", "ip", "piece", "day", "ts", "seen"):
            self.assertNotIn(word, body)

    def test_profile_without_model_is_unchanged(self):
        self.observe(6)
        body, _, _ = tp.profile_body(self.conn, at(0, 18), model={})
        data = json.loads(body)
        self.assertNotIn("curves", data, "без модели — прежний формат")
        self.assertEqual(len(data["edges"][0]), 6)

    def test_merge_breaks_on_bend_and_curve(self):
        c1, c2 = tuple(tm.curve(0.5)), tuple(tm.curve(0.3))
        model = {(1, 2): (GRAPH, c1, (41.3, 69.28, 41.3009, 69.28)),
                 (2, 3): (GRAPH, c1, (41.3009, 69.28, 41.3009, 69.2812)),   # поворот на 90°
                 (3, 4): (GRAPH, c2, (41.3009, 69.2812, 41.3009, 69.2824))}
        rows = tp.merge_model_rows(model)
        self.assertEqual(len(rows), 3)
        long_line = {(i, i + 1): (GRAPH, c1, (41.3 + i * 0.0008, 69.28, 41.3 + (i + 1) * 0.0008, 69.28))
                     for i in range(5)}
        self.assertEqual(len(tp.merge_model_rows(long_line)), 3, "445 м прямой — отрезки не длиннее 200 м")


class PrivacyTest(unittest.TestCase):

    def test_model_file_is_only_osm(self):
        payload, _ = BuildTest().build(*tiny_network())
        text = gzip.decompress(tm.model_bytes(payload)).decode()
        self.assertEqual(set(json.loads(text)), {"v", "curves", "edges"})
        for word in ("device", "ip", "piece", "day", "seen", "generated", "time", "Амир"):
            self.assertNotIn(word, text)


if __name__ == "__main__":
    unittest.main()
