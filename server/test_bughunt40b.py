"""Ревью 40b. PYTHONPATH=<worktree>/server python3 -m unittest test_bughunt40b"""
import unittest

from test_api import ServerTestBase, _call


class MobileCourse(ServerTestBase):

    def test_mobile_list_carries_reporter_course(self):
        """Клиент 40b (MobilePassWatch.crosses) ждёт курс отметившего в
        /api/mobile, а сервер отдаёт его только в /api/road (`if road:`):
        reportCourses всегда пуст, и вопрос «Тренога ещё стоит?» задаётся и
        поперечной улице, а её «Убрали» (не встречное — 90°) режет срок."""
        s, _ = _call(self.port, "POST", "/api/report",
                     {"lat": 41.31, "lon": 69.25, "device": "a", "type": "tripod",
                      "fresh": True, "course": 10}, ip="10.90.0.1")
        self.assertEqual(s, 200)
        _, listing = _call(self.port, "GET", "/api/mobile", None, ip="10.90.0.2")
        item = listing["reports"][0]
        self.assertEqual(item.get("course"), 10, f"курса нет в /api/mobile: {item}")

    def test_queued_report_age_is_from_the_tap(self):
        """Досланная из очереди тренога отмечена 40 мин назад: created в
        /api/mobile — момент отметки, а не приёма, иначе карточка и машина
        пишут «только что» (Н7)."""
        import time
        s, _ = _call(self.port, "POST", "/api/report",
                     {"lat": 41.32, "lon": 69.26, "device": "b", "type": "tripod",
                      "fresh": True, "age": 2400}, ip="10.90.0.3")
        self.assertEqual(s, 200)
        _, listing = _call(self.port, "GET", "/api/mobile", None, ip="10.90.0.4")
        item = listing["reports"][0]
        self.assertLess(item["created"], time.time() - 2300, f"возраст не от отметки: {item}")
        self.assertEqual(item.get("course"), -1, "курс неизвестен — -1, а не пропуск поля")


if __name__ == "__main__":
    unittest.main()
