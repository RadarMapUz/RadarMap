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


def _call(port, method, path, payload=None, ip=None):
    """ip — имитация X-Forwarded-For: в проде его ставит nginx ($remote_addr),
    здесь мы сами играем роль nginx и подставляем «адрес клиента»."""
    url = f"http://127.0.0.1:{port}{path}"
    data = json.dumps(payload).encode() if payload is not None else None
    headers = {"Content-Type": "application/json"}
    if ip:
        headers["X-Forwarded-For"] = ip
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
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
        api.init_db()      # схема, миграции и индексы — один раз, как в проде
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
        with api._ip_lock:
            api._ip_counters.clear()
        with api._cleanup_lock:
            api._last_cleanup = 0.0

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
                                 {"id": rid, "device": device, "value": -1},
                                 ip=f"10.0.0.{i + 1}")
        self.assertFalse(body["active"], "3 дизлайка с разных адресов должны скрыть")

    def test_dislikes_from_one_ip_do_not_hide(self):
        """Три свежих UUID с ОДНОГО адреса — это один недовольный, а не кворум:
        раньше так снималась с карты любая чужая отметка."""
        _, first = _call(self.port, "POST", "/api/report",
                         {"lat": 41.31, "lon": 69.25, "device": "creator"})
        rid = first["id"]
        for device in ("h1", "h2", "h3"):
            status, body = _call(self.port, "POST", "/api/vote",
                                 {"id": rid, "device": device, "value": -1},
                                 ip="10.9.9.9")
        self.assertTrue(body["active"], "ротация UUID с одного IP не должна скрывать")

    def test_vote_ip_daily_cap(self):
        _, first = _call(self.port, "POST", "/api/report",
                         {"lat": 41.31, "lon": 69.25, "device": "creator"})
        rid = first["id"]
        for i in range(api.IP_DAILY_CAPS["vote"]):
            _call(self.port, "POST", "/api/vote",
                  {"id": rid, "device": f"v{i}", "value": 1}, ip="10.1.1.1")
        status, _ = _call(self.port, "POST", "/api/vote",
                          {"id": rid, "device": "extra", "value": 1}, ip="10.1.1.1")
        self.assertEqual(status, 429, "кап голосов по IP не сработал")
        status, _ = _call(self.port, "POST", "/api/vote",
                          {"id": rid, "device": "other", "value": 1}, ip="10.1.1.2")
        self.assertEqual(status, 200, "чужой IP не должен страдать от чужого капа")

    def test_report_types_ttl_and_no_cross_merge(self):
        """ДТП живёт час; пост рядом с радаром не сливается (разные сущности)."""
        import time as t
        now = t.time()
        _, accident = _call(self.port, "POST", "/api/report",
                            {"lat": 41.4, "lon": 69.4, "device": "a", "type": "accident"})
        conn = sqlite3.connect(api.DB_PATH)
        expires, rtype = conn.execute("SELECT expires, type FROM reports WHERE id = ?",
                                      (accident["id"],)).fetchone()
        conn.close()
        self.assertEqual(rtype, "accident")
        self.assertLess(expires - now, 3700, "ДТП должно жить ~час")
        status, post = _call(self.port, "POST", "/api/report",
                             {"lat": 41.4001, "lon": 69.4001, "device": "b", "type": "post"})
        self.assertFalse(post["merged"], "пост не должен сливаться с ДТП рядом")

    def test_report_bad_type(self):
        status, _ = _call(self.port, "POST", "/api/report",
                          {"lat": 41.4, "lon": 69.4, "device": "x", "type": "ufo"})
        self.assertEqual(status, 400)

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

    def test_camera_report_huge_db_version_is_400(self):
        """10**100 раньше ронял хендлер OverflowError'ом на INSERT."""
        status, _ = _call(self.port, "POST", "/api/camera_report",
                          {"camera_id": 7, "reason": "gone", "device": "d",
                           "db_version": 10**100})
        self.assertEqual(status, 400)

    def test_camera_report_nan_coords_stored_null(self):
        status, _ = _call(self.port, "POST", "/api/camera_report",
                          {"camera_id": 7, "reason": "gone", "device": "d",
                           "lat": float("nan"), "lon": 200.0})
        self.assertEqual(status, 200)
        conn = sqlite3.connect(api.DB_PATH)
        lat, lon = conn.execute(
            "SELECT lat, lon FROM camera_reports").fetchone()
        conn.close()
        self.assertIsNone(lat, "NaN не должен долетать до БД")
        self.assertIsNone(lon, "координата вне Узбекистана не должна долетать до БД")

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

    def test_feedback_app_version_stripped_and_dict_message_rejected(self):
        _call(self.port, "POST", "/api/feedback",
              {"message": "ок", "device": "d", "app_version": "1.0[2J"})
        conn = sqlite3.connect(api.DB_PATH)
        version = conn.execute("SELECT app_version FROM feedback").fetchone()[0]
        conn.close()
        self.assertNotIn("", version, "ANSI в app_version идёт в терминал модератора")
        status, _ = _call(self.port, "POST", "/api/feedback",
                          {"message": {"a": 1}, "device": "d2"})
        self.assertEqual(status, 400, "словарь вместо строки сохранялся Python-repr'ом")

    def test_trailing_slash_and_query_are_same_endpoint(self):
        status, _ = _call(self.port, "GET", "/api/health/")
        self.assertEqual(status, 200)
        status, _ = _call(self.port, "GET", "/api/mobile?x=1")
        self.assertEqual(status, 200)

    def test_metrics_roundtrip_saved(self):
        status, _ = _call(self.port, "POST", "/api/metrics",
                          {"device": "d", "kind": "metric", "payload": {"cpu": 1}})
        self.assertEqual(status, 200)
        conn = sqlite3.connect(api.DB_PATH)
        kind, payload = conn.execute("SELECT kind, payload FROM metrics").fetchone()
        conn.close()
        self.assertEqual(kind, "metric")
        self.assertEqual(json.loads(payload), {"cpu": 1})

    def test_metrics_rejects_oversize_payload(self):
        status, _ = _call(self.port, "POST", "/api/metrics",
                          {"device": "d", "kind": "metric", "payload": "x" * 250000})
        self.assertEqual(status, 400, "раньше payload молча резался в битый JSON")

    # --- схема и нагрузка ---

    def test_wal_and_indexes_are_set_up(self):
        """WAL и индексы ставятся один раз в init_db, а не на каждый запрос."""
        conn = sqlite3.connect(api.DB_PATH)
        mode = conn.execute("PRAGMA journal_mode").fetchone()[0]
        names = {r[0] for r in conn.execute(
            "SELECT name FROM sqlite_master WHERE type = 'index'")}
        conn.close()
        self.assertEqual(mode.lower(), "wal",
                         "без WAL писатель блокирует читателей и они получают 500")
        for index in ("idx_reports_live", "idx_camrep_camera", "idx_feedback_received",
                      "idx_metrics_device", "idx_votes_device"):
            self.assertIn(index, names, f"нет индекса {index} — полный скан на каждый кап")

    def test_db_connection_does_not_touch_schema(self):
        """db() обязан быть дешёвым: раньше он гонял всю миграцию на КАЖДЫЙ
        HTTP-запрос — шесть CREATE TABLE и четыре ALTER, все четыре в исключение."""
        conn = api.db()
        try:
            self.assertEqual(conn.execute("PRAGMA busy_timeout").fetchone()[0],
                             api.BUSY_TIMEOUT_MS,
                             "без busy_timeout параллельная запись даёт мгновенный 500")
        finally:
            conn.close()
        # схему db() не создаёт — проверяем на пустом файле
        empty = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        saved, api.DB_PATH = api.DB_PATH, empty.name
        try:
            conn = api.db()
            tables = conn.execute(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table'").fetchone()[0]
            conn.close()
        finally:
            api.DB_PATH = saved
        self.assertEqual(tables, 0, "db() не должен создавать схему")

    def test_camera_report_stores_ip(self):
        """Кворум на скрытие камеры считается по разным адресам, а не по
        device: UUID ротируется бесплатно, и «5 разных устройств» подделывалось
        одним телефоном. Снятая по фейку живая камера — это молчание там, где
        камера стоит, худший отказ системы."""
        _call(self.port, "POST", "/api/camera_report",
              {"camera_id": 7, "reason": "gone", "device": "d1"}, ip="10.5.5.5")
        conn = sqlite3.connect(api.DB_PATH)
        ip = conn.execute("SELECT ip FROM camera_reports").fetchone()[0]
        conn.close()
        self.assertEqual(ip, "10.5.5.5")

    def test_bounded_server_refuses_over_capacity(self):
        """Сверх потолка потоков — честный 503, а не бесконечная очередь."""
        class FakeSocket:
            def __init__(self): self.sent = b""; self.closed = False
            def sendall(self, data): self.sent += data
            def shutdown(self, how): pass
            def close(self): self.closed = True

        server = api.BoundedHTTPServer(("127.0.0.1", 0), api.Handler, max_workers=1)
        try:
            self.assertTrue(server._slots.acquire(blocking=False))  # занимаем единственный слот
            sock = FakeSocket()
            server.process_request(sock, ("10.0.0.1", 1234))
            self.assertIn(b"503", sock.sent)
            self.assertTrue(sock.closed, "соединение сверх потолка должно закрываться")
        finally:
            server.server_close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
