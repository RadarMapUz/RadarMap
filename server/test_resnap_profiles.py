#!/usr/bin/env python3
"""Тесты resnap_profiles (11.3): точка камеры неприкосновенна, тротуар в индекс
не попадает, профиль пишется только по доказательству — на перекрёстке без
имени и у кармана рядом с магистралью профиль остаётся прежним, потому что
доверенный неверный профиль глушит камеру, а недоверенный только шумит.

14.11 (--mode links): снап на проезд/жилую/съезд при трассе в адресе — решает
адрес: названная трасса бьёт ближнюю безымянную дорогу и улицу-ориентир,
перекрёсток двух трасс или улиц без номера и ненайденная трасса — без
изменений, точка не двигается, нетронутые записи совпадают байт в байт.
Без данных и сети — дороги синтетические, во временном файле."""
import copy
import json
import math
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import snap_cameras as snap
import resnap_profiles as rp


def line(highway, coords, **props):
    props = dict(props, highway=highway)
    return {"type": "Feature", "properties": props,
            "geometry": {"type": "LineString", "coordinates": coords}}


def north(lon, lat0=41.300, lat1=41.320):
    return [[lon, lat0 + (lat1 - lat0) * k / 10] for k in range(11)]


def roads_file():
    features = [
        # A: односторонняя улица на север и тротуар вдоль неё (~12 м восточнее).
        line("secondary", north(69.2800), name="Test ko'chasi", oneway="yes", lanes="3"),
        line("footway", north(69.28015)),
        # B: перекрёсток двух безымянных для адреса улиц.
        line("secondary", north(69.3000), name="Birinchi"),
        line("secondary", [[69.290, 41.3100], [69.310, 41.3100]], name="Ikkinchi"),
        # C: боковой проезд и магистраль в ~25 м от него.
        line("service", north(69.3200)),
        line("primary", north(69.3203), name="Katta"),
        # D: трасса с ref и ближе к камере — жилая улица.
        line("trunk", north(69.3403), ref="M39"),
        line("residential", north(69.3400), name="Boshqa"),
        # Грунтовка: камера рядом с ней — всё равно «нет проезжей части».
        line("track", north(69.4000)),
    ]
    f = tempfile.NamedTemporaryFile("w", suffix=".geojson", delete=False,
                                    encoding="utf-8")
    json.dump({"type": "FeatureCollection", "features": features}, f)
    f.close()
    return f.name


def cam(cid, lat, lon, location="Тест", **extra):
    out = {"id": cid, "region": "R", "city": "C", "location": location,
           "lat": lat, "lon": lon, "type": "Стационар радар"}
    out.update(extra)
    return out


FOOTWAY = dict(axis=0, cls="footway", road=[0, 0, 100, 0])


class ResnapProfilesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.path = roads_file()
        cls.index, _, _ = snap.load_roads(cls.path, keep_highway=rp.is_carriageway)

    @classmethod
    def tearDownClass(cls):
        os.unlink(cls.path)

    def run_one(self, camera, others=()):
        cameras = [camera, *others]
        result, rows = rp.resnap_profiles(cameras, self.index)
        return result, rows

    # --- отбор -----------------------------------------------------------

    def test_needs_resnap_classes(self):
        self.assertEqual(rp.needs_resnap({"cls": "footway", "axis": 5}), "pedestrian")
        self.assertEqual(rp.needs_resnap({"cls": "platform"}), "pedestrian")
        self.assertEqual(rp.needs_resnap({"cls": "bus_stop", "axis": 1}), "pedestrian")
        self.assertEqual(rp.needs_resnap({"needsReview": True}), "no-profile")
        self.assertIsNone(rp.needs_resnap({"cls": "primary", "axis": 10, "road": [1, 2]}))
        self.assertIsNone(rp.needs_resnap({"cls": "service", "axis": 10}))

    def test_pedestrian_set_matches_app_rule(self):
        # RoadShape.swift: RoadClass.init(raw:) → .pedestrian ровно для этих.
        self.assertEqual(rp.PEDESTRIAN_CLASSES, {
            "footway", "path", "cycleway", "steps", "pedestrian", "platform", "bus_stop"})
        self.assertFalse(rp.PEDESTRIAN_CLASSES & rp.CARRIAGEWAY_CLASSES)

    def test_index_holds_no_footways_or_tracks(self):
        classes = {a.cls for a in self.index.attrs}
        self.assertNotIn("footway", classes)
        self.assertNotIn("track", classes)
        self.assertIn("secondary", classes)

    # --- выбор дороги ----------------------------------------------------

    def test_footway_camera_gets_carriageway_at_same_point(self):
        c = cam(1, 41.3100, 69.28013, location="Test ko'chasi", needsReview=True,
                **FOOTWAY)
        result, rows = self.run_one(c)
        out = result[0]
        self.assertEqual((out["lat"], out["lon"]), (41.3100, 69.28013),
                         "координата не двигается")
        self.assertEqual(out["cls"], "secondary")
        self.assertEqual(out["dir"], 0, "односторонняя на север")
        self.assertEqual(out["lanes"], 3)
        self.assertLess(min(out["axis"], 180 - out["axis"]), 3)
        self.assertNotEqual(out["road"], FOOTWAY["road"])
        self.assertTrue(out["needsReview"], "точку человек не проверял — флаг остаётся")
        self.assertEqual(rows[0]["status"], "fixed")
        self.assertIn("name", rows[0]["note"])
        # Исходный список не изменён.
        self.assertEqual(c["cls"], "footway")

    def test_road_stub_is_relative_to_unmoved_camera(self):
        c = cam(1, 41.3100, 69.28013, location="Test ko'chasi", **FOOTWAY)
        out = self.run_one(c)[0][0]
        # Кусок — дельты 1e-6° от камеры: ось дороги в ~11 м западнее.
        dlons = out["road"][1::2]
        self.assertTrue(all(-140 <= d <= -120 for d in dlons), dlons)

    def test_no_carriageway_keeps_profile(self):
        c = cam(2, 41.3100, 69.4001, **FOOTWAY)   # рядом только грунтовка
        result, rows = self.run_one(c)
        self.assertEqual(result[0], c)
        self.assertEqual(rows[0]["status"], "no_carriageway")

    def test_no_profile_camera_far_from_roads_stays_empty(self):
        c = cam(3, 41.3100, 69.5000, needsReview=True)
        result, rows = self.run_one(c)
        self.assertEqual(result[0], c)
        self.assertEqual(rows[0]["reason"], "no-profile")
        self.assertIn("300 м", rows[0]["note"])

    def test_no_profile_camera_on_road_gets_profile(self):
        c = cam(4, 41.3100, 69.28005, location="Test ko'chasi", needsReview=True)
        out = self.run_one(c)[0][0]
        self.assertEqual(out["cls"], "secondary")
        self.assertIn("road", out)

    def test_unnamed_intersection_is_ambiguous(self):
        c = cam(5, 41.3101, 69.3001, location="Noma'lum joy", **FOOTWAY)
        result, rows = self.run_one(c)
        self.assertEqual(result[0], c, "на перекрёстке без имени не угадываем")
        self.assertEqual(rows[0]["status"], "ambiguous")

    def test_named_intersection_takes_the_named_street(self):
        c = cam(6, 41.3101, 69.3001, location="Ikkinchi ko'chasi", **FOOTWAY)
        out = self.run_one(c)[0][0]
        self.assertEqual(out["axis"], 90, "ось улицы из адреса, а не ближайшей")

    def test_minor_road_next_to_major_is_ambiguous(self):
        # Карман в 4 м, магистраль в ~29 м: дальше запаса, но в радиусе.
        c = cam(7, 41.3100, 69.31995, **FOOTWAY)
        result, rows = self.run_one(c)
        self.assertEqual(result[0], c)
        self.assertEqual(rows[0]["status"], "ambiguous")

    def test_major_beats_closer_service_within_margin(self):
        c = cam(8, 41.3100, 69.3201, **FOOTWAY)   # проезд ~8 м, магистраль ~17 м
        out = self.run_one(c)[0][0]
        self.assertEqual(out["cls"], "primary")

    def test_ref_beats_closer_road(self):
        c = cam(9, 41.3100, 69.34005, location="M-39 avtomobil yo'li 12 km", **FOOTWAY)
        out = self.run_one(c)[0][0]
        self.assertEqual(out["cls"], "trunk")

    def test_trusted_cameras_are_untouched(self):
        other = cam(10, 41.3100, 69.3001, axis=0, cls="secondary", road=[0, 0, 1, 1],
                    dir=0, split=True)
        result, rows = rp.resnap_profiles([other], self.index)
        self.assertEqual(result[0], other)
        self.assertEqual(rows, [])

    # --- пары и проверка различий -----------------------------------------

    def test_twins_are_remarked_across_the_base(self):
        fixed = cam(11, 41.3100, 69.28013, location="Test ko'chasi", **FOOTWAY)
        partner = cam(12, 41.3104, 69.2800, axis=0, cls="secondary", dir=180,
                      split=True, road=[0, 0, 1, 1])
        stale = cam(13, 41.5000, 69.9000, axis=0, cls="primary", dir=0, split=True,
                    road=[0, 0, 1, 1], twin=True)
        result, _ = rp.resnap_profiles([fixed, partner, stale], self.index)
        by_id = {c["id"]: c for c in result}
        self.assertTrue(by_id[11].get("twin"))
        self.assertTrue(by_id[12].get("twin"))
        self.assertNotIn("twin", by_id[13], "пары нет — признак не переживает")
        stats = rp.verify_diff([fixed, partner, stale], result, {11})
        self.assertEqual(stats["profile_changed"], [11])
        self.assertEqual(stats["twin_added"], [11, 12])
        self.assertEqual(stats["twin_removed"], [13])

    def test_verify_diff_refuses_moves_and_foreign_changes(self):
        base = [cam(1, 41.31, 69.28, **FOOTWAY), cam(2, 41.32, 69.28, axis=5, cls="primary")]
        moved = copy.deepcopy(base)
        moved[0]["lat"] = 41.3101
        with self.assertRaises(ValueError):
            rp.verify_diff(base, moved, {1})
        foreign = copy.deepcopy(base)
        foreign[1]["axis"] = 6
        with self.assertRaises(ValueError):
            rp.verify_diff(base, foreign, {1})
        flag = copy.deepcopy(base)
        flag[0]["needsReview"] = True
        with self.assertRaises(ValueError):
            rp.verify_diff(base, flag, {1})
        reordered = list(reversed(base))
        with self.assertRaises(ValueError):
            rp.verify_diff(base, reordered, {1, 2})

    def test_verify_diff_accepts_real_run(self):
        cameras = [cam(1, 41.3100, 69.28013, location="Test ko'chasi", **FOOTWAY),
                   cam(2, 41.3101, 69.3001, **FOOTWAY),
                   cam(3, 41.3300, 69.2800, axis=0, cls="secondary", road=[0, 0, 1, 1])]
        result, _ = rp.resnap_profiles(cameras, self.index)
        stats = rp.verify_diff(cameras, result,
                               {c["id"] for c in cameras if rp.needs_resnap(c)})
        self.assertEqual(stats["profile_changed"], [1])



# --- 14.11 ------------------------------------------------------------------

class HighwayRefsTests(unittest.TestCase):
    """Номера дорог нового реестра: снап знал только М/А/4Р."""

    def refs(self, text):
        return [m.ref for m in snap.highway_refs_in_text(text)]

    def test_new_numbering_in_addresses(self):
        self.assertEqual(self.refs("D006 “Toshkent Sh. — Chirchiq”"), ["d6"])
        self.assertEqual(self.refs("D 087 Marg‘ilon"), ["d87"])
        self.assertEqual(self.refs("D-109 avtomobil Yo`lining 85KM"), ["d109"])
        self.assertEqual(self.refs("bilan 10V006 A/y Kesishgan"), ["10v6"])
        self.assertEqual(self.refs('40 V 088 "Qo‘qon Shahriga"'), ["40v88"])
        self.assertEqual(self.refs("10B09- Toshkent"), ["10v9"])
        self.assertEqual(self.refs("10В015-yo‘l"), ["10v15"])

    def test_old_numbering_and_lookalikes(self):
        self.assertEqual(self.refs("4P85 “Qamashi”"), ["4r85"], "латинская P = кириллическая Р")
        self.assertEqual(self.refs("4Р-116-YO'L"), ["4r116"])
        self.assertEqual(self.refs("4K-103"), ["4k103"])
        self.assertEqual(self.refs("4H-901 Islom"), ["4n901"])
        self.assertEqual(self.refs("М-39 трасса"), ["m39"])

    def test_branch_letter(self):
        self.assertEqual(self.refs("A373A-avtomobil"), ["a373a"])
        self.assertEqual(self.refs("A373 A avtomobil"), ["a373a"])
        self.assertEqual(self.refs('A373 "A" Avtoyo‘li'), ["a373a"])
        self.assertEqual(self.refs("D076H va D076HI"), ["d76h", "d76hi"])
        self.assertEqual(self.refs("A373 A/y 45 km"), ["a373"], "«A/y» — не буква ответвления")
        self.assertEqual(self.refs("M-37 A.y 330 km"), ["m37"])
        self.assertEqual(self.refs("A373km"), ["a373"])

    def test_not_a_road_number(self):
        for text in ("dom 39", "д 39", "va 125", "uy 5d", "17,7 Kilometri", "D006ga keyin",
                     "M 4 uy"):
            self.assertEqual(self.refs(text), [], text)

    def test_tag_values(self):
        self.assertEqual(snap.highway_refs_from_tag("D006"), {"d6"})
        self.assertEqual(snap.highway_refs_from_tag("M39;M34"), {"m39", "m34"})
        self.assertEqual(snap.highway_refs_from_tag("4К - 835"), {"4k835"})
        self.assertEqual(snap.highway_refs_from_tag("ref=4Р10"), {"4r10"})
        self.assertEqual(snap.highway_refs_from_tag("A373a"), {"a373a"})
        self.assertEqual(snap.highway_refs_from_tag("10V111o"), {"10v111o"})
        self.assertEqual(snap.highway_refs_from_tag("E 40;AH5;КХ-50"), set())
        self.assertEqual(snap.highway_refs_from_props(
            {"ref": "D006", "old_ref": "4Р6", "name": "D009"}), {"d6", "4r6"})

    def test_narrow_parser_is_unchanged(self):
        # Полный снап и 11.3 стоят на узком разборе: D-номера им не видны,
        # иначе пересъёмка 11.3 перестала бы воспроизводиться.
        self.assertEqual(snap.ref_tokens_from_text("D006 avtomobil yo'li"), set())
        self.assertEqual(snap.ref_tokens_from_tag("D006"), set())


_LAT0, _LON0 = 41.40, 69.50
_KX = 111320.0 * math.cos(math.radians(_LAT0))


def at(x, y):
    """Метры к востоку/северу от точки участка → [lon, lat]."""
    return [_LON0 + x / _KX, _LAT0 + y / 110540.0]


def site(n, x, y):
    """Участки разнесены на 5 км по долготе, чтобы не видеть друг друга."""
    return at(x + 5000 * n, y)


def cam_at(cid, n, x, y, location, **extra):
    lon, lat = site(n, x, y)
    return cam(cid, round(lat, 6), round(lon, 6), location=location, **extra)


D006 = "D006 “Toshkent Sh. — Chirchiq Sh. — Chimyon Q.” avtomobil Yo‘lining " \
       "23 Kilometri bilan Furqat ko‘chasi Tutashgan chorraha"
#: Старый профиль проезда (как у 2977): поперёк трассы, доверенный.
CROSS = dict(axis=90, cls="unclassified", road=[0, -1200, 0, 1200])


def links_roads_file():
    ns = lambda n, x: [site(n, x, -300), site(n, x, 300)]          # noqa: E731
    sn = lambda n, x: [site(n, x, 300), site(n, x, -300)]          # noqa: E731
    we = lambda n, y: [site(n, -300, y), site(n, 300, y)]          # noqa: E731
    ew = lambda n, y: [site(n, 300, y), site(n, -300, y)]          # noqa: E731
    features = [
        # 0: трасса D006 — две проезжие части (в 11 и 31 м), улица Furqat
        #    поперёк через точку камеры и безымянная жилая в 4 м.
        line("primary", ns(0, 11), ref="D006", oneway="yes", lanes="3"),
        line("primary", sn(0, 31), ref="D006", oneway="yes", lanes="3"),
        line("unclassified", we(0, 0), name="Furqat ko‘chasi"),
        line("residential", ns(0, 4)),
        # 1: перекрёсток D006 × 10V006 — оси расходятся.
        line("primary", ns(1, 6), ref="D006"),
        line("tertiary", we(1, 6), ref="10V006"),
        # 2: только D006 (10V006 в OSM нет).
        line("primary", ns(2, 6), ref="D006"),
        # 3: рядом трасса с ДРУГИМ номером.
        line("trunk", we(3, 5), ref="D099", oneway="yes"),
        # 4: названная трасса дальше радиуса (53 м).
        line("primary", ns(4, 53), ref="D089"),
        line("residential", we(4, 0)),
        # 5: номер только у съезда, на котором стоит камера.
        line("trunk_link", ns(5, 0), ref="M39", oneway="yes"),
        # 6: съезд на запад вдоль трассы, ближайшая её сторона — на восток.
        line("trunk_link", ew(6, 0), oneway="yes"),
        line("trunk", we(6, 8), ref="D001", oneway="yes"),
        line("trunk", ew(6, 28), ref="D001", oneway="yes"),
        # 7: трасса сама размечена жилой улицей — камера уже на ней.
        line("residential", ns(7, 0), ref="D036"),
        # 8: Kxay — малое кольцо без номера, по имени.
        line("trunk", we(8, 6), name="Kichik Halqa yo'li", oneway="yes"),
        line("trunk_link", ns(8, 0), oneway="yes"),
        # 9: проспект по имени: тупик с тем же словом ближе, проспект — магистраль.
        line("residential", we(9, 0), name="Farg‘ona berk ko‘chasi"),
        line("primary", ns(9, 5), name="Farg‘ona yo‘li"),
        # 10: описание маршрута в кавычках: A373 ближе, но адрес о D002.
        line("trunk", we(10, 5), ref="A373"),
        line("primary", ns(10, 20), ref="D002"),
        # 11: Txay = D001.
        line("trunk", ns(11, 6), ref="D001", oneway="yes"),
        line("trunk_link", we(11, 0), oneway="yes"),
        # 12: одна трасса рядом под двумя осями (петля развязки).
        line("primary", ns(12, 5), ref="D020"),
        line("primary", we(12, 9), ref="D020"),
    ]
    f = tempfile.NamedTemporaryFile("w", suffix=".geojson", delete=False,
                                    encoding="utf-8")
    json.dump({"type": "FeatureCollection", "features": features}, f)
    f.close()
    return f.name


def dumps(record):
    return json.dumps(record, ensure_ascii=False, separators=(",", ":"))


class ResnapLinksTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.path = links_roads_file()
        cls.index, _, _ = snap.load_roads(cls.path, keep_highway=rp.is_carriageway,
                                          refs_of=snap.highway_refs_from_props)

    @classmethod
    def tearDownClass(cls):
        os.unlink(cls.path)

    def run_links(self, *cameras):
        result, rows = rp.resnap_links(list(cameras), self.index)
        return result, {row["id"]: row for row in rows}

    # --- разбор адреса ---------------------------------------------------

    def test_address_roads(self):
        roads = rp.address_roads(D006)
        self.assertEqual([h.key for h in roads.highways], ["d6"])
        self.assertTrue(roads.junction)
        two = rp.address_roads('D006 "Toshkent Sh.-chirchiq Sh." A/y bilan 10V006 A/y '
                               'Kеsishgan Chorraxa (Qipchoq).')
        self.assertEqual([h.key for h in two.highways], ["d6", "10v6"])
        self.assertTrue(two.junction)
        quoted = rp.address_roads("D002 – “Toshkent Sh. — A373 avtomobil Yoʻli (44 Km.ga)” "
                                  "avtomobil Yo‘lining 30 km")
        self.assertEqual([h.key for h in quoted.highways], ["d2"],
                         "номер в кавычках — описание маршрута, не дорога камеры")
        self.assertEqual([h.key for h in rp.address_roads('"D025G" Samarqand').highways],
                         ["d25g"], "номер, с которого начинается кавычка, — дорога камеры")
        self.assertEqual([h.key for h in rp.address_roads("D001 Txay, avtosalon").highways],
                         ["d1"], "D001 и Txay — одна дорога")
        kxay = rp.address_roads("Kxay - 4/5- Uy qarshisida").highways
        self.assertEqual([(h.kind, h.key) for h in kxay], [("name", {"kichik", "halqa"})])
        self.assertTrue(rp.address_roads("Amir Temur shoh ko‘chasi, 5").avenue)
        self.assertTrue(rp.address_roads("Farg‘ona yo‘li ko‘chasi, 21-UY").avenue)
        plain = rp.address_roads("Mangulik ko‘chasi (bozor oldi)")
        self.assertEqual((plain.highways, plain.avenue), ([], False))
        self.assertTrue(rp.address_roads("4D072 avtomobil Yo‘lining 24 km").highway_word)

    # --- выбор дороги ----------------------------------------------------

    def test_named_highway_beats_nearer_roads(self):
        # 2977: точка на Furqat (0 м), безымянная жилая в 4 м, D006 в 11 м.
        c = cam_at(2977, 0, 0, 0, D006, needsReview=True, **CROSS)
        result, rows = self.run_links(c)
        out = result[0]
        self.assertEqual((out["lat"], out["lon"]), (c["lat"], c["lon"]),
                         "координата не двигается")
        self.assertEqual(out["cls"], "primary")
        self.assertEqual(out["axis"], 0, "ось трассы, а не улицы-ориентира")
        self.assertEqual(out["dir"], 0, "ближайшая проезжая часть — на север")
        self.assertIs(out["split"], True, "встречная в 20 м — разделённая")
        self.assertEqual(out["lanes"], 3)
        self.assertTrue(out["needsReview"], "флаг не трогается")
        self.assertNotEqual(out["road"], CROSS["road"])
        self.assertEqual(rows[2977]["status"], "fixed")
        self.assertEqual(rows[2977]["dist_m"], "11")
        self.assertEqual(c["cls"], "unclassified", "исходный список не изменён")

    def test_two_highway_junction_is_ambiguous(self):
        addr = 'D006 "Toshkent Sh.-chirchiq Sh." A/y bilan 10V006 A/y Kesishgan Chorraxa'
        crossing = cam_at(3138, 1, 0, 0, addr, axis=45, cls="primary_link", road=[0, 0, 9, 9])
        missing = cam_at(3139, 2, 0, 0, addr, axis=90, cls="primary_link", road=[0, 0, 9, 9])
        result, rows = self.run_links(crossing, missing)
        self.assertEqual(result, [crossing, missing], "какую снимает — адрес не говорит")
        self.assertEqual(rows[3138]["status"], "ambiguous")
        self.assertIn("10V006", rows[3138]["note"])
        self.assertEqual(rows[3139]["status"], "ambiguous")
        self.assertIn("не найдена", rows[3139]["note"])

    def test_other_highway_nearby_is_not_found(self):
        c = cam_at(662, 3, 0, 0, "D105 avtomobil yo'lining 301 km kesishgan chorraha",
                   axis=3, cls="secondary_link", dir=3, road=[0, 0, 9, 0])
        result, rows = self.run_links(c)
        self.assertEqual(result[0], c, "трасса с другим номером — не та, что в адресе")
        self.assertEqual(rows[662]["status"], "not_found")
        self.assertIn("рядом trunk", rows[662]["note"])
        self.assertIn("D99", rows[662]["note"])

    def test_named_highway_beyond_radius_is_listed_with_distance(self):
        c = cam_at(484, 4, 0, 0, "D089 avtomobil yo'lining 1,6 km", axis=90,
                   cls="residential", road=[0, 0, 9, 9])
        result, rows = self.run_links(c)
        self.assertEqual(result[0], c)
        self.assertEqual(rows[484]["status"], "not_found")
        self.assertEqual(rows[484]["dist_m"], "53")

    def test_ref_only_on_own_link_keeps_link(self):
        c = cam_at(5, 5, 1, 0, "M-39 avtomobil yo'li 12 km", axis=0, cls="trunk_link",
                   dir=0, road=[0, 0, 9, 0])
        result, rows = self.run_links(c)
        self.assertEqual(result[0], c)
        self.assertEqual(rows[5]["status"], "on_link")

    def test_opposite_carriageway_next_to_parallel_link_is_ambiguous(self):
        c = cam_at(6, 6, 0, 0, "D001 Txay, avtosalon qarshisida", axis=90,
                   cls="trunk_link", dir=270, road=[0, 0, 0, 9])
        result, rows = self.run_links(c)
        self.assertEqual(result[0], c, "на чьей стороне съезд — не сказать")
        self.assertEqual(rows[6]["status"], "ambiguous")
        self.assertIn("встречная", rows[6]["note"])

    def test_same_highway_under_two_axes_is_ambiguous(self):
        c = cam_at(2880, 12, 0, 0, "D020 avtomobil Yo‘lining 94-95 Km.lari", axis=45,
                   cls="residential", road=[0, 0, 9, 9])
        result, rows = self.run_links(c)
        self.assertEqual(result[0], c)
        self.assertEqual(rows[2880]["status"], "ambiguous")
        self.assertIn("двумя осями", rows[2880]["note"])

    def test_camera_already_on_named_road_is_byte_identical(self):
        c = cam_at(7, 7, 0, 0, "Uyas mfy, D 036 avtomobil yo‘li", axis=0,
                   cls="residential", road=[1, 2, 3, 4])
        result, rows = self.run_links(c)
        self.assertEqual(dumps(result[0]), dumps(c))
        self.assertEqual(rows[7]["status"], "unchanged")

    def test_small_ring_by_name(self):
        c = cam_at(2652, 8, 0, 0, "Kxay - 4/5- Uy qarshisida", axis=0, cls="trunk_link",
                   road=[0, 0, 9, 0])
        out = self.run_links(c)[0][0]
        self.assertEqual((out["cls"], out["axis"]), ("trunk", 90))

    def test_txay_is_d001(self):
        c = cam_at(3444, 11, 0, 0, "Txay - Dehqonobod ko'chalari kesishgan chorraha",
                   axis=90, cls="trunk_link", road=[0, 0, 0, 9])
        out = self.run_links(c)[0][0]
        self.assertEqual((out["cls"], out["axis"]), ("trunk", 0))

    def test_avenue_by_name_prefers_major_road(self):
        c = cam_at(2211, 9, 0, 0, "Farg‘ona yo‘li ko‘chasi, 21-UY qarshisida", axis=90,
                   cls="residential", road=[0, 0, 0, 9])
        out = self.run_links(c)[0][0]
        self.assertEqual((out["cls"], out["axis"]), ("primary", 0),
                         "тупик «Farg‘ona berk» ближе, но адрес о проспекте")

    def test_avenue_junction_is_ambiguous(self):
        c = cam_at(2244, 9, 0, 0, "Turkiston va Farg‘ona yo‘li ko‘chasi chorrahasi",
                   axis=90, cls="residential", road=[0, 0, 0, 9])
        result, rows = self.run_links(c)
        self.assertEqual(result[0], c)
        self.assertEqual(rows[2244]["status"], "ambiguous")

    def test_route_description_in_quotes_is_not_the_road(self):
        # Вне кавычек — перекрёсток с улицами: прочти разбор A373 как вторую
        # трассу, это был бы «перекрёсток трасс» и никакого решения.
        c = cam_at(3077, 10, 0, 0, "D002 – “Toshkent Sh. — A373 avtomobil Yoʻli (44 Km.ga)” "
                   "avtomobil Yo‘lining 30-31 Kilometr, Navro‘z va Bog‘ ko‘chalari "
                   "kesishgan chorraha", axis=45, cls="residential", road=[0, 0, 9, 9])
        out = self.run_links(c)[0][0]
        self.assertEqual((out["cls"], out["axis"]), ("primary", 0), "D002 в 20 м, не A373 в 5 м")

    def test_no_highway_in_address_is_skipped(self):
        c = cam_at(63, 0, 0, 0, "Mangulik ko‘chasi (bozor oldi)", **CROSS)
        result, rows = self.run_links(c)
        self.assertEqual(result[0], c)
        self.assertEqual(rows[63]["status"], "skip")

    def test_unrecognised_number_is_listed(self):
        c = cam_at(1575, 0, 0, 0, "Nurbuloq mahallasi 4D072 avtomobil Yo‘lining 24 km", **CROSS)
        result, rows = self.run_links(c)
        self.assertEqual(result[0], c)
        self.assertEqual(rows[1575]["status"], "not_found")

    def test_other_classes_are_not_touched(self):
        primary = cam_at(1, 0, 0, 0, D006, axis=90, cls="primary", road=[0, 0, 9, 9])
        footway = cam_at(2, 0, 0, 0, D006, axis=90, cls="footway", road=[0, 0, 9, 9])
        result, rows = self.run_links(primary, footway)
        self.assertEqual(result, [primary, footway])
        self.assertEqual(rows, {})

    # --- база целиком ----------------------------------------------------

    def test_untouched_records_are_byte_identical_and_verified(self):
        cameras = [
            cam_at(2977, 0, 0, 0, D006, **CROSS),
            cam_at(63, 0, 0, 0, "Mangulik ko‘chasi", **CROSS),
            cam_at(662, 3, 0, 0, "D105 avtomobil yo'lining 301 km", axis=3,
                   cls="secondary_link", dir=3, road=[0, 0, 9, 0]),
            cam_at(30, 9, 200, 200, "Boshqa ko‘chasi", axis=10, cls="secondary",
                   dir=10, split=False, road=[0, 0, 9, 9]),
        ]
        before = [dumps(c) for c in cameras]
        result, rows = rp.resnap_links(cameras, self.index)
        self.assertEqual([dumps(c) for c in cameras], before, "вход не изменён")
        changed = {c["id"] for c, b in zip(result, before) if dumps(c) != b}
        self.assertEqual(changed, {2977})
        stats = rp.verify_diff(cameras, result,
                               {c["id"] for c in cameras if c["cls"] in rp.LINK_SNAP_CLASSES})
        self.assertEqual(stats["profile_changed"], [2977])
        # Профиль чужой камеры, тронутый «заодно», verify_diff не пропустит.
        tampered = copy.deepcopy(result)
        tampered[3]["axis"] = 11
        with self.assertRaises(ValueError):
            rp.verify_diff(cameras, tampered, {2977, 63, 662})

    def test_second_run_changes_nothing(self):
        cameras = [cam_at(2977, 0, 0, 0, D006, **CROSS),
                   cam_at(2652, 8, 0, 0, "Kxay - 4/5- Uy qarshisida", axis=0,
                          cls="trunk_link", road=[0, 0, 9, 0])]
        once, _ = rp.resnap_links(cameras, self.index)
        twice, rows = rp.resnap_links(once, self.index)
        self.assertEqual([dumps(c) for c in twice], [dumps(c) for c in once])
        self.assertEqual(rows, [], "исправленные ушли из классов 14.11")


if __name__ == "__main__":
    unittest.main(verbosity=2)
