#!/usr/bin/env python3
"""Тесты подсказок поворотов (89, docs/plan_89_turn_hints_2026-11-10.md):
счётчики выходов (traffic_build.turn_moves_from_match, store), подозрение
(traffic_build.turn_hints), запреты в turns.csv (traffic_speeds.banned_turns,
merge_bans) и экран «Повороты» панели (admin.py).

Перекрёсток — синтетический: узел 2, подход с юга (1 → 2), прямо — 3,
направо — 4, налево — 5; на выезд 5 въезжают с востока (4 → 2 → 5).
Сбор — на настоящем ответе OSRM стенда (fixtures/osrm_match_left_turn.json).
Запуск: python3 server/test_turn_hints.py
"""
import io
import json
import os
import shutil
import sqlite3
import tempfile
import time
import unittest
from contextlib import redirect_stdout

import admin
import api
import traffic_build as tb
import traffic_config as tc
import traffic_speeds as ts
import test_admin
from test_admin import _get, _get_full, _post

HERE = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(HERE, "fixtures", "osrm_match_left_turn.json"), encoding="utf-8") as f:
    FIXTURE = json.load(f)
LEFT = (4545270448, 4568983062, 7851505433)          # левый поворот фикстуры
NOW = 1_794_300_000.0                                # 15.11.2026
DAY = 86400
LEAKS = ("device", "ip", "created", "src", "gen", "piece", "ts", "received", "points", "trip")

NODES = {1: (41.2990, 69.2800), 2: (41.3000, 69.2800), 3: (41.3010, 69.2800),
         4: (41.3000, 69.2813), 5: (41.3000, 69.2787), 6: (41.3000, 69.2826)}
# Выезды подхода 1 → 2: азимут у узла 2, угол, разрешён ли въезд.
EXITS = ((0, 0, True), (90, 90, True), (180, -180, False), (270, -90, True))
EAST_EXITS = ((0, 90, True), (90, -180, False), (180, -90, True), (270, 0, True))
SUSPECT = (1, 2, 5)


def columns(conn, table):
    return {row[1] for row in conn.execute(f"PRAGMA table_info({table})")}


class Crossing:
    """Синтетический перекрёсток в traffic.db через настоящий store()."""

    def __init__(self, path):
        self.conn = sqlite3.connect(path)
        tb.schema(self.conn)
        self.conn.executemany("INSERT OR REPLACE INTO traffic_nodes(id, lat, lon) VALUES(?, ?, ?)",
                              [(i, lat, lon) for i, (lat, lon) in NODES.items()])
        self.conn.executemany("INSERT OR REPLACE INTO traffic_edges(u, v, model_kmh) VALUES(?, ?, ?)",
                              [(1, 2, 40), (2, 3, 40), (2, 4, 40), (2, 5, 40), (4, 2, 40), (6, 4, 40)])
        self.share(1, 2)

    def share(self, u, v, seen=None):
        seen = NOW if seen is None else seen
        self.conn.execute("INSERT OR REPLACE INTO traffic_shared(u, v, seen) VALUES(?, ?, ?)", (u, v, seen))
        self.conn.commit()

    def drive(self, move, days, per_day, start=0):
        """`per_day` проездов `move` в каждый из `days` дней, начиная `start`
        дней назад."""
        for d in range(start, start + days):
            at = NOW - d * DAY
            for _ in range(per_day):
                tb.store(self.conn, 0, [], {}, {}, at, moves=[move])
        self.conn.commit()

    def straight(self, days=12, per_day=5, start=0, exits=EXITS):
        self.drive((1, 2, 3, 0, exits), days, per_day, start)

    def other_side(self, days=3, per_day=1):
        """С востока прямо на запад — на выезд 5: дорога проезжая, узел известен."""
        self.drive((4, 2, 5, 270, EAST_EXITS), days, per_day)

    def hints(self, now=NOW, skip=frozenset()):
        return tb.turn_hints(self.conn, now, skip)

    def triples(self, **kwargs):
        return [(h["u"], h["v"], h["w"]) for h in self.hints(**kwargs)]


class MovesFromMatchTest(unittest.TestCase):

    def test_every_crossing_node_is_counted_with_graph_exits(self):
        moves = tb.turn_moves_from_match(FIXTURE["response"], FIXTURE["points"])
        by_key = {m[:3]: m for m in moves}
        self.assertIn(LEFT, by_key)
        _, _, _, out_bearing, exits = by_key[LEFT]
        self.assertEqual(out_bearing, 315)
        table = {b: (angle, ok) for b, angle, ok in exits}
        self.assertEqual(tb.maneuver(table[315][0]), "left")
        self.assertTrue(table[315][1], "поворот, которым проехали, граф разрешает")
        self.assertEqual(table[30], (0, True), "прямо")
        self.assertEqual(table[210], (-180, False), "разворот на этом узле запрещён графом")
        # Узел сразу за поворотом (19 м) 33B сливает с ним в один манёвр, а
        # счётчик выходов видит отдельно — иначе въезд в разрыв
        # разделительной с первого подхода был бы не виден.
        self.assertIn((LEFT[1], LEFT[2], 13285994603), by_key)
        self.assertNotIn((LEFT[1], LEFT[2], 13285994603), {t[:3] for t in
                                                            tb.turns_from_match(FIXTURE["response"], FIXTURE["points"])})

    def test_without_steps_nothing_is_counted(self):
        bare = json.loads(json.dumps(FIXTURE["response"]))
        for matching in bare["matchings"]:
            for leg in matching["legs"]:
                leg.pop("steps", None)
        self.assertEqual(tb.turn_moves_from_match(bare, FIXTURE["points"]), [])

    def test_exit_angle_signs(self):
        bearings = [180, 0, 90, 270]
        self.assertEqual([tb.exit_angle(bearings, 0, b) for b in bearings], [-180, 0, 90, -90])


class StoreTest(unittest.TestCase):

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.conn = sqlite3.connect(os.path.join(self.dir, "traffic.db"))
        tb.schema(self.conn)

    def tearDown(self):
        self.conn.close()
        shutil.rmtree(self.dir, ignore_errors=True)

    def test_process_counts_passes_per_day(self):
        for _ in range(3):
            self.conn.execute("INSERT INTO traffic_pieces(received, points, src, gen) VALUES(?, ?, 'abcd1234', 1)",
                              (NOW, json.dumps(FIXTURE["points"])))
        self.conn.commit()
        tb.process(self.conn, NOW, matcher=lambda points: FIXTURE["response"])
        row = self.conn.execute("SELECT day, bearing, n FROM traffic_turn_moves WHERE u = ? AND v = ? AND w = ?",
                                LEFT).fetchone()
        self.assertEqual(row, (tb.day_number(NOW), 315, 3), "три куска — счётчик 3 в одной строке дня")
        exits = self.conn.execute("SELECT bearing, entry FROM traffic_turn_exits WHERE u = ? AND v = ?",
                                  LEFT[:2]).fetchall()
        self.assertEqual(sorted(exits), [(30, 1), (120, 0), (210, 0), (315, 1)])

    def test_new_tables_hold_only_counters(self):
        for table in ("traffic_turn_moves", "traffic_turn_exits"):
            names = columns(self.conn, table)
            self.assertTrue(names, table)
            for leak in LEAKS:
                self.assertNotIn(leak, names, f"{table}.{leak}")
        self.assertEqual(columns(self.conn, "traffic_turn_moves"), {"u", "v", "w", "day", "bearing", "n"})

    def test_counters_age_out_of_the_window(self):
        crossing = Crossing(os.path.join(self.dir, "aging.db"))
        crossing.straight(days=1, per_day=1, start=tc.TURN_HINT_DAYS)
        crossing.straight(days=1, per_day=1, start=0)
        tb.maintain_profile(crossing.conn, NOW)
        days = [row[0] for row in crossing.conn.execute("SELECT day FROM traffic_turn_moves")]
        self.assertEqual(days, [tb.day_number(NOW)], "старше окна — удалено")
        self.assertEqual({row[0] for row in crossing.conn.execute("SELECT day FROM traffic_turn_exits")},
                         {tb.day_number(NOW)})
        crossing.conn.close()


class HintsTest(unittest.TestCase):

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.x = Crossing(os.path.join(self.dir, "traffic.db"))

    def tearDown(self):
        self.x.conn.close()
        shutil.rmtree(self.dir, ignore_errors=True)

    def test_nobody_turned_left_is_a_suspicion(self):
        self.x.straight()
        self.x.other_side()
        hints = self.x.hints()
        self.assertEqual([(h["u"], h["v"], h["w"]) for h in hints], [SUSPECT])
        hint = hints[0]
        self.assertEqual((hint["kind"], hint["angle"], hint["passes"], hint["days"]), ("left", -90, 60, 12))
        self.assertEqual((hint["exit_passes"], hint["exit_days"]), (3, 3))
        self.assertEqual(hint["at"], NODES[2])
        self.assertEqual([(t["w"], t["n"]) for t in hint["taken"]], [(3, 60)])

    def test_little_data_is_silence(self):
        self.x.other_side()
        self.x.straight(days=12, per_day=4)
        self.x.drive((1, 2, 3, 0, EXITS), days=1, per_day=11)
        self.assertEqual(self.x.hints(), [], "59 проездов — мало")
        self.x.conn.execute("DELETE FROM traffic_turn_moves WHERE u = 1")
        self.x.straight(days=11, per_day=10)
        self.assertEqual(self.x.hints(), [], "110 проездов за 11 дней — мало дней")
        self.x.straight(days=1, per_day=1, start=11)
        self.assertEqual(self.x.triples(), [SUSPECT], "12-й день — подсказка")

    def test_one_turn_is_enough_to_stay_silent(self):
        self.x.straight()
        self.x.other_side()
        self.x.drive((1, 2, 5, 270, EXITS), days=1, per_day=1)
        self.assertEqual(self.x.hints(), [])

    def test_a_turn_under_an_older_bearing_still_counts(self):
        self.x.straight()
        self.x.other_side()
        self.x.drive((1, 2, 5, 268, ()), days=1, per_day=1, start=5)   # до пересборки графа
        self.assertEqual(self.x.hints(), [], "поворот к тому же узлу — поворот, какой бы ни был азимут")

    def test_only_left_and_u_turns(self):
        self.x.straight()
        self.x.other_side()
        self.x.drive((3, 2, 4, 90, ()), days=3, per_day=1)    # на выезд 4 въезжают с севера,
                                                              # направо с юга — никто
        self.assertEqual(self.x.triples(), [SUSPECT], "направо не предлагается")

    def test_u_turn_is_suggested_when_the_graph_allows_it(self):
        exits = ((0, 0, True), (180, -180, True))
        self.x.straight(exits=exits)
        self.x.drive((3, 2, 1, 180, ()), days=3, per_day=1)
        self.x.conn.execute("INSERT INTO traffic_edges(u, v, model_kmh) VALUES(2, 1, 40)")
        hints = self.x.hints()
        self.assertEqual([(h["u"], h["v"], h["w"], h["kind"]) for h in hints], [(1, 2, 1, "uturn")])

    def test_forbidden_by_the_graph_is_not_a_hint(self):
        exits = tuple((b, a, False if b == 270 else ok) for b, a, ok in EXITS)
        self.x.straight(exits=exits)
        self.x.other_side()
        self.assertEqual(self.x.hints(), [], "запрет уже в OSM — нечего предлагать")

    def test_yards_and_unknown_roads_are_silent(self):
        self.x.straight()
        self.assertEqual(self.x.hints(), [], "на выезд никто не въезжал — узел и дорога неизвестны")
        self.x.other_side(days=2)
        self.assertEqual(self.x.hints(), [], "въезжали в 2 дня — мало")
        self.x.other_side(days=3)
        self.x.conn.execute("UPDATE traffic_edges SET model_kmh = 15 WHERE u = 2 AND v = 5")
        self.assertEqual(self.x.hints(), [], "выезд во двор (service) — не предлагается")
        self.x.conn.execute("UPDATE traffic_edges SET model_kmh = 40 WHERE u = 2 AND v = 5")
        self.x.conn.execute("UPDATE traffic_edges SET model_kmh = 20 WHERE u = 1 AND v = 2")
        self.assertEqual(self.x.hints(), [], "подход со двора — не предлагается")

    def test_one_person_is_not_a_hint(self):
        self.x.straight()
        self.x.other_side()
        self.x.conn.execute("DELETE FROM traffic_shared")
        self.assertEqual(self.x.hints(), [], "подход ни разу не прошли двое — может быть один человек")
        self.x.share(1, 2, seen=NOW - tb.SHARED_TTL - 1)
        self.assertEqual(self.x.hints(), [], "отметка «не один» просрочена")

    def test_stale_graph_exits_are_ignored(self):
        self.x.straight(days=12, per_day=5, start=1, exits=EXITS)
        self.x.other_side()
        new_graph = ((0, 0, True), (90, 90, True), (268, -92, False))
        self.x.straight(days=1, per_day=1, exits=new_graph)
        self.assertEqual(self.x.hints(), [], "на последнем проезде граф показал другой набор выездов")

    def test_decided_triples_are_skipped(self):
        self.x.straight()
        self.x.other_side()
        self.assertEqual(self.x.hints(skip=frozenset({SUSPECT})), [])


class TurnsFileTest(unittest.TestCase):

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.reports = os.path.join(self.dir, "reports.db")
        self.saved = admin.DB_PATH, api.DB_PATH
        admin.DB_PATH = api.DB_PATH = self.reports
        api.init_db()
        admin.init_db()

    def tearDown(self):
        admin.DB_PATH, api.DB_PATH = self.saved
        shutil.rmtree(self.dir, ignore_errors=True)

    def decide(self, key, decision):
        conn = sqlite3.connect(self.reports)
        conn.execute("INSERT OR REPLACE INTO turn_decisions(u, v, w, decision, decided_at) VALUES(?, ?, ?, ?, ?)",
                     key + (decision, NOW))
        conn.commit()
        conn.close()

    def test_only_bans_are_read(self):
        self.decide(LEFT, "ban")
        self.decide((1, 2, 3), "allow")
        self.decide((1, 2, 4), "later")
        self.assertEqual(ts.banned_turns(self.reports), [LEFT])

    def test_without_the_table_or_file_there_are_no_bans(self):
        self.assertEqual(ts.banned_turns(os.path.join(self.dir, "missing.db")), [])
        empty = os.path.join(self.dir, "empty.db")
        sqlite3.connect(empty).close()
        self.assertEqual(ts.banned_turns(empty), [])

    def test_merge_takes_the_bigger_value_and_survives_the_cap(self):
        rows = [(1, 2, 3, 40, 20.0), LEFT + (90, 70.0)]
        merged = ts.merge_bans(rows, [LEFT, (7, 8, 9)])
        self.assertEqual([row[:4] for row in merged],
                         [(1, 2, 3, 40), (7, 8, 9, tc.TURN_BAN_PENALTY), LEFT + (tc.TURN_BAN_PENALTY,)])
        self.assertEqual(ts.merge_bans([LEFT + (900, 1.0)], [LEFT])[0][3], 900, "задержка больше штрафа — она")
        kept, trimmed = ts.cap_turns(merged, limit=2)
        self.assertEqual(trimmed, 1)
        self.assertNotIn((1, 2, 3), [row[:3] for row in kept], "потолок обрезает задержку, а не запрет")
        self.assertEqual(ts.turns_body(kept), f"7,8,9,{tc.TURN_BAN_PENALTY}\n"
                                              f"{LEFT[0]},{LEFT[1]},{LEFT[2]},{tc.TURN_BAN_PENALTY}\n")

    def test_route_run_writes_the_penalty(self):
        traffic = os.path.join(self.dir, "traffic.db")
        conn = sqlite3.connect(traffic)
        tb.schema(conn)
        conn.close()
        self.decide(LEFT, "ban")
        speeds, turns = os.path.join(self.dir, "speeds.csv"), os.path.join(self.dir, "turns.csv")
        out = io.StringIO()
        with redirect_stdout(out):
            code = ts.main(["--db", traffic, "--out", speeds, "--turns-out", turns, "--source", "route",
                            "--now", str(NOW), "--model", "", "--reports-db", self.reports,
                            "--events-cache", os.path.join(self.dir, "events.json")])
        self.assertEqual(code, 0, out.getvalue())
        with open(turns, encoding="ascii") as f:
            self.assertEqual(f.read(), f"{LEFT[0]},{LEFT[1]},{LEFT[2]},{tc.TURN_BAN_PENALTY}\n")
        self.assertIn("запретов 1", out.getvalue())
        with open(speeds, encoding="ascii") as f:
            self.assertEqual(f.read(), "", "запрет не трогает файл скоростей")

    def test_switch_turns_bans_off(self):
        self.decide(LEFT, "ban")
        traffic = os.path.join(self.dir, "traffic.db")
        conn = sqlite3.connect(traffic)
        tb.schema(conn)
        conn.close()
        turns = os.path.join(self.dir, "turns.csv")
        saved, tc.LAYER_TURN_BANS = tc.LAYER_TURN_BANS, False
        try:
            with redirect_stdout(io.StringIO()):
                ts.main(["--db", traffic, "--out", os.path.join(self.dir, "speeds.csv"), "--turns-out", turns,
                         "--source", "route", "--now", str(NOW), "--model", "", "--reports-db", self.reports,
                         "--events-cache", os.path.join(self.dir, "events.json")])
        finally:
            tc.LAYER_TURN_BANS = saved
        with open(turns, encoding="ascii") as f:
            self.assertEqual(f.read(), "")


class TurnsPanelTest(unittest.TestCase):
    """Экран «Повороты»: стенд test_admin.AdminTest (сервер, база, вход) без его тестов."""

    login = test_admin.AdminTest.login

    @classmethod
    def setUpClass(cls):
        test_admin.AdminTest.setUpClass.__func__(cls)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.saved = admin.TRAFFIC_DB_PATH
        admin.TRAFFIC_DB_PATH = os.path.join(self.dir, "traffic.db")
        conn = admin.db()
        conn.execute("DELETE FROM turn_decisions")
        conn.commit()
        conn.close()

    def tearDown(self):
        admin.TRAFFIC_DB_PATH = self.saved
        shutil.rmtree(self.dir, ignore_errors=True)

    def suspect(self, now=None):
        """Подсказка у «сейчас» сервера: панель считает от time.time()."""
        global NOW
        saved, NOW = NOW, now or time.time()
        try:
            x = Crossing(admin.TRAFFIC_DB_PATH)
            x.straight()
            x.other_side()
            x.conn.close()
        finally:
            NOW = saved

    def act(self, action, key=SUSPECT, note=""):
        return _post(self.port, "/turns/act", {"u": key[0], "v": key[1], "w": key[2],
                                               "action": action, "note": note})

    def decisions(self):
        conn = admin.db()
        try:
            return [tuple(row) for row in conn.execute("SELECT u, v, w, decision FROM turn_decisions")]
        finally:
            conn.close()

    def test_without_traffic_db_the_page_says_so(self):
        status, body = _get(self.port, "/turns")
        self.assertEqual(status, 200)
        self.assertIn("traffic.db ещё нет", body)

    def test_queue_shows_the_suspicion_with_a_scheme(self):
        self.suspect()
        status, body = _get(self.port, "/turns")
        self.assertEqual(status, 200)
        self.assertIn("Ждут решения (1)", body)
        self.assertIn("0 из 60", body)
        self.assertIn("<svg", body)
        self.assertIn("https://www.openstreetmap.org/node/2", body)
        self.assertNotIn("<script", body, "серверный HTML, без скриптов")

    def test_ban_leaves_the_queue_and_reaches_the_export_and_the_file(self):
        self.suspect()
        self.assertEqual(self.act("ban", note="знак 4.1.1"), 303)
        self.assertEqual(self.decisions(), [SUSPECT + ("ban",)])
        _, body = _get(self.port, "/turns")
        self.assertIn("Ждут решения (0)", body)
        self.assertIn("Запрещено (1)", body)
        _, page = _get(self.port, "/turns/osm")
        self.assertIn("no_left_turn", page)
        self.assertIn("https://www.openstreetmap.org/edit?node=2", page)
        status, raw, headers = _get_full(self.port, "/turns.geojson")
        self.assertEqual(status, 200)
        self.assertIn("geo+json", headers.get("Content-Type", ""))
        geo = json.loads(raw)
        self.assertEqual(len(geo["features"]), 1)
        feature = geo["features"][0]
        self.assertEqual((feature["properties"]["from_node"], feature["properties"]["via_node"],
                          feature["properties"]["to_node"]), SUSPECT)
        self.assertEqual(feature["geometry"]["coordinates"][1], [NODES[2][1], NODES[2][0]])
        self.assertEqual(ts.banned_turns(admin.DB_PATH), [SUSPECT], "стенд читает то, что решил модератор")
        self.assertEqual(self.act("undo"), 303)
        self.assertEqual(self.decisions(), [])
        _, body = _get(self.port, "/turns")
        self.assertIn("Ждут решения (1)", body, "снятый запрет возвращается в очередь")

    def test_turning_after_a_ban_is_flagged(self):
        self.suspect()
        self.act("ban")
        _, body = _get(self.port, "/turns")
        self.assertNotIn("после запрета повернули", body)
        x = Crossing(admin.TRAFFIC_DB_PATH)
        conn = admin.db()
        conn.execute("UPDATE turn_decisions SET decided_at = ?", (time.time() - 2 * DAY,))
        conn.commit()
        conn.close()
        global NOW
        saved, NOW = NOW, time.time()
        try:
            x.drive((1, 2, 5, 270, EXITS), days=1, per_day=2)
        finally:
            NOW = saved
            x.conn.close()
        _, body = _get(self.port, "/turns")
        self.assertIn("после запрета повернули 2 раз", body)

    def test_allowed_is_never_suggested_again(self):
        self.suspect()
        self.act("allow")
        self.assertEqual(self.decisions(), [SUSPECT + ("allow",)])
        _, body = _get(self.port, "/turns")
        self.assertIn("Ждут решения (0)", body)
        self.assertEqual(ts.banned_turns(admin.DB_PATH), [], "«разрешено» в граф не идёт")

    def test_later_hides_until_the_snooze_ends(self):
        self.suspect()
        self.act("later")
        conn = admin.db()
        until = conn.execute("SELECT until FROM turn_decisions").fetchone()[0]
        self.assertGreater(until, time.time() + (tc.TURN_HINT_SNOOZE_DAYS - 1) * DAY)
        self.assertIn(SUSPECT, admin.turn_decided(conn, time.time()))
        self.assertNotIn(SUSPECT, admin.turn_decided(conn, until + 1), "срок вышел — снова в очереди")
        conn.close()

    def test_a_triple_outside_the_queue_is_refused(self):
        self.suspect()
        self.act("ban", key=(1, 2, 3))
        self.act("explode")
        self.assertEqual(self.decisions(), [], "решение только по тому, что в очереди")

    def test_decision_table_holds_no_driver_data(self):
        conn = admin.db()
        names = columns(conn, "turn_decisions")
        conn.close()
        for leak in LEAKS:
            self.assertNotIn(leak, names)


if __name__ == "__main__":
    unittest.main()
