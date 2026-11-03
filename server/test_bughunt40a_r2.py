"""Повторное ревью 40a: повтор доставленной отметки и устаревшее слияние в /api/mine."""
import sqlite3
import time
import unittest

import api
from test_api import ServerTestBase, _call


def _post(port, lat, lon, rtype="tripod", device="me", ip="10.80.0.1", **extra):
    body = {"lat": lat, "lon": lon, "device": device, "type": rtype, "fresh": True}
    body.update(extra)
    return _call(port, "POST", "/api/report", body, ip=ip)


class Retry(ServerTestBase):

    def test_retry_of_a_delivered_report_is_not_refused(self):
        """Живая отметка: ответ потерян по таймауту, сервер точку создал.
        Клиент кладёт её в очередь и через 20 с досылает ту же отметку
        (тот же at → age 20). Сервер отвечает 429 «too fast» (пауза теперь
        от observed, а у повтора тот же момент), и клиент с 49ac2a03 говорит
        водителю «Отметка не ушла», хотя точка на карте."""
        s1, first = _post(self.port, 41.3100, 69.2500)
        self.assertEqual(s1, 200)
        s2, again = _post(self.port, 41.3100, 69.2500, age=20)
        self.assertEqual(s2, 200, f"повтор доставленной отметки отвергнут: {again}")
        self.assertEqual(again.get("id"), first["id"])


class StaleCounts(ServerTestBase):

    def test_stale_merge_is_not_a_confirmation_in_mine(self):
        """Устаревшее (из очереди, 40 мин) слияние не подтверждение для
        /api/mobile — а /api/mine и telegram_publish считают его."""
        _, a = _post(self.port, 41.3100, 69.2500, device="a", ip="10.81.0.1")
        _post(self.port, 41.3101, 69.2500, device="b", ip="10.81.0.2", age=40 * 60)
        _, mine = _call(self.port, "POST", "/api/mine", {"device": "a"}, ip="10.81.0.1")
        got = {r["id"]: r["confirmers"] for r in mine["reports"]}
        self.assertEqual(got.get(a["id"]), 0, "устаревшее слияние засчитано подтверждением")


if __name__ == "__main__":
    unittest.main()


class MigrateStrict(ServerTestBase):

    def test_migrate_raises_on_anything_but_duplicate_column(self):
        """Занятая или сломанная база при старте — громкий отказ, а не схема
        без новой колонки и 500 на каждой отметке."""
        conn = sqlite3.connect(api.DB_PATH)
        try:
            api.migrate(conn, "reports", "observed REAL DEFAULT 0")     # уже есть — тихо
            with self.assertRaises(sqlite3.OperationalError):
                api.migrate(conn, "no_such_table", "x INTEGER")
        finally:
            conn.close()
