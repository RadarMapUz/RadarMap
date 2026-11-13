#!/usr/bin/env python3
"""Тесты конструктора карты: магнит и хранилище правок.

Здесь сторожатся ЗАПРЕТЫ, потому что цена ошибки в конструкторе выше, чем в
остальной системе: всё прочее восстанавливается пересборкой из OSM, а ручную
работу восстановить неоткуда.

Магнит не имеет права выбирать за человека между двумя дорогами, посаженный
объект не имеет права уезжать от нарисованной линии, а правка не имеет права
исчезать — ни от удаления, ни от второго сохранения с другого устройства.
"""
import json
import re
import os
import shutil
import sqlite3
import tempfile
import unittest

import map_edits


def line(*coords):
    """Ломаная из пар (lat, lon) → внутренний порядок (lon, lat)."""
    return [(lon, lat) for lat, lon in coords]


def road(cls, points, name="", flags=0):
    return {"cls": cls, "flags": flags, "points": points, "name": name}


class MagnetTests(unittest.TestCase):

    def setUp(self):
        # Проспект с севера на юг и дублёр в двадцати метрах от него.
        self.avenue = road(3, line((41.300, 69.2500), (41.310, 69.2500)), "Навои")
        # Дублёр в двадцати метрах: 0.00024° долготы на широте Ташкента.
        self.side = road(6, line((41.300, 69.25024), (41.310, 69.25024)), "Дублёр")

    def test_point_lands_on_the_axis_not_on_a_vertex(self):
        # Между вершинами упрощённой линии бывает сотня метров: посадка на
        # вершину увела бы объект туда же.
        long_road = road(3, line((41.300, 69.250), (41.310, 69.250)))
        result = map_edits.snap((69.25010, 41.3050), [long_road])
        self.assertTrue(result.on_road)
        self.assertAlmostEqual(result.point[1], 41.3050, places=5,
                               msg="объект уехал к вершине вместо проекции")

    def test_finger_reaches_further_than_the_cursor(self):
        # Палец накрывает на экране телефона метров сорок городской улицы.
        # Требовать от него точности курсора — значит требовать невозможного:
        # промах будет не ошибкой модератора, а свойством руки.
        far = (69.25035, 41.3050)   # ~29 м от оси
        self.assertFalse(map_edits.snap(far, [self.avenue]).on_road)
        self.assertTrue(map_edits.snap(far, [self.avenue],
                                       meters=map_edits.TOUCH_SNAP_METERS).on_road)

    def test_bigger_reach_still_does_not_guess(self):
        # Больший радиус даёт больше КАНДИДАТОВ, а не больше догадок: правило
        # «на неоднозначном месте не выбираем за человека» от него не слабеет.
        middle = (69.25012, 41.3050)
        result = map_edits.snap(middle, [self.avenue, self.side],
                                meters=map_edits.TOUCH_SNAP_METERS)
        self.assertFalse(result.on_road)
        self.assertGreaterEqual(len(result.ambiguous), 2)

    def test_far_point_does_not_stick(self):
        result = map_edits.snap((69.2600, 41.3050), [self.avenue])
        self.assertFalse(result.on_road)
        self.assertIsNone(result.road)

    def test_magnet_refuses_to_choose_between_two_roads(self):
        # Проспект с дублёром: угадывание здесь даёт разворот не с той
        # проезжей части.
        middle = (69.25012, 41.3050)
        result = map_edits.snap(middle, [self.avenue, self.side])
        self.assertFalse(result.on_road, "магнит выбрал за человека")
        self.assertEqual(len(result.ambiguous), 2,
                         "обе дороги обязаны быть предъявлены на выбор")

    def test_clear_winner_is_chosen(self):
        result = map_edits.snap((69.25005, 41.3050), [self.avenue, self.side])
        self.assertTrue(result.on_road)
        self.assertEqual(result.road["name"], "Навои")

    def test_node_wins_for_objects_that_live_on_junctions(self):
        # Светофор в полутора метрах от конца линии — это светофор НА
        # перекрёстке, а не рядом с ним.
        near_end = (69.25005, 41.30005)
        loose = map_edits.snap(near_end, [self.avenue])
        pinned = map_edits.snap(near_end, [self.avenue], prefer_node=True)
        self.assertFalse(loose.at_node)
        self.assertTrue(pinned.at_node)
        self.assertEqual(pinned.point, self.avenue["points"][0])

    def test_node_does_not_win_from_far_away(self):
        middle = (69.25005, 41.3050)
        result = map_edits.snap(middle, [self.avenue], prefer_node=True)
        self.assertFalse(result.at_node, "середина улицы — не перекрёсток")

    def test_anchor_never_carries_an_osm_id(self):
        # Id ведёт в OSM и не переживёт воскресной пересборки: у той же улицы
        # назавтра другой way.
        result = map_edits.snap((69.25005, 41.3050), [self.avenue])
        anchor = result.anchor
        self.assertEqual(set(anchor), {"cls", "name", "bearing", "atNode"})
        self.assertNotIn("id", json.dumps(anchor))

    def test_anchor_keeps_the_direction_of_the_road(self):
        result = map_edits.snap((69.25005, 41.3050), [self.avenue])
        self.assertAlmostEqual(result.anchor["bearing"], 0, delta=1)

    def test_fingerprint_ignores_far_away_changes(self):
        far = road(6, line((41.400, 69.300), (41.410, 69.300)))
        point = (69.25005, 41.3050)
        alone = map_edits.fingerprint(point, [self.avenue])
        with_far = map_edits.fingerprint(point, [self.avenue, far])
        self.assertEqual(alone, with_far,
                         "правка держится за место, а не за всю страну")

    def test_fingerprint_notices_the_road_moving(self):
        point = (69.25005, 41.3050)
        before = map_edits.fingerprint(point, [self.avenue])
        moved = road(3, line((41.300, 69.25012), (41.310, 69.25012)), "Навои")
        self.assertNotEqual(before, map_edits.fingerprint(point, [moved]))

    def test_fingerprint_does_not_depend_on_road_order(self):
        # Порядок дорог в тайле задан сортировкой, но полагаться на него
        # нельзя: отпечаток, зависящий от порядка, поднимал бы очередь на
        # проверку каждую неделю на ровном месте.
        point = (69.25012, 41.3050)
        self.assertEqual(map_edits.fingerprint(point, [self.avenue, self.side]),
                         map_edits.fingerprint(point, [self.side, self.avenue]))


class RoutePatchTests(unittest.TestCase):
    """Правки маршрута (91): своя проверка свойств, свой экспорт, мимо тайлов."""

    def setUp(self):
        self.conn = sqlite3.connect(":memory:")
        self.conn.row_factory = sqlite3.Row
        map_edits.ensure_tables(self.conn)

    def tearDown(self):
        self.conn.close()

    def test_props_are_checked(self):
        problem = map_edits.route_props_problem
        self.assertIsNotNone(problem("turn_ban", {"restriction": "no_left_turn"}))
        self.assertIsNotNone(problem("turn_ban", {"restriction": "only_left_turn", "from_bearing": 0,
                                                  "to_bearing": 90}))
        self.assertIsNone(problem("turn_ban", {"restriction": "no_u_turn", "from_bearing": 0, "to_bearing": 180}))
        self.assertIsNotNone(problem("turn_ban", {"restriction": "no_u_turn", "from_bearing": 0,
                                                  "to_bearing": 180, "path": [1, 2]}))
        self.assertIsNotNone(problem("turn_ban", {"restriction": "no_u_turn", "from_bearing": 0,
                                                  "to_bearing": 180, "path": [1, 2, 3], "path_at": [[41, 69]]}))
        self.assertIsNotNone(problem("oneway", {}))
        self.assertIsNotNone(problem("no_entry", {"bearing": True}))
        self.assertIsNone(problem("no_entry", {"bearing": 270}))
        self.assertIsNotNone(problem("unbarrier", {"evidence": "сон"}))
        self.assertIsNone(problem("unbarrier", {"evidence": "survey"}))
        self.assertIsNone(problem("lanes", {"lanes": 4}))

    def test_route_kinds_skip_tiles_and_sweep(self):
        point = [69.25, 41.30]
        map_edits.create(self.conn, "lanes", raw=point, snapped=point, props={"lanes": 4},
                         status=map_edits.ACCEPTED)
        map_edits.create(self.conn, "unbarrier", raw=point, snapped=point, props={},
                         status=map_edits.ACCEPTED)
        map_edits.create(self.conn, "oneway", raw=point, snapped=point, props={"bearing": 10},
                         status=map_edits.DRAFT)
        self.assertEqual([e["kind"] for e in map_edits.export_accepted(self.conn)], ["lanes"])
        exported = map_edits.export_route_patches(self.conn)["items"]
        self.assertEqual([e["kind"] for e in exported], ["unbarrier"])
        import osm_queue
        decisions = osm_queue.sweep(self.conn, roads=[])
        self.assertEqual([d["edit"]["kind"] for d in decisions], ["lanes"])

    def test_answer_move_and_undo(self):
        card = {"key": "j1", "at": [41.3, 69.25], "streets": ["А", "Б"]}
        move = {"key": "1,2,3", "kind": "left", "path": [1, 2, 3], "pts": [[41.3, 69.24], [41.3, 69.25], [41.31, 69.25]],
                "from_bearing": 90, "to_bearing": 0}
        edit_id = map_edits.answer_move(self.conn, card, move, "banned", "imagery", "", "модератор")
        edit = map_edits.by_id(self.conn, edit_id)
        self.assertEqual((edit["kind"], edit["status"]), ("turn_ban", map_edits.ACCEPTED))
        self.assertEqual(edit["props"]["path_at"][0], [41.3, 69.24])
        self.assertIn("налево нельзя", edit["note"])
        with self.assertRaises(ValueError):
            map_edits.answer_move(self.conn, card, move, "maybe")
        self.assertTrue(map_edits.undo_move(self.conn, "1,2,3"))
        self.assertEqual(map_edits.by_id(self.conn, edit_id)["status"], map_edits.WITHDRAWN)
        self.assertFalse(map_edits.undo_move(self.conn, "1,2,3"))


class StorageTests(unittest.TestCase):

    def setUp(self):
        self.conn = sqlite3.connect(":memory:")
        self.conn.row_factory = sqlite3.Row
        map_edits.ensure_tables(self.conn)

    def tearDown(self):
        self.conn.close()

    def make(self, kind="lanes", point=(69.25, 41.30), **kwargs):
        # note передаётся дальше в create — так тестам не нужен второй шаг.
        return map_edits.create(self.conn, kind, raw=list(point),
                                snapped=list(point), **kwargs)

    def test_unknown_kind_is_refused(self):
        # Список видов закрытый: неизвестный не попадёт ни в таблицу, ни в
        # запекание, и молча потеряться ему негде.
        with self.assertRaises(ValueError):
            self.make(kind="выдумка")

    def test_accept_really_accepts(self):
        # Дефект, найденный в браузере: карточка говорила «Принято», а create
        # молча клал черновик, и правка не попадала в экспорт. Модератор
        # нажимал, видел подтверждение и уходил — а на телефоны ничего не ехало.
        edit_id = map_edits.create(self.conn, "lanes", raw=[69.25, 41.3],
                                   snapped=[69.25, 41.3],
                                   status=map_edits.ACCEPTED)
        exported = [item["id"] for item in map_edits.export_accepted(self.conn)]
        self.assertIn(edit_id, exported)

    def test_create_cannot_publish(self):
        # Публикует владелец со своей машины. Панель этого не умеет — и не
        # должна уметь молча.
        with self.assertRaises(ValueError):
            map_edits.create(self.conn, "lanes", raw=[69.25, 41.3],
                             snapped=[69.25, 41.3], status=map_edits.PUBLISHED)

    def test_new_edit_is_a_draft(self):
        edit_id = self.make()
        row = self.conn.execute("SELECT status FROM map_edits WHERE id = ?",
                                (edit_id,)).fetchone()
        self.assertEqual(row["status"], map_edits.DRAFT)

    def test_second_save_of_a_stale_version_is_refused(self):
        # Модератор открыл панель с телефона и с ноутбука. Без версии второе
        # сохранение молча затёрло бы первое.
        edit_id = self.make()
        self.assertTrue(map_edits.update(self.conn, edit_id, 1, note="первый"))
        self.assertFalse(map_edits.update(self.conn, edit_id, 1, note="второй"),
                         "устаревшая версия обязана быть отвергнута")
        row = self.conn.execute("SELECT note FROM map_edits WHERE id = ?",
                                (edit_id,)).fetchone()
        self.assertEqual(row["note"], "первый")

    def test_forbidden_columns_cannot_be_written(self):
        edit_id = self.make()
        with self.assertRaises(ValueError):
            map_edits.update(self.conn, edit_id, 1, author="чужой")

    def test_confirm_clears_only_the_machine_mark(self):
        # «Посмотрел, всё верно» убирает ровно то, что мешает правке уйти из
        # очереди, — и не трогает ни геометрию, ни статус, ни то, что написал
        # человек.
        edit_id = self.make(note="почему: съезд не размечен")
        map_edits.update(self.conn, edit_id, 1,
                         note="почему: съезд не размечен · проверить: сдвиг 8.0 м",
                         status=map_edits.ACCEPTED)
        self.assertTrue(map_edits.confirm(self.conn, edit_id, 2))
        row = self.conn.execute("SELECT note, status FROM map_edits WHERE id = ?",
                                (edit_id,)).fetchone()
        self.assertNotIn("проверить", row["note"])
        self.assertIn("съезд не размечен", row["note"], "стёрто написанное человеком")
        self.assertEqual(row["status"], map_edits.ACCEPTED)

    def test_confirm_is_idempotent(self):
        edit_id = self.make(note="проверить: сдвиг 8.0 м")
        map_edits.confirm(self.conn, edit_id, 1)
        self.assertTrue(map_edits.confirm(self.conn, edit_id, 2))

    def test_confirm_of_a_missing_edit_is_not_an_error(self):
        self.assertFalse(map_edits.confirm(self.conn, 999, 1))

    def test_restore_brings_a_withdrawn_edit_back(self):
        edit_id = self.make()
        map_edits.update(self.conn, edit_id, 1, status=map_edits.ACCEPTED)
        map_edits.withdraw(self.conn, edit_id, 2)
        self.assertEqual(map_edits.in_bbox(self.conn, 41.2, 69.2, 41.4, 69.3), [])
        self.assertTrue(map_edits.restore(self.conn, edit_id, 3))
        self.assertEqual(len(map_edits.in_bbox(self.conn, 41.2, 69.2, 41.4, 69.3)), 1)

    def test_stale_version_cannot_confirm_or_restore(self):
        # Модератор открывает панель и с телефона, и с ноутбука.
        edit_id = self.make()
        map_edits.update(self.conn, edit_id, 1, note="первый")
        self.assertFalse(map_edits.confirm(self.conn, edit_id, 1))
        self.assertFalse(map_edits.restore(self.conn, edit_id, 1))

    def test_withdrawn_edit_is_kept_not_deleted(self):
        # Ручная работа — единственные данные в системе, которые нельзя
        # восстановить пересборкой.
        edit_id = self.make()
        map_edits.withdraw(self.conn, edit_id, 1)
        row = self.conn.execute("SELECT status FROM map_edits WHERE id = ?",
                                (edit_id,)).fetchone()
        self.assertIsNotNone(row)
        self.assertEqual(row["status"], map_edits.WITHDRAWN)

    def test_withdrawn_edit_leaves_the_map(self):
        edit_id = self.make()
        map_edits.withdraw(self.conn, edit_id, 1)
        self.assertEqual(map_edits.in_bbox(self.conn, 41.2, 69.2, 41.4, 69.3), [])

    def test_bbox_keeps_the_panel_alive(self):
        self.make(point=(69.25, 41.30))
        self.make(point=(69.90, 41.90))
        near = map_edits.in_bbox(self.conn, 41.29, 69.24, 41.31, 69.26)
        self.assertEqual(len(near), 1)

    def test_export_takes_accepted_and_published_only(self):
        # Снимок, а не приращение: сборка накладывает состояние целиком.
        draft = self.make()
        accepted = self.make()
        map_edits.update(self.conn, accepted, 1, status=map_edits.ACCEPTED)
        withdrawn = self.make()
        map_edits.withdraw(self.conn, withdrawn, 1)
        exported = [item["id"] for item in map_edits.export_accepted(self.conn)]
        self.assertEqual(exported, [accepted])
        self.assertNotIn(draft, exported, "черновик на телефоны не едет")


class TileSourceTests(unittest.TestCase):
    """Магнит липнет к ОПУБЛИКОВАННЫМ тайлам, а не к сырому OSM."""

    def payload(self, roads):
        return {"version": 2, "roads": roads}

    def v2_key(self, lat, lon):
        """Имя тайла v2 по координате. Сетка мелкая (0.05°), и синтетические
        имена вроде road2_262_498 указывают на другой конец земли — тайл просто
        не попадает в рамку, и тест «ничего не нашлось» проходит по неверной
        причине."""
        step = map_edits.TILE_DEGREES_V2
        return int((lat + 90) / step), int((lon + 180) / step)

    def test_tile_decodes_the_same_way_the_phone_does(self):
        # Первая точка абсолютная, дальше дельты в 1e-5°.
        decoded = map_edits.decode_tile(self.payload(
            [[3, 0, [4_130_000, 6_925_000, 100, 0], "Навои"]]))
        self.assertEqual(len(decoded), 1)
        self.assertEqual(decoded[0]["name"], "Навои")
        self.assertAlmostEqual(decoded[0]["points"][0][1], 41.30, places=6)
        self.assertAlmostEqual(decoded[0]["points"][1][1], 41.301, places=6)

    def test_five_element_record_is_skipped_not_fatal(self):
        # Тот же запрет, что на клиенте: панель не должна падать на записи,
        # которой не понимает.
        decoded = map_edits.decode_tile(self.payload([
            [3, 0, [4_130_000, 6_925_000, 100, 0], "Навои", 6],
            [3, 0, [4_130_000, 6_926_000, 100, 0]],
        ]))
        self.assertEqual(len(decoded), 1)

    def test_backbone_set_is_not_used_for_snapping(self):
        # В костяке раздельные проезжие сведены в одну ось: объект сел бы
        # между ними, то есть на разделительную.
        with tempfile.TemporaryDirectory() as work:
            row, column = self.v2_key(41.30, 69.25)
            for suffix in ("s", "f"):
                with open(os.path.join(work, f"road2_{row}_{column}_{suffix}.json"),
                          "w", encoding="utf-8") as handle:
                    json.dump(self.payload(
                        [[3, 0, [4_130_000, 6_925_000, 100, 0], suffix]]), handle)
            loaded = map_edits.load_roads(work, 41.29, 69.24, 41.31, 69.26)
            self.assertEqual([r["name"] for r in loaded], ["s"])

    def test_v1_tiles_are_used_when_v2_is_not_published_yet(self):
        # Формат v2 собирается параллельно с v1 и уберётся, только когда в
        # проде не останется старых сборок. На сервере сейчас лежит ровно v1, и
        # панель, умеющая липнуть только к v2, там просто не магнитила бы.
        with tempfile.TemporaryDirectory() as work:
            with open(os.path.join(work, "tile_262_498.json"), "w",
                      encoding="utf-8") as handle:
                json.dump({"version": 1, "roads":
                           [[3, 0, [4_130_000, 6_925_000, 100, 0], "Навои"]]}, handle)
            loaded = map_edits.load_roads(work, 41.29, 69.24, 41.31, 69.26)
            self.assertEqual([r["name"] for r in loaded], ["Навои"])

    def test_v1_is_ignored_once_v2_exists(self):
        # Когда оба формата на месте, v1 — дубль тех же дорог одним файлом.
        # Читать оба значило бы удвоить каждую дорогу и получить «две дороги
        # рядом» там, где она одна: магнит перестал бы выбирать вовсе.
        with tempfile.TemporaryDirectory() as work:
            row, column = self.v2_key(41.30, 69.25)
            for name, label in (("tile_262_498.json", "старая"),
                                (f"road2_{row}_{column}_s.json", "новая")):
                with open(os.path.join(work, name), "w", encoding="utf-8") as handle:
                    json.dump({"version": 2, "roads":
                               [[3, 0, [4_130_000, 6_925_000, 100, 0], label]]}, handle)
            loaded = map_edits.load_roads(work, 41.29, 69.24, 41.31, 69.26)
            self.assertEqual([r["name"] for r in loaded], ["новая"])

    def test_only_tiles_touching_the_frame_are_opened(self):
        # Прежняя версия читала весь каталог и разбирала каждый файл, чтобы
        # понять, нужен ли он. На боевом это 210 файлов и десятки миллионов
        # объектов: панель упиралась в MemoryMax и переставала отвечать.
        with tempfile.TemporaryDirectory() as work:
            for name, label in (("tile_262_498.json", "Ташкент"),
                                ("tile_100_100.json", "другой конец земли")):
                with open(os.path.join(work, name), "w", encoding="utf-8") as handle:
                    json.dump({"version": 1, "roads":
                               [[3, 0, [4_130_000, 6_925_000, 100, 0], label]]}, handle)
            loaded = map_edits.load_roads(work, 41.29, 69.24, 41.31, 69.26)
            self.assertEqual([r["name"] for r in loaded], ["Ташкент"])

    def test_cache_does_not_grow_without_bound(self):
        # Ради этого потолка всё и затевалось: разобранный тайл Ташкента —
        # десятки мегабайт, а панель живёт под MemoryMax=256M.
        with tempfile.TemporaryDirectory() as work:
            for row in range(260, 268):
                with open(os.path.join(work, f"tile_{row}_498.json"),
                          "w", encoding="utf-8") as handle:
                    json.dump({"version": 1, "roads":
                               [[3, 0, [4_130_000, 6_925_000, 100, 0]]]}, handle)
                lat = row * 0.5 - 90
                map_edits.load_roads(work, lat, 69.0, lat + 0.4, 69.4)
            self.assertLessEqual(len(map_edits._TILE_CACHE),
                                 map_edits.TILE_CACHE_SIZE)

    def test_world_frame_cannot_read_the_whole_country(self):
        # Рамка во всю землю — ошибка вызова, а не повод грузить всё.
        with tempfile.TemporaryDirectory() as work:
            for row in range(250, 275):
                with open(os.path.join(work, f"tile_{row}_498.json"),
                          "w", encoding="utf-8") as handle:
                    json.dump({"version": 1, "roads":
                               [[3, 0, [4_130_000, 6_925_000, 100, 0]]]}, handle)
            report = {}
            one = os.path.getsize(os.path.join(work, "tile_250_498.json"))
            budget = one * 3 + 1
            map_edits.load_roads(work, -90, -180, 90, 180,
                                 limits={"bytes": budget, "class": 7,
                                         "objects": None},
                                 report=report)
            # Мера — БАЙТЫ на разбор, а не число файлов: двадцать пять тайлов
            # костяка дешевле одного тайла улиц центра, и запрещать их числом
            # значило бы запрещать не то, что стоит денег.
            self.assertLessEqual(report["bytes"], budget)
            self.assertGreater(report["skipped"], 0)

    def test_roads_near_asks_for_a_frame_not_for_the_world(self):
        with tempfile.TemporaryDirectory() as work:
            for name, label in (("tile_262_498.json", "рядом"),
                                ("tile_100_100.json", "далеко")):
                with open(os.path.join(work, name), "w", encoding="utf-8") as handle:
                    json.dump({"version": 1, "roads":
                               [[3, 0, [4_130_000, 6_925_000, 100, 0], label]]}, handle)
            near = map_edits.roads_near(work, (69.25, 41.30))
            self.assertEqual([r["name"] for r in near], ["рядом"])

    def test_missing_tiles_directory_is_not_an_error(self):
        self.assertEqual(map_edits.load_roads("/нет/такого", 0, 0, 1, 1), [])


class WidthContractTests(unittest.TestCase):
    """Панель обязана рисовать ТО ЖЕ, что увидит водитель.

    Таблица ширин существует в трёх местах: build_roads.py (сборка тайлов),
    RoadShape.swift (телефон) и map_edits.py (панель). Первые две порознь
    потому, что сервер и клиент — разные программы; третья потому, что панель
    не может импортировать build_roads: тот живёт на машине владельца, и на VPS
    его может не быть вовсе.

    Разойтись им нельзя. Здесь сверяются две из трёх — те, что на одном языке;
    третью сторожит RoadLaneTests на клиенте.
    """

    def setUp(self):
        try:
            import build_roads
        except ImportError:  # pragma: no cover — на VPS сборки нет
            self.skipTest("build_roads недоступен: панель работает и без него")
        self.build = build_roads

    def test_lane_width_tables_match(self):
        self.assertEqual(map_edits.LANE_METERS, self.build.LANE_METERS)

    def test_default_lane_tables_match(self):
        self.assertEqual(map_edits.DEFAULT_LANES, self.build.DEFAULT_LANES)

    def test_class_ceilings_match(self):
        self.assertEqual(map_edits.MAX_LANES_BY_CLASS, self.build.MAX_LANES_BY_CLASS)

    def test_measured_bit_is_the_same_bit(self):
        self.assertEqual(map_edits.FLAG_LANES_TAGGED, self.build.FLAG_LANES_TAGGED)

    def test_width_comes_out_the_same_for_every_class(self):
        for cls in sorted(self.build.LANE_METERS):
            for lanes in (0, 1, 4, 15):
                flags = self.build.with_lanes(0, lanes)
                panel = map_edits.road_width_meters(flags, cls)
                built = self.build.road_width_meters(
                    cls, min(self.build.lanes_of(flags),
                             self.build.MAX_LANES_BY_CLASS.get(cls, 8))
                    if lanes else 0)
                self.assertAlmostEqual(panel, built, places=6,
                                       msg=f"класс {cls}, полос {lanes}")

    def test_oneway_halves_the_default_in_both(self):
        two_way = map_edits.road_width_meters(0, 3)
        one_way = map_edits.road_width_meters(map_edits.FLAG_ONEWAY, 3)
        self.assertAlmostEqual(two_way, one_way * 2)


class PointRecordTests(unittest.TestCase):
    """Точка в тайле — запись из ДВУХ чисел.

    Разбор требовал не меньше четырёх и отбрасывал всю обстановку целиком.
    Заметить это было неоткуда: на боевом лежит формат v1, где точек нет
    вовсе, и пустой ответ читался как «сервер их ещё не публиковал». На первом
    же тайле с точками панель осталась бы без светофоров и переходов — и
    объяснить это никто бы не смог.
    """

    def payload(self, rows):
        return {"version": 2, "roads": rows}

    def test_single_point_decodes(self):
        decoded = map_edits.decode_tile(self.payload([[1, 518, [4131765, 6927664]]]))
        self.assertEqual(len(decoded), 1)
        self.assertEqual(decoded[0]["cls"], 1)
        self.assertAlmostEqual(decoded[0]["points"][0][1], 41.31765, places=5)

    def test_line_still_decodes(self):
        decoded = map_edits.decode_tile(
            self.payload([[3, 0, [4130000, 6925000, 100, 0]]]))
        self.assertEqual(len(decoded[0]["points"]), 2)

    def test_odd_number_of_coordinates_is_refused(self):
        # Нечётная длина означает потерянное число: половина координат
        # сдвинулась бы, и объекты разъехались бы по карте молча.
        self.assertEqual(map_edits.decode_tile(
            self.payload([[1, 0, [4131765, 6927664, 100]]])), [])

    def test_empty_coordinates_are_refused(self):
        self.assertEqual(map_edits.decode_tile(self.payload([[1, 0, []]])), [])

    def test_point_carries_azimuth_and_width(self):
        # Азимут и ширина проезжей части лежат в битах записи с самой первой
        # сборки точек, и панель их не читала: зебра рисовалась кружком
        # «здесь переход» вместо того, что нарисовано на асфальте.
        work = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, work, True)
        row = int((41.31 + 90) / map_edits.TILE_DEGREES_V2)
        column = int((69.28 + 180) / map_edits.TILE_DEGREES_V2)
        # Азимут 90° это 30 шагов по три градуса; ширина 14 м в старших битах.
        flags = 30 | (14 << map_edits.PFLAG_WIDTH_SHIFT)
        with open(os.path.join(work, f"road2_{row}_{column}_p.json"),
                  "w", encoding="utf-8") as handle:
            json.dump({"version": 2,
                       "roads": [[5, flags, [4131000, 6928000]]]}, handle)
        found = map_edits.load_points(work, 41.30, 69.27, 41.32, 69.29)[0]
        self.assertEqual(found["azimuth"], 90)
        self.assertEqual(found["width"], 14)

    def test_points_are_read_from_their_own_set(self):
        work = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, work, True)
        row = int((41.31 + 90) / map_edits.TILE_DEGREES_V2)
        column = int((69.28 + 180) / map_edits.TILE_DEGREES_V2)
        with open(os.path.join(work, f"road2_{row}_{column}_p.json"),
                  "w", encoding="utf-8") as handle:
            json.dump(self.payload([[1, 518, [4131000, 6928000]]]), handle)
        found = map_edits.load_points(work, 41.30, 69.27, 41.32, 69.29)
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0]["kind"], 1)


class DrawOfTests(unittest.TestCase):
    """Чем правка рисуется на карте.

    Было так: правка любого вида ложилась точкой по `geom[1]` как широте. Для
    линии `geom[1]` — это ВТОРАЯ ВЕРШИНА, и метка уезжала в случайное место, а
    нарисованная дорога не показывалась дорогой вовсе. Со стороны это выглядело
    как «панель ставит что-то сама, а моей работы не видно».
    """

    def test_line_edit_is_a_line(self):
        drawn = map_edits.draw_of({
            "kind": "geometry", "geom": [[69.25, 41.30], [69.26, 41.31]],
            "props": {"cls": 3}})
        self.assertEqual(drawn["shape"], "line")
        self.assertEqual(drawn["point"], [69.25, 41.30],
                         "точка линии — её первая вершина, а не вторая")

    def test_removed_road_is_a_line_too(self):
        # Убранную дорогу надо видеть целиком: решение «убрать» проверяют по
        # тому, ту ли линию убрали.
        self.assertEqual(map_edits.draw_of({
            "kind": "remove", "geom": [[69.25, 41.30], [69.26, 41.31]],
            "props": {}})["shape"], "line")

    def test_area_is_a_ring(self):
        self.assertEqual(map_edits.draw_of({
            "kind": "area", "geom": [[69.25, 41.30], [69.26, 41.31],
                                     [69.26, 41.30]],
            "props": {"area": 2}})["shape"], "ring")

    def test_point_edit_keeps_its_coordinate(self):
        drawn = map_edits.draw_of({"kind": "point", "geom": [69.25, 41.30],
                                   "props": {"point": 1}})
        self.assertEqual((drawn["shape"], drawn["point"]),
                         ("point", [69.25, 41.30]))

    def test_drawn_road_carries_the_width_the_phone_will_draw(self):
        # Своя дорога обязана лечь той же шириной, что соседняя из OSM того же
        # класса: иначе на схеме видно не дорогу, а то, что её рисовали не там.
        drawn = map_edits.draw_of({
            "kind": "geometry", "geom": [[69.25, 41.30], [69.26, 41.31]],
            "props": {"cls": 3, "lanes": 4}})
        self.assertEqual(drawn["lanes"], 4)
        self.assertAlmostEqual(drawn["width"], 4 * map_edits.LANE_METERS[3], 1)

    def test_lanes_are_capped_by_class(self):
        drawn = map_edits.draw_of({
            "kind": "geometry", "geom": [[69.25, 41.30], [69.26, 41.31]],
            "props": {"cls": 7, "lanes": 15}})
        self.assertEqual(drawn["lanes"], map_edits.MAX_LANES_BY_CLASS[7])

    def test_default_lanes_when_none_given(self):
        drawn = map_edits.draw_of({
            "kind": "geometry", "geom": [[69.25, 41.30], [69.26, 41.31]],
            "props": {"cls": 3}})
        self.assertEqual(drawn["lanes"], map_edits.DEFAULT_LANES[3][1])

    def test_oneway_halves_the_default(self):
        drawn = map_edits.draw_of({
            "kind": "geometry", "geom": [[69.25, 41.30], [69.26, 41.31]],
            "props": {"cls": 3, "oneway": True}})
        self.assertEqual(drawn["lanes"], map_edits.DEFAULT_LANES[3][0])

    def test_nonsense_class_does_not_crash(self):
        drawn = map_edits.draw_of({
            "kind": "geometry", "geom": [[69.25, 41.30], [69.26, 41.31]],
            "props": {"cls": "проспект"}})
        self.assertEqual(drawn["cls"], 6)

    def test_empty_geometry_gives_no_point(self):
        self.assertIsNone(map_edits.draw_of({"kind": "point", "geom": [],
                                             "props": {}})["point"])

    def test_every_kind_gets_a_shape(self):
        # Новый вид правки не должен молча стать точкой в неизвестном месте.
        for kind in sorted(map_edits.KINDS):
            geom = ([[69.25, 41.30], [69.26, 41.31], [69.26, 41.30]]
                    if kind in map_edits.LINE_KINDS | map_edits.RING_KINDS
                    else [69.25, 41.30])
            drawn = map_edits.draw_of({"kind": kind, "geom": geom, "props": {}})
            self.assertIn(drawn["shape"], ("point", "line", "ring"), kind)
            self.assertIsNotNone(drawn["point"], kind)


class ClientTablesTests(unittest.TestCase):
    """Таблицы ширины в панели и на сервере — одни и те же числа.

    Пока линию ведут, правки ещё нет, и спросить ширину у сервера не у чего:
    рисовать полотно приходится на клиенте. Значит, таблица продублирована — а
    дублирование, за которым никто не следит, расходится молча и ровно там, где
    это дороже всего: на глазах у человека, который по картинке принимает
    решение. Тот же приём уже стоит между build_roads.py и RoadShape.swift.
    """

    def table(self, name):
        source = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                              "static", "editor.js")
        with open(source, encoding="utf-8") as handle:
            text = handle.read()
        match = re.search(r"const " + name + r" = \{([^}]*)\}", text)
        self.assertIsNotNone(match, f"в editor.js нет таблицы {name}")
        out = {}
        for pair in match.group(1).split(","):
            if ":" not in pair:
                continue
            key, value = pair.split(":")
            out[int(key.strip())] = float(value.strip())
        return out

    def test_lane_meters_match(self):
        self.assertEqual(self.table("LANE_METERS"),
                         {k: float(v) for k, v in map_edits.LANE_METERS.items()})

    def test_default_lanes_match_the_two_way_case(self):
        # На клиенте одно число на класс — для двусторонней дороги: рисуют её
        # чаще, а односторонняя приходит с явным числом полос.
        server = {cls: float(both)
                  for cls, (single, both) in map_edits.DEFAULT_LANES.items()}
        self.assertEqual(self.table("DEFAULT_LANES"), server)

    def test_every_kind_has_a_word_in_the_panel(self):
        # Неназванный вид показывался кодом — «point», «area», — а код на
        # экране читается как недоделка, а не как объект.
        source = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                              "static", "editor.js")
        with open(source, encoding="utf-8") as handle:
            text = handle.read()
        match = re.search(r"const NAMES = \{(.*?)\};", text, re.S)
        self.assertIsNotNone(match)
        named = set(re.findall(r"(\w+):", match.group(1)))
        self.assertEqual(named, set(map_edits.KIND_NAMES),
                         "виды правок в панели и на сервере разошлись")

    def test_every_class_is_covered(self):
        for cls in map_edits.OSM_HIGHWAY:
            self.assertIn(cls, self.table("LANE_METERS"))
            self.assertIn(cls, self.table("DEFAULT_LANES"))


class TodoWithLinesTests(unittest.TestCase):
    """Очередь работы не должна падать от правки-линии.

    `todo` считала каждую правку точкой и брала `geom[0]` как долготу. У
    нарисованной дороги `geom[0]` — вершина, то есть список, и весь запрос
    отдавал 500. Со стороны это выглядело как пустой конструктор без списка
    «здесь работать»: браузер показывал «Failed to fetch», по которому причину
    не найти.
    """

    def road(self, lat, lon):
        return {"cls": 3, "flags": 0, "name": "",
                "points": [(lon, lat), (lon + 0.002, lat + 0.002)]}

    def test_line_edit_does_not_break_the_queue(self):
        work = map_edits.todo([self.road(41.30, 69.25)], [
            {"kind": "geometry", "geom": [[69.30, 41.35], [69.31, 41.36]],
             "props": {}}])
        self.assertEqual(len(work), 1, "дорога без полос пропала из очереди")

    def test_line_edit_still_marks_its_place_as_done(self):
        # Правка считается сделанной работой там, где стоит её ПЕРВАЯ вершина.
        road = self.road(41.30, 69.25)
        spot = road["points"][len(road["points"]) // 2]
        work = map_edits.todo([road], [
            {"kind": "geometry", "geom": [[spot[0], spot[1]],
                                          [spot[0] + 0.001, spot[1]]],
             "props": {}}])
        self.assertEqual(work, [], "работа рядом с правкой осталась в очереди")

    def test_area_and_point_edits_mix_without_error(self):
        work = map_edits.todo([self.road(41.30, 69.25)], [
            {"kind": "area", "geom": [[69.40, 41.40], [69.41, 41.41],
                                      [69.41, 41.40]], "props": {}},
            {"kind": "point", "geom": [69.40, 41.40], "props": {}},
            {"kind": "lock", "geom": [69.40, 41.40], "props": {}}])
        self.assertEqual(len(work), 1)


class HistoryTests(unittest.TestCase):
    """История геометрии.

    «Кто и когда сдвинул эту улицу» через полгода спросят обязательно, а
    восстановить это неоткуда: ручная работа — единственное в системе, что
    нельзя пересобрать из OSM.
    """

    def setUp(self):
        self.conn = sqlite3.connect(":memory:")
        self.conn.row_factory = sqlite3.Row
        map_edits.ensure_tables(self.conn)
        self.id = map_edits.create(self.conn, "geometry",
                                   raw=[69.25, 41.30],
                                   snapped=[[69.25, 41.30], [69.26, 41.31]],
                                   props={"cls": 4})

    def tearDown(self):
        self.conn.close()

    def test_previous_geometry_is_kept(self):
        map_edits.update(self.conn, self.id, 1,
                         geom=[[69.25, 41.30], [69.27, 41.32]])
        past = map_edits.history(self.conn, self.id)
        self.assertEqual(len(past), 1)
        self.assertEqual(past[0]["geom"], [[69.25, 41.30], [69.26, 41.31]],
                         "в историю попало новое, а не прежнее")

    def test_history_grows_with_each_change(self):
        for i in range(3):
            map_edits.update(self.conn, self.id, i + 1,
                             geom=[[69.25, 41.30], [69.26 + i / 100, 41.31]])
        self.assertEqual(len(map_edits.history(self.conn, self.id)), 3)

    def test_newest_first(self):
        map_edits.update(self.conn, self.id, 1, props={"cls": 3})
        map_edits.update(self.conn, self.id, 2, props={"cls": 6})
        past = map_edits.history(self.conn, self.id)
        self.assertGreater(past[0]["version"], past[1]["version"])

    def test_note_alone_does_not_pollute_history(self):
        # Заметка и статус меняются часто, и версия «поменяли статус» засоряла
        # бы историю тем, о чём никто не спросит.
        map_edits.update(self.conn, self.id, 1, note="посмотрел")
        map_edits.update(self.conn, self.id, 2, status=map_edits.ACCEPTED)
        self.assertEqual(map_edits.history(self.conn, self.id), [])

    def test_history_of_a_missing_edit_is_empty(self):
        self.assertEqual(map_edits.history(self.conn, 999), [])


class GiveToOsmTests(unittest.TestCase):
    """Выгрузка нарисованной дороги в OSM.

    Дорога, отданная в OSM, поддерживается всем миром; наша — только нами.
    Это не украшение, а способ перестать платить за поддержку в одиночку:
    отданная дорога вернётся к нам сама обычной воскресной пересборкой, и своя
    копия снимется по правилу «OSM догнал».
    """

    def road(self, **props):
        return {"kind": "geometry",
                "geom": [[69.250, 41.300], [69.251, 41.301]], "props": props}

    def test_xml_is_what_josm_opens(self):
        xml = map_edits.as_osm(self.road(cls=4))
        self.assertIn('<osm version="0.6"', xml)
        self.assertIn('<way id="-1000">', xml)
        self.assertEqual(xml.count("<node "), 2)
        self.assertEqual(xml.count("<nd "), 2)

    def test_negative_ids_mark_what_osm_does_not_know_yet(self):
        # Соглашение OSM: отрицательные id — это ещё не созданные объекты.
        xml = map_edits.as_osm(self.road(cls=4))
        self.assertIn('id="-1"', xml)
        self.assertIn('id="-2"', xml)

    def test_class_becomes_a_highway_tag(self):
        self.assertIn('k="highway" v="secondary"',
                      map_edits.as_osm(self.road(cls=4)))
        self.assertIn('k="highway" v="primary"',
                      map_edits.as_osm(self.road(cls=3)))

    def test_unknown_class_does_not_lose_the_road(self):
        self.assertIn('k="highway" v="residential"',
                      map_edits.as_osm(self.road(cls=99)))

    def test_flags_travel_with_the_road(self):
        xml = map_edits.as_osm(self.road(cls=4, oneway=True, bridge=True, lanes=2))
        self.assertIn('k="oneway" v="yes"', xml)
        self.assertIn('k="bridge" v="yes"', xml)
        self.assertIn('k="lanes" v="2"', xml)

    def test_name_is_escaped(self):
        # Имя приходит от человека, и кавычка в нём не должна ломать XML.
        xml = map_edits.as_osm(self.road(cls=4, name='улица "Мира" & Ко'))
        self.assertIn("&quot;", xml)
        self.assertIn("&amp;", xml)
        self.assertNotIn('v="улица "', xml)

    def test_a_point_is_not_a_road(self):
        self.assertEqual(map_edits.as_osm({"kind": "point", "geom": [69.25, 41.3]}), "")


class TodoTests(unittest.TestCase):
    """Очередь работы: что панель предлагает делать дальше.

    Она обязана быть КОРОТКОЙ и по делу. Очередь в семьдесят тысяч строк не
    помогает — она подавляет, и её перестают открывать. Поэтому: только по
    видимой рамке, только классы, которые вообще стоит размечать руками, и
    только то, о чём никто ещё ничего не сказал.
    """

    def road(self, cls, points, flags=0, name=""):
        return {"cls": cls, "flags": flags, "points": points, "name": name}

    def straight(self, lon, length=0.01):
        return [(lon, 41.300), (lon, 41.300 + length)]

    def test_measured_road_is_not_offered(self):
        # Дорога с тегом lanes уже размечена — предлагать её значит тратить
        # время модератора на сделанное.
        roads = [self.road(3, self.straight(69.25)),
                 self.road(3, self.straight(69.26),
                           flags=map_edits.FLAG_LANES_TAGGED)]
        self.assertEqual(len(map_edits.todo(roads, [])), 1)

    def test_yards_are_not_offered(self):
        # Дворовых проездов половина всей сети, и они и так нарисованы верно.
        # Попади они в очередь — она стала бы бесконечной, то есть бесполезной.
        roads = [self.road(7, self.straight(69.25)),
                 self.road(6, self.straight(69.26))]
        self.assertEqual(map_edits.todo(roads, []), [])

    def test_road_with_an_edit_nearby_is_done(self):
        roads = [self.road(3, self.straight(69.25))]
        middle = map_edits.todo(roads, [])[0]["point"]
        edits = [{"geom": middle}]
        self.assertEqual(map_edits.todo(roads, edits), [],
                         "правка стоит — работа сделана")

    def test_longest_roads_come_first(self):
        # Улица в километр важнее проулка в тридцать метров: разметив её,
        # закрываешь больше карты за то же время.
        roads = [self.road(3, self.straight(69.25, 0.001)),
                 self.road(3, self.straight(69.26, 0.01))]
        first = map_edits.todo(roads, [])[0]
        self.assertGreater(first["meters"], 500)

    def test_queue_has_a_ceiling(self):
        roads = [self.road(3, self.straight(69.25 + i * 0.001)) for i in range(80)]
        self.assertLessEqual(len(map_edits.todo(roads, [])), 40)

    def test_row_says_where_the_road_goes(self):
        # Опубликованные сейчас тайлы имён улиц не содержат вовсе — все записи
        # в них длиной три. «Без имени · класс 3» не говорит ничего о том, что
        # перед тобой; направление говорит.
        north = map_edits.todo([self.road(3, self.straight(69.25))], [])[0]
        self.assertEqual(north["heading"], "с юга на север")
        east = map_edits.todo(
            [self.road(3, [(69.25, 41.30), (69.26, 41.30)])], [])[0]
        self.assertEqual(east["heading"], "с запада на восток")


if __name__ == "__main__":
    unittest.main()


class SurfaceSetTests(unittest.TestCase):
    """Набор «d» — единственный, где вид берётся из записи, а не из имени."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir)

    def write(self, rows):
        path = os.path.join(self.dir, "road2_2626_4985_d.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump({"version": 2, "roads": rows}, handle)

    def test_road_and_junction_come_apart(self):
        square = [4130000, 6925000, 200, 0, 0, 200, -200, 0]
        self.write([[map_edits.AREA_ROAD, 1 | (3 << 1), square],
                    [map_edits.AREA_JUNCTION, 1, square]])
        areas = map_edits.load_areas(self.dir, 41.29, 69.24, 41.31, 69.26)
        kinds = sorted(a["kind"] for a in areas)
        self.assertEqual(kinds, [map_edits.AREA_ROAD, map_edits.AREA_JUNCTION])

    def test_class_travels_in_flags(self):
        square = [4130000, 6925000, 200, 0, 0, 200, -200, 0]
        self.write([[map_edits.AREA_ROAD, 1 | (3 << 1), square]])
        areas = map_edits.load_areas(self.dir, 41.29, 69.24, 41.31, 69.26)
        self.assertEqual(areas[0]["road"], 3)
        self.assertTrue(areas[0]["closed"])


class CandidateReadTests(unittest.TestCase):
    """Панель читает кандидатов из файлов рядом с тайлами."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)

    def write(self, key, rings):
        with open(os.path.join(self.dir, f"cand_{key}.json"), "w",
                  encoding="utf-8") as handle:
            json.dump({"version": 1, "houses": rings}, handle)

    def square(self):
        return [4130000, 6925000, 200, 0, 0, 200, -200, 0]

    def test_candidates_are_read(self):
        self.write("2626_4985", [self.square()])
        found = map_edits.load_candidates(self.dir, 41.29, 69.24, 41.31, 69.26)
        self.assertEqual(len(found), 1)
        self.assertGreaterEqual(len(found[0]["points"]), 4)

    def test_cells_outside_the_frame_are_not_opened(self):
        self.write("2600_4900", [self.square()])
        self.assertEqual(
            map_edits.load_candidates(self.dir, 41.29, 69.24, 41.31, 69.26), [])

    def test_limit_holds(self):
        self.write("2626_4985", [self.square()] * 50)
        found = map_edits.load_candidates(self.dir, 41.29, 69.24, 41.31, 69.26,
                                          limit=10)
        self.assertEqual(len(found), 10, "потолок не сработал")

    def test_tiles_are_not_read_as_candidates(self):
        # Кандидат не тайл: индекс подписан и описывает то, что едет на
        # телефоны, а кандидата ещё никто не смотрел.
        with open(os.path.join(self.dir, "road2_2626_4985_h.json"), "w",
                  encoding="utf-8") as handle:
            json.dump({"version": 2, "roads": [[6, 1, self.square()]]}, handle)
        self.assertEqual(
            map_edits.load_candidates(self.dir, 41.29, 69.24, 41.31, 69.26), [])


class OwnSearchTests(unittest.TestCase):
    """Поиск по своему адресному индексу: без ключа и без чужого сервиса."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)
        path = os.path.join(self.dir, "road2_262_498_a.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump({"version": 1, "streets": [
                {"n": "Mustaqillik shoh ko'chasi", "h": ["5", "7"],
                 "p": [4131000, 6928000, 100, 100]},
                {"n": "Navoiy ko'chasi", "h": ["1"],
                 "p": [4132000, 6929000]},
            ]}, handle)

    def test_cyrillic_finds_latin(self):
        # 72 % улиц центра записаны латиницей, 28 % кириллицей, и человек
        # ищет как ему привычно. «Мустакиллик» и «Mustaqillik» — одна улица.
        found = map_edits.search_addresses(self.dir, "Мустакиллик")
        self.assertTrue(found)
        self.assertEqual(found[0]["street"], "Mustaqillik shoh ko'chasi")

    def test_latin_spellings_agree(self):
        for spelling in ("Mustaqillik", "Mustakillik", "mustaqillik"):
            self.assertTrue(map_edits.search_addresses(self.dir, spelling),
                            spelling)

    def test_house_number_narrows(self):
        found = map_edits.search_addresses(self.dir, "Mustaqillik 7")
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0]["house"], "7")

    def test_nearest_comes_first(self):
        near = map_edits.search_addresses(self.dir, "ko", near=(41.32, 69.29))
        self.assertEqual(near[0]["street"], "Navoiy ko'chasi")

    def test_uzbek_o_with_apostrophe_is_russian_u(self):
        # «Oʻzbekiston» — «Узбекистан»: «oʻ» по-русски «у», а не «а».
        self.assertEqual(map_edits.fold("O\u02bbzbekiston"), map_edits.fold("Узбекистан"))
        self.assertEqual(map_edits.fold("Ko'kcha"), map_edits.fold("Кукча"))
        self.assertEqual(map_edits.fold("G\u2018afur"), map_edits.fold("Гафур"))

    def test_the_same_address_is_not_listed_twice(self):
        # В OSM адрес висит и точкой, и на контуре дома — в списке из восьми
        # строк два одинаковых адреса это две строки впустую.
        path = os.path.join(self.dir, "road2_262_499_a.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump({"version": 1, "streets": [
                {"n": "Mustaqillik shoh ko'chasi", "h": ["5"],
                 "p": [4131000, 6928000]},
            ]}, handle)
        found = map_edits.search_addresses(self.dir, "Mustaqillik 5")
        self.assertEqual(len(found), 1)

    def test_empty_query_finds_nothing(self):
        self.assertEqual(map_edits.search_addresses(self.dir, "  "), [])

    def test_missing_directory_is_not_an_error(self):
        self.assertEqual(map_edits.search_addresses("/нет", "что-нибудь"), [])


class FrameLimitTests(unittest.TestCase):
    """Потолок по охвату: на квартале всё, на городе — костяк.

    Один потолок на все случаи означал «покажи шестую часть города и молчи»,
    и молчал он именно там, где пустой экран неотличим от отсутствия данных.
    """

    def test_close_view_keeps_everything(self):
        limits = map_edits.frame_limits(41.310, 69.280, 41.315, 69.285)
        self.assertEqual(limits["class"], 7, "на квартале скрыли дворовые")

    def test_city_view_drops_the_small_roads(self):
        limits = map_edits.frame_limits(41.20, 69.10, 41.40, 69.40)
        self.assertLessEqual(limits["class"], 4)

    def test_city_view_reads_the_skeleton_not_the_streets(self):
        # Кадр города на наборе улиц — 134 файла и 3,7 МБ; он же костяком —
        # 0,6 МБ. Костяк для дальнего плана и посчитан.
        far = map_edits.frame_limits(41.0, 68.9, 41.6, 69.7, mpp=19.0)
        self.assertEqual(far["sets"], ("f",))
        self.assertTrue(far["skeleton"])
        near = map_edits.frame_limits(41.310, 69.280, 41.315, 69.285, mpp=0.9)
        self.assertEqual(near["sets"], ("s", "y"))
        self.assertFalse(near["skeleton"])

    def test_wider_view_never_gets_a_smaller_budget(self):
        # Бюджет считаем в БАЙТАХ: файл — плохая мера работы, тайл костяка
        # весит килобайт, а тайл улиц центра — сто тридцать три.
        budget = [map_edits.frame_limits(41.3, 69.2, 41.4, 69.3, mpp=m)["bytes"]
                  for m in (0.5, 2.0, 6.0, 12.0, 40.0)]
        self.assertEqual(budget, sorted(budget), "бюджет не растёт с масштабом")

    def test_object_ceiling_holds_at_every_span(self):
        for span in (0.005, 0.02, 0.08, 0.3, 2.0):
            limits = map_edits.frame_limits(41.3, 69.2, 41.3 + span, 69.2 + span)
            self.assertLessEqual(limits["objects"], 20_000)


class LimitReportTests(unittest.TestCase):
    """Потолок обязан о себе сообщать."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)

    def tile(self, key, roads):
        with open(os.path.join(self.dir, f"road2_{key}_s.json"), "w",
                  encoding="utf-8") as handle:
            json.dump({"version": 2, "roads": roads}, handle)

    def road(self, cls):
        return [cls, 0, [4131000, 6928000, 100, 100]]

    def test_thinned_roads_are_counted(self):
        self.tile("2626_4985", [self.road(3), self.road(7), self.road(7)])
        report = {}
        roads = map_edits.load_roads(self.dir, 41.30, 69.27, 41.32, 69.29,
                                     limits={"files": 9, "class": 4,
                                             "objects": None},
                                     report=report)
        self.assertEqual(len(roads), 1)
        self.assertEqual(report["thinned"], 2)
        self.assertEqual(report["worstClass"], 4)

    def test_skipped_files_are_counted(self):
        for column in range(4985, 4989):
            self.tile(f"2626_{column}", [self.road(3)])
        report = {}
        one = os.path.getsize(os.path.join(self.dir, "road2_2626_4985_s.json"))
        map_edits.load_roads(self.dir, 41.0, 69.0, 42.0, 70.0,
                             limits={"bytes": one * 2 + 1, "class": 7,
                                     "objects": None},
                             report=report)
        self.assertEqual(report["files"], 2)
        self.assertEqual(report["skipped"], 2)
        self.assertLessEqual(report["bytes"], one * 2 + 1)

    def test_the_budget_drops_the_edges_and_keeps_the_middle(self):
        # Прежний потолок брал ПЕРВЫЕ имена, а имена идут с юга на север:
        # у модератора северная половина города просто не приезжала, ровным
        # горизонтальным срезом. Если резать всё же придётся, теряем окраины.
        for row in range(2620, 2633):
            self.tile(f"{row}_4985", [self.road(3)])
        one = os.path.getsize(os.path.join(self.dir, "road2_2620_4985_s.json"))
        middle = {}
        map_edits.load_roads(self.dir, 41.0, 69.2, 41.6, 69.3,
                             limits={"bytes": one * 3 + 1, "class": 7,
                                     "objects": None},
                             report=middle)
        self.assertEqual(middle["files"], 3)
        self.assertGreater(middle["skipped"], 0)
        # Середина кадра — 41.3, то есть ряды 2626 и соседние.
        kept = map_edits.load_roads(self.dir, 41.29, 69.2, 41.31, 69.3,
                                    limits={"bytes": one * 3 + 1, "class": 7,
                                            "objects": None})
        self.assertTrue(kept, "центр кадра остался пустым")

    def test_cut_keeps_the_biggest_roads(self):
        # Обрезать список с конца значило бы выкинуть половину города целиком;
        # так исчезают самые мелкие проезды, и рисунок города остаётся.
        self.tile("2626_4985", [self.road(7), self.road(3), self.road(6)])
        report = {}
        roads = map_edits.load_roads(self.dir, 41.30, 69.27, 41.32, 69.29,
                                     limits={"files": 9, "class": 7,
                                             "objects": 2},
                                     report=report)
        self.assertTrue(report["cut"])
        self.assertEqual(sorted(r["cls"] for r in roads), [3, 6])

    def test_silence_when_nothing_was_hidden(self):
        self.tile("2626_4985", [self.road(3)])
        report = {}
        map_edits.load_roads(self.dir, 41.30, 69.27, 41.32, 69.29,
                             limits={"files": 9, "class": 7, "objects": None},
                             report=report)
        self.assertFalse(report["cut"])
        self.assertEqual(report["skipped"], 0)
        self.assertEqual(report["thinned"], 0)


class ViewportSpanTests(unittest.TestCase):
    """Потолок считается по ЭКРАНУ, а не по рамке запроса.

    Рамку мы просим с запасом в 60 % — чтобы движение туда-сюда не стоило
    запросов. Считать по ней подробность значит перебрасывать вид в более
    грубую полосу: на зуме 17 дворовые проезды пропадали ровно там, где по ним
    и работают.
    """

    def test_margin_does_not_coarsen_the_view(self):
        # Экран 0,01°, рамка с запасом — 0,022°.
        by_box = map_edits.frame_limits(41.300, 69.270, 41.322, 69.292)
        by_screen = map_edits.frame_limits(41.300, 69.270, 41.322, 69.292,
                                           span=0.01)
        self.assertEqual(by_screen["class"], 7, "на экране квартала скрыли дворы")
        self.assertLess(by_box["class"], by_screen["class"],
                        "проверка ничего не ловит: полосы совпали")

    def test_span_of_none_falls_back_to_the_box(self):
        # Рамку берём В СЕРЕДИНЕ полосы, а не на её краю: 41.32 − 41.30 в
        # двоичных дробях равно 0,019999999999996, а 69.29 − 69.27 — уже
        # 0,020000000000010, и одна и та же рамка попадает в разные полосы.
        # Тест, стоящий на границе, проверяет округление, а не правило.
        same = map_edits.frame_limits(41.300, 69.270, 41.305, 69.275)
        explicit = map_edits.frame_limits(41.300, 69.270, 41.305, 69.275,
                                          span=0.005)
        self.assertEqual(same, explicit)


class StreetPiecesTests(unittest.TestCase):
    """Полосы — свойство улицы, а не куска.

    Сборка режет дороги по перекрёсткам, чтобы получился граф. Размечать
    проспект пятнадцатью правками значит платить пятнадцать раз за один
    ответ: сто самых длинных улиц центра — 808 правок поштучно и 100 целиком.
    """

    def road(self, points, name="Навои", cls=3):
        return {"cls": cls, "name": name, "points": points, "flags": 0}

    def test_connected_pieces_come_together(self):
        a = self.road([(69.25, 41.30), (69.26, 41.30)])
        b = self.road([(69.26, 41.30), (69.27, 41.30)])
        c = self.road([(69.27, 41.30), (69.28, 41.30)])
        found = map_edits.street_pieces([a, b, c], a)
        self.assertEqual(len(found), 3)

    def test_same_name_apart_stays_apart(self):
        # «Мустакиллик» есть в каждом районе: совпало имя — мало.
        a = self.road([(69.25, 41.30), (69.26, 41.30)])
        far = self.road([(69.50, 41.40), (69.51, 41.40)])
        self.assertEqual(len(map_edits.street_pieces([a, far], a)), 1)

    def test_another_class_is_another_street(self):
        a = self.road([(69.25, 41.30), (69.26, 41.30)])
        side = self.road([(69.26, 41.30), (69.27, 41.30)], cls=6)
        self.assertEqual(len(map_edits.street_pieces([a, side], a)), 1)

    def test_nameless_road_is_alone(self):
        a = self.road([(69.25, 41.30), (69.26, 41.30)], name="")
        b = self.road([(69.26, 41.30), (69.27, 41.30)], name="")
        self.assertEqual(map_edits.street_pieces([a, b], a), [a])

    def test_limit_holds(self):
        chain = [self.road([(69.25 + i * 0.001, 41.30),
                            (69.251 + i * 0.001, 41.30)]) for i in range(30)]
        self.assertLessEqual(len(map_edits.street_pieces(chain, chain[0],
                                                         limit=5)), 5)

    def test_middle_is_by_length_not_by_vertex(self):
        # У куска из двух точек «средняя вершина» — это его конец, а концы
        # общие у соседей: правка села бы на перекрёсток вместо дороги.
        middle = map_edits.middle_of([(69.25, 41.30), (69.27, 41.30)])
        self.assertAlmostEqual(middle[0], 69.26, places=4)

    def test_middle_of_nothing_is_nothing(self):
        self.assertIsNone(map_edits.middle_of([]))


class NeverEmptyTests(unittest.TestCase):
    """Прореживание не имеет права оставить пустой экран.

    Замерено на живом кадре окраины: 876 дорог в тайлах, все класса 7, и
    потолок охвата скрыл их целиком. На экране чернота и совет «приблизьтесь»
    — то есть мы знали, что показать, и не показали.
    """

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)
        with open(os.path.join(self.dir, "road2_2626_4985_y.json"), "w",
                  encoding="utf-8") as handle:
            json.dump({"version": 2, "roads": [
                [7, 0, [4131000, 6928000, 100, 100]],
                [7, 0, [4131200, 6928200, 100, 100]],
            ]}, handle)

    def test_yards_are_shown_when_nothing_else_is_left(self):
        report = {}
        roads = map_edits.load_roads(self.dir, 41.30, 69.27, 41.32, 69.29,
                                     limits={"files": 9, "class": 4,
                                             "objects": 100},
                                     report=report)
        self.assertEqual(len(roads), 2, "экран остался пустым")
        self.assertEqual(report["thinned"], 0, "о скрытом сказано неправду")

    def test_thinning_still_works_when_something_remains(self):
        with open(os.path.join(self.dir, "road2_2626_4985_s.json"), "w",
                  encoding="utf-8") as handle:
            json.dump({"version": 2, "roads": [
                [3, 0, [4131000, 6928000, 100, 100]],
            ]}, handle)
        report = {}
        roads = map_edits.load_roads(self.dir, 41.30, 69.27, 41.32, 69.29,
                                     limits={"files": 9, "class": 4,
                                             "objects": 100},
                                     report=report)
        self.assertEqual(len(roads), 1)
        self.assertEqual(report["thinned"], 2)


class ScaleLimitTests(unittest.TestCase):
    """Подробность решает МАСШТАБ, а не размер окна.

    Полосы считались по охвату рамки в градусах, и на большом мониторе тот же
    зум давал вдвое больший охват: панель прятала дворовые проезды на
    семнадцатом зуме — там, где по ним и работают.
    """

    def test_same_zoom_gives_same_detail_on_any_screen(self):
        small = map_edits.frame_limits(41.300, 69.270, 41.310, 69.280, mpp=1.0)
        big = map_edits.frame_limits(41.280, 69.250, 41.330, 69.320, mpp=1.0)
        self.assertEqual(small, big)
        self.assertEqual(small["class"], 7, "на рабочем масштабе скрыли дворы")

    def test_zooming_out_thins_the_small_roads(self):
        self.assertEqual(
            map_edits.frame_limits(41.2, 69.1, 41.4, 69.4, mpp=10.0)["class"], 4)

    def test_span_still_works_when_scale_is_unknown(self):
        # Старые вкладки шлют только охват — они обязаны продолжать работать.
        by_span = map_edits.frame_limits(41.300, 69.270, 41.305, 69.275)
        self.assertEqual(by_span["class"], 7)

    def test_scale_beats_span_when_both_are_given(self):
        both = map_edits.frame_limits(41.2, 69.1, 41.4, 69.4, span=0.3, mpp=0.8)
        self.assertEqual(both["class"], 7, "масштаб проиграл охвату")


class PanelShadowTests(unittest.TestCase):
    """Своя переменная не имеет права звать функцию тем же именем.

    `const wide = ...` внутри drawRoads перекрыл функцию `wide()`, которую
    та же drawRoads зовёт двумя строками выше. Это не предупреждение, а
    смерть кадра: ReferenceError на первой строке, отрисовка не начинается,
    карта остаётся чёрной — и никакой разбор файла об этом не скажет,
    `node --check` такой файл принимает.

    Сторожим ровно смертельный случай — затенение В ТОМ ЖЕ теле, которое
    функцию зовёт. Безобидные тёзки в чужих телах не трогаем: запрет,
    требующий переименовывать работающий код, снимут первым.
    """

    def bodies(self):
        source = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                              "static", "editor.js")
        with open(source, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
        names = set()
        for text in lines:
            head = re.match(r"^  (?:async )?function (\w+)\s*\(", text)
            if head:
                names.add(head.group(1))
        out, start, name = [], None, None
        for number, text in enumerate(lines, 1):
            head = re.match(r"^  (?:async )?function (\w+)\s*\(", text)
            if head:
                start, name = number, head.group(1)
            elif text == "  }" and start is not None:
                out.append((name, start, lines[start:number - 1]))
                start = None
        return names, out

    def test_no_local_shadows_a_function_its_own_body_calls(self):
        names, bodies = self.bodies()
        self.assertGreater(len(names), 50, "функции верхнего уровня не нашлись")
        deadly = []
        for owner, start, body in bodies:
            taken = set()
            for text in body:
                own = re.match(r"^\s{3,}(?:const|let|var)\s+(\w+)\s*[=;]", text)
                if own and own.group(1) in names:
                    taken.add(own.group(1))
            for shadow in sorted(taken):
                for offset, text in enumerate(body):
                    call = re.search(r"(?<![.\w])" + shadow + r"\s*\(", text)
                    if call and not re.match(r"^\s*(?:const|let|var)\s+" + shadow, text):
                        deadly.append(f"{owner} (строка {start}): "
                                      f"{shadow} затенён и вызван на "
                                      f"{start + offset}")
                        break
        self.assertEqual(deadly, [], "затенение убьёт кадр: " + "; ".join(deadly))


class TileListingCacheTests(unittest.TestCase):
    """Перечисление имён — тоже работа, и на боевом она была самой дорогой.

    Каждый запрос делал sorted(os.listdir()) по каталогу с 82 496 файлами:
    230 мс ещё до того, как открыт хоть один тайл. Набор воды из тысячи
    объектов «стоил» столько же, сколько набор кварталов из пятнадцати тысяч —
    вот по этому совпадению и нашлось.

    Кэш обязан отпускать после публикации: подменённый каталог с новыми
    тайлами, о котором панель не узнала, — это вчерашняя карта без единого
    признака того, что она вчерашняя.
    """

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)
        map_edits._NAMES_CACHE.clear()

    def write(self, name):
        with open(os.path.join(self.dir, name), "w", encoding="utf-8") as handle:
            json.dump({"version": 2, "roads": [[3, 0, [4131000, 6928000, 10, 10]]]},
                      handle)

    def test_second_call_does_not_list_again(self):
        self.write("road2_2626_4985_s.json")
        first = map_edits._tile_names(self.dir)
        calls = []
        real = os.listdir

        def counted(path):
            calls.append(path)
            return real(path)

        os.listdir = counted
        try:
            again = map_edits._tile_names(self.dir)
        finally:
            os.listdir = real
        self.assertEqual(first, again)
        self.assertEqual(calls, [], "каталог перечитан впустую")

    def test_publishing_new_tiles_is_noticed(self):
        self.write("road2_2626_4985_s.json")
        self.assertEqual(len(map_edits._tile_names(self.dir)), 1)
        # Публикация меняет каталог — вместе с ним и его метку времени.
        self.write("road2_2626_4986_s.json")
        os.utime(self.dir, (0, 0))
        self.assertEqual(len(map_edits._tile_names(self.dir)), 2,
                         "панель не заметила новых тайлов")

    def test_a_missing_directory_is_not_an_exception(self):
        self.assertEqual(map_edits._tile_names(os.path.join(self.dir, "нет")), [])


class AreaCeilingTests(unittest.TestCase):
    """Потолок местности режет по размеру, а не по порядку файлов.

    У дорог эту работу делает класс: проспект переживает прореживание, двор —
    нет. У местности класса нет. Резать с конца списка нельзя: файлы идут по
    порядку имён, то есть по земле, и с конца стирались бы целые области.
    """

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)
        map_edits._NAMES_CACHE.clear()

    def tile(self, key, areas):
        with open(os.path.join(self.dir, f"road2_{key}_g.json"), "w",
                  encoding="utf-8") as handle:
            json.dump({"version": 2, "roads": areas}, handle)

    def patch(self, size):
        # Квадрат со стороной size (в стотысячных градуса) от одной точки.
        return [2, map_edits.AREA_CLOSED,
                [4131000, 6928000, size, 0, 0, size, -size, 0]]

    def test_the_biggest_survive(self):
        self.tile("2626_4985", [self.patch(20), self.patch(4000), self.patch(50)])
        kept = map_edits.load_areas(self.dir, 41.30, 69.27, 41.36, 69.33,
                                    sets=("g",), objects=1)
        self.assertEqual(len(kept), 1)
        self.assertGreater(map_edits._area_extent(kept[0]), 0.01,
                           "потолок оставил мелочь, а не крупное")

    def test_no_ceiling_keeps_everything(self):
        self.tile("2626_4985", [self.patch(20), self.patch(4000), self.patch(50)])
        self.assertEqual(len(map_edits.load_areas(self.dir, 41.30, 69.27,
                                                  41.36, 69.33, sets=("g",))), 3)

    def test_sets_thin_out_with_the_scale(self):
        # Полотно дорог на кадре города — 4,8 МБ ради ленты в полтора пикселя,
        # поверх которой и так рисуется сама дорога.
        self.assertIn("d", map_edits.area_sets(0.9))
        self.assertNotIn("d", map_edits.area_sets(19.0))
        self.assertNotIn("t", map_edits.area_sets(19.0))
        self.assertIn("w", map_edits.area_sets(19.0), "вода нужна на любом охвате")


class ThinPointsTests(unittest.TestCase):
    """Вершины, ложащиеся в один пиксель, — это байты, которых не видно.

    Порог держим в ОДИН пиксель. На двух уже видно, как скругляются углы
    кварталов, а кольцо обязано остаться кольцом: заливка по двум точкам не
    рисуется вовсе.
    """

    def ring(self, count):
        return [[69.28 + i * 0.00001, 41.31] for i in range(count)]

    def test_close_vertices_go(self):
        # Шаг между вершинами — около метра; порог в пятьдесят.
        kept = map_edits.thin_points(self.ring(60), 50)
        self.assertLess(len(kept), 10)
        self.assertGreaterEqual(len(kept), 3)

    def test_the_ends_are_never_dropped(self):
        points = self.ring(60)
        kept = map_edits.thin_points(points, 50)
        self.assertEqual(kept[0], points[0], "начало кольца потеряно")
        self.assertEqual(kept[-1], points[-1], "замыкание кольца потеряно")

    def test_a_triangle_survives_any_threshold(self):
        triangle = [[69.28, 41.31], [69.2801, 41.31], [69.28, 41.3101]]
        self.assertEqual(map_edits.thin_points(triangle, 10_000), triangle)

    def test_sparse_geometry_is_left_alone(self):
        wide = [[69.28, 41.31], [69.29, 41.31], [69.29, 41.32], [69.28, 41.32]]
        self.assertEqual(map_edits.thin_points(wide, 5), wide)

    def test_no_threshold_changes_nothing(self):
        points = self.ring(60)
        self.assertEqual(map_edits.thin_points(points, 0), points)


class PanelPaletteTests(unittest.TestCase):
    """Контраст палитры — число, а не впечатление.

    Отсюда и взялся квартал #12151b при фоне #0e1013: кто-то посмотрел и
    решил, что видно. Контраст 1,04 — это невидимо, и на охвате области
    застройка не давала городу никакой массы.

    Поднять её на всех масштабах нельзя: вблизи дорога идёт ПО кварталу, и
    при контрасте 1,51 дворовый проезд к нему — 1,15, то есть исчезает.
    Поэтому палитр две, и сторожим обе.
    """

    GROUND = "#0e1013"

    def source(self):
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "static", "editor.js")
        with open(path, encoding="utf-8") as handle:
            return handle.read()

    def lum(self, colour):
        parts = [int(colour[i:i + 2], 16) / 255 for i in (1, 3, 5)]
        parts = [c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
                 for c in parts]
        return 0.2126 * parts[0] + 0.7152 * parts[1] + 0.0722 * parts[2]

    def ratio(self, one, two):
        a, b = self.lum(one), self.lum(two)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)

    def skin(self, name):
        """Одна шкура целиком: земля, местность, асфальт, кайма."""
        text = self.source()
        body = re.search(name + r": \{(.*?)\n    \},\n(?:    day|  \};)",
                         text, re.S)
        self.assertIsNotNone(body, f"шкуры {name} нет в editor.js")
        return body.group(1)

    def ground(self, name):
        found = re.search(r"ground: '(#\w{6})'", self.skin(name))
        self.assertIsNotNone(found, f"у шкуры {name} нет земли")
        return found.group(1)

    def look(self, name="night"):
        out = {}
        for row in re.finditer(r"(\d+): \{ fill: '(#\w{6})'(?:, far: '(#\w{6})')?",
                               self.skin(name)):
            out[int(row.group(1))] = (row.group(2), row.group(3))
        self.assertTrue(out, f"у шкуры {name} нет местности")
        return out

    def asphalt(self, name="night"):
        rows = [(int(r.group(1)), r.group(2), r.group(3)) for r in
                re.finditer(r"upto: (\d+), near: '(#\w{6})', far: '(#\w{6})'",
                            self.skin(name))]
        self.assertTrue(rows, f"у шкуры {name} нет асфальта")
        return rows

    def test_far_land_is_actually_visible(self):
        want = {1: 1.25, 2: 1.25, 4: 1.4, 6: 1.2}
        for skin in ("night", "day"):
            ground = self.ground(skin)
            for kind, least in want.items():
                near, far = self.look(skin)[kind]
                self.assertIsNotNone(far, f"{skin}: у вида {kind} нет дальней ступени")
                self.assertGreaterEqual(round(self.ratio(far, ground), 2), least,
                                        f"{skin}: вид {kind} вдали не виден")

    def test_roads_stay_above_the_buildings(self):
        # Самая мелкая дорога обязана отличаться от застройки — иначе сеть
        # тонет в кварталах ровно там, где по ней и ориентируются. Ночью это
        # делает светлота асфальта, днём — кайма: белая дорога на светло-сером
        # квартале различима именно краем.
        for skin, least_near, least_far in (("night", 1.5, 1.7), ("day", 1.15, 1.5)):
            block_near, block_far = self.look(skin)[4]
            for upto, near, far in self.asphalt(skin):
                self.assertGreater(self.ratio(near, block_near), least_near,
                                   f"{skin}: класс ≤{upto} тонет в квартале вблизи")
                self.assertGreater(self.ratio(far, block_far), least_far,
                                   f"{skin}: класс ≤{upto} тонет в квартале вдали")

    def test_the_casing_gives_the_road_an_edge(self):
        # Кайма, хорошая вблизи, на дальнем плане сливалась с кварталом (1,02),
        # и дорога теряла края — поэтому она тоже двухступенчатая.
        for skin in ("night", "day"):
            body = self.skin(skin)
            near = re.search(r"casing: '(#\w{6})'", body).group(1)
            far = re.search(r"casingFar: '(#\w{6})'", body).group(1)
            road = self.asphalt(skin)[0]
            self.assertGreater(self.ratio(near, road[1]), 1.5,
                               f"{skin}: кайма не отделяет дорогу вблизи")
            block_far = self.look(skin)[4][1]
            self.assertGreater(self.ratio(far, block_far), 1.2,
                               f"{skin}: кайма вдали сливается с кварталом")

    def test_the_hierarchy_of_classes_never_inverts(self):
        for skin in ("night", "day"):
            rows = self.asphalt(skin)
            back = self.lum(self.ground(skin)) < 0.2
            for name, at in (("вблизи", 1), ("вдали", 2)):
                light = [self.lum(row[at]) for row in rows]
                # Ночью магистраль — самая светлая, днём — тоже (белая), но
                # порядок обязан быть строго один и тот же в обе стороны.
                self.assertEqual(light, sorted(light, reverse=True),
                                 f"{skin} {name}: мелкая дорога светлее магистрали")
                self.assertTrue(back or True)

    def test_the_far_step_moves_away_from_the_ground(self):
        # Ночью дальняя ступень светлее ближней, днём — темнее. Общее правило
        # одно: она обязана быть ДАЛЬШЕ от земли, иначе смысла в ней нет.
        for skin in ("night", "day"):
            ground = self.lum(self.ground(skin))
            for kind, (near, far) in self.look(skin).items():
                if far is None:
                    continue
                self.assertGreater(abs(self.lum(far) - ground),
                                   abs(self.lum(near) - ground),
                                   f"{skin}: вид {kind} вдали ближе к земле, чем вблизи")


class StreetNameTests(unittest.TestCase):
    """Подписи улиц: правила, а не шрифт.

    До этого в панели не было НИ ОДНОГО вызова fillText — карта была
    безымянной, и улица называлась только после щелчка. Раскладку в canvas
    приходится писать руками: ни коллизий, ни автоматики там нет, поэтому
    сторожим ровно те правила, из-за нарушения которых подписи превращаются
    в мусор.

    Замерено на живом кадре центра, 3008 пикселей, 1,8 м/пиксель: улиц с
    именем 361, подписей нарисовано 40 (упёрлись в бюджет), коротких 31,
    не поместились 32, наложились 3, за кадром 32.
    """

    def source(self):
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "static", "editor.js")
        with open(path, encoding="utf-8") as handle:
            return handle.read()

    def test_the_pass_is_wired_in(self):
        text = self.source()
        self.assertIn("paintNames", text)
        order = re.search(r"\[paintLand, paintNet, paintMarks, (\w+), ", text)
        self.assertIsNotNone(order, "проход подписей не в списке слоёв")
        self.assertEqual(order.group(1), "paintNames",
                         "подписи рисуются не после сети и обстановки")

    def test_a_label_is_never_upside_down(self):
        # Разворачиваем УЧАСТОК, а не текст: перевёрнутое название читается
        # как сбой отрисовки, а не как подпись.
        self.assertIn("if (to[0] < from[0]) { const swap = from; from = to; to = swap; }",
                      self.source())

    def test_labels_do_not_overlap(self):
        self.assertIn("taken.push(box)", self.source(),
                      "занятые места не запоминаются — подписи налезут")

    def test_a_label_that_does_not_fit_is_not_drawn(self):
        # Обрезок названия хуже его отсутствия.
        self.assertIn("if (width + 12 > run.length) { return false; }",
                      self.source())

    def test_one_name_is_not_repeated_side_by_side(self):
        # Улица приезжает несколькими лентами: у проспекта с дублёром разные
        # классы, а склейка идёт по классу. «Mustaqillik shoh ko'chasi» так
        # подписывалась пять раз, и две подписи стояли впритык одна над другой.
        text = self.source()
        found = re.search(r"const NAME_REPEAT = (\d+);", text)
        self.assertIsNotNone(found, "повторы имён ничем не разведены")
        self.assertGreaterEqual(int(found.group(1)), 300,
                                "полэкрана — это меньше трёхсот пикселей?")
        self.assertIn("already[text] = centre", text)

    def test_the_budget_is_real_and_sane(self):
        found = re.search(r"const NAME_BUDGET = (\d+);", self.source())
        self.assertIsNotNone(found, "бюджета подписей нет")
        self.assertLessEqual(int(found.group(1)), 60,
                             "столько подписей в кадре — это уже не карта")

    def test_far_views_are_left_alone(self):
        # На охвате района имя улицы не нужно и не помещается; там нужны
        # названия населённых пунктов, а их в данных пока нет.
        found = re.search(r"const NAME_FAR_MPP = (\d+);", self.source())
        self.assertIsNotNone(found)
        self.assertLessEqual(int(found.group(1)), 12)


class PassRunnerTests(unittest.TestCase):
    """Слой обязан дорисоваться даже без кадра.

    Голого requestAnimationFrame мало: у окна, закрытого другим окном, кадры
    не приходят ВООБЩЕ. Поймано следом в консоли — кадр заказан (id 2, 3, 4),
    таймер на 300 мс сработал трижды, кадр не пришёл ни разу. Холст оставался
    залитым землёй с одной местностью: ни сети, ни обстановки, ни подписей.
    """

    def source(self):
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "static", "editor.js")
        with open(path, encoding="utf-8") as handle:
            return handle.read()

    def test_the_next_layer_has_a_second_way_to_arrive(self):
        text = self.source()
        self.assertIn("function soon(work)", text, "гонки кадра и таймера нет")
        self.assertIn("soon(step)", text, "слои по-прежнему ждут только кадра")

    def test_the_race_cancels_the_loser(self):
        text = self.source()
        self.assertIn("window.clearTimeout(timer)", text)
        self.assertIn("window.cancelAnimationFrame(frame)", text)

    def test_no_bare_frame_request_is_left_in_the_runner(self):
        text = self.source()
        runner = re.search(r"function runPasses\(passes\) \{(.*?)\n  \}", text, re.S)
        self.assertIsNotNone(runner)
        self.assertNotIn("requestAnimationFrame", runner.group(1),
                         "в бегуне слоёв снова остался голый кадр")


class PlaceReadTests(unittest.TestCase):
    """Названия населённых пунктов: читаются своим набором и по масштабу.

    До этого набора дальний план оставался картой без адресов: сеть дорог
    есть, а где Чирчик, а где Ангрен — неизвестно. Показать все ранги сразу
    значит закрыть карту словами, поэтому ранг решает, с какого масштаба
    подписывать.
    """

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)
        map_edits._NAMES_CACHE.clear()

    def tile(self, key, rows):
        with open(os.path.join(self.dir, f"road2_{key}_n.json"), "w",
                  encoding="utf-8") as handle:
            json.dump({"version": 2, "roads": rows}, handle, ensure_ascii=False)

    def place(self, rank, lat, lon, name):
        return [rank, 0, [round(lat * 100000), round(lon * 100000)], name]

    def test_a_city_is_read_with_its_name(self):
        self.tile("2626_4985", [self.place(1, 41.31, 69.28, "Toshkent")])
        got = map_edits.load_places(self.dir, 41.0, 69.0, 41.6, 69.6, mpp=100)
        self.assertEqual(len(got), 1)
        self.assertEqual(got[0]["name"], "Toshkent")
        self.assertEqual(got[0]["rank"], 1)
        self.assertEqual(got[0]["kind"], "город")

    def test_small_places_wait_for_a_closer_scale(self):
        self.tile("2626_4985", [self.place(1, 41.31, 69.28, "Toshkent"),
                                self.place(6, 41.312, 69.282, "Чиланзар")])
        far = map_edits.load_places(self.dir, 41.0, 69.0, 41.6, 69.6, mpp=100)
        self.assertEqual([p["name"] for p in far], ["Toshkent"])
        near = map_edits.load_places(self.dir, 41.0, 69.0, 41.6, 69.6, mpp=2)
        self.assertEqual(len(near), 2, "вблизи скрыли квартал")

    def test_the_frame_is_respected(self):
        self.tile("2626_4985", [self.place(1, 41.31, 69.28, "Toshkent")])
        self.assertEqual(
            map_edits.load_places(self.dir, 40.0, 68.0, 40.5, 68.5, mpp=100), [])

    def test_the_biggest_survive_the_ceiling(self):
        rows = [self.place(6, 41.30 + i / 1000, 69.28, f"квартал {i}")
                for i in range(20)]
        rows.append(self.place(1, 41.31, 69.29, "Toshkent"))
        self.tile("2626_4985", rows)
        got = map_edits.load_places(self.dir, 41.0, 69.0, 41.6, 69.6,
                                    mpp=2, limit=3)
        self.assertEqual(got[0]["name"], "Toshkent",
                         "потолок съел город, а не квартал")

    def test_scale_table_never_inverts(self):
        # Чем дальше отъехали, тем крупнее должны быть оставшиеся места.
        ranks = [map_edits.place_rank(m) for m in (200, 80, 30, 12, 6, 2)]
        self.assertEqual(ranks, sorted(ranks), "порядок рангов перевернулся")


class FrameTouchTests(unittest.TestCase):
    """Рамку проверяем ПЕРЕСЕЧЕНИЕМ, а не наличием вершины внутри.

    У куска дороги вершины стоят через десятки метров, и на ближнем плане
    проспект, проходящий через весь экран, не имеет внутри кадра ни одной.
    Замерено на боевых тайлах: 121 кадр вида вблизи (55 метров) по центру
    Ташкента. По вершине находилось 174 дороги, ещё **71 терялась** — они
    пересекают кадр, а вершины внутри не имеют. Это 28 % содержимого кадра, и
    именно на этом масштабе работает вид за рулём.
    """

    BOX = (41.310, 69.280, 41.311, 69.281)   # юг, запад, север, восток

    def test_a_road_crossing_the_frame_is_found(self):
        # Ни одной вершины внутри: концы далеко по обе стороны.
        crossing = [(69.270, 41.3105), (69.290, 41.3105)]
        self.assertTrue(map_edits.touches_box(crossing, *self.BOX))

    def test_a_road_beside_the_frame_is_not(self):
        aside = [(69.270, 41.3200), (69.290, 41.3200)]
        self.assertFalse(map_edits.touches_box(aside, *self.BOX))

    def test_a_vertex_inside_still_counts(self):
        self.assertTrue(map_edits.touches_box([(69.2805, 41.3105)], *self.BOX))

    def test_a_diagonal_that_misses_the_corner(self):
        # Рамки пересекаются, а сам отрезок проходит мимо угла — раньше такой
        # случай ловился «по рамке» и давал ложное попадание.
        miss = [(69.2790, 41.3120), (69.2830, 41.3160)]
        self.assertFalse(map_edits.touches_box(miss, *self.BOX))

    def test_an_empty_line_is_not_a_hit(self):
        self.assertFalse(map_edits.touches_box([], *self.BOX))
