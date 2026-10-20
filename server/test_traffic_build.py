#!/usr/bin/env python3
"""Тесты сборщика пробок. Запуск: python3 server/test_traffic_build.py

Ответ OSRM — настоящий, снятый с прод-сервера на условном следе по Амира
Темура (fixtures/osrm_match_amir_temur.json): в середине следа «пробка» —
три шага по 40 с вместо 8.
"""
import calendar
import json
import math
import os
import re
import sqlite3
import tempfile
import time
import unittest

import traffic_build as tb

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE = json.load(open(os.path.join(HERE, "fixtures", "osrm_match_amir_temur.json"), encoding="utf-8"))


def meters(a, b):
    lat = math.radians((a[0] + b[0]) / 2)
    return math.hypot((a[0] - b[0]) * 111_320, (a[1] - b[1]) * 111_320 * math.cos(lat))


class EdgesFromMatchTest(unittest.TestCase):
    def setUp(self):
        self.points = FIXTURE["points"]
        self.samples, self.nodes, self.models = tb.edges_from_match(FIXTURE["response"], self.points)

    def test_samples_are_osm_edges_with_sane_speeds(self):
        self.assertGreater(len(self.samples), 10)
        for u, v, kmh, weight, passed in self.samples:
            self.assertIsInstance(u, int)
            self.assertIsInstance(v, int)
            self.assertNotEqual(u, v)
            self.assertTrue(0 <= kmh <= tb.MAX_KMH)
            self.assertGreater(weight, 0)
            self.assertIsInstance(passed, bool)

    def test_jam_part_of_the_trace_is_slower(self):
        speeds = sorted({round(kmh) for _, _, kmh, _, _ in self.samples})
        self.assertLess(speeds[0], 15, "шаги по 40 с — это ползком")
        self.assertGreater(speeds[-1], 30, "шаги по 8 с — это ход")

    def test_node_coordinates_lie_on_the_trace(self):
        """Выравнивание геометрии: узел обязан быть рядом со следом, иначе
        участки дороги на карте окажутся не там."""
        self.assertGreater(len(self.nodes), 5)
        for lat, lon in self.nodes.values():
            nearest = min(meters((lat, lon), (p[0], p[1])) for p in self.points)
            self.assertLess(nearest, 120)

    def test_graph_speed_is_known_for_edges(self):
        self.assertTrue(self.models)
        for kmh in self.models.values():
            self.assertTrue(5 < kmh < 130)

    def test_piece_ends_are_touched_not_passed(self):
        """Первое и последнее рёбра совпадения кусок задел, а не прошёл; в
        свидетели идут только отрезки не ближе PIECE_END_GUARD к концам."""
        self.assertEqual(self.samples[0][:2], (1164782806, 1564859142))
        self.assertFalse(self.samples[0][4])
        self.assertEqual(self.samples[-1][:2], (4467322436, 13438299814))
        self.assertFalse(self.samples[-1][4])
        total = sum(s[3] for s in self.samples)
        along, passed = 0.0, 0
        for _, _, _, weight, through in self.samples:
            start, along = along, along + weight
            self.assertEqual(through, start >= tb.PIECE_END_GUARD and along <= total - tb.PIECE_END_GUARD)
            passed += through
        self.assertGreater(passed, 10)

    def test_low_confidence_and_errors_give_nothing(self):
        self.assertEqual(tb.edges_from_match({"code": "NoMatch"}, self.points), ([], {}, {}))
        weak = json.loads(json.dumps(FIXTURE["response"]))
        weak["matchings"][0]["confidence"] = 0.01
        self.assertEqual(tb.edges_from_match(weak, self.points)[0], [])


def split_fixture(at):
    """Две соседние части следа фикстуры — как два куска одной машины:
    первый кончается на точке `at`, второй с неё начинается (тот же ответ
    OSRM, разрезанный по участкам)."""
    matching = FIXTURE["response"]["matchings"][0]
    legs = matching["legs"]
    coords = matching["geometry"]["coordinates"]
    cut = sum(len(leg["annotation"]["distance"]) for leg in legs[:at])

    def part(lo, hi, geometry):
        points = FIXTURE["points"][lo:hi + 1]
        t0 = points[0][2]
        points = [[lat, lon, t - t0, kmh] for lat, lon, t, kmh in points]
        response = {"code": "Ok",
                    "tracepoints": [{"waypoint_index": i, "matchings_index": 0} for i in range(hi - lo + 1)],
                    "matchings": [{"confidence": matching["confidence"],
                                   "geometry": {"coordinates": geometry}, "legs": legs[lo:hi]}]}
        return points, response

    return part(0, at, coords[:cut + 1]), part(at, len(legs), coords[cut:])


class PipelineTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        self.conn = sqlite3.connect(self.tmp.name)
        tb.schema(self.conn)
        self.now = 1_760_000_000.0

    def tearDown(self):
        self.conn.close()
        os.unlink(self.tmp.name)

    def add_piece(self, received=None):
        self.conn.execute("INSERT INTO traffic_pieces(received, points) VALUES(?, ?)",
                          (received or self.now, json.dumps(FIXTURE["points"])))
        self.conn.commit()

    def test_matched_piece_is_deleted_at_once(self):
        self.add_piece()
        done, segments = tb.process(self.conn, self.now, matcher=lambda pts: FIXTURE["response"])
        self.assertEqual(done, 1)
        self.assertGreater(segments, 0)
        left = self.conn.execute("SELECT COUNT(*) FROM traffic_pieces").fetchone()[0]
        self.assertEqual(left, 0, "сырой след не хранится после сопоставления")

    def test_unmatched_piece_waits_but_not_forever(self):
        self.add_piece()

        def down(points):
            raise OSError("connection refused")

        tb.process(self.conn, self.now, matcher=down)
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM traffic_pieces").fetchone()[0], 1)
        tb.prune(self.conn, self.now + tb.PIECE_TTL + 1)
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM traffic_pieces").fetchone()[0], 0)

    def test_one_piece_is_not_enough_to_publish(self):
        self.add_piece()
        tb.process(self.conn, self.now, matcher=lambda pts: FIXTURE["response"])
        self.assertEqual(tb.aggregate(self.conn, self.now), [],
                         "один водитель у обочины пробку не рисует")

    def test_two_pieces_publish_edges_with_levels(self):
        for _ in range(2):
            self.add_piece()
        tb.process(self.conn, self.now, matcher=lambda pts: FIXTURE["response"])
        edges = tb.aggregate(self.conn, self.now)
        self.assertTrue(edges)
        self.assertEqual({e[4] for e in edges} - {1, 2, 3}, set())
        self.assertIn(3, {e[4] for e in edges}, "ползком на проспекте — пробка")

    def test_neighbour_pieces_of_one_car_vouch_for_nothing(self):
        """Соседние куски одной машины стыкуются на одном ребре: по касанию
        это были бы «два куска» — пробка в now.json и «не один человек» для
        «обычно» от одного водителя."""
        (pa, ra), (pb, rb) = split_fixture(5)
        edges_a = {s[:2] for s in tb.edges_from_match(ra, pa)[0]}
        edges_b = {s[:2] for s in tb.edges_from_match(rb, pb)[0]}
        self.assertTrue(edges_a & edges_b, "стык — общее ребро")
        for points in (pa, pb):
            self.conn.execute("INSERT INTO traffic_pieces(received, points) VALUES(?, ?)",
                              (self.now, json.dumps(points)))
        self.conn.commit()
        tb.process(self.conn, self.now, matcher=lambda pts: ra if pts == pa else rb)
        self.assertEqual(self.conn.execute("SELECT COUNT(DISTINCT piece) FROM traffic_samples").fetchone()[0], 2)
        self.assertEqual(tb.aggregate(self.conn, self.now), [])
        tb.mark_shared(self.conn, self.now)
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM traffic_shared").fetchone()[0], 0)

    def test_standing_car_paints_no_jam(self):
        """Машина стоит: кусок закрывается по времени, и все его точки — на
        одном ребре. Два таких куска подряд — всё ещё одна машина."""
        points = [[41.3, 69.28, 0, 0], [41.30001, 69.28, 250, 0], [41.30002, 69.28, 500, 0]]
        leg = {"distance": 1.1, "annotation": {"nodes": [10, 11], "distance": [1.1], "duration": [0.1]}}
        response = {"code": "Ok",
                    "tracepoints": [{"waypoint_index": i, "matchings_index": 0} for i in range(3)],
                    "matchings": [{"confidence": 0.9, "legs": [leg, leg],
                                   "geometry": {"coordinates": [[69.28, 41.3], [69.28, 41.30001],
                                                                [69.28, 41.30002]]}}]}
        self.conn.executemany("INSERT INTO traffic_nodes VALUES(?, ?, ?)", [(10, 41.3, 69.28), (11, 41.3001, 69.28)])
        for start in (self.now - 500, self.now):
            self.conn.execute("INSERT INTO traffic_pieces(received, points) VALUES(?, ?)",
                              (start, json.dumps(points)))
        self.conn.commit()
        tb.process(self.conn, self.now, matcher=lambda pts: response)
        self.assertEqual(self.conn.execute("SELECT COUNT(DISTINCT piece) FROM traffic_samples").fetchone()[0], 2)
        self.assertEqual(tb.aggregate(self.conn, self.now), [], "одна стоящая машина — не пробка")

    def test_prune_clears_old_repeat_marks(self):
        # Таблицу создаёт api.py; старого api.py без неё cron не роняет.
        tb.prune(self.conn, self.now)
        self.conn.execute("CREATE TABLE traffic_seen(hash TEXT PRIMARY KEY, received REAL NOT NULL)")
        self.conn.execute("INSERT INTO traffic_seen VALUES('old', ?), ('new', ?)",
                          (self.now - tb.SEEN_TTL - 1, self.now))
        tb.prune(self.conn, self.now)
        left = [r[0] for r in self.conn.execute("SELECT hash FROM traffic_seen")]
        self.assertEqual(left, ["new"])

    def test_old_samples_leave_the_window(self):
        for _ in range(2):
            self.add_piece()
        tb.process(self.conn, self.now, matcher=lambda pts: FIXTURE["response"])
        self.assertEqual(tb.aggregate(self.conn, self.now + tb.SAMPLE_WINDOW + 1), [])
        tb.prune(self.conn, self.now + tb.SAMPLE_KEEP + 1)
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM traffic_samples").fetchone()[0], 0)

    def test_profile_accumulates_by_hour_of_week(self):
        for _ in range(2):
            self.add_piece()
        tb.process(self.conn, self.now, matcher=lambda pts: FIXTURE["response"])
        hows = {row[0] for row in self.conn.execute("SELECT DISTINCT how FROM traffic_profile")}
        self.assertEqual(hows, {tb.hour_of_week(self.now)})

    def test_payload_carries_nothing_but_edges(self):
        for _ in range(2):
            self.add_piece()
        tb.process(self.conn, self.now, matcher=lambda pts: FIXTURE["response"])
        body = tb.payload(tb.aggregate(self.conn, self.now), self.now)
        self.assertEqual(set(body), {"v", "generated", "edges"})
        for edge in body["edges"]:
            self.assertEqual(len(edge), 7)
            self.assertTrue(all(isinstance(x, (int, float)) for x in edge))


class ProfileFixture:
    """База, каталог выхода и куски по фикстуре для тестов профиля."""

    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        self.conn = sqlite3.connect(self.tmp.name)
        tb.schema(self.conn)
        self.now = 1_760_000_000.0
        self.out = tempfile.mkdtemp()

    def tearDown(self):
        self.conn.close()
        os.unlink(self.tmp.name)
        for name in os.listdir(self.out):
            os.unlink(os.path.join(self.out, name))
        os.rmdir(self.out)

    def pieces(self, count, at=None, shared=True, slower=1):
        """`count` кусков по фикстуре; shared — проверка «не один человек»
        (два куска в одном окне) пройдена; slower — время следа × N."""
        at = at or self.now
        points = [[lat, lon, t * slower, kmh] for lat, lon, t, kmh in FIXTURE["points"]]
        for _ in range(count):
            self.conn.execute("INSERT INTO traffic_pieces(received, points) VALUES(?, ?)",
                              (at, json.dumps(points)))
        self.conn.commit()
        tb.process(self.conn, at, matcher=lambda pts: FIXTURE["response"])
        if shared:
            tb.mark_shared(self.conn, at)

    def bucket(self):
        return tb.bucket_name(tb.hour_of_week(self.now))

    def read(self, name):
        with open(os.path.join(self.out, f"{name}.json"), encoding="utf-8") as f:
            return json.load(f)

    def effective(self, now):
        """{(u, v, how): эффективные куски} — хранимое, делённое на масштаб."""
        scale = tb.decay_scale(tb.profile_epoch(self.conn, now), now)
        return {(u, v, how): pieces / scale for u, v, how, pieces in
                self.conn.execute("SELECT u, v, how, pieces FROM traffic_profile")}


class TypicalTest(ProfileFixture, unittest.TestCase):
    """«Обычно по водителям» (8.8.16): traffic/typical/<класс>-<час>.json."""

    def test_bucket_names_split_weekdays_and_days_off(self):
        self.assertEqual(tb.bucket_name(0), "wd-00")
        self.assertEqual(tb.bucket_name(4 * 24 + 23), "wd-23", "пятница 23:00 — будни")
        self.assertEqual(tb.bucket_name(5 * 24 + 8), "off-08", "суббота 8:00 — выходные")
        self.assertEqual(tb.bucket_name(6 * 24 + 18), "off-18")
        self.assertEqual(len(tb.ALL_BUCKETS), 48)
        self.assertEqual(len(set(tb.ALL_BUCKETS)), 48)

    def test_profile_counts_pieces_not_segments(self):
        self.pieces(2)
        for n, pieces in self.conn.execute("SELECT n, pieces FROM traffic_profile"):
            self.assertEqual(pieces, 2, "кусок — одно наблюдение ребра")
            self.assertGreaterEqual(n, pieces)

    def test_harmonic_speed(self):
        """Пробка 5 и свобода 50 — это время, а не среднее км/ч: 9, не 27,5."""
        profile = tb.piece_profile([(1, 2, 50.0, 100.0, True), (1, 2, 5.0, 100.0, True)])
        count, total, pace = profile[(1, 2)]
        self.assertEqual(count, 2)
        self.assertAlmostEqual(total, 55.0)
        self.assertAlmostEqual(3600 / pace, 9.09, places=2)
        # Стоянка не делает темп бесконечным.
        self.assertAlmostEqual(tb.piece_profile([(1, 2, 0.0, 10.0, True)])[(1, 2)][2], 3600 / tb.PACE_MIN_KMH)

    def test_too_few_pieces_publish_nothing(self):
        self.pieces(tb.TYPICAL_MIN_PIECES - 1)
        self.assertEqual(tb.typical_buckets(self.conn, self.now), {})

    def test_one_driver_never_becomes_typical(self):
        """Пять кусков по одному — пять дней одного человека: без двух
        кусков в одном окне ребро в «обычно» не попадает."""
        for day in range(tb.TYPICAL_MIN_PIECES):
            self.pieces(1, at=self.now + day * 7 * 86400, shared=False)
            tb.mark_shared(self.conn, self.now + day * 7 * 86400)
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM traffic_shared").fetchone()[0], 0)
        self.assertEqual(tb.typical_buckets(self.conn, self.now + 28 * 86400), {})

    def test_enough_shared_pieces_publish_in_their_hour(self):
        self.pieces(tb.TYPICAL_MIN_PIECES)
        buckets = tb.typical_buckets(self.conn, self.now)
        self.assertEqual(set(buckets), {self.bucket()})
        edges = buckets[self.bucket()]
        self.assertGreater(len(edges), 5)
        for edge in edges:
            self.assertEqual(len(edge), 5)
            self.assertTrue(tb.PACE_MIN_KMH <= edge[4] <= tb.MAX_KMH)

    def test_weekdays_add_up_in_one_file(self):
        """Понедельник и среда в один час — один файл, порог по сумме
        (эффективных кусков: двухдневные весят 0,96)."""
        monday_like = self.now
        self.pieces(3, at=monday_like)
        other = monday_like + 2 * 86400 if tb.hour_of_week(monday_like) // 24 < 3 else monday_like - 2 * 86400
        self.assertEqual(tb.bucket_name(tb.hour_of_week(other)), self.bucket())
        self.assertEqual(tb.typical_buckets(self.conn, max(monday_like, other)), {}, "одного дня мало")
        self.pieces(3, at=other)
        self.assertIn(self.bucket(), tb.typical_buckets(self.conn, max(monday_like, other)))

    def test_files_carry_nothing_but_edges(self):
        self.pieces(tb.TYPICAL_MIN_PIECES)
        written = tb.write_typical(self.conn, self.now, directory=self.out)
        self.assertEqual(written, 48, "пустой час — файл с пустыми рёбрами, а не 404")
        body = self.read(self.bucket())
        self.assertEqual(set(body), {"v", "bucket", "generated", "edges"})
        self.assertEqual(body["bucket"], self.bucket())
        self.assertTrue(body["edges"])
        for edge in body["edges"]:
            self.assertEqual(len(edge), 5)
            self.assertTrue(all(isinstance(x, (int, float)) for x in edge))
        self.assertEqual(self.read("off-03" if self.bucket() != "off-03" else "wd-03")["edges"], [])
        raw = open(os.path.join(self.out, f"{self.bucket()}.json"), encoding="utf-8").read()
        for word in ("piece", "device", "trip", "ts"):
            self.assertNotIn(word, raw)

    def test_unchanged_files_are_not_rewritten(self):
        # С запасом над порогом: за пару часов пять кусков отстареют до 4,99.
        self.pieces(tb.TYPICAL_MIN_PIECES + 1)
        tb.write_typical(self.conn, self.now, directory=self.out)
        generated = self.read(self.bucket())["generated"]
        self.assertEqual(tb.write_typical(self.conn, self.now + 3600, directory=self.out), 0)
        self.assertEqual(self.read(self.bucket())["generated"], generated, "тот же файл — тот же ETag")
        self.pieces(1)   # такой же кусок — скорости те же, файл тот же
        self.assertEqual(tb.write_typical(self.conn, self.now + 5400, directory=self.out), 0)
        self.pieces(1, slower=3)
        self.assertGreaterEqual(tb.write_typical(self.conn, self.now + 7200, directory=self.out), 1)

    def test_corrupt_file_is_replaced(self):
        self.pieces(tb.TYPICAL_MIN_PIECES)
        with open(os.path.join(self.out, f"{self.bucket()}.json"), "w", encoding="utf-8") as f:
            f.write("{обрыв")
        tb.write_typical(self.conn, self.now, directory=self.out)
        self.assertTrue(self.read(self.bucket())["edges"])

    def test_rebuild_at_most_hourly(self):
        self.assertTrue(tb.typical_due(self.conn, self.now))
        tb.write_typical(self.conn, self.now, directory=self.out)
        self.assertFalse(tb.typical_due(self.conn, self.now + 120))
        self.assertTrue(tb.typical_due(self.conn, self.now + tb.TYPICAL_EVERY))

    def test_old_profile_table_is_migrated(self):
        conn = sqlite3.connect(":memory:")
        conn.execute("""CREATE TABLE traffic_profile(u INTEGER NOT NULL, v INTEGER NOT NULL,
                        how INTEGER NOT NULL, n INTEGER NOT NULL, sum_kmh REAL NOT NULL,
                        PRIMARY KEY(u, v, how))""")
        conn.execute("INSERT INTO traffic_profile VALUES(1, 2, 8, 7, 280.0)")
        tb.schema(conn)
        tb.schema(conn)   # повторный запуск cron — без ошибок
        self.assertEqual(conn.execute("SELECT n, pieces, sum_pace FROM traffic_profile").fetchone(), (7, 0, 0.0),
                         "старые строки в «обычно» не идут: у них нет кусков")
        conn.close()


H = tb.PROFILE_HALF_LIFE


class AgingTest(ProfileFixture, unittest.TestCase):
    """«Обычно» стареет (14.4): полураспад, порог в эффективных кусках,
    уборка, перевод к новой метке и срок отметки «не один человек».
    self.now + k·H — тот же час недели (H = 5 недель)."""

    def test_scale_doubles_every_half_life(self):
        self.assertEqual(tb.decay_scale(self.now, self.now), 1.0)
        self.assertAlmostEqual(tb.decay_scale(self.now, self.now + H), 2.0)
        self.assertAlmostEqual(tb.decay_scale(self.now, self.now + 3 * H), 8.0)
        self.assertAlmostEqual(tb.decay_scale(self.now, self.now - H), 0.5, msg="часы назад — не авария")
        self.assertEqual(tb.hour_of_week(self.now + 8 * H), tb.hour_of_week(self.now))

    def test_piece_weighs_half_after_a_half_life(self):
        self.pieces(4)
        for value in self.effective(self.now).values():
            self.assertAlmostEqual(value, 4.0)
        for value in self.effective(self.now + H).values():
            self.assertAlmostEqual(value, 2.0)
        for value in self.effective(self.now + 2 * H).values():
            self.assertAlmostEqual(value, 1.0)

    def test_threshold_counts_effective_pieces(self):
        """Пять кусков пять недель назад — 2,5 эффективных: в файле их нет,
        хотя настоящих пять. Три свежих добирают до 5,5."""
        self.pieces(tb.TYPICAL_MIN_PIECES)
        self.assertIn(self.bucket(), tb.typical_buckets(self.conn, self.now))
        self.assertEqual(tb.typical_buckets(self.conn, self.now + H), {})
        self.pieces(3, at=self.now + H)
        self.assertIn(self.bucket(), tb.typical_buckets(self.conn, self.now + H))
        for value in self.effective(self.now + H).values():
            self.assertAlmostEqual(value, 5.5)

    def test_effective_never_exceeds_real_pieces(self):
        """Вес куска ≤ 1, поэтому старение порог только ужесточает."""
        moments = [self.now, self.now + 3 * 86400, self.now + 7 * 86400, self.now + 40 * 86400]
        for at in moments:
            self.pieces(1, at=at, shared=False)
        for (_, _, how), value in self.effective(moments[-1]).items():
            real = sum(1 for at in moments if tb.profile_slot(at) == how)
            self.assertLessEqual(value, real + 1e-9)

    def test_rebuilt_road_shows_through(self):
        """Дорогу перестроили: шесть медленных кусков два полураспада назад
        весят вчетверо меньше шести новых — «обычно» тянется к новой
        скорости, а не стоит на среднем за всю историю."""
        self.pieces(6, slower=3)
        later = self.now + 2 * H
        self.pieces(6, at=later)
        slow_points = [[lat, lon, t * 3, kmh] for lat, lon, t, kmh in FIXTURE["points"]]
        slow = tb.piece_profile(tb.edges_from_match(FIXTURE["response"], slow_points)[0])
        fast = tb.piece_profile(tb.edges_from_match(FIXTURE["response"], FIXTURE["points"])[0])
        nodes = dict(tb.edges_from_match(FIXTURE["response"], FIXTURE["points"])[1])
        published = {(round(e[0], 6), round(e[1], 6), round(e[2], 6), round(e[3], 6)): e[4]
                     for e in tb.typical_buckets(self.conn, later)[self.bucket()]}
        checked = 0
        for (u, v), (_, _, pace_fast) in fast.items():
            if u not in nodes or v not in nodes:
                continue
            key = tuple(round(x, 6) for x in (*nodes[u], *nodes[v]))
            if key not in published:
                continue
            pace_slow = slow[(u, v)][2]
            aged = 3600 / ((0.25 * pace_slow + pace_fast) / 1.25)
            flat = 3600 / ((pace_slow + pace_fast) / 2)
            self.assertAlmostEqual(published[key], min(tb.MAX_KMH, aged), places=6)
            if pace_slow > pace_fast:
                self.assertGreater(aged, flat, "новые данные перевешивают старые")
            checked += 1
        self.assertGreater(checked, 5)

    def test_maintenance_drops_dead_rows_and_keeps_live(self):
        tb.profile_epoch(self.conn, self.now)
        self.conn.executemany("INSERT INTO traffic_profile(u, v, how, n, sum_kmh, pieces, sum_pace) "
                              "VALUES(?, ?, ?, ?, ?, ?, ?)",
                              [(1, 2, 8, 1, 40.0, 1, 90.0),     # один кусок: 1/32 < 0,05
                               (1, 2, 9, 3, 120.0, 3, 270.0),   # три: 3/32 — ещё живая
                               (3, 4, 8, 7, 280.0, 0, 0.0)])    # строка до 8.8.16: n = 7
        self.conn.executemany("INSERT INTO traffic_shared(u, v, seen) VALUES(?, ?, ?)",
                              [(5, 6, self.now), (7, 8, self.now + 5 * H - 86400)])
        self.conn.commit()
        self.assertTrue(tb.maintain_profile(self.conn, self.now))
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM traffic_profile").fetchone()[0], 3)
        self.assertFalse(tb.maintain_profile(self.conn, self.now + 3600), "уборка — раз в сутки")
        self.assertTrue(tb.maintain_profile(self.conn, self.now + 5 * H))
        left = {row for row in self.conn.execute("SELECT u, v, how FROM traffic_profile")}
        self.assertEqual(left, {(1, 2, 9), (3, 4, 8)})
        shared = [row for row in self.conn.execute("SELECT u, v FROM traffic_shared")]
        self.assertEqual(shared, [(7, 8)])
        self.assertTrue(tb.maintain_profile(self.conn, self.now + 7 * H))
        self.assertEqual([row for row in self.conn.execute("SELECT u, v, how FROM traffic_profile")],
                         [(3, 4, 8)], "строка до 8.8.16 живёт, пока не отстареет её n (7/128)")
        self.assertTrue(tb.maintain_profile(self.conn, self.now + 8 * H))
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM traffic_profile").fetchone()[0], 0,
                         "7/256 < 0,05 — и её нет")

    def test_renormalization_changes_nothing_visible(self):
        """Раз в PROFILE_RENORM_AFTER суммы переводятся к метке «сейчас»: те
        же рёбра, та же скорость, а числа в базе — снова около настоящих."""
        self.pieces(6)
        later = self.now + tb.PROFILE_RENORM_AFTER
        self.pieces(6, at=later)
        before = tb.typical_buckets(self.conn, later)
        self.assertTrue(before)
        self.assertTrue(tb.maintain_profile(self.conn, later))
        self.assertEqual(tb.profile_epoch(self.conn, later), later)
        after = tb.typical_buckets(self.conn, later)
        self.assertEqual(set(after), set(before))
        for name in before:
            self.assertEqual(len(after[name]), len(before[name]))
            for a, b in zip(after[name], before[name]):
                self.assertEqual(a[:4], b[:4])
                self.assertAlmostEqual(a[4], b[4], places=6)
        stored = [row[0] for row in self.conn.execute("SELECT pieces FROM traffic_profile")]
        for value in stored:
            self.assertAlmostEqual(value, 6 + 6 / 256)

    def test_shared_mark_expires(self):
        """Двое проехали улицу однажды, дальше ездит один: пока отметка
        свежая — улица в файле, через SHARED_TTL без второго водителя — нет,
        хотя кусков у неё хватает. Снова проехали двое — снова в файле."""
        self.pieces(2)                                         # двое в одном окне
        lone = self.now + tb.SHARED_TTL - 2 * 3600
        self.pieces(8, at=lone, shared=False)                  # дальше — один человек
        self.assertTrue(tb.typical_buckets(self.conn, self.now + tb.SHARED_TTL - 3600))
        self.assertEqual(tb.typical_buckets(self.conn, self.now + tb.SHARED_TTL + 3600), {},
                         "давнее «не один» не прикрывает данные одного человека")
        again = self.now + tb.SHARED_TTL + 3600
        self.pieces(2, at=again)
        self.assertTrue(tb.typical_buckets(self.conn, again))
        seen = {row[0] for row in self.conn.execute("SELECT seen FROM traffic_shared")}
        self.assertEqual(seen, {again}, "отметка обновилась")


# Схема traffic.db, как её оставляет 8.8.16 (cbbe5e1) — то, что лежит на VPS.
SCHEMA_8_8_16 = (
    """CREATE TABLE traffic_pieces(id INTEGER PRIMARY KEY AUTOINCREMENT,
        received REAL NOT NULL, points TEXT NOT NULL)""",
    """CREATE TABLE traffic_samples(u INTEGER NOT NULL, v INTEGER NOT NULL,
        kmh REAL NOT NULL, weight REAL NOT NULL, ts REAL NOT NULL, piece INTEGER NOT NULL)""",
    "CREATE INDEX traffic_samples_ts ON traffic_samples(ts)",
    "CREATE TABLE traffic_nodes(id INTEGER PRIMARY KEY, lat REAL NOT NULL, lon REAL NOT NULL)",
    """CREATE TABLE traffic_edges(u INTEGER NOT NULL, v INTEGER NOT NULL, model_kmh REAL NOT NULL,
        PRIMARY KEY(u, v))""",
    """CREATE TABLE traffic_profile(u INTEGER NOT NULL, v INTEGER NOT NULL, how INTEGER NOT NULL,
        n INTEGER NOT NULL, sum_kmh REAL NOT NULL, pieces INTEGER NOT NULL DEFAULT 0,
        sum_pace REAL NOT NULL DEFAULT 0, PRIMARY KEY(u, v, how))""",
    "CREATE TABLE traffic_shared(u INTEGER NOT NULL, v INTEGER NOT NULL, PRIMARY KEY(u, v))",
    "CREATE TABLE traffic_meta(key TEXT PRIMARY KEY, value REAL NOT NULL)",
)


class MigrationTest(unittest.TestCase):
    """Первый прогон нового сборщика на базе, которую оставил 8.8.16."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.db = os.path.join(self.dir, "traffic.db")
        self.out = os.path.join(self.dir, "www", "now.json")
        self.typical = os.path.join(self.dir, "www", "typical")
        self.now = 1_760_000_000.0
        conn = sqlite3.connect(self.db)
        for statement in SCHEMA_8_8_16:
            conn.execute(statement)
        # Профиль 8.8.16: по 6 кусков на рёбрах фикстуры в этот час, их
        # узлы, вечные отметки «не один» и вчерашняя пересборка «обычно».
        samples, nodes, models = tb.edges_from_match(FIXTURE["response"], FIXTURE["points"])
        self.profile = tb.piece_profile(samples)
        how = tb.profile_slot(self.now)
        conn.executemany("INSERT INTO traffic_profile VALUES(?, ?, ?, ?, ?, ?, ?)",
                         [(u, v, how, 6 * count, 6 * total, 6, 6 * pace)
                          for (u, v), (count, total, pace) in self.profile.items()])
        conn.executemany("INSERT INTO traffic_shared VALUES(?, ?)", list(self.profile))
        conn.executemany("INSERT INTO traffic_nodes VALUES(?, ?, ?)",
                         [(i, lat, lon) for i, (lat, lon) in nodes.items()])
        conn.executemany("INSERT INTO traffic_edges VALUES(?, ?, ?)",
                         [(u, v, kmh) for (u, v), kmh in models.items()])
        conn.executemany("INSERT INTO traffic_samples VALUES(?, ?, ?, ?, ?, ?)",
                         [(u, v, kmh, w, self.now - 60, 900) for u, v, kmh, w, _ in samples[:5]])
        conn.execute("INSERT INTO traffic_meta VALUES('typical_built', ?)", (self.now - 86400,))
        conn.commit()
        conn.close()

    def tearDown(self):
        for root, dirs, files in os.walk(self.dir, topdown=False):
            for name in files:
                os.unlink(os.path.join(root, name))
            for name in dirs:
                os.rmdir(os.path.join(root, name))
        os.rmdir(self.dir)

    def run_builder(self, now, pending=0):
        conn = sqlite3.connect(self.db)
        try:
            for _ in range(pending):
                conn.execute("INSERT INTO traffic_pieces(received, points) VALUES(?, ?)",
                             (now, json.dumps(FIXTURE["points"])))
            conn.commit()
            return tb.run(conn, now, matcher=lambda pts: FIXTURE["response"],
                          out_path=self.out, typical_dir=self.typical)
        finally:
            conn.close()

    def typical_edges(self, now):
        name = tb.bucket_name(tb.profile_slot(now))
        with open(os.path.join(self.typical, f"{name}.json"), encoding="utf-8") as f:
            return json.load(f)["edges"]

    def test_first_run_on_the_8_8_16_database(self):
        result = self.run_builder(self.now)
        self.assertEqual(result[3], 48, "первый прогон пишет все 48 файлов")
        self.run_builder(self.now + 120)                       # и второй — без ошибок схемы
        conn = sqlite3.connect(self.db)
        try:
            columns = {row[1] for row in conn.execute("PRAGMA table_info(traffic_shared)")}
            self.assertIn("seen", columns)
            columns = {row[1] for row in conn.execute("PRAGMA table_info(traffic_samples)")}
            self.assertIn("passed", columns)
            self.assertEqual(conn.execute("SELECT DISTINCT passed FROM traffic_samples WHERE piece = 900")
                             .fetchall(), [(0,)], "сэмплы до выкладки — не свидетели")
            self.assertEqual(tb.profile_epoch(conn, self.now + 120), self.now,
                             "метка — первый прогон после выкладки")
            self.assertEqual(conn.execute("SELECT COUNT(*) FROM traffic_shared").fetchone()[0], 0,
                             "отметки без времени не в счёт и убраны")
            pieces = {row[0] for row in conn.execute("SELECT pieces FROM traffic_profile")}
            self.assertEqual(pieces, {6}, "накопленный профиль сохранён как есть")
        finally:
            conn.close()
        self.assertTrue(os.path.getsize(self.out) > 0)
        self.assertEqual(self.typical_edges(self.now), [],
                         "до нового подтверждения «не один» старые рёбра не публикуются")

    def test_old_profile_comes_back_once_two_drivers_confirm(self):
        self.run_builder(self.now)
        self.run_builder(self.now + 120, pending=2)            # двое в одном окне
        self.run_builder(self.now + tb.TYPICAL_EVERY + 120)
        edges = self.typical_edges(self.now)
        self.assertTrue(edges)
        # Скорость — старые 6 и новые 2 куска одной скорости: та же, что у
        # фикстуры (масштаб сокращается).
        nodes = tb.edges_from_match(FIXTURE["response"], FIXTURE["points"])[1]
        expected = {}
        for (u, v), (_, _, pace) in self.profile.items():
            if u in nodes and v in nodes:
                expected[tuple(round(x, 5) for x in (*nodes[u], *nodes[v]))] = int(round(3600 / pace))
        for edge in edges:
            self.assertEqual(edge[4], expected[tuple(edge[:4])])


SWIFT_HOLIDAYS = os.path.join(HERE, "..", "RadarMap", "Models", "UzHolidays.swift")


def tashkent_ts(year, month, day, hour, minute=0):
    """Момент по ташкентским часам (UTC+5) как unix-время."""
    return calendar.timegm((year, month, day, hour, minute, 0)) - tb.TASHKENT_UTC_OFFSET


def swift_holiday_lists():
    """(fixed, moving) из UzHolidays.swift: телефон и сервер обязаны делить
    один список — иначе файл «обычно» праздника собран не из тех дней,
    которые телефон в нём ищет."""
    source = open(SWIFT_HOLIDAYS, encoding="utf-8").read()
    source = re.sub(r"//[^\n]*", "", source)
    pair = re.compile(r"\((\d+),\s*(\d+)\)")
    fixed_block = re.search(r"static let fixed[^=]*=\s*\[(.*?)\]\s*\n", source, re.S).group(1)
    fixed = tuple((int(m), int(d)) for m, d in pair.findall(fixed_block))
    moving_block = re.search(r"static let moving[^=]*=\s*\[(.*?)\n\s*\]", source, re.S).group(1)
    moving = {int(year): tuple((int(m), int(d)) for m, d in pair.findall(days))
              for year, days in re.findall(r"(\d{4}):\s*\[([^\]]*)\]", moving_block)}
    return fixed, moving


class HolidayTest(unittest.TestCase):
    """Праздник — выходной класс «обычно», как у телефона (UzHolidays)."""

    def test_lists_match_the_phone(self):
        if not os.path.exists(SWIFT_HOLIDAYS):
            self.skipTest("нет исходника телефона рядом (запуск вне репозитория)")
        fixed, moving = swift_holiday_lists()
        self.assertEqual(len(fixed), 7, "разбор UzHolidays.fixed")
        self.assertEqual(fixed, tb.HOLIDAYS_FIXED)
        self.assertEqual(moving, tb.HOLIDAYS_MOVING)

    def test_days_match_the_phone_tests(self):
        """Те же даты, что UzHolidaysTests: перенос с выходного на ближайший
        рабочий день, один перенос на праздник, год вне списка."""
        def holiday(year, month, day):
            return month * 100 + day in tb.holidays(year)

        for m, d in [(1, 1), (3, 8), (3, 9), (3, 20), (3, 21), (3, 23), (5, 9), (5, 11),
                     (5, 27), (5, 28), (5, 29), (9, 1), (10, 1), (12, 8)]:
            self.assertTrue(holiday(2026, m, d), f"2026-{m}-{d}")
        for m, d in [(3, 24), (5, 26), (6, 1), (9, 2), (10, 20)]:
            self.assertFalse(holiday(2026, m, d), f"будний 2026-{m}-{d}")
        for m, d in [(1, 1), (3, 8), (3, 9), (3, 21), (3, 22), (5, 9), (5, 10), (5, 16), (5, 17),
                     (9, 1), (10, 1), (12, 8)]:
            self.assertTrue(holiday(2027, m, d), f"2027-{m}-{d}")
        self.assertFalse(holiday(2027, 3, 10))
        self.assertFalse(holiday(2027, 5, 18))
        for m, d in [(1, 1), (1, 3), (2, 26), (2, 28), (3, 8), (3, 21), (5, 5), (5, 9), (9, 1),
                     (10, 1), (12, 8)]:
            self.assertTrue(holiday(2028, m, d), f"2028-{m}-{d}")
        self.assertFalse(holiday(2028, 2, 29), "один перенос на один праздник")
        self.assertTrue(holiday(2030, 1, 1))
        self.assertTrue(holiday(2030, 3, 21))
        self.assertFalse(holiday(2030, 3, 20))

    def test_date_is_tashkent_whatever_the_server_zone(self):
        """23.03.2026 (перенос Навруза, понедельник) начинается в Ташкенте в
        19:00 UTC воскресенья; часовой пояс сервера роли не играет."""
        saved = os.environ.get("TZ")
        try:
            os.environ["TZ"] = "America/New_York"
            if hasattr(time, "tzset"):
                time.tzset()
            self.assertTrue(tb.is_holiday(tashkent_ts(2026, 3, 23, 0, 30)))
            self.assertFalse(tb.is_holiday(tashkent_ts(2026, 3, 22, 23, 30)),
                             "воскресенье 22-го — не праздник: перенос лёг на понедельник")
            self.assertFalse(tb.is_holiday(tashkent_ts(2026, 3, 24, 0, 30)), "вторник 24-го — будни")
            self.assertTrue(tb.is_holiday(tashkent_ts(2026, 5, 28, 8, 30)))
        finally:
            if saved is None:
                os.environ.pop("TZ", None)
            else:
                os.environ["TZ"] = saved
            if hasattr(time, "tzset"):
                time.tzset()

    def test_slots_and_buckets(self):
        thursday = tashkent_ts(2026, 5, 28, 8, 30)       # Курбан хайит, доп. нерабочий день
        self.assertEqual(tb.hour_of_week(thursday), 3 * 24 + 8)
        self.assertEqual(tb.profile_slot(thursday), tb.HOLIDAY_SLOT + 3 * 24 + 8)
        self.assertEqual(tb.bucket_name(tb.profile_slot(thursday)), "off-08")
        workday = tashkent_ts(2026, 10, 20, 8, 30)       # обычный вторник
        self.assertEqual(tb.profile_slot(workday), tb.hour_of_week(workday))
        self.assertEqual(tb.bucket_name(tb.profile_slot(workday)), "wd-08")
        for how in range(2 * tb.HOLIDAY_SLOT):
            self.assertIn(tb.bucket_name(how), tb.ALL_BUCKETS)

    def test_holiday_piece_goes_to_days_off(self):
        tmp = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        conn = sqlite3.connect(tmp.name)
        try:
            tb.schema(conn)
            at = tashkent_ts(2026, 5, 28, 8, 30)
            for _ in range(tb.TYPICAL_MIN_PIECES):
                conn.execute("INSERT INTO traffic_pieces(received, points) VALUES(?, ?)",
                             (at, json.dumps(FIXTURE["points"])))
            conn.commit()
            tb.process(conn, at, matcher=lambda pts: FIXTURE["response"])
            tb.mark_shared(conn, at)
            buckets = tb.typical_buckets(conn, at)
            self.assertEqual(set(buckets), {"off-08"}, "праздничный четверг — не будни")
        finally:
            conn.close()
            os.unlink(tmp.name)


class PureTest(unittest.TestCase):
    def test_levels(self):
        self.assertEqual(tb.level(10, 60), 3)
        self.assertEqual(tb.level(30, 60), 2)
        self.assertEqual(tb.level(50, 60), 1)
        self.assertIsNone(tb.level(50, 0))

    def test_weighted_median(self):
        self.assertEqual(tb.weighted_median([(10, 1), (50, 1), (60, 5)]), 60)
        self.assertEqual(tb.weighted_median([(10, 3), (50, 1)]), 10)
        self.assertIsNone(tb.weighted_median([]))

    def test_hour_of_week_is_tashkent_local(self):
        # 2026-10-12 03:30 UTC — понедельник 08:30 в Ташкенте.
        self.assertEqual(tb.hour_of_week(1_791_775_800), 8)


if __name__ == "__main__":
    unittest.main()
