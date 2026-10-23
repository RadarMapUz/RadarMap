#!/usr/bin/env python3
"""Тесты append_registry (28.I, v13): реестр дописывается в КОНЕЦ базы.

Охраняется три вещи. Прежние записи неподвижны — меняется у старой камеры
только twin, и только когда пару ей дала новая камера (id лежит в чужой
истории проездов, профиль старой камеры измерен и не переснимается).
Сопоставление по адресу: та же камера с переписанным адресом и сдвинутой
координатой не дублируется, а другая камера в 150 м от известной — не
глотается. Профиль новой — только по доказательству: перекрёсток двух улиц и
ненайденная трасса дают needsReview без профиля, потому что доверенный
неверный профиль глушит камеру. Дороги синтетические, без сети.
"""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import append_registry as ar  # noqa: E402

LAT_M = 1 / 110540.0
LON_M = 1 / 83630.0     # метр долготы на широте 41.3


def line(highway, coords, **props):
    props = dict(props, highway=highway)
    return {"type": "Feature", "properties": props,
            "geometry": {"type": "LineString", "coordinates": coords}}


def north(lon, lat0=41.300, lat1=41.320):
    return [[lon, lat0 + (lat1 - lat0) * k / 10] for k in range(11)]


def south(lon, lat0=41.300, lat1=41.320):
    return list(reversed(north(lon, lat0, lat1)))


def roads_file():
    features = [
        # Разделённая трасса D105: две проезжие части в ~21 м друг от друга.
        line("trunk", north(69.5000), ref="D105", oneway="yes", lanes="2"),
        line("trunk", south(69.50025), ref="D105", oneway="yes", lanes="2"),
        # Перекрёсток двух улиц.
        line("secondary", north(69.3000), name="Birinchi ko'chasi"),
        line("secondary", [[69.290, 41.3100], [69.310, 41.3100]], name="Ikkinchi ko'chasi"),
        # Боковой проезд и магистраль в ~25 м от него.
        line("service", north(69.3200)),
        line("primary", north(69.3203), name="Katta ko'chasi"),
        # Тротуар в индекс не попадает.
        line("footway", north(69.4000), name="Piyoda"),
    ]
    f = tempfile.NamedTemporaryFile("w", suffix=".geojsonl", delete=False, encoding="utf-8")
    for feat in features:
        f.write(json.dumps(feat) + "\n")
    f.close()
    return f.name


def cam(ident, lat, lon, location="Test", **extra):
    out = {"id": ident, "region": "Toshkent shahar", "city": "Chilonzor tumani",
           "location": location, "lat": lat, "lon": lon, "type": "Стационар радар"}
    out.update(extra)
    return out


def row(lat, lon, location="Yangi", typ="Стационар радар"):
    return {"region": "Toshkent shahar", "city": "Chilonzor tumani", "location": location,
            "lat": lat, "lon": lon, "type": typ}


class AddressTest(unittest.TestCase):
    def test_respelled_address_is_the_same(self):
        self.assertTrue(ar.addr_same("Txay-shifokorlar Shaharchasi 89-UY qarshisida",
                                     "Txay-shifokorlar Shaxarchasi 89-UY qarshisida"))
        # Кириллическая «е» внутри латинского слова — та же строка.
        self.assertTrue(ar.addr_same("Ibn Sino Ko‘chalari Kеsishmasi",
                                     "Ibn Sino Ko‘chalari Kesishmasi"))

    def test_other_number_is_another_camera(self):
        # «3-NUQTA» и «4-NUQTA» на одном базаре — две камеры.
        self.assertFalse(ar.addr_same('Saqchimon ko‘chasi "eski Juva" bozori oldi (3-NUQTA)',
                                      'Saqchimon ko‘chasi "eski Juva" bozori oldi (4-NUQTA)'))

    def test_share_road_by_number_or_name(self):
        self.assertTrue(ar.share_road('A-373 avtomobil Yo‘lining 320-321 km', 'A-373 "toshkent-o‘sh" 321 KM'))
        self.assertFalse(ar.share_road("D105 115 km", "A373 291 km"))
        self.assertTrue(ar.share_road("Labzak ko‘chasi 1-UY", "Labzak ko‘chasi Matrix oldi"))
        self.assertFalse(ar.share_road("Iftixor ko‘chasi 17 Uy", "Bunyod ko‘chasi 51-UY"))


class ClassifyTest(unittest.TestCase):
    def setUp(self):
        self.base = [cam(1, 41.30, 69.28, "Navoiy ko‘chasi 5-maktab oldi"),
                     cam(2, 41.32, 69.28, "Chilonzor ko‘chasi 10-UY")]

    def classes(self, source):
        matches, _ = ar.classify(self.base, source)
        return [m.cls for m in matches]

    def test_near_point_is_the_same_camera(self):
        self.assertEqual(self.classes([row(41.30 + 20 * LAT_M, 69.28, "Boshqa")]), ["same"])

    def test_same_address_far_from_snapped_point_is_not_new(self):
        # Снап отодвинул нашу точку на 120 м, реестр переписал адрес одной буквой.
        self.assertEqual(self.classes([row(41.30 + 120 * LAT_M, 69.28,
                                           "Navoiy ko‘chasi 5-MAKTAB oldi")]), ["same_addr"])

    def test_another_address_150_m_from_a_matched_camera_is_new(self):
        # Камера у школы в 150 м от перекрёстка, у которого реестр держит свою
        # строку рядом с нашей точкой, — другая камера. Порог 200 м её глотал.
        source = [row(41.30, 69.28, "Navoiy ko‘chasi 5-maktab oldi"),
                  row(41.30 + 150 * LAT_M, 69.28, "Navoiy ko‘chasi Prezident maktabi oldi")]
        self.assertEqual(self.classes(source), ["same", "new"])

    def test_registry_row_inside_50_m_is_one_place(self):
        self.assertEqual(self.classes([row(41.30 + 40 * LAT_M, 69.28, "Boshqa joy")]),
                         ["collapse"])

    def test_orphan_on_the_same_road_is_likely_the_same(self):
        # У камеры 2 своей строки нет, а в 150 м строка на той же улице — скорее
        # она же с новой координатой: не дописываем, отдаём человеку.
        self.assertEqual(self.classes([row(41.32 + 150 * LAT_M, 69.28,
                                           "Chilonzor ko‘chasi, avtobus bekati")]),
                         ["likely_same"])

    def test_new_rows_collapse_and_keep_the_senior_type(self):
        source = [row(41.40, 69.40, "A", "Стационар радар"),
                  row(41.40 + 20 * LAT_M, 69.40, "B", "Интеллектуал + радар")]
        matches, _ = ar.classify(self.base, source)
        by_cls = {m.cls: m.row["type"] for m in matches}
        self.assertEqual(by_cls["new"], "Интеллектуал + радар")
        self.assertEqual(by_cls["dup_new"], "Стационар радар")

    def test_gone_lists_only_unclaimed_cameras(self):
        source = [row(41.30, 69.28, "Navoiy ko‘chasi 5-maktab oldi")] + \
                 [row(41.40 + k * 0.001, 69.40, "x%d" % k) for k in range(3)]
        _, gone = ar.classify(self.base, source)
        self.assertEqual([c["id"] for c, _ in gone], [2])


class ProfileTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.path = roads_file()
        cls.index = ar.load_index(cls.path)

    @classmethod
    def tearDownClass(cls):
        os.unlink(cls.path)

    def choose(self, lat, lon, location):
        return ar.choose_profile(row(lat, lon, location), self.index)

    def test_highway_number_wins(self):
        choice = self.choose(41.31, 69.5000 + 5 * LON_M, "D105 avtomobil yo‘lining 115 km")
        self.assertEqual(choice.how, "ref")
        rec = ar.new_record(3540, row(41.31, 69.50005, "D105"), self.index, choice)
        self.assertNotIn("needsReview", rec)
        self.assertEqual(rec["dir"], 0)
        self.assertTrue(rec["split"])
        self.assertEqual(rec["cls"], "trunk")
        self.assertGreaterEqual(len(rec["road"]), 4)

    def test_junction_of_two_streets_gets_no_profile(self):
        choice = self.choose(41.3101, 69.3001, "Birinchi va Ikkinchi ko‘chalari kesishmasi")
        self.assertIsNone(choice.cand)
        self.assertEqual(choice.how, "junction")

    def test_unfound_highway_gets_no_profile(self):
        # Номер трассы назван, а рядом её нет: ближайшая улица — не довод.
        choice = self.choose(41.3050, 69.3001, "D999 avtomobil yo‘lining 3 km")
        self.assertIsNone(choice.cand)
        self.assertEqual(choice.how, "ref_not_found")

    def test_unnamed_junction_is_ambiguous(self):
        choice = self.choose(41.3101, 69.3001, "Maktab oldi")
        self.assertIsNone(choice.cand)
        self.assertEqual(choice.how, "ambiguous")

    def test_street_name_prefers_the_main_road(self):
        choice = self.choose(41.31, 69.3201, "Katta ko‘chasi, 5-maktab oldi")
        self.assertEqual(choice.how, "name")
        self.assertEqual(self.index.attrs[choice.cand.way].cls, "primary")

    def test_footway_is_not_a_road(self):
        choice = self.choose(41.31, 69.4000, "Piyoda ko‘chasi")
        self.assertIsNone(choice.cand)

    def test_unproven_record_carries_registry_point_and_no_profile(self):
        r = row(41.3101, 69.3001, "Birinchi va Ikkinchi ko‘chalari kesishmasi")
        rec = ar.new_record(3540, r, self.index, ar.choose_profile(r, self.index))
        self.assertEqual((rec["lat"], rec["lon"]), (r["lat"], r["lon"]))
        self.assertTrue(rec["needsReview"])
        self.assertFalse(set(rec) & set(ar.rp.PROFILE_KEYS))


class BuildTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.path = roads_file()
        cls.index = ar.load_index(cls.path)

    @classmethod
    def tearDownClass(cls):
        os.unlink(cls.path)

    def base(self):
        return [
            # Северная проезжая часть D105, пары пока нет.
            cam(10, 41.3050, 69.5000, "D105 110 km", axis=0, dir=0, split=True, cls="trunk",
                road=[0, 0, 900, 0]),
            # Старая пара без признака twin (так лежит в базе) — её не трогаем:
            # пару образовала не новая камера.
            cam(20, 41.3150, 69.5000, "D105 120 km", axis=0, dir=0, split=True, cls="trunk"),
            cam(21, 41.3152, 69.50025, "D105 120 km", axis=0, dir=180, split=True, cls="trunk"),
            cam(30, 41.3100, 69.3203, "Katta ko‘chasi", axis=0, cls="primary"),
        ]

    def test_new_pair_marks_old_partner_only(self):
        base = self.base()
        before = json.dumps(base, ensure_ascii=False)
        fresh = [row(41.3056, 69.50025 + 3 * LON_M, "D105 avtomobil yo‘lining 111 km")]
        result, rows, partners = ar.build(base, fresh, self.index, first_id=3540)
        self.assertEqual(json.dumps(base, ensure_ascii=False), before, "вход не меняется")
        self.assertEqual(partners, {10})
        self.assertTrue(result[0]["twin"])
        self.assertEqual(list(result[0])[-1], "twin", "twin дописан в конец записи")
        self.assertNotIn("twin", result[1])
        self.assertNotIn("twin", result[2])
        self.assertEqual(result[3], base[3])
        self.assertEqual(result[4]["id"], 3540)
        self.assertEqual(result[4]["dir"], 180)
        self.assertTrue(result[4]["twin"])
        ok, why = ar.verify(base, result, 3540, partners)
        self.assertTrue(ok, why)

    def test_ids_continue_and_skip_dropped_duplicates(self):
        base = self.base()
        fresh = [row(41.3100 + 10 * LAT_M, 69.3203, "Katta ko‘chasi 2-UY"),   # дубль 30
                 row(41.3180, 69.3203, "Katta ko‘chasi 40-UY"),
                 row(41.3101, 69.3001, "Birinchi va Ikkinchi ko‘chalari kesishmasi")]
        result, rows, _ = ar.build(base, fresh, self.index, first_id=3540)
        self.assertEqual([c["id"] for c in result[len(base):]], [3540, 3541])
        self.assertEqual([r["status"] for r in rows],
                         ["дубль после снапа", "профиль", "needsReview"])
        ok, why = ar.verify(base, result, 3540, set())
        self.assertTrue(ok, why)


class VerifyTest(unittest.TestCase):
    def setUp(self):
        self.base = [cam(1, 41.30, 69.28, axis=10, cls="primary"), cam(2, 41.31, 69.28)]
        self.good = self.base + [cam(3, 41.35, 69.30), cam(4, 41.36, 69.30, needsReview=True)]

    def test_good(self):
        self.assertTrue(ar.verify(self.base, self.good, 3, set())[0])

    def test_old_record_changed(self):
        bad = [dict(self.base[0], axis=100)] + self.good[1:]
        self.assertFalse(ar.verify(self.base, bad, 3, set())[0])

    def test_twin_only_for_listed_partners(self):
        bad = [dict(self.base[0], twin=True)] + self.good[1:]
        self.assertFalse(ar.verify(self.base, bad, 3, set())[0])
        self.assertTrue(ar.verify(self.base, bad, 3, {1})[0])

    def test_twin_partner_may_not_change_anything_else(self):
        bad = [dict(self.base[0], axis=100, twin=True)] + self.good[1:]
        self.assertFalse(ar.verify(self.base, bad, 3, {1})[0])

    def test_id_gap(self):
        bad = self.base + [cam(4, 41.35, 69.30)]
        self.assertFalse(ar.verify(self.base, bad, 3, set())[0])

    def test_duplicate_within_30_m(self):
        bad = self.base + [cam(3, 41.30 + 10 * LAT_M, 69.28)]
        self.assertFalse(ar.verify(self.base, bad, 3, set())[0])

    def test_unproven_camera_without_profile(self):
        bad = self.base + [cam(3, 41.35, 69.30, needsReview=True, axis=5)]
        self.assertFalse(ar.verify(self.base, bad, 3, set())[0])

    def test_outside_the_country(self):
        bad = self.base + [cam(3, 55.75, 37.62)]
        self.assertFalse(ar.verify(self.base, bad, 3, set())[0])


if __name__ == "__main__":
    unittest.main()
