#!/usr/bin/env python3
"""Слияние реестра с боевой базой камер.

Главное, что здесь охраняется, — НЕПОДВИЖНОСТЬ id. Он лежит в пользовательских
данных (проезды истории, «свои» камеры, скрытые, переопределения), и его сдвиг
переклеивает чужие проезды на чужие камеры. Это единственная ошибка в проекте,
которую нельзя починить следующим релизом: история уже испорчена.
"""
import unittest

import merge_cameras as mc


def cam(ident, lat, lon, **extra):
    base = {"id": ident, "region": "Toshkent shahar", "city": "Chilonzor tumani",
            "location": "Тест", "lat": lat, "lon": lon, "type": "Стационар радар"}
    base.update(extra)
    return base


def src(lat, lon, typ="Statsionar radar", location="Новая"):
    return {"Kenglik": str(lat), "Uzunlik": str(lon), "Turi": typ,
            "Viloyat": "Toshkent shahar / Ташкент / Tashkent",
            "Tuman": "CHILONZOR TUMANI", "Joylashganjoyi": location}


class ReadSourceTest(unittest.TestCase):
    def test_header_row_is_not_a_camera(self):
        rows = mc.read_source([{"Viloyat": "Viloyat / Област / Region",
                                "Kenglik": "41.0", "Uzunlik": "69.0", "Turi": "x"}])
        self.assertEqual(rows, [])

    def test_types_are_translated(self):
        rows = mc.read_source([src(41.3, 69.2, "Intellektual + radar")])
        self.assertEqual(rows[0]["type"], "Интеллектуал + радар")

    def test_coordinates_outside_the_country_are_dropped(self):
        self.assertEqual(mc.read_source([src(0, 0)]), [])
        self.assertEqual(mc.read_source([src(55.7, 37.6)]), [])   # Москва

    def test_accepts_an_already_normalised_candidate(self):
        rows = mc.read_source([{"lat": 41.3, "lon": 69.2, "type": "Стационар радар",
                                "region": "Toshkent shahar", "city": "Ч", "location": "Л"}])
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["type"], "Стационар радар")


class UnknownTypeTest(unittest.TestCase):
    def test_unknown_type_is_not_imported(self):
        # Незнакомая строка падает в CameraType.other, и камера ИСЧЕЗАЕТ с
        # карты у всех, кто включил фильтр «Камеры» или «Радары». Молчание о
        # настоящей камере хуже лишнего предупреждения.
        rows = mc.read_source([src(41.3, 69.2, "Kvadrokopter")])
        self.assertEqual(rows, [])

    def test_all_three_registry_types_are_known_to_the_app(self):
        for raw in ("Statsionar kamera", "Statsionar radar", "Intellektual + radar"):
            rows = mc.read_source([src(41.3, 69.2, raw)])
            self.assertEqual(len(rows), 1, raw)
            self.assertIn(rows[0]["type"], mc.KNOWN_TYPES)

    def test_verify_catches_a_strange_type_that_slipped_in(self):
        base = [cam(1, 41.0, 69.0)]
        sneaked = base + [cam(2, 42.0, 70.0, type="Квадрокоптер")]
        ok, why = mc.verify(base, sneaked)
        self.assertFalse(ok)
        self.assertIn("не знает", why)


class IdSpaceTest(unittest.TestCase):
    def test_ids_may_not_reach_the_hand_placed_space(self):
        # С 1 000 001 начинаются камеры, поставленные рукой: владельца точки
        # определяют ПО ЗНАЧЕНИЮ id, а не по флагу.
        base = [cam(1, 41.0, 69.0)]
        overflow = base + [cam(mc.MAX_BASE_ID + 1, 42.0, 70.0)]
        ok, why = mc.verify(base, overflow)
        self.assertFalse(ok)
        self.assertIn("рукой", why)

    def test_normal_ids_pass(self):
        base = [cam(3503, 41.0, 69.0)]
        ok, _why = mc.verify(base, mc.merged(base, mc.read_source([src(43.0, 71.0)])))
        self.assertTrue(ok)


class PlanTest(unittest.TestCase):
    def test_known_camera_is_not_added_again(self):
        base = [cam(1, 41.3000, 69.2000)]
        fresh, report = mc.plan(base, mc.read_source([src(41.3001, 69.2001)]))
        self.assertEqual(fresh, [])
        self.assertEqual(report["совпало с базой"], 1)

    def test_distant_camera_is_new(self):
        base = [cam(1, 41.3000, 69.2000)]
        fresh, _ = mc.plan(base, mc.read_source([src(41.3200, 69.2400)]))
        self.assertEqual(len(fresh), 1)

    def test_registry_duplicates_collapse_into_one(self):
        # Реестр держит одну камеру тремя строками, различающимися символом
        # апострофа в адресе. Три маркера в одной точке — это три голоса об
        # одном и том же радаре.
        base = [cam(1, 41.0, 69.0)]
        rows = mc.read_source([src(41.31, 69.25, location="QIZGʻALDOQ"),
                               src(41.31, 69.25, location="QIZG‘ALDOQ"),
                               src(41.3101, 69.2501, location="QIZGALDOQ")])
        fresh, _ = mc.plan(base, rows)
        self.assertEqual(len(fresh), 1)

    def test_camera_missing_from_the_registry_is_reported_not_deleted(self):
        base = [cam(1, 41.0, 69.0), cam(2, 42.0, 70.0)]
        fresh, report = mc.plan(base, mc.read_source([src(41.0, 69.0)]))
        self.assertEqual(report["в базе, но не в реестре"], 1)
        self.assertEqual(fresh, [])


class IdentityTest(unittest.TestCase):
    def test_new_ids_continue_the_numbering(self):
        base = [cam(1, 41.0, 69.0), cam(7, 42.0, 70.0)]
        self.assertEqual(mc.next_id(base), 8)

    def test_holes_in_the_numbering_are_never_reused(self):
        # Дыра — это удалённая камера. За её id может стоять чей-то проезд в
        # истории, и отдать его новой камере значит переклеить чужую поездку.
        base = [cam(1, 41.0, 69.0), cam(2, 41.1, 69.1), cam(9, 42.0, 70.0)]
        result = mc.merged(base, mc.read_source([src(43.0, 71.0)]))
        self.assertEqual(result[-1]["id"], 10, "новая камера заняла дыру 3–8")

    def test_existing_cameras_are_untouched(self):
        base = [cam(1, 41.0, 69.0, axis=167, dir=347, cls="primary",
                    road=[-882, 264, 883, -260])]
        result = mc.merged(base, mc.read_source([src(43.0, 71.0)]))
        self.assertEqual(result[0], base[0],
                         "существующая запись обязана остаться байт-в-байт той же")

    def test_geometry_of_existing_cameras_survives(self):
        # Кандидат update_cameras.py несёт только семь полей. Слияние обязано
        # брать геометрию из базы, а не из реестра.
        base = [cam(1, 41.0, 69.0, axis=90, cls="trunk", road=[1, 2, 3, 4], lanes=4)]
        result = mc.merged(base, mc.read_source([src(41.0001, 69.0001)]))
        self.assertEqual(result[0]["axis"], 90)
        self.assertEqual(result[0]["road"], [1, 2, 3, 4])

    def test_new_camera_is_marked_approximate(self):
        # Координата прямо из реестра, на ось дороги не посажена — приложение
        # обязано сказать об этом плашкой, а не делать вид, что знает точно.
        result = mc.merged([cam(1, 41.0, 69.0)], mc.read_source([src(43.0, 71.0)]))
        self.assertTrue(result[-1]["needsReview"])


class VerifyTest(unittest.TestCase):
    def test_untouched_base_passes(self):
        base = [cam(1, 41.0, 69.0)]
        ok, _why = mc.verify(base, mc.merged(base, mc.read_source([src(43.0, 71.0)])))
        self.assertTrue(ok)

    def test_renumbering_is_caught(self):
        # Ровно то, что делает update_cameras.py в конце build(): раздаёт id
        # заново по алфавиту. Проверка обязана это поймать.
        base = [cam(1, 41.0, 69.0), cam(2, 42.0, 70.0)]
        renumbered = [cam(1, 42.0, 70.0), cam(2, 41.0, 69.0)]
        ok, why = mc.verify(base, renumbered)
        self.assertFalse(ok)
        self.assertIn("переехала", why)

    def test_disappearing_camera_is_caught(self):
        base = [cam(1, 41.0, 69.0), cam(2, 42.0, 70.0)]
        ok, why = mc.verify(base, [cam(1, 41.0, 69.0)])
        self.assertFalse(ok)
        self.assertIn("исчезла", why)

    def test_duplicate_ids_are_caught(self):
        base = [cam(1, 41.0, 69.0)]
        ok, why = mc.verify(base, [cam(1, 41.0, 69.0), cam(1, 42.0, 70.0)])
        self.assertFalse(ok)
        self.assertIn("одинаковые", why)


if __name__ == "__main__":
    unittest.main()
