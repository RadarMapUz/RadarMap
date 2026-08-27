#!/usr/bin/env python3
"""Тесты очереди изменений OSM.

Каждый тест здесь — про границу между «чиню сам» и «спрашиваю». Она проведена
по одному признаку: автоматика вправе ДВИГАТЬ объект, но не вправе решать, что
он больше не нужен. Сдвинуть на два метра — её работа. Снять с публикации —
решение человека, и подменять его удобством нельзя: правка, снятая молча, не
оставит следа, по которому через полгода можно было бы понять, что случилось.
"""
import json
import os
import shutil
import sqlite3
import tempfile
import unittest

import map_edits
import osm_queue


def line(*coords):
    return [(lon, lat) for lat, lon in coords]


def road(cls, points, name=""):
    return {"cls": cls, "flags": 0, "points": points, "name": name}


class ReconcileTests(unittest.TestCase):

    def setUp(self):
        self.before = [road(3, line((41.300, 69.2500), (41.310, 69.2500)), "Навои")]
        self.point = (69.25005, 41.3050)
        snapped = map_edits.snap(self.point, self.before)
        self.edit = {
            "id": 1, "version": 1, "kind": "lanes",
            "raw": list(self.point), "geom": list(snapped.point),
            "anchor": snapped.anchor, "props": {"lanes": 4}, "note": "",
            "fingerprint": map_edits.fingerprint(self.point, self.before),
        }

    def moved(self, degrees):
        """Та же улица, сдвинутая на восток."""
        return [road(3, line((41.300, 69.2500 + degrees),
                             (41.310, 69.2500 + degrees)), "Навои")]

    def test_unchanged_surroundings_cost_nothing(self):
        # Самый частый случай, и он не должен стоить ни одной посадки.
        verdict, point, _ = osm_queue.reconcile(self.edit, self.before)
        self.assertEqual(verdict, osm_queue.KEEP)
        self.assertIsNone(point)

    def test_small_shift_is_fixed_silently(self):
        # Два метра — ширина обочины: ни полоса, ни сторона перекрёстка от
        # такого сдвига не меняются.
        verdict, point, shift = osm_queue.reconcile(self.edit, self.moved(0.000024))
        self.assertEqual(verdict, osm_queue.RESETTLED)
        self.assertIsNotNone(point)
        self.assertLessEqual(shift, osm_queue.SILENT_METERS)

    def test_medium_shift_is_fixed_but_flagged(self):
        # Подвинули, но человек пусть посмотрит: на таком сдвиге объект уже мог
        # оказаться не на той стороне.
        verdict, point, shift = osm_queue.reconcile(self.edit, self.moved(0.00008))
        self.assertEqual(verdict, osm_queue.CHECK)
        self.assertIsNotNone(point)
        self.assertGreater(shift, osm_queue.SILENT_METERS)

    def test_big_shift_is_never_fixed_by_the_machine(self):
        # Полпроспекта. Двигать вслепую нельзя — объект может уехать на
        # встречную проезжую часть.
        verdict, point, _ = osm_queue.reconcile(self.edit, self.moved(0.0003))
        self.assertEqual(verdict, osm_queue.LOST)
        self.assertIsNone(point, "автоматика не двигает на такой сдвиг")

    def test_road_gone_means_ask(self):
        verdict, point, _ = osm_queue.reconcile(self.edit, [])
        self.assertEqual(verdict, osm_queue.LOST)
        self.assertIsNone(point)

    def test_newly_ambiguous_place_is_not_guessed(self):
        # Там, где была одна дорога, теперь две в трёх метрах. Это ровно тот
        # проспект с дублёром, ради которого магнит не гадает.
        twins = self.moved(0.000024) + self.moved(0.00005)
        verdict, point, _ = osm_queue.reconcile(self.edit, twins)
        self.assertEqual(verdict, osm_queue.LOST)
        self.assertIsNone(point)

    def test_resettling_starts_from_the_human_click(self):
        # Посадка от посадки накапливает ошибку: объект уползает каждую неделю,
        # оставаясь каждый раз «в пределах трёх метров». От исходного намерения
        # он не уползает никогда.
        #
        # Различаем так: дорога идёт с юга на север, значит проекция сохраняет
        # ШИРОТУ той точки, от которой сажали. Прошлая посадка лежит на два
        # метра южнее клика — и если пересадка пойдёт от неё, широта уедет туда.
        drifted = dict(self.edit, geom=[69.250024, 41.30498])
        verdict, point, _ = osm_queue.reconcile(drifted, self.moved(0.000024))
        self.assertEqual(verdict, osm_queue.RESETTLED)
        self.assertAlmostEqual(point[1], self.point[1], places=5,
                               msg="пересадили от прошлой посадки, а не от raw")

    def test_edit_without_raw_is_not_moved_at_random(self):
        broken = dict(self.edit, raw=[])
        verdict, point, _ = osm_queue.reconcile(broken, self.before)
        self.assertEqual(verdict, osm_queue.LOST)
        self.assertIsNone(point)


class LockedAreaTests(unittest.TestCase):
    """Размеченная область: смотрим, но не двигаем.

    Ради этого правила и затевалась своя карта. Перекрёсток, который человек
    разметил по спутнику, не должен уезжать за тем, как его в очередной раз
    перерисовал случайный картограф: без области каждая воскресная пересборка
    отчасти обесценивает предыдущую неделю работы, причём молча.

    Автоматика при этом не слепнет — она считает сдвиг и докладывает. Меняется
    одно: решение принимает человек.
    """

    def setUp(self):
        self.roads = [road(3, line((41.300, 69.2500), (41.310, 69.2500)), "Навои")]
        self.point = (69.25005, 41.3050)
        snapped = map_edits.snap(self.point, self.roads)
        self.edit = {"id": 1, "version": 1, "kind": "lanes",
                     "raw": list(self.point), "geom": list(snapped.point),
                     "props": {"lanes": 4}, "note": "",
                     "fingerprint": map_edits.fingerprint(self.point, self.roads)}
        self.moved = [road(3, line((41.300, 69.25008), (41.310, 69.25008)), "Навои")]

    def test_without_an_area_the_machine_moves_it(self):
        verdict, point, _ = osm_queue.reconcile(self.edit, self.moved)
        self.assertIn(verdict, (osm_queue.RESETTLED, osm_queue.CHECK))
        self.assertIsNotNone(point)

    def test_inside_an_area_nothing_is_moved(self):
        areas = [(self.point, 120.0)]
        verdict, point, shift = osm_queue.reconcile(self.edit, self.moved, areas)
        self.assertEqual(verdict, osm_queue.LOCKED)
        self.assertIsNone(point, "автоматика подвинула размеченное")
        self.assertGreater(shift, 0, "но сдвиг обязана показать")

    def test_area_does_not_reach_the_next_district(self):
        far = [((69.40, 41.40), 120.0)]
        verdict, point, _ = osm_queue.reconcile(self.edit, self.moved, far)
        self.assertNotEqual(verdict, osm_queue.LOCKED)
        self.assertIsNotNone(point)

    def test_unchanged_place_inside_an_area_is_still_quiet(self):
        # Область не должна поднимать шум там, где ничего не менялось: иначе
        # очередь наполнится сама собой и её перестанут открывать.
        areas = [(self.point, 120.0)]
        verdict, _, _ = osm_queue.reconcile(self.edit, self.roads, areas)
        self.assertEqual(verdict, osm_queue.KEEP)

    def test_area_itself_is_not_swept(self):
        conn = sqlite3.connect(":memory:")
        conn.row_factory = sqlite3.Row
        map_edits.ensure_tables(conn)
        map_edits.create(conn, "lock", raw=[69.25, 41.30], snapped=[69.25, 41.30],
                         props={"radius": 150}, status=map_edits.ACCEPTED)
        try:
            self.assertEqual(osm_queue.sweep(conn, self.roads), [],
                             "область — не правка геометрии, сверять её не с чем")
        finally:
            conn.close()

    def test_area_is_read_from_the_table(self):
        conn = sqlite3.connect(":memory:")
        conn.row_factory = sqlite3.Row
        map_edits.ensure_tables(conn)
        map_edits.create(conn, "lock", raw=list(self.point),
                         snapped=list(self.point), props={"radius": 150},
                         status=map_edits.ACCEPTED)
        try:
            areas = map_edits.locks(conn)
            self.assertEqual(len(areas), 1)
            self.assertTrue(map_edits.inside_lock(self.point, areas))
            self.assertFalse(map_edits.inside_lock((69.40, 41.40), areas))
        finally:
            conn.close()

    def test_draft_area_does_not_protect_anything(self):
        # Черновик не едет на телефоны и не должен менять поведение сборки.
        conn = sqlite3.connect(":memory:")
        conn.row_factory = sqlite3.Row
        map_edits.ensure_tables(conn)
        map_edits.create(conn, "lock", raw=list(self.point),
                         snapped=list(self.point), props={"radius": 150})
        try:
            self.assertEqual(map_edits.locks(conn), [])
        finally:
            conn.close()

    def test_absurd_radius_is_trimmed(self):
        conn = sqlite3.connect(":memory:")
        conn.row_factory = sqlite3.Row
        map_edits.ensure_tables(conn)
        map_edits.create(conn, "lock", raw=list(self.point),
                         snapped=list(self.point), props={"radius": 999999},
                         status=map_edits.ACCEPTED)
        try:
            self.assertLessEqual(map_edits.locks(conn)[0][1],
                                 map_edits.MAX_LOCK_METERS)
        finally:
            conn.close()


class CaughtUpTests(unittest.TestCase):

    def test_osm_catching_up_is_noticed(self):
        # Своя дорога живёт, пока OSM её не догнал, и панель обязана сказать,
        # когда это случилось.
        ours = {"kind": "geometry", "geom": [69.2500, 41.3050]}
        real = [road(6, line((41.300, 69.25005), (41.310, 69.25005)))]
        self.assertTrue(osm_queue.caught_up(ours, real))

    def test_far_away_road_is_not_catching_up(self):
        ours = {"kind": "geometry", "geom": [69.2500, 41.3050]}
        far = [road(6, line((41.300, 69.2600), (41.310, 69.2600)))]
        self.assertFalse(osm_queue.caught_up(ours, far))

    def test_rule_applies_only_to_our_own_geometry(self):
        # У правки полос опоры в OSM есть по определению: соседняя дорога рядом
        # с ней — не новость, а норма.
        lanes = {"kind": "lanes", "geom": [69.2500, 41.3050]}
        real = [road(6, line((41.300, 69.25005), (41.310, 69.25005)))]
        self.assertFalse(osm_queue.caught_up(lanes, real))


class SweepTests(unittest.TestCase):

    def setUp(self):
        self.conn = sqlite3.connect(":memory:")
        self.conn.row_factory = sqlite3.Row
        map_edits.ensure_tables(self.conn)
        self.roads = [road(3, line((41.300, 69.2500), (41.310, 69.2500)), "Навои")]
        point = (69.25005, 41.3050)
        snapped = map_edits.snap(point, self.roads)
        self.edit_id = map_edits.create(
            self.conn, "lanes", raw=list(point), snapped=list(snapped.point),
            anchor=snapped.anchor, props={"lanes": 4},
            fingerprint_value=map_edits.fingerprint(point, self.roads),
            status=map_edits.ACCEPTED)

    def tearDown(self):
        self.conn.close()

    def moved(self, degrees):
        return [road(3, line((41.300, 69.2500 + degrees),
                             (41.310, 69.2500 + degrees)), "Навои")]

    def test_drafts_are_not_swept(self):
        # Черновик на телефоны не едет, и трогать его пересборка не должна.
        map_edits.create(self.conn, "lanes", raw=[69.25, 41.3], snapped=[69.25, 41.3])
        self.assertEqual(len(osm_queue.sweep(self.conn, self.roads)), 1)

    def test_small_shift_is_applied(self):
        decisions = osm_queue.sweep(self.conn, self.moved(0.000024))
        moved, queued = osm_queue.apply_sweep(self.conn, decisions)
        self.assertEqual((moved, queued), (1, 0))

    def test_lost_edit_is_queued_but_stays_published(self):
        # Снятие с публикации — решение человека. Автоматика лишь показывает.
        decisions = osm_queue.sweep(self.conn, [])
        moved, queued = osm_queue.apply_sweep(self.conn, decisions)
        self.assertEqual((moved, queued), (0, 1))
        row = self.conn.execute("SELECT status FROM map_edits WHERE id = ?",
                                (self.edit_id,)).fetchone()
        self.assertEqual(row["status"], map_edits.ACCEPTED,
                         "автоматика сняла правку сама — так нельзя")

    def test_flagged_edit_says_why_in_its_note(self):
        # Через полгода «почему эта правка помечена» вспомнит только заметка.
        decisions = osm_queue.sweep(self.conn, self.moved(0.00008))
        osm_queue.apply_sweep(self.conn, decisions)
        row = self.conn.execute("SELECT note FROM map_edits WHERE id = ?",
                                (self.edit_id,)).fetchone()
        self.assertIn("проверить", row["note"])

    def test_note_is_not_stamped_twice(self):
        for _ in range(3):
            osm_queue.apply_sweep(self.conn, osm_queue.sweep(self.conn, self.moved(0.00008)))
        row = self.conn.execute("SELECT note FROM map_edits WHERE id = ?",
                                (self.edit_id,)).fetchone()
        self.assertLessEqual(row["note"].count("проверить"), 1,
                             "заметка распухает с каждой пересборкой")

    def test_summary_counts_by_verdict(self):
        counts = osm_queue.summary(osm_queue.sweep(self.conn, self.roads))
        self.assertEqual(counts, {osm_queue.KEEP: 1})


if __name__ == "__main__":
    unittest.main()

class IdentityReconcileTests(unittest.TestCase):
    """Сверка по id из OSM.

    Смысл опоры — снять из очереди то, что не двигалось. До неё в «пересажены,
    стоит посмотреть» падало всё, что шевельнулось хоть на метр, и очередь
    росла пропорционально числу правок.

    Порядок обязателен: отпечаток → id → геометрия. Id не заменяет
    геометрический поиск, а предшествует ему, и его исчезновение возвращает
    ровно прежнее поведение.
    """

    def setUp(self):
        self.work = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.work, True)

    def identities(self, rows):
        row = int((41.30 + 90) / map_edits.TILE_DEGREES_V1)
        column = int((69.25 + 180) / map_edits.TILE_DEGREES_V1)
        with open(os.path.join(self.work, f"ids_{row}_{column}.json"),
                  "w", encoding="utf-8") as handle:
            json.dump({"version": 1, "roads": rows}, handle)

    def road(self, lat=41.30, lon=69.25):
        return {"cls": 3, "flags": 0, "name": "Навои",
                "points": [(lon, lat), (lon, lat + 0.002)]}

    def edit(self, osm_id=None, lat=41.30, lon=69.25):
        anchor = {"cls": 3, "name": "Навои", "bearing": 0.0, "atNode": False}
        if osm_id:
            anchor["osmId"] = osm_id
        return {"kind": "lanes", "raw": [lon, lat], "geom": [lon, lat],
                "anchor": anchor, "props": {}, "fingerprint": None}

    def test_road_that_did_not_move_stays_out_of_the_queue(self):
        self.identities([["w1", round(41.30 * 1e5), round(69.25 * 1e5), 0.0, 3]])
        verdict, point, shift = osm_queue.reconcile(
            self.edit("w1"), [self.road()], (), self.work)
        self.assertEqual(verdict, osm_queue.KEEP)
        self.assertIsNone(point)

    def test_small_move_is_resettled_silently_by_id(self):
        self.identities([["w1", round(41.3001 * 1e5), round(69.25 * 1e5), 0.0, 3]])
        verdict, point, shift = osm_queue.reconcile(
            self.edit("w1"), [self.road()], (), self.work)
        self.assertEqual(verdict, osm_queue.RESETTLED)
        self.assertIsNotNone(point)
        self.assertGreater(shift, 0)

    def test_big_move_with_the_same_id_asks_a_human(self):
        # Дорога с тем же id уехала дальше, чем бывает от правки геометрии.
        self.identities([["w1", round(41.303 * 1e5), round(69.25 * 1e5), 0.0, 3]])
        verdict, _, shift = osm_queue.reconcile(
            self.edit("w1"), [self.road()], (), self.work)
        self.assertEqual(verdict, osm_queue.CHECK)
        self.assertGreater(shift, osm_queue.SILENT_METERS)

    def test_vanished_id_falls_back_to_geometry(self):
        # Способ разрезали или удалили — работает прежний путь, а не «потеряла
        # опору».
        self.identities([["w999", round(41.30 * 1e5), round(69.25 * 1e5), 0.0, 3]])
        verdict, _, _ = osm_queue.reconcile(
            self.edit("w1"), [self.road()], (), self.work)
        self.assertIn(verdict, (osm_queue.KEEP, osm_queue.RESETTLED))

    def test_without_identity_files_nothing_changes(self):
        # Экстракт без -u type_id: опоры нет, всё работает как раньше.
        verdict, _, _ = osm_queue.reconcile(
            self.edit("w1"), [self.road()], (), self.work)
        self.assertIn(verdict, (osm_queue.KEEP, osm_queue.RESETTLED))

    def test_marked_area_still_wins_over_the_identity(self):
        # Внутри размеченной области автоматика не двигает НИЧЕГО, даже когда
        # уверена: там разбирались руками.
        self.identities([["w1", round(41.3001 * 1e5), round(69.25 * 1e5), 0.0, 3]])
        verdict, point, shift = osm_queue.reconcile(
            self.edit("w1"), [self.road()], [((69.25, 41.30), 150.0)], self.work)
        self.assertEqual(verdict, osm_queue.LOCKED)
        self.assertIsNone(point)

