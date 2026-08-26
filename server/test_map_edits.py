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
import os
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
            loaded = map_edits.load_roads(work, -90, -180, 90, 180)
            self.assertLessEqual(len(loaded), map_edits.MAX_TILES_PER_CALL)

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
