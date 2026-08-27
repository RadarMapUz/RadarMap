#!/usr/bin/env python3
"""Тесты ворот публикации. Запуск: python3 server/test_roads_gate.py

Здесь сторожится не «правильность», а ОСТОРОЖНОСТЬ: каждый тест описывает
способ, которым на телефоны могла бы уехать испорченная карта, и проверяет,
что ворота этого не пустили.
"""
import unittest

import roads_gate


def index(tiles, degrees=0.05):
    return {"version": 2, "tileDegrees": degrees,
            "tiles": {key: {"sha256": sha, "bytes": size}
                      for key, (sha, size) in tiles.items()}}


def even(count, size=1000, salt="a"):
    return index({f"t{i}": (f"{salt}{i}", size) for i in range(count)})


class GateTests(unittest.TestCase):

    def test_normal_week_passes(self):
        # Обычная неделя: пара правок в OSM, объём почти тот же.
        previous = even(100, 1000)
        candidate = even(100, 1010, salt="b")
        ok, reasons = roads_gate.decide(previous, candidate)
        self.assertTrue(ok, reasons)

    def test_truncated_extract_is_refused(self):
        # Выгрузка приехала обрезанной: osmium отработал, тайлы собрались,
        # всё выглядит нормально — просто дорог вдвое меньше.
        ok, reasons = roads_gate.decide(even(100, 1000), even(100, 500))
        self.assertFalse(ok)
        self.assertTrue(any("объём" in r for r in reasons), reasons)

    def test_sudden_growth_is_refused(self):
        # Рост тоже подозрителен: сменился фильтр классов, и в тайлы поехали
        # тропинки. Сеть страны за неделю так не растёт.
        ok, _ = roads_gate.decide(even(100, 1000), even(100, 2000))
        self.assertFalse(ok)

    def test_vanished_tile_is_refused(self):
        # Тайл исчезает, только если из региона пропали ВСЕ дороги.
        previous = even(10, 1000)
        candidate = index({f"t{i}": (f"b{i}", 1000) for i in range(9)})
        ok, reasons = roads_gate.decide(previous, candidate)
        self.assertFalse(ok)
        self.assertTrue(any("исчезло" in r for r in reasons), reasons)

    def test_single_tile_gutted_is_refused(self):
        # Общий объём в норме, а один тайл потерял три четверти: так выглядит
        # регион, выпавший из выгрузки.
        previous = even(20, 1000)
        tiles = {f"t{i}": (f"b{i}", 1000) for i in range(20)}
        tiles["t7"] = ("b7", 200)
        ok, reasons = roads_gate.decide(previous, index(tiles))
        self.assertFalse(ok)
        self.assertTrue(any("похудело" in r for r in reasons), reasons)

    def test_empty_candidate_is_refused(self):
        ok, reasons = roads_gate.decide(even(10), index({}))
        self.assertFalse(ok)
        self.assertIn("пуст", reasons[0])

    def test_first_publication_passes(self):
        # Сравнивать не с чем — это не повод отказывать.
        ok, _ = roads_gate.decide(index({}), even(10))
        self.assertTrue(ok)

    def test_grid_change_needs_saying_out_loud(self):
        # Смена сетки меняет ВСЕ ключи разом. Потайловые ворота при этом не
        # срабатывают, а теряют смысл — и первая же публикация нового формата
        # упёрлась бы в правило, написанное ради обрезанных выгрузок.
        previous = even(10, 1000, salt="a")
        candidate = index({f"n{i}": (f"c{i}", 100) for i in range(100)}, degrees=0.05)
        previous["tileDegrees"] = 0.5
        ok, reasons = roads_gate.decide(previous, candidate)
        self.assertFalse(ok)
        self.assertTrue(any("сетка" in r for r in reasons), reasons)

        ok, reasons = roads_gate.decide(previous, candidate, allow_grid_change=True)
        self.assertTrue(ok, reasons)

    def test_grid_change_still_checks_volume(self):
        # Разрешение сменить сетку — не индульгенция: обрезанную выгрузку оно
        # пускать не должно.
        previous = even(10, 1000)
        previous["tileDegrees"] = 0.5
        candidate = index({f"n{i}": (f"c{i}", 10) for i in range(10)})
        ok, reasons = roads_gate.decide(previous, candidate, allow_grid_change=True)
        self.assertFalse(ok)
        self.assertTrue(any("объём" in r for r in reasons), reasons)

    def test_summary_counts_changed_tiles(self):
        previous = even(10, 1000, salt="a")
        tiles = {f"t{i}": (f"a{i}", 1000) for i in range(10)}
        tiles["t3"] = ("changed", 1000)
        text = roads_gate.summary(previous, index(tiles))
        self.assertIn("изменилось 1", text)


class DrawnGateTests(unittest.TestCase):
    """Ворота для нарисованного руками.

    Своя геометрия — единственные данные в системе, которые нельзя
    восстановить пересборкой, и единственные, которые не с чем сверить, кроме
    рук, их нарисовавших. Проверять её надо строже всего остального, но
    проверять СМЫСЛ, а не аккуратность.
    """

    def line(self, *coords, **props):
        props.setdefault("why", "нет в OSM")
        return {"id": 1, "kind": "geometry",
                "geom": [[lon, lat] for lat, lon in coords], "props": props}

    def straight(self, meters, **props):
        # 0.00001° широты ≈ 1.11 м.
        return self.line((41.300, 69.250),
                         (41.300 + meters / 111_320.0, 69.250), **props)

    def test_good_road_passes(self):
        ok, reasons = roads_gate.check_drawn([self.straight(200)])
        self.assertTrue(ok, reasons)

    def test_stub_is_refused(self):
        ok, reasons = roads_gate.check_drawn([self.straight(5)])
        self.assertFalse(ok)
        self.assertIn("короче", " ".join(reasons))

    def test_reason_is_mandatory(self):
        edit = self.straight(200)
        edit["props"].pop("why")
        ok, reasons = roads_gate.check_drawn([edit])
        self.assertFalse(ok)
        self.assertIn("почему", " ".join(reasons))

    def test_free_text_reason_is_not_accepted(self):
        # Свободный текст через полгода превращается в «тест» и «пока так».
        ok, _ = roads_gate.check_drawn([self.straight(200, why="пока так")])
        self.assertFalse(ok)

    def test_jump_across_the_city_is_refused(self):
        ok, reasons = roads_gate.check_drawn([self.straight(9000)])
        self.assertFalse(ok)
        self.assertIn("полгорода", " ".join(reasons))

    def test_mouse_tremor_is_refused(self):
        many = [(41.300 + i * 0.00002, 69.250) for i in range(300)]
        ok, reasons = roads_gate.check_drawn([self.line(*many)])
        self.assertFalse(ok)
        self.assertIn("дрожь", " ".join(reasons))

    def test_all_complaints_come_at_once(self):
        # Модератор, нарисовавший десять дорог, должен увидеть все замечания
        # разом, а не открывать ворота десять раз подряд.
        bad = self.straight(5)
        bad["props"].pop("why")
        ok, reasons = roads_gate.check_drawn([bad])
        self.assertFalse(ok)
        self.assertGreaterEqual(len(reasons), 2)

    def test_too_many_at_once_is_a_question(self):
        ok, reasons = roads_gate.check_drawn(
            [self.straight(200) for _ in range(60)])
        self.assertFalse(ok)
        self.assertIn("за раз", " ".join(reasons))

    def test_other_kinds_are_not_checked_here(self):
        ok, _ = roads_gate.check_drawn([{"kind": "lanes", "geom": [69.25, 41.3]}])
        self.assertTrue(ok)


if __name__ == "__main__":
    unittest.main()


class DeliberateWaiverTests(unittest.TestCase):
    """Осознанный пропуск объёмных ворот — с причиной и не для всего.

    День, ради которого он заведён: набор домов уехал впервые (+78 МБ), а
    крупная местность перестала возиться в каждый тайл целиком — 2 925 тайлов
    похудели. На проверенном образце это 1 421 вершина против 13 при той же
    покрытой земле, то есть ворота видели правду и правильно останавливали
    автоматику.
    """

    def index(self, tiles):
        return {"tileDegrees": 0.05,
                "tiles": {k: {"sha256": k, "bytes": v} for k, v in tiles.items()}}

    def test_volume_passes_only_when_asked(self):
        was = self.index({"a_w": 1000, "b_w": 1000})
        now = self.index({"a_w": 3000, "b_w": 3000})
        ok, reasons = roads_gate.decide(was, now)
        self.assertFalse(ok, "трёхкратный рост прошёл молча")
        ok, reasons = roads_gate.decide(was, now, allow_big_change=True)
        self.assertTrue(ok)
        self.assertTrue(any("пропущено осознанно" in r for r in reasons),
                        "пропуск не назван вслух")

    def test_an_empty_candidate_is_never_waived(self):
        # Пустой кандидат — это отсутствие данных, а не «сильное изменение».
        ok, reasons = roads_gate.decide(self.index({"a_w": 1000}), {"tiles": {}},
                                        allow_big_change=True)
        self.assertFalse(ok)

    def test_a_grid_change_is_never_waived(self):
        was = self.index({"a_w": 1000})
        now = {"tileDegrees": 0.02, "tiles": {"x_w": {"sha256": "x", "bytes": 1000}}}
        ok, _ = roads_gate.decide(was, now, allow_big_change=True)
        self.assertFalse(ok, "смена сетки прошла по пропуску объёма")

    def test_nothing_is_waived_when_nothing_is_wrong(self):
        same = self.index({"a_w": 1000})
        ok, reasons = roads_gate.decide(same, same, allow_big_change=True)
        self.assertTrue(ok)
        self.assertEqual(reasons, [], "тихая публикация обросла словами")
