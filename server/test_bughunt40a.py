"""Ловец багов, ревью plan/40a-report-bugs: неявное уточнение, курс при
слиянии, отметка и голос из очереди, пауза между отметками, гонка записи."""
import sqlite3
import threading
import time
import unittest

import api
from test_api import ServerTestBase, _call


def _put(lat, lon, ago, rtype="radar", device="me", ip="10.50.0.1", cls="residential",
         course=-1.0, ttl=3600):
    conn = sqlite3.connect(api.DB_PATH)
    now = time.time()
    cur = conn.execute(
        "INSERT INTO reports(lat, lon, created, expires, device, type, ip, cls, active, course) "
        "VALUES(?,?,?,?,?,?,?,?,1,?)",
        (lat, lon, now - ago, now + ttl, device, rtype, ip, cls, course))
    conn.commit()
    rid = cur.lastrowid
    conn.close()
    return rid


def _row(rid):
    conn = sqlite3.connect(api.DB_PATH)
    row = conn.execute("SELECT type, expires, active FROM reports WHERE id = ?", (rid,)).fetchone()
    conn.close()
    return row


def _post(port, lat, lon, rtype="radar", device="me", ip="10.50.0.1", **extra):
    body = {"lat": lat, "lon": lon, "device": device, "type": rtype}
    body.update(extra)
    return _call(port, "POST", "/api/report", body, ip=ip)


class Hunt40a(ServerTestBase):

    def test_fan_post_right_after_own_tripod_keeps_the_tripod(self):
        """Новый клиент: веер «Тренога», через 6 с и 100 м — веер «Пост ДПС»
        (засада «тренога, за ней пост»). Веер не шлёт amend_id, сервер видит
        неявное уточнение и переписывает треногу в пост: тренога пропадает у всех."""
        tripod = _put(41.3100, 69.2500, ago=6, rtype="tripod")
        status, body = _post(self.port, 41.3109, 69.2500, "post")     # ~100 м
        self.assertEqual(_row(tripod)[0], "tripod",
                         f"тренога переписана в пост ({status} {body})")

    def test_own_radar_after_own_tripod_does_not_downgrade(self):
        """Тренога из веера на телефоне, через 20 с «Радар!» с CarPlay в 50 м:
        неявное уточнение перекрашивает треногу в радар — точный тип проигрывает,
        хотя в слиянии того же семейства правило обратное (побеждает тренога)."""
        tripod = _put(41.3100, 69.2500, ago=20, rtype="tripod")
        _post(self.port, 41.31045, 69.2500, "radar")
        self.assertEqual(_row(tripod)[0], "tripod", "тренога понижена до радара")

    def test_opposite_carriageway_tripod_is_a_new_point(self):
        """Проспект (primary, радиус 300 м): тренога на северной стороне;
        водитель, едущий на юг, отмечает свою треногу в 250 м на встречной
        стороне с курсом 180. Сервер сливает её в северную (курс не смотрит):
        южной точки нет, и едущие на юг получают оповещение о точке в 250 м
        от настоящей засады — после неё, если северная стоит дальше по их ходу."""
        north = _put(41.3100, 69.2500, ago=600, rtype="tripod", device="a",
                     ip="10.50.1.1", cls="primary", course=0.0)
        status, body = _post(self.port, 41.31225, 69.2500, "tripod", device="b",
                             ip="10.50.1.2", cls="primary", course=180.0)
        self.assertEqual(status, 200)
        self.assertFalse(body["merged"],
                         f"встречная тренога слита в точку {north}, своей точки нет")

    def test_queued_report_is_not_a_fresh_confirmation(self):
        """Отметка из очереди (без связи 40 мин назад) сливается с чужой
        треногой как свежее независимое подтверждение: полный срок (3 ч от
        создания) по наблюдению сорокаминутной давности. Тренога — это «сейчас»."""
        rid = _put(41.3100, 69.2500, ago=70 * 60, rtype="tripod", device="a",
                   ip="10.50.2.1", ttl=5 * 60)
        before = _row(rid)[1]
        status, body = _post(self.port, 41.3101, 69.2500, "tripod", device="b",
                             ip="10.50.2.2", age=40 * 60)
        self.assertTrue(body.get("merged"))
        after = _row(rid)[1]
        self.assertLessEqual(after, before + 1,
                             f"срок продлён на {int((after - before) / 60)} мин по старой отметке")

    def test_parallel_writes_do_not_fail(self):
        """BEGIN IMMEDIATE: 40 одновременных отметок и голосов — ни одного 5xx."""
        base = [_put(41.30 + i * 0.01, 69.25, ago=600, device=f"o{i}", ip=f"10.60.{i}.1")
                for i in range(20)]
        codes = []
        lock = threading.Lock()
        gate = threading.Barrier(40)

        def report(i):
            gate.wait()
            s, _ = _post(self.port, 41.0 + i * 0.01, 70.0, device=f"r{i}", ip=f"10.61.{i}.1")
            with lock:
                codes.append(s)

        def vote(i):
            gate.wait()
            s, _ = _call(self.port, "POST", "/api/vote",
                         {"id": base[i], "device": f"v{i}", "value": 1}, ip=f"10.62.{i}.1")
            with lock:
                codes.append(s)

        threads = [threading.Thread(target=report, args=(i,)) for i in range(20)] + \
                  [threading.Thread(target=vote, args=(i,)) for i in range(20)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(sorted(set(codes)), [200], f"коды: {codes}")



class Hunt40aQueue(ServerTestBase):

    def test_live_tap_after_queue_flush_is_not_too_fast(self):
        """Выехали из мёртвой зоны: «связь вернулась» досылает отметку A,
        поставленную 10 мин назад; через 30 с водитель жмёт «Тренога» у новой
        засады B в 2 км. «120 с между отметками» считается от ПРИЁМА A, а не
        от её времени — B получает 429 «Слишком часто» и теряется (в очередь
        отказ сервера не кладётся)."""
        s1, a = _post(self.port, 41.3000, 69.2500, "tripod", device="q", ip="10.70.0.1", age=600)
        self.assertEqual(s1, 200)
        conn = sqlite3.connect(api.DB_PATH)
        conn.execute("UPDATE reports SET created = created - 30 WHERE id = ?", (a["id"],))
        conn.commit()
        conn.close()
        s2, b = _post(self.port, 41.3180, 69.2500, "tripod", device="q", ip="10.70.0.1")
        self.assertEqual(s2, 200, f"живая отметка B отвергнута: {b}")


if __name__ == "__main__":
    unittest.main()
