"""Тесты пульта состояния: каждый класс «тихо умерло» обязан краснеть.

Сеть и подпись подменяются: проверки получают Context с фальшивым fetch.
Единственное исключение — test_real_signature: настоящий боевой overrides.json
проверяется настоящим openssl, чтобы подмена в остальных тестах не скрыла
поломку самой проверки подписи.
"""
import base64
import gzip
import hashlib
import json
import os
import shutil
import sqlite3
import tempfile
import time
import unittest

import status as st

NOW = 1_790_000_000.0
DAY = 86400


def envelope(obj):
    payload = base64.b64encode(json.dumps(obj).encode()).decode()
    return json.dumps({"payload": payload, "sig": "c2ln"}).encode()


def http_date(ts):
    from email.utils import formatdate
    return formatdate(ts, usegmt=True)


class FakeWeb:
    """Сервер в памяти: путь → (тело по gzip, тело по identity, заголовки)."""

    def __init__(self):
        self.files = {}

    def put(self, path, body, plain=None, age_days=0, code=200):
        headers = {"Last-Modified": http_date(NOW - age_days * DAY)}
        self.files[path] = (code, body, body if plain is None else plain, headers)

    def __call__(self, path, gzip_ok=True, timeout=20):
        if path not in self.files:
            return st.Fetched(404)
        code, zipped, plain, headers = self.files[path]
        return st.Fetched(code, zipped if gzip_ok else plain, headers, ms=5)


def healthy_web():
    web = FakeWeb()
    web.put("api/health", b'{"ok": true}')
    web.put("api/mobile", b'{"reports": [{}, {}]}')
    cams = b'[{"id":1}]'
    web.put("cameras.json", cams)
    web.put("version.json", json.dumps({"version": 12, "count": 1, "updatedAt": "2026-09-01",
                                        "sha256": hashlib.sha256(cams).hexdigest(),
                                        "sig": "c2ln"}).encode())
    web.put("config.json", envelope({}))
    web.put("overrides.json", envelope({"items": []}))
    web.put("hotspots.json", envelope({"spots": [{}, {}]}), age_days=3)
    for path in ("speed_limits.json", "speed_limits_v2.json"):
        web.put(path, json.dumps({"version": NOW - 10 * DAY, "segments": []}).encode())
    tile = b'{"roads":[]}'
    sha = hashlib.sha256(tile).hexdigest()
    web.put("roads_index_v2.json", envelope({"version": 2, "tiles": {"a": {"sha256": sha}}}), age_days=2)
    web.put("roads/road2_a.json", tile)
    web.put("mvt_index.json", envelope({"version": 1, "tiles": {"1/2/3": {"sha256": sha}}}), age_days=2)
    web.put("mvt/1/2/3.mvt", tile)
    web.put("osrm/route/v1/driving/69.24,41.31;69.28,41.33?overview=false", b'{"code":"Ok"}')
    return web


class Base(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.db = os.path.join(self.dir, "reports.db")
        conn = sqlite3.connect(self.db)
        conn.executescript("""
            CREATE TABLE reports(created REAL);
            CREATE TABLE camera_reports(received REAL, camera_id INTEGER, reason TEXT, resolved INTEGER DEFAULT 0);
            CREATE TABLE feedback(received REAL);
            CREATE TABLE metrics(received REAL, device TEXT);
            CREATE TABLE overrides(camera_id INTEGER, decided_at REAL, published_at REAL);
        """)
        conn.commit()
        conn.close()
        os.makedirs(os.path.join(self.dir, "backups"))
        self.log = os.path.join(self.dir, "roads.log")
        self.web = healthy_web()

    def tearDown(self):
        shutil.rmtree(self.dir)

    def ctx(self, verify=lambda data, sig: True):
        return st.Context(now=NOW, fetcher=self.web, verify=verify, reports_db=self.db,
                          root=self.dir, roads_log=self.log)

    def sql(self, statement, args=()):
        conn = sqlite3.connect(self.db)
        conn.execute(statement, args)
        conn.commit()
        conn.close()


class HealthyTests(Base):
    def test_everything_green_on_a_healthy_server(self):
        for check in (st.check_api, st.check_cameras, st.check_limits, st.check_roads,
                      st.check_mvt, st.check_overrides, st.check_hotspots, st.check_config,
                      st.check_osrm):
            with self.subTest(check=check.__name__):
                self.assertEqual(check(self.ctx())["state"], st.OK, check(self.ctx()))

    def test_markers_are_counted(self):
        self.assertIn("меток на карте: 2", st.check_api(self.ctx())["summary"])


class SilentDeathTests(Base):
    """Ровно то, что нашёл осмотр 27.09.2026."""

    def test_stale_gz_behind_fresh_json_is_red(self):
        # Лимиты: nginx отдавал июльский .gz, .json был свежий.
        fresh = json.dumps({"version": NOW, "segments": []}).encode()
        july = json.dumps({"version": NOW - 74 * DAY, "segments": []}).encode()
        self.web.put("speed_limits.json", july, plain=fresh)
        result = st.check_limits(self.ctx())
        self.assertEqual(result["state"], st.BAD)
        self.assertIn("старый .gz", result["summary"])

    def test_missing_v2_is_red(self):
        del self.web.files["speed_limits_v2.json"]
        self.assertEqual(st.check_limits(self.ctx())["state"], st.BAD)

    def test_old_limits_warn_then_red(self):
        for age, state in ((50, st.WARN), (80, st.BAD)):
            for path in ("speed_limits.json", "speed_limits_v2.json"):
                self.web.put(path, json.dumps({"version": NOW - age * DAY}).encode())
            self.assertEqual(st.check_limits(self.ctx())["state"], state, age)

    def test_never_published_hotspots_are_red(self):
        del self.web.files["hotspots.json"]
        result = st.check_hotspots(self.ctx())
        self.assertEqual(result["state"], st.BAD)
        self.assertIn("404", result["summary"])

    def test_failed_roads_build_is_visible_even_while_index_is_fresh(self):
        with open(self.log, "w") as f:
            f.write("=== 2026-09-20T04:17:02+05:00 обновление дорог ===\n--- 2/4\nok\n"
                    "=== 2026-09-27T04:17:01+05:00 обновление дорог ===\n--- 1/4: свежий OSM\n"
                    "uzbekistan-new.osm.pbf: FAILED\n")
        result = st.check_roads(self.ctx())
        self.assertEqual(result["state"], st.WARN)
        self.assertIn("2026-09-27", " ".join(result["details"]))

    def test_successful_rerun_clears_the_failure(self):
        with open(self.log, "w") as f:
            f.write("=== 2026-09-27T04:17:01+05:00 обновление дорог ===\nFAILED\n"
                    "=== 2026-09-27T17:55:16+05:00 обновление дорог ===\nuzbekistan-new.osm.pbf: OK\n")
        self.assertEqual(st.check_roads(self.ctx())["state"], st.OK)

    def test_stale_roads_warn_then_red(self):
        for age, state in ((12, st.WARN), (25, st.BAD)):
            code, body, plain, _ = self.web.files["roads_index_v2.json"]
            self.web.put("roads_index_v2.json", body, age_days=age)
            self.assertEqual(st.check_roads(self.ctx())["state"], state, age)

    def test_unpublished_candidate_is_yellow(self):
        self.web.put("roads_index_v2.json", self.web.files["roads_index_v2.json"][1], age_days=8)
        folder = os.path.join(self.dir, "work", "roads_tiles_candidate")
        os.makedirs(folder)
        path = os.path.join(folder, "index_payload_v2.json")
        open(path, "w").close()
        os.utime(path, (NOW - 4 * DAY, NOW - 4 * DAY))
        result = st.check_roads(self.ctx())
        self.assertEqual(result["state"], st.WARN)
        self.assertIn("не опубликован", " ".join(result["details"]))

    def test_tampered_tile_is_red(self):
        self.web.put("roads/road2_a.json", b'{"roads":["planted"]}')
        self.assertEqual(st.check_roads(self.ctx())["state"], st.BAD)
        self.web.put("mvt/1/2/3.mvt", b"planted")
        self.assertEqual(st.check_mvt(self.ctx())["state"], st.BAD)

    def test_waiting_moderator_decisions_warn_then_red(self):
        self.sql("INSERT INTO overrides VALUES (1, ?, NULL)", (NOW - 5 * DAY,))
        result = st.check_overrides(self.ctx())
        self.assertEqual(result["state"], st.WARN)
        self.assertIn("ждут подписи 1", result["summary"])
        self.sql("INSERT INTO overrides VALUES (2, ?, NULL)", (NOW - 20 * DAY,))
        self.assertEqual(st.check_overrides(self.ctx())["state"], st.BAD)

    def test_published_decisions_do_not_count(self):
        self.sql("INSERT INTO overrides VALUES (1, ?, ?)", (NOW - 40 * DAY, NOW - 39 * DAY))
        self.assertEqual(st.check_overrides(self.ctx())["state"], st.OK)


class SignatureTests(Base):
    def test_bad_signature_is_red_everywhere(self):
        refuse = lambda data, sig: False  # noqa: E731
        for check in (st.check_cameras, st.check_config, st.check_overrides,
                      st.check_hotspots, st.check_roads, st.check_mvt):
            with self.subTest(check=check.__name__):
                self.assertEqual(check(self.ctx(verify=refuse))["state"], st.BAD)

    def test_no_openssl_is_not_a_forgery(self):
        # None — «нечем проверить»: пульт говорит об этом, но не кричит «подделка».
        result = st.check_config(self.ctx(verify=lambda data, sig: None))
        self.assertEqual(result["state"], st.OK)
        self.assertIn("не проверена", result["summary"])

    def test_camera_db_sha_mismatch_is_red(self):
        self.web.put("cameras.json", b'[{"id":2}]')
        self.assertEqual(st.check_cameras(self.ctx())["state"], st.BAD)

    def test_real_signature(self):
        # Боевой overrides.json от 07.08.2026, подписан ключом владельца.
        payload = base64.b64decode(
            "eyJ2ZXJzaW9uIjoxLCJ1cGRhdGVkQXQiOiIyMDI2LTA4LTA3IiwiaXRlbXMiOltdfQo=")
        sig = ("b363yePZHDC6Zw5DM+E2d+Lcw+dVTHAJe9CDEI5u2kzRNqQXrMQCG/KeXReZht6KLcd7"
               "J5GzA3qBCZTAfxJRDw==")
        verdict = st.verify_ed25519(payload, sig)
        if verdict is None:
            self.skipTest("openssl без Ed25519")
        self.assertTrue(verdict)
        self.assertFalse(st.verify_ed25519(payload + b" ", sig))


class LocalTests(Base):
    def test_crowd_without_data_is_grey_not_red(self):
        self.assertEqual(st.check_crowd(self.ctx())["state"], st.IDLE)
        self.sql("INSERT INTO reports VALUES (?)", (NOW - DAY,))
        self.assertEqual(st.check_crowd(self.ctx())["state"], st.OK)

    def test_backup_age(self):
        self.assertEqual(st.check_backup(self.ctx())["state"], st.BAD)
        path = os.path.join(self.dir, "backups", "reports-20260927.db.gz")
        open(path, "w").close()
        os.utime(path, (NOW - 3600, NOW - 3600))
        # Копии только на том же диске — жёлтый: переживут всё, кроме сервера.
        self.assertEqual(st.check_backup(self.ctx())["state"], st.WARN)
        marker = os.path.join(self.dir, "backups", ".offsite")
        open(marker, "w").close()
        os.utime(marker, (NOW - 7200, NOW - 7200))
        result = st.check_backup(self.ctx())
        self.assertEqual(result["state"], st.OK)
        self.assertIn("вне VPS: 2 ч назад", result["summary"])
        os.utime(marker, (NOW - 5 * DAY, NOW - 5 * DAY))
        self.assertEqual(st.check_backup(self.ctx())["state"], st.WARN)
        os.utime(path, (NOW - 3 * DAY, NOW - 3 * DAY))
        self.assertEqual(st.check_backup(self.ctx())["state"], st.BAD)

    def test_cert(self):
        for left, state in ((40, st.OK), (10, st.WARN), (3, st.BAD)):
            self.assertEqual(st.check_cert(self.ctx(), days_left=lambda h, l=left: l)["state"], state)

    def test_a_crashing_check_is_red_not_a_crash(self):
        def boom(ctx):
            raise RuntimeError("сломалось")
        saved = st.CHECKS
        st.CHECKS = (boom,)
        try:
            report = st.run_all(self.ctx())
        finally:
            st.CHECKS = saved
        self.assertEqual(report["overall"], st.BAD)
        self.assertIn("сломалось", report["checks"][0]["summary"])


class CameraPipelineTests(Base):
    def test_quality_counts_follow_the_app_rules(self):
        cams = [
            {"road": [1], "dir": 90, "cls": "trunk", "twin": True},        # стороны доказаны
            {"road": [1], "dir": 90, "cls": "primary", "split": False},    # доказаны
            {"road": [1], "dir": 90, "cls": "primary", "split": True},     # не доказаны
            {"road": [1], "dir": 90, "cls": "footway", "twin": True},      # тротуар — не верим
            {"needsReview": True},
        ]
        line = st.camera_quality(cams)
        self.assertIn("профиль дороги 80%", line)
        self.assertIn("стороны доказаны 2", line)
        self.assertIn("приблизительная 1", line)
        self.assertIn("тротуаре/остановке 1", line)

    def test_unanswered_wrong_location_is_yellow(self):
        self.assertEqual(st.check_cameras(self.ctx())["state"], st.OK)
        self.sql("INSERT INTO camera_reports VALUES (?, 7, 'wrong_location', 0)", (NOW,))
        self.sql("INSERT INTO camera_reports VALUES (?, 7, 'wrong_location', 0)", (NOW,))
        self.sql("INSERT INTO camera_reports VALUES (?, 8, 'gone', 0)", (NOW,))
        result = st.check_cameras(self.ctx())
        self.assertEqual(result["state"], st.WARN)
        self.assertIn("без ответа: 1", " ".join(result["details"]))
        self.sql("UPDATE camera_reports SET resolved = 1")
        self.assertEqual(st.check_cameras(self.ctx())["state"], st.OK)

    def write_log(self, *lines):
        os.makedirs(os.path.join(self.dir, "api"), exist_ok=True)
        with open(os.path.join(self.dir, "api", "update.log"), "w") as f:
            f.write("\n".join(lines) + "\n")

    def stamp(self, days_ago):
        return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(NOW - days_ago * DAY))

    def test_registry_polled_recently_is_green(self):
        self.write_log(self.stamp(2) + " UNCHANGED: 3480 cameras, hash a582")
        self.assertEqual(st.check_registry(self.ctx())["state"], st.OK)

    def test_registry_not_polled_is_yellow(self):
        # Ровно боевой случай: последний опрос — 3 августа.
        self.write_log(self.stamp(55) + " UNCHANGED: 3480 cameras, hash a582")
        self.assertEqual(st.check_registry(self.ctx())["state"], st.WARN)
        os.unlink(os.path.join(self.dir, "api", "update.log"))
        self.assertEqual(st.check_registry(self.ctx())["state"], st.WARN)

    def test_failed_poll_is_yellow(self):
        self.write_log(self.stamp(1) + " FETCH FAILED: timeout")
        self.assertEqual(st.check_registry(self.ctx())["state"], st.WARN)

    def test_registry_change_is_reported(self):
        self.write_log(self.stamp(9) + " CANDIDATE UPDATED: 3520 cameras, hash b1",
                       self.stamp(2) + " UNCHANGED: 3520 cameras, hash b1")
        result = st.check_registry(self.ctx())
        self.assertIn("CANDIDATE UPDATED", " ".join(result["details"]))


class AlertTests(unittest.TestCase):
    def report(self, **states):
        return {"at": 1, "checks": [{"id": k, "title": k, "state": v, "summary": "s"}
                                    for k, v in states.items()]}

    def test_first_run_is_silent(self):
        self.assertIsNone(st.changes({}, self.report(api=st.BAD)))

    def test_only_changes_alert(self):
        self.assertIsNone(st.changes({"api": st.BAD}, self.report(api=st.BAD)))
        self.assertIn("🔴", st.changes({"api": st.OK}, self.report(api=st.BAD)))
        self.assertIn("🟢", st.changes({"api": st.BAD}, self.report(api=st.OK)))

    def test_idle_and_ok_are_the_same_for_alerts(self):
        self.assertIsNone(st.changes({"crowd": st.OK}, self.report(crowd=st.IDLE)))

    def test_history_roundtrip_and_pruning(self):
        folder = tempfile.mkdtemp()
        try:
            conn = st.open_history(os.path.join(folder, "s.db"))
            st.record(conn, {"at": 100, "checks": [{"id": "api", "state": st.OK}]})
            st.record(conn, {"at": 100 + 31 * DAY, "checks": [{"id": "api", "state": st.BAD}]})
            self.assertEqual(st.previous_states(conn), {"api": st.BAD})
            self.assertEqual(conn.execute("SELECT COUNT(*) FROM history").fetchone()[0], 1)
            conn.close()
        finally:
            shutil.rmtree(folder)


if __name__ == "__main__":
    unittest.main(verbosity=1)
