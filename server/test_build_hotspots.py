#!/usr/bin/env python3
"""Тесты сборки горячих точек. Без базы и сети — только чистая логика.

Проверяется в основном то, чего происходить НЕ должно: один упорный водитель
не создаёт горячую точку, устройство не набирает кворум само себе через смену
UUID, наружу не уходит ничего, по чему восстанавливается маршрут.

    python3 test_build_hotspots.py
"""
import json
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
        self.assertEqual(sorted(spot), ["days", "lat", "lon", "n", "peak"])

    def test_spots_sorted_by_weight(self):
        strong = [report(lon=69.28, days_ago=d, device=f"d{d}", ip=f"{d}.0.0.1")
                  for d in range(1, 6)]
        weak = [report(lon=69.40, days_ago=d, device=f"w{d}", ip=f"{d}.0.1.1")
                for d in range(1, 4)]
        result = bh.spots(bh.cluster(strong + weak))
        self.assertEqual([s["n"] for s in result], [5, 3])


if __name__ == "__main__":
    unittest.main(verbosity=2)
