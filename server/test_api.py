#!/usr/bin/env python3
"""Тесты RadarMap API: поднимаем настоящий сервер на случайном порту с временной
БД и ходим в него HTTP-клиентом stdlib. Запуск: python3 server/test_api.py
"""
import json
import sqlite3
import tempfile
import threading
import time
import unittest
import urllib.request
import urllib.error
from http.server import ThreadingHTTPServer

import api


def _call(port, method, path, payload=None):
    url = f"http://127.0.0.1:{port}{path}"
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


class APITest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        api.DB_PATH = cls.tmp.name
        api.db().close()   # создать схему до первого setUp
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), api.Handler)
        cls.port = cls.server.server_address[1]
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        conn = sqlite3.connect(api.DB_PATH)
        for table in ("reports", "votes", "metrics", "camera_reports", "feedback"):
            conn.execute(f"DELETE FROM {table}")
        conn.commit()
        conn.close()

    # --- передвижные радары ---

    def test_report_and_merge_then_vote_keeps_confirmations(self):
        """Главный сценарий: merge-подтверждения должны переживать дизлайк."""
        _, first = _call(self.port, "POST", "/api/report",
                         {"lat": 41.31, "lon": 69.25, "device": "creator"})
        rid = first["id"]
        for device in ("a", "b", "c"):  # три водителя подтверждают той же точкой
            status, body = _call(self.port, "POST", "/api/report",
                                 {"lat": 41.3101, "lon": 69.2501, "device": device})
            self.assertTrue(body["merged"], "300 м — должно слиться")
        status, body = _call(self.port, "POST", "/api/vote",
                             {"id": rid, "device": "hater", "value": -1})
        self.assertEqual(status, 200)
        self.assertEqual(body["up"], 3, "merge-подтверждения потерялись при пересчёте")
        self.assertTrue(body["active"], "3 подтверждения против 1 дизлайка — отметка жива")

    def test_three_dislikes_hide_unconfirmed(self):
        _, first = _call(self.port, "POST", "/api/report",
                         {"lat": 41.31, "lon": 69.25, "device": "creator"})
        rid = first["id"]
        for i, device in enumerate(("h1", "h2", "h3")):
            status, body = _call(self.port, "POST", "/api/vote",
                                 {"id": rid, "device": device, "value": -1})
        self.assertFalse(body["active"], "3 дизлайка без лайков должны скрыть")

    def test_report_out_of_bounds(self):
        status, _ = _call(self.port, "POST", "/api/report",
                          {"lat": 55.75, "lon": 37.61, "device": "moscow"})
        self.assertEqual(status, 400)

    def test_vote_rejects_huge_id(self):
        """1e100 раньше ронял SQLite OverflowError — теперь чистый 400."""
        status, _ = _call(self.port, "POST", "/api/vote",
                          {"id": 10**100, "device": "x", "value": 1})
        self.assertEqual(status, 400)

    def test_report_rate_limit_120s(self):
        _call(self.port, "POST", "/api/report", {"lat": 41.31, "lon": 69.25, "device": "d"})
        status, _ = _call(self.port, "POST", "/api/report",
                          {"lat": 42.0, "lon": 70.0, "device": "d"})
        self.assertEqual(status, 429, "вторая отметка раньше 120 с")

    def test_mobile_purges_orphan_votes(self):
        conn = sqlite3.connect(api.DB_PATH)
        conn.execute("INSERT INTO votes(report_id, device, value, ts) VALUES(999, 'x', 1, 0)")
        conn.commit(); conn.close()
        _call(self.port, "GET", "/api/mobile")
        conn = sqlite3.connect(api.DB_PATH)
        left = conn.execute("SELECT COUNT(*) FROM votes").fetchone()[0]
        conn.close()
        self.assertEqual(left, 0, "голоса-сироты должны чиститься")

    # --- камеры и фидбек ---

    def test_camera_report_dedup_per_device(self):
        payload = {"camera_id": 7, "reason": "gone", "device": "d1"}
        _, first = _call(self.port, "POST", "/api/camera_report", payload)
        _, second = _call(self.port, "POST", "/api/camera_report", payload)
        self.assertNotIn("duplicate", first)
        self.assertTrue(second.get("duplicate"), "повтор с того же устройства")

    def test_camera_report_bad_reason(self):
        status, _ = _call(self.port, "POST", "/api/camera_report",
                          {"camera_id": 7, "reason": "hacked", "device": "d"})
        self.assertEqual(status, 400)

    def test_feedback_strips_control_chars(self):
        _call(self.port, "POST", "/api/feedback",
              {"message": "привет\x1b[2Jмир", "device": "d"})
        conn = sqlite3.connect(api.DB_PATH)
        message = conn.execute("SELECT message FROM feedback").fetchone()[0]
        conn.close()
        self.assertNotIn("\x1b", message, "ANSI-escape в терминал модератора")

    def test_metrics_rejects_oversize_payload(self):
        status, _ = _call(self.port, "POST", "/api/metrics",
                          {"device": "d", "kind": "metric", "payload": "x" * 250000})
        self.assertEqual(status, 400, "раньше payload молча резался в битый JSON")


if __name__ == "__main__":
    unittest.main(verbosity=2)
