#!/usr/bin/env python3
"""Тесты сборки горячих точек. Без базы и сети — только чистая логика.

Проверяется в основном то, чего происходить НЕ должно: один упорный водитель
не создаёт горячую точку, устройство не набирает кворум само себе через смену
UUID, наружу не уходит ничего, по чему восстанавливается маршрут.

    python3 test_build_hotspots.py
"""
import json
import os
import sqlite3
import tempfile
import unittest

import build_hotspots as bh

#: Опорное время — фиксировано, чтобы «дни» и «четверти суток» не зависели
#: от того, когда запускают тесты.
NOW = 1_800_000_000.0
DAY = 86400.0


def report(lat=41.31, lon=69.28, days_ago=1.0, device="a", ip="1.1.1.1"):
    return (lat, lon, NOW - days_ago * DAY, device, ip)


class ClusterTests(unittest.TestCase):
    def test_close_points_merge(self):
        rows = [report(lon=69.2800), report(lon=69.2805), report(lon=69.2810)]
        clusters = bh.cluster(rows)
        self.assertEqual(len(clusters), 1)
        self.assertEqual(clusters[0]["n"], 3)

    def test_far_points_stay_separate(self):
        rows = [report(lon=69.280), report(lon=69.300)]
        self.assertEqual(len(bh.cluster(rows)), 2)

    def test_centre_is_running_average_not_first_point(self):
        rows = [report(lat=41.3100), report(lat=41.3110), report(lat=41.3120)]
        centre = bh.cluster(rows)[0]["lat"]
        self.assertAlmostEqual(centre, 41.3110, places=4)


class ThresholdTests(unittest.TestCase):
    def test_one_stubborn_driver_makes_no_hotspot(self):
        """Главная защита: один человек, отмечающий одно место каждый день,
        не должен заставить приложение врать всему городу."""
        rows = [report(days_ago=d, device="a", ip="1.1.1.1") for d in (1, 2, 3, 4, 5)]
        self.assertEqual(bh.spots(bh.cluster(rows)), [])

    def test_one_device_rotating_uuid_does_not_reach_quorum(self):
        """Смена анонимного UUID раз в 30 дней не должна давать кворум:
        адрес остаётся тем же, и по нему видно, что это один и тот же человек."""
        rows = [report(days_ago=d, device=f"dev{d}", ip="1.1.1.1") for d in (1, 2, 3, 4)]
        self.assertEqual(bh.spots(bh.cluster(rows)), [])

    def test_three_reports_from_two_independent_drivers_pass(self):
        rows = [report(days_ago=1, device="a", ip="1.1.1.1"),
                report(days_ago=2, device="b", ip="2.2.2.2"),
                report(days_ago=3, device="a", ip="1.1.1.1")]
        result = bh.spots(bh.cluster(rows))
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["n"], 3)
        self.assertEqual(result[0]["days"], 3)

    def test_two_reports_are_not_enough(self):
        rows = [report(days_ago=1, device="a", ip="1.1.1.1"),
                report(days_ago=2, device="b", ip="2.2.2.2")]
        self.assertEqual(bh.spots(bh.cluster(rows)), [])

    def test_empty_ip_is_not_counted_as_an_address(self):
        """Строки старого сервера без ip не должны сходить за независимые."""
        rows = [report(days_ago=d, device=f"dev{d}", ip="") for d in (1, 2, 3)]
        self.assertEqual(bh.spots(bh.cluster(rows)), [])


class PeakTests(unittest.TestCase):
    def _rows_at_quarter(self, q, count):
        # Середина нужной четверти суток по местному времени.
        base = NOW - (NOW + bh.TZ_OFFSET) % DAY   # местная полночь в метках UTC
        hour = q * 6 + 3
        return [(41.31, 69.28, base + hour * 3600 - i * DAY,
                 f"dev{i}", f"{i}.{i}.{i}.{i}") for i in range(count)]

    def test_dominant_quarter_is_reported(self):
        rows = self._rows_at_quarter(1, 4)          # утро
        self.assertEqual(bh.spots(bh.cluster(rows))[0]["peak"], 1)

    def test_flat_distribution_reports_no_peak(self):
        rows = (self._rows_at_quarter(0, 2) + self._rows_at_quarter(2, 2))
        rows = [(lat, lon, created, f"d{i}", f"{i}.0.0.1")
                for i, (lat, lon, created, _, _) in enumerate(rows)]
        self.assertEqual(bh.spots(bh.cluster(rows))[0]["peak"], -1)


class PayloadTests(unittest.TestCase):
    def test_payload_carries_no_identifiers(self):
        """Контракт наружу: координата, счётчики, четверть суток — и ничего,
        по чему можно собрать чей-то маршрут."""
        rows = [report(days_ago=1, device="secret-device", ip="8.8.8.8"),
                report(days_ago=2, device="other", ip="9.9.9.9"),
                report(days_ago=3, device="secret-device", ip="8.8.8.8")]
        raw = json.dumps(bh.build(rows, now=NOW), ensure_ascii=False)
        for leak in ("secret-device", "other", "8.8.8.8", "9.9.9.9", "device", "ip"):
            self.assertNotIn(leak, raw, f"в payload утекло «{leak}»")
        self.assertIn('"spots"', raw)

    def test_payload_shape(self):
        rows = [report(days_ago=1, device="a", ip="1.1.1.1"),
                report(days_ago=2, device="b", ip="2.2.2.2"),
                report(days_ago=3, device="c", ip="3.3.3.3")]
        payload = bh.build(rows, now=NOW)
        self.assertEqual(payload["version"], 1)
        self.assertEqual(payload["window_days"], bh.WINDOW_DAYS)
        spot = payload["spots"][0]
        self.assertEqual(sorted(spot), ["days", "lat", "lon", "n", "pdays", "peak", "src"])

    def test_spots_sorted_by_weight(self):
        strong = [report(lon=69.28, days_ago=d, device=f"d{d}", ip=f"{d}.0.0.1")
                  for d in range(1, 6)]
        weak = [report(lon=69.40, days_ago=d, device=f"w{d}", ip=f"{d}.0.1.1")
                for d in range(1, 4)]
        result = bh.spots(bh.cluster(strong + weak))
        self.assertEqual([s["n"] for s in result], [5, 3])


class HabitTests(unittest.TestCase):
    """Пункт 82: src и pdays — по ним телефон предупреждает заранее."""

    def _evening(self, days, ips):
        base = NOW - (NOW + bh.TZ_OFFSET) % DAY
        return [(41.31, 69.28, base + 20 * 3600 - d * DAY, f"dev{i}", ip)
                for i, (d, ip) in enumerate(zip(days, ips))]

    def test_peak_days_count_distinct_days_in_the_peak_quarter(self):
        rows = self._evening([1, 1, 2, 3], ["1.1.1.1", "2.2.2.2", "3.3.3.3", "4.4.4.4"])
        spot = bh.spots(bh.cluster(rows))[0]
        self.assertEqual(spot["peak"], 3)
        self.assertEqual(spot["pdays"], 3, "два наблюдения в один вечер — один день")
        self.assertEqual(spot["src"], 4)

    def test_sources_are_capped(self):
        rows = self._evening(range(1, 15), [f"{i}.0.0.1" for i in range(1, 15)])
        self.assertEqual(bh.spots(bh.cluster(rows))[0]["src"], bh.SOURCES_CAP)

    def test_no_peak_means_no_peak_days(self):
        base = NOW - (NOW + bh.TZ_OFFSET) % DAY
        rows = [(41.31, 69.28, base + (q * 6 + 3) * 3600 - q * DAY, f"d{q}", f"{q}.1.1.1")
                for q in range(4)]
        spot = bh.spots(bh.cluster(rows))[0]
        self.assertEqual((spot["peak"], spot["pdays"]), (-1, 0))

    def test_history_moment_keeps_day_and_quarter(self):
        for day, q in ((20_000, 0), (20_001, 3)):
            moment = bh.history_moment(day, q)
            self.assertEqual((bh.day_key(moment), bh.quarter(moment)), (day, q))


class LoadTests(unittest.TestCase):
    """Источник наблюдений: живые отметки, их «Стоит» и история погасших."""

    def setUp(self):
        handle, self.path = tempfile.mkstemp(suffix=".db")
        os.close(handle)
        conn = sqlite3.connect(self.path)
        conn.executescript("""
            CREATE TABLE reports(id INTEGER PRIMARY KEY, lat REAL, lon REAL, created REAL,
                observed REAL DEFAULT 0, type TEXT, device TEXT, ip TEXT, closed TEXT DEFAULT '');
            CREATE TABLE votes(report_id INTEGER, device TEXT, value INTEGER, ts REAL,
                ip TEXT, stale INTEGER DEFAULT 0);
            CREATE TABLE report_history(lat REAL, lon REAL, type TEXT, day INTEGER,
                quarter INTEGER, device TEXT, ip TEXT, kind TEXT);""")
        t = NOW - DAY
        conn.execute("INSERT INTO reports VALUES(1, 41.31, 69.28, ?, 0, 'tripod', 'a', '1.1.1.1', '')", (t,))
        conn.execute("INSERT INTO reports VALUES(2, 41.31, 69.28, ?, 0, 'tripod', 'x', '9.9.9.9', 'author')", (t,))
        conn.execute("INSERT INTO reports VALUES(3, 41.31, 69.28, ?, 0, 'post', 'p', '8.8.8.8', '')", (t,))
        conn.execute("INSERT INTO votes VALUES(1, 'b', 1, ?, '2.2.2.2', 0)", (t + 60,))
        conn.execute("INSERT INTO votes VALUES(1, 'a', 1, ?, '1.1.1.1', 0)", (t + 90,))
        conn.execute("INSERT INTO votes VALUES(1, 'c', 1, ?, '3.3.3.3', 1)", (t + 99,))
        day = int((NOW + bh.TZ_OFFSET) // DAY) - 10
        conn.execute("INSERT INTO report_history VALUES(41.31, 69.28, 'tripod', ?, 3, 'h', '4.4.4.4', 'report')",
                     (day,))
        conn.execute("INSERT INTO report_history VALUES(41.31, 69.28, 'tripod', ?, 3, 'old', '5.5.5.5', 'report')",
                     (day - bh.WINDOW_DAYS - 5,))
        conn.commit()
        conn.close()

    def tearDown(self):
        os.unlink(self.path)

    def test_load_takes_reports_fresh_votes_and_history(self):
        rows = bh.load(self.path, now=NOW)
        self.assertEqual(sorted(r[3] for r in rows), ["a", "b", "h"],
                         "отозванная, свой голос, несвежий голос, пост и старая история — не наблюдения")

    def test_database_without_history_still_loads(self):
        conn = sqlite3.connect(self.path)
        conn.execute("DROP TABLE report_history")
        conn.commit()
        conn.close()
        self.assertEqual(sorted(r[3] for r in bh.load(self.path, now=NOW)), ["a", "b"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
