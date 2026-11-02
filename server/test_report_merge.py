"""Отметки водителей: уточнение своей точки, слияние семей, гонка вставки.

Первые три теста — сценарии ловца багов (цикл 39), падали на main; остальные —
правила картографа (A1, A2)."""
import sqlite3
import threading
import time
import unittest

import api
from test_api import ServerTestBase, _call


class _Helpers:

    def _put(self, lat, lon, ago, rtype="radar", device="me", ip="10.39.0.1", cls="residential"):
        conn = sqlite3.connect(api.DB_PATH)
        now = time.time()
        cur = conn.execute(
            "INSERT INTO reports(lat, lon, created, expires, device, type, ip, cls, active) "
            "VALUES(?,?,?,?,?,?,?,?,1)",
            (lat, lon, now - ago, now + 3600, device, rtype, ip, cls))
        conn.commit()
        rid = cur.lastrowid
        conn.close()
        return rid

    def _type(self, rid):
        conn = sqlite3.connect(api.DB_PATH)
        row = conn.execute("SELECT type FROM reports WHERE id = ?", (rid,)).fetchone()
        conn.close()
        return row[0]

    def _active(self):
        conn = sqlite3.connect(api.DB_PATH)
        count = conn.execute("SELECT COUNT(*) FROM reports WHERE active = 1").fetchone()[0]
        conn.close()
        return count

    def _post(self, lat, lon, rtype="radar", device="me", ip="10.39.0.1", **extra):
        body = {"lat": lat, "lon": lon, "device": device, "type": rtype}
        body.update(extra)
        return _call(self.port, "POST", "/api/report", body, ip=ip)


class AmendTest(_Helpers, ServerTestBase):

    def test_refine_retypes_the_point_named_by_amend_id(self):
        """«Что это было? → Тренога» о свежей точке B переписывает B, а не
        свою же точку A четырьмя минутами раньше в 250 м."""
        a = self._put(41.3100, 69.2500, ago=240)
        status, b = self._post(41.31225, 69.2500, cls="residential")
        self.assertEqual(status, 200)
        self.assertFalse(b["merged"], "B должна быть новой точкой")
        status, amended = self._post(41.31225, 69.2500, "tripod", amend_id=b["id"])
        self.assertEqual(status, 200)
        self.assertEqual(amended["id"], b["id"], "уточнение ушло не в ту точку")
        self.assertEqual(self._type(b["id"]), "tripod")
        self.assertEqual(self._type(a), "radar", "чужая для уточнения точка A перекрашена")

    def test_post_after_radar_is_a_new_point(self):
        """Радар, через 2 мин в 350 м — пост из веера: две засады, а не
        пост поверх радара."""
        a = self._put(41.3100, 69.2500, ago=130)
        status, body = self._post(41.31315, 69.2500, "post")
        self.assertEqual(status, 200)
        self.assertNotIn("amended", body, "пост в 350 м переписал свой радар")
        self.assertEqual(self._type(a), "radar")

    def test_implicit_amend_only_for_a_fresh_point_close_by(self):
        """Без amend_id уточняется только своя точка не старше 60 с и не дальше
        150 м (старая плашка «Что это было?»)."""
        fresh = self._put(41.3100, 69.2500, ago=20)
        _, body = self._post(41.3105, 69.2500, "tripod")       # ~55 м
        self.assertTrue(body.get("amended"))
        self.assertEqual(body["id"], fresh)
        self.assertEqual(self._type(fresh), "tripod")

    def test_implicit_amend_window_is_sixty_seconds(self):
        old = self._put(41.3100, 69.2500, ago=70, rtype="tripod")
        # 70 с — ещё действует «120 с между отметками» (429), но не уточнение.
        _, body = self._post(41.3101, 69.2500, "post")
        self.assertNotIn("amended", body, "уточнение минутной давности")
        self.assertEqual(self._type(old), "tripod")

    def test_implicit_amend_radius_is_150_metres(self):
        near = self._put(41.3100, 69.2500, ago=10, rtype="tripod")
        status, body = self._post(41.3118, 69.2500, "accident")   # ~200 м
        self.assertNotIn("amended", body)
        self.assertEqual(self._type(near), "tripod")

    def test_amend_of_a_point_that_is_not_mine_is_refused(self):
        """Явное уточнение несуществующей, чужой или далёкой точки — 409, а не
        новая точка: уточнение не создаёт засад."""
        foreign = self._put(41.3100, 69.2500, ago=20, device="other", ip="10.39.0.9")
        status, _ = self._post(41.3100, 69.2500, "tripod", amend_id=foreign)
        self.assertEqual(status, 409)
        status, _ = self._post(41.3100, 69.2500, "tripod", amend_id=999_999)
        self.assertEqual(status, 409)
        self.assertEqual(self._active(), 1)
        self.assertEqual(self._type(foreign), "radar")


class FamilyMergeTest(_Helpers, ServerTestBase):

    def test_radar_next_to_a_tripod_confirms_it(self):
        """Быстрый «Радар!» у чужой треноги — подтверждение, а не вторая точка;
        тип остаётся точным."""
        tripod = self._put(41.3100, 69.2500, ago=600, rtype="tripod", device="a", ip="10.40.0.1")
        status, body = self._post(41.3102, 69.2500, "radar", device="b", ip="10.40.0.2")
        self.assertEqual(status, 200)
        self.assertTrue(body["merged"])
        self.assertEqual(body["id"], tripod)
        self.assertEqual(self._type(tripod), "tripod")
        self.assertEqual(self._active(), 1)

    def test_tripod_next_to_a_radar_refines_its_type(self):
        radar = self._put(41.3100, 69.2500, ago=600, rtype="radar", device="a", ip="10.40.1.1")
        _, body = self._post(41.3102, 69.2500, "tripod", device="b", ip="10.40.1.2")
        self.assertTrue(body["merged"])
        self.assertEqual(body["id"], radar)
        self.assertEqual(self._type(radar), "tripod", "точный тип не победил")

    def test_post_and_accident_stay_their_own_family(self):
        self._put(41.3100, 69.2500, ago=600, rtype="tripod", device="a", ip="10.40.2.1")
        _, post = self._post(41.3101, 69.2500, "post", device="b", ip="10.40.2.2")
        _, crash = self._post(41.3101, 69.2501, "accident", device="c", ip="10.40.2.3")
        self.assertFalse(post["merged"])
        self.assertFalse(crash["merged"])
        self.assertEqual(self._active(), 3)

    def test_merge_goes_to_the_nearest_point(self):
        """Две треноги на трассе в 300 м: отметка у второй подтверждает вторую,
        а не первую в выборке."""
        first = self._put(41.3100, 69.2500, ago=600, rtype="tripod", device="a",
                          ip="10.40.3.1", cls="trunk")
        second = self._put(41.3127, 69.2500, ago=600, rtype="tripod", device="b",
                           ip="10.40.3.2", cls="trunk")
        _, body = self._post(41.3125, 69.2500, "radar", device="c", ip="10.40.3.3", cls="trunk")
        self.assertTrue(body["merged"])
        self.assertEqual(body["id"], second, f"голос ушёл точке {first}, а не ближайшей")


class RaceTest(ServerTestBase):

    def test_two_drivers_at_once_make_one_point(self):
        """Два водителя жмут «Радар!» у одной треноги в одну секунду: одна
        точка с подтверждением, а не две рядом."""
        doubles = 0
        for round_ in range(30):
            conn = sqlite3.connect(api.DB_PATH)
            conn.execute("DELETE FROM reports")
            conn.execute("DELETE FROM votes")
            conn.commit()
            conn.close()
            with api._ip_lock:
                api._ip_counters.clear()
            gate = threading.Barrier(2)

            def tap(device, ip):
                gate.wait()
                _call(self.port, "POST", "/api/report",
                      {"lat": 41.3100, "lon": 69.2500, "device": device}, ip=ip)

            threads = [threading.Thread(target=tap, args=(f"d{round_}a", "10.39.1.1")),
                       threading.Thread(target=tap, args=(f"d{round_}b", "10.39.1.2"))]
            for t in threads:
                t.start()
            for t in threads:
                t.join()
            conn = sqlite3.connect(api.DB_PATH)
            count = conn.execute("SELECT COUNT(*) FROM reports WHERE active = 1").fetchone()[0]
            conn.close()
            if count > 1:
                doubles += 1
        self.assertEqual(doubles, 0, f"две точки вместо одной в {doubles} из 30 раундов")


if __name__ == "__main__":
    unittest.main()
