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


if __name__ == "__main__":
    unittest.main()
