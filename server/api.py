#!/usr/bin/env python3
"""RadarMap API: краудсорсинг передвижных радаров, метрики, обратная связь.

Stdlib-only (sqlite3 + http.server): без pip-зависимостей на общем VPS.
Слушает 127.0.0.1:8091, наружу отдаётся nginx'ом на :8090/api/.

Endpoints:
  GET  /api/health         -> {"ok": true}
  GET  /api/mobile         -> {"reports": [{id, lat, lon, created, expires, up, down}]}
  POST /api/report         {lat, lon, device}        -> {"id": N, "merged": bool}
  POST /api/vote           {id, device, value: 1|-1} -> {"ok": true}
  POST /api/metrics        {device, kind, payload}   -> {"ok": true}   (MetricKit)
  POST /api/camera_report  {camera_id, reason, lat, lon, db_version, device} -> {"ok": true}
  POST /api/feedback       {message, contact, app_version, device}     -> {"ok": true}

Правила передвижных радаров:
  * отметка живёт 3 ч; подтверждение (+1) продлевает на 30 мин (максимум 6 ч)
  * новая отметка в 300 м от активной считается подтверждением (дедупликация)
  * 3+ дизлайков и дизлайков больше лайков -> отметка скрывается
  * на устройство: максимум 3 активных отметки, минимум 120 с между отметками

Модерация репортов о камерах — вручную на сервере:
  sqlite3 /opt/radarmap/api/reports.db \
    "SELECT camera_id, reason, COUNT(DISTINCT device) n, MAX(datetime(received,'unixepoch')) last \
     FROM camera_reports WHERE resolved=0 GROUP BY camera_id, reason ORDER BY n DESC;"
  sqlite3 /opt/radarmap/api/reports.db \
    "SELECT id, datetime(received,'unixepoch'), app_version, contact, message FROM feedback ORDER BY id DESC LIMIT 20;"
"""
import json
import math
import sqlite3
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DB_PATH = "/opt/radarmap/api/reports.db"
TTL = 3 * 3600
EXTEND = 30 * 60
MAX_LIFE = 6 * 3600
MERGE_METERS = 300
UZ_LAT = (37.0, 46.0)
UZ_LON = (55.0, 74.0)

def db():
    conn = sqlite3.connect(DB_PATH)
    conn.execute("""CREATE TABLE IF NOT EXISTS reports(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        lat REAL NOT NULL, lon REAL NOT NULL,
        created REAL NOT NULL, expires REAL NOT NULL,
        device TEXT NOT NULL, up INTEGER DEFAULT 0, down INTEGER DEFAULT 0,
        active INTEGER DEFAULT 1)""")
    conn.execute("""CREATE TABLE IF NOT EXISTS votes(
        report_id INTEGER, device TEXT, value INTEGER,
        PRIMARY KEY(report_id, device))""")
    conn.execute("""CREATE TABLE IF NOT EXISTS metrics(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        device TEXT NOT NULL, kind TEXT NOT NULL,
        received REAL NOT NULL, payload TEXT NOT NULL)""")
    conn.execute("""CREATE TABLE IF NOT EXISTS camera_reports(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        camera_id INTEGER NOT NULL,
        reason TEXT NOT NULL,
        lat REAL, lon REAL,
        db_version INTEGER,
        device TEXT NOT NULL,
        received REAL NOT NULL,
        resolved INTEGER DEFAULT 0)""")
    conn.execute("""CREATE TABLE IF NOT EXISTS feedback(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        message TEXT NOT NULL,
        contact TEXT,
        app_version TEXT,
        device TEXT NOT NULL,
        received REAL NOT NULL)""")
    return conn

def haversine(lat1, lon1, lat2, lon2):
    r = 6371000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = math.radians(lat2 - lat1), math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))

class Handler(BaseHTTPRequestHandler):
    server_version = "RadarMapAPI/1.1"

    def log_message(self, fmt, *args):
        pass  # keep journald quiet; errors surface via exceptions

    def _json(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self, limit=4096):
        try:
            length = int(self.headers.get("Content-Length", 0))
            if length <= 0 or length > limit:
                return None
            return json.loads(self.rfile.read(length))
        except (ValueError, json.JSONDecodeError):
            return None

    def do_GET(self):
        if self.path == "/api/health":
            return self._json(200, {"ok": True})
        if self.path == "/api/mobile":
            now = time.time()
            conn = db()
            try:
                conn.execute("DELETE FROM reports WHERE expires < ?", (now - 86400,))
                conn.commit()
                rows = conn.execute(
                    "SELECT id, lat, lon, created, expires, up, down FROM reports "
                    "WHERE active = 1 AND expires > ?", (now,)).fetchall()
            finally:
                conn.close()
            return self._json(200, {"reports": [
                {"id": r[0], "lat": r[1], "lon": r[2], "created": r[3],
                 "expires": r[4], "up": r[5], "down": r[6]} for r in rows]})
        self._json(404, {"error": "not found"})

    def do_POST(self):
        if self.path == "/api/report":
            return self._report()
        if self.path == "/api/vote":
            return self._vote()
        if self.path == "/api/metrics":
            return self._metrics()
        if self.path == "/api/camera_report":
            return self._camera_report()
        if self.path == "/api/feedback":
            return self._feedback()
        self._json(404, {"error": "not found"})

    def _metrics(self):
        try:
            length = int(self.headers.get("Content-Length", 0))
            if length <= 0 or length > 262144:
                return self._json(400, {"error": "bad length"})
            data = json.loads(self.rfile.read(length))
            device = str(data["device"])[:64]
            kind = str(data["kind"])[:16]
            payload = json.dumps(data["payload"])[:200000]
        except (KeyError, TypeError, ValueError, json.JSONDecodeError):
            return self._json(400, {"error": "bad json"})
        if not device or kind not in ("metric", "diagnostic"):
            return self._json(400, {"error": "bad fields"})
        now = time.time()
        conn = db()
        try:
            count = conn.execute(
                "SELECT COUNT(*) FROM metrics WHERE device = ? AND received > ?",
                (device, now - 86400)).fetchone()[0]
            if count >= 20:
                return self._json(429, {"error": "too many"})
            conn.execute("DELETE FROM metrics WHERE received < ?", (now - 30 * 86400,))
            conn.execute("INSERT INTO metrics(device, kind, received, payload) VALUES(?,?,?,?)",
                         (device, kind, now, payload))
            conn.commit()
        finally:
            conn.close()
        return self._json(200, {"ok": True})

    def _camera_report(self):
        """Репорт по базе камер: «больше нет» / «неверное место» / «на месте»
        (still_here — краудсорс-подтверждение, гасит ложные gone-репорты).
        Разбирается вручную (см. запросы модерации в шапке файла)."""
        data = self._body()
        if not data:
            return self._json(400, {"error": "bad json"})
        try:
            camera_id = int(data["camera_id"])
            reason = str(data["reason"])[:32]
            device = str(data["device"])[:64]
            lat = float(data.get("lat") or 0) or None
            lon = float(data.get("lon") or 0) or None
            db_version = int(data.get("db_version") or 0) or None
        except (KeyError, TypeError, ValueError):
            return self._json(400, {"error": "bad fields"})
        if reason not in ("gone", "wrong_location", "still_here") or not device or camera_id <= 0:
            return self._json(400, {"error": "bad fields"})

        now = time.time()
        conn = db()
        try:
            count = conn.execute(
                "SELECT COUNT(*) FROM camera_reports WHERE device = ? AND received > ?",
                (device, now - 86400)).fetchone()[0]
            if count >= 20:
                return self._json(429, {"error": "too many"})
            # Повтор того же репорта с того же устройства не плодим — сигнал
            # считаем по числу РАЗНЫХ устройств на камеру.
            dup = conn.execute(
                "SELECT id FROM camera_reports WHERE device = ? AND camera_id = ? "
                "AND reason = ? AND received > ?",
                (device, camera_id, reason, now - 7 * 86400)).fetchone()
            if dup:
                return self._json(200, {"ok": True, "duplicate": True})
            conn.execute(
                "INSERT INTO camera_reports(camera_id, reason, lat, lon, db_version, device, received) "
                "VALUES(?,?,?,?,?,?,?)",
                (camera_id, reason, lat, lon, db_version, device, now))
            conn.commit()
        finally:
            conn.close()
        return self._json(200, {"ok": True})

    def _feedback(self):
        """Сообщение разработчику из формы в настройках."""
        data = self._body(limit=16384)
        if not data:
            return self._json(400, {"error": "bad json"})
        try:
            message = str(data["message"]).strip()[:2000]
            contact = str(data.get("contact") or "")[:200]
            app_version = str(data.get("app_version") or "")[:32]
            device = str(data["device"])[:64]
        except (KeyError, TypeError, ValueError):
            return self._json(400, {"error": "bad fields"})
        if not message or not device:
            return self._json(400, {"error": "bad fields"})

        now = time.time()
        conn = db()
        try:
            count = conn.execute(
                "SELECT COUNT(*) FROM feedback WHERE device = ? AND received > ?",
                (device, now - 86400)).fetchone()[0]
            if count >= 10:
                return self._json(429, {"error": "too many"})
            conn.execute(
                "INSERT INTO feedback(message, contact, app_version, device, received) "
                "VALUES(?,?,?,?,?)",
                (message, contact, app_version, device, now))
            conn.commit()
        finally:
            conn.close()
        return self._json(200, {"ok": True})

    def _report(self):
        data = self._body()
        if not data:
            return self._json(400, {"error": "bad json"})
        try:
            lat, lon = float(data["lat"]), float(data["lon"])
            device = str(data["device"])[:64]
        except (KeyError, TypeError, ValueError):
            return self._json(400, {"error": "bad fields"})
        if not (UZ_LAT[0] <= lat <= UZ_LAT[1] and UZ_LON[0] <= lon <= UZ_LON[1]) or not device:
            return self._json(400, {"error": "out of bounds"})

        now = time.time()
        conn = db()
        try:
            # rate limits per device
            recent = conn.execute(
                "SELECT COUNT(*), MAX(created) FROM reports WHERE device = ? AND active = 1 AND expires > ?",
                (device, now)).fetchone()
            if recent[0] >= 3:
                return self._json(429, {"error": "too many active reports"})
            if recent[1] and now - recent[1] < 120:
                return self._json(429, {"error": "too fast"})

            # dedupe: nearby active report -> treat as confirmation
            for r in conn.execute(
                    "SELECT id, lat, lon, created, expires FROM reports WHERE active = 1 AND expires > ?",
                    (now,)).fetchall():
                if haversine(lat, lon, r[1], r[2]) <= MERGE_METERS:
                    new_exp = min(r[3] + MAX_LIFE, max(r[4], now) + EXTEND)
                    conn.execute("UPDATE reports SET up = up + 1, expires = ? WHERE id = ?",
                                 (new_exp, r[0]))
                    conn.commit()
                    return self._json(200, {"id": r[0], "merged": True})

            cur = conn.execute(
                "INSERT INTO reports(lat, lon, created, expires, device) VALUES(?,?,?,?,?)",
                (lat, lon, now, now + TTL, device))
            conn.commit()
            return self._json(200, {"id": cur.lastrowid, "merged": False})
        finally:
            conn.close()

    def _vote(self):
        data = self._body()
        if not data:
            return self._json(400, {"error": "bad json"})
        try:
            rid = int(data["id"])
            device = str(data["device"])[:64]
            value = int(data["value"])
        except (KeyError, TypeError, ValueError):
            return self._json(400, {"error": "bad fields"})
        if value not in (1, -1) or not device:
            return self._json(400, {"error": "bad value"})

        now = time.time()
        conn = db()
        try:
            row = conn.execute("SELECT created, expires FROM reports WHERE id = ? AND active = 1",
                               (rid,)).fetchone()
            if not row:
                return self._json(404, {"error": "no report"})
            conn.execute("INSERT OR REPLACE INTO votes(report_id, device, value) VALUES(?,?,?)",
                         (rid, device, value))
            up, down = conn.execute(
                "SELECT COALESCE(SUM(value = 1), 0), COALESCE(SUM(value = -1), 0) "
                "FROM votes WHERE report_id = ?", (rid,)).fetchone()
            expires = row[1]
            if value == 1:
                expires = min(row[0] + MAX_LIFE, max(expires, now) + EXTEND)
            active = 0 if (down >= 3 and down > up) else 1
            conn.execute("UPDATE reports SET up = ?, down = ?, expires = ?, active = ? WHERE id = ?",
                         (up, down, expires, active, rid))
            conn.commit()
            return self._json(200, {"ok": True, "up": up, "down": down, "active": bool(active)})
        finally:
            conn.close()

if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 8091), Handler).serve_forever()
