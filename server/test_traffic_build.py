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
        for u, v, kmh, weight in self.samples:
            self.assertIsInstance(u, int)
            self.assertIsInstance(v, int)
            self.assertNotEqual(u, v)
            self.assertTrue(0 <= kmh <= tb.MAX_KMH)
            self.assertGreater(weight, 0)

    def test_jam_part_of_the_trace_is_slower(self):
        speeds = sorted({round(kmh) for _, _, kmh, _ in self.samples})
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

    def test_low_confidence_and_errors_give_nothing(self):
        self.assertEqual(tb.edges_from_match({"code": "NoMatch"}, self.points), ([], {}, {}))
        weak = json.loads(json.dumps(FIXTURE["response"]))
        weak["matchings"][0]["confidence"] = 0.01
        self.assertEqual(tb.edges_from_match(weak, self.points)[0], [])


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


class TypicalTest(unittest.TestCase):
    """«Обычно по водителям» (8.8.16): traffic/typical/<класс>-<час>.json."""

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
        profile = tb.piece_profile([(1, 2, 50.0, 100.0), (1, 2, 5.0, 100.0)])
        count, total, pace = profile[(1, 2)]
        self.assertEqual(count, 2)
        self.assertAlmostEqual(total, 55.0)
        self.assertAlmostEqual(3600 / pace, 9.09, places=2)
        # Стоянка не делает темп бесконечным.
        self.assertAlmostEqual(tb.piece_profile([(1, 2, 0.0, 10.0)])[(1, 2)][2], 3600 / tb.PACE_MIN_KMH)

    def test_too_few_pieces_publish_nothing(self):
        self.pieces(tb.TYPICAL_MIN_PIECES - 1)
        self.assertEqual(tb.typical_buckets(self.conn), {})

    def test_one_driver_never_becomes_typical(self):
        """Пять кусков по одному — пять дней одного человека: без двух
        кусков в одном окне ребро в «обычно» не попадает."""
        for day in range(tb.TYPICAL_MIN_PIECES):
            self.pieces(1, at=self.now + day * 7 * 86400, shared=False)
            tb.mark_shared(self.conn, self.now + day * 7 * 86400)
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM traffic_shared").fetchone()[0], 0)
        self.assertEqual(tb.typical_buckets(self.conn), {})

    def test_enough_shared_pieces_publish_in_their_hour(self):
        self.pieces(tb.TYPICAL_MIN_PIECES)
        buckets = tb.typical_buckets(self.conn)
        self.assertEqual(set(buckets), {self.bucket()})
        edges = buckets[self.bucket()]
        self.assertGreater(len(edges), 5)
        for edge in edges:
            self.assertEqual(len(edge), 5)
            self.assertTrue(tb.PACE_MIN_KMH <= edge[4] <= tb.MAX_KMH)

    def test_weekdays_add_up_in_one_file(self):
        """Понедельник и среда в один час — один файл, порог по сумме."""
        monday_like = self.now
        self.pieces(3, at=monday_like)
        other = monday_like + 2 * 86400 if tb.hour_of_week(monday_like) // 24 < 3 else monday_like - 2 * 86400
        self.assertEqual(tb.bucket_name(tb.hour_of_week(other)), self.bucket())
        self.pieces(2, at=other)
        self.assertIn(self.bucket(), tb.typical_buckets(self.conn))

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
        self.pieces(tb.TYPICAL_MIN_PIECES)
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
            buckets = tb.typical_buckets(conn)
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
