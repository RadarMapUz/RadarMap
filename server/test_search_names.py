#!/usr/bin/env python3
"""Тесты имён для поиска (40G). Запуск: python3 server/test_search_names.py

Сторожится контракт с телефоном: новые поля клетки необязательны (старый
клиент читает `n/h/p` и `row[0:4]`), записи без новых имён байт в байт те же,
что были, а старое имя «Хамза» доезжает до станции «Новза».
"""
import json
import os
import shutil
import tempfile
import unittest

import build_roads
import search_names as N


def point(lon, lat, **properties):
    return {"type": "Feature", "geometry": {"type": "Point", "coordinates": [lon, lat]},
            "properties": properties}


def line(coords, **properties):
    return {"type": "Feature", "geometry": {"type": "LineString", "coordinates": coords},
            "properties": properties}


NOVZA = {"name": "Novza", "name:en": "Novza (Hamza)", "name:fa": "نوزا (حمزه)",
         "name:ru": "Новза (Хамза)", "name:uz": "Novza (Hamza)", "old_name": "Хамза;Новза",
         "old_name:en": "Khamza;Novza", "public_transport": "station", "railway": "station",
         "station": "subway", "subway": "yes"}


class Base(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.work)

    def write(self, name, features):
        path = os.path.join(self.work, name)
        with open(path, "w", encoding="utf-8") as handle:
            for feature in features:
                handle.write("\x1e" + json.dumps(feature, ensure_ascii=False) + "\n")
        return path


class FoldTests(unittest.TestCase):
    """Тот же fold, что SearchIndex.fold на телефоне: иначе сборка отсеет как
    «повтор» имя, которое телефон считает другим, или наоборот."""

    def test_three_scripts_are_equal(self):
        groups = [
            ["Ўзбекистон", "O'zbekiston", "Oʻzbekiston", "о'збекистон", "Узбекистон"],
            ["Ҳамза", "Hamza", "Xamza", "Хамза", "Khamza"],
            ["Қўйлиқ", "Qo'yliq", "Куйлик"],
            ["Алимджан", "Olimjon", "Alimdjan"],
            ["Навоий", "Navoiy", "Навои"],
            ["Новза", "Novza"],
        ]
        for group in groups:
            self.assertEqual(len({N.fold(text) for text in group}), 1, group)

    def test_core_key_ignores_street_type_and_order(self):
        self.assertEqual(N.core_key("проспект Амира Темура"), N.core_key("Амира Темура проспект"))
        self.assertEqual(N.core_key("Amir Temur shoh ko'chasi"), N.core_key("Amir Temur"))


class NamesTests(unittest.TestCase):
    def test_metro_station_keeps_old_name_and_drops_its_own(self):
        display = N.metro_display(NOVZA)
        self.assertEqual(display, "Новза")
        alts, olds = N.names_from(NOVZA, display, parenthetical=True)
        self.assertEqual(alts, [], "Novza — то же, что Новза; персидское имя не берём")
        self.assertEqual(olds, ["Хамза"], "«Новза» в old_name — ошибка разметки, а не история")

    def test_semicolon_lists_and_families(self):
        alts, olds = N.names_from({"name": "Amir Temur shoh ko'chasi", "name:ru": "Амира Темура проспект",
                                   "alt_name:ru": "Амира Тимура проспект",
                                   "old_name:ru": "Московская улица;Энгельса улица",
                                   "name:kk-Arab": "امىر تەمۋر"}, "Amir Temur shoh ko'chasi")
        self.assertEqual(alts, ["Амира Темура проспект", "Амира Тимура проспект"])
        self.assertEqual(olds, ["Московская улица", "Энгельса улица"])

    def test_caps_keep_records_small(self):
        tags = {f"old_name:{i}": f"Имя {chr(0x430 + i)}" for i in range(20)}
        _, olds = N.names_from(tags, "Ташкент")
        self.assertEqual(len(olds), N.MAX_OLD)

    def test_plain_script(self):
        self.assertTrue(N.plain_script("Oʻzbekiston"))
        self.assertTrue(N.plain_script("Ўзбекистон"))
        self.assertFalse(N.plain_script("نوزا"))
        self.assertFalse(N.plain_script("12"))


class VenueTests(Base):
    def test_metro_is_kind_14_with_names_and_entrances_are_not(self):
        path = self.write("v.geojsonl", [
            point(69.2236, 41.2918, **NOVZA),
            point(69.2240, 41.2920, railway="subway_entrance", name="Novza"),
            point(69.25, 41.30, amenity="fuel", name="Lukoil"),
        ])
        rows = build_roads.collect_venues(path)
        self.assertEqual(rows[0][:2], (N.VENUE_METRO, "Новза"))
        self.assertEqual(rows[0][4:], ([], ["Хамза"]))
        self.assertEqual(rows[1], (1, "Lukoil", 69.25, 41.30), "без новых имён — прежние четыре поля")
        self.assertEqual(len(rows), 2)

    def test_places_file_gives_kind_15_only_for_named_settlements(self):
        path = self.write("p.geojsonl", [
            point(69.2787, 41.3123, place="city", name="Toshkent", **{"name:ru": "Ташкент", "old_name": "Chach"}),
            point(69.20, 41.30, place="neighbourhood"),
            point(69.21, 41.30, place="state", name="Toshkent viloyati"),
        ])
        rows = build_roads.collect_venues(path, places=True)
        # «Toshkent» после приведения — то же «Ташкент»: телефону ничего не добавляет.
        self.assertEqual(rows, [(N.VENUE_PLACE, "Ташкент", 69.2787, 41.3123, [], ["Chach"])])
        self.assertEqual(build_roads.collect_venues(None, places=True), [])

    def test_city_keeps_its_node_not_the_outline_centre(self):
        # Ревью 03.11: середина рамки границы Ташкента — в 4,5 км от центра.
        area = {"type": "Feature", "geometry": {"type": "Polygon", "coordinates": [[
                    [69.12, 41.17], [69.53, 41.17], [69.53, 41.41], [69.12, 41.41], [69.12, 41.17]]]},
                "properties": {"place": "city", "name": "Toshkent", "name:ru": "Ташкент", "old_name": "Chach"}}
        path = self.write("p.geojsonl", [
            point(69.2787, 41.3123, place="city", name="Toshkent", **{"name:ru": "Ташкент"}), area])
        rows = build_roads.collect_venues(path, places=True)
        self.assertEqual(rows, [(N.VENUE_PLACE, "Ташкент", 69.2787, 41.3123, [], ["Chach"])],
                         "узел остаётся, имена контура — ему")
        kept = [r for c in build_roads.venues_by_cell(rows).values() for r in c["venues"]]
        self.assertEqual([(r[2], r[3]) for r in kept], [(4131230, 6927870)])

    def test_outline_without_its_node_stays(self):
        area = {"type": "Feature", "geometry": {"type": "Polygon", "coordinates": [[
                    [69.20, 41.20], [69.21, 41.20], [69.21, 41.21], [69.20, 41.21], [69.20, 41.20]]]},
                "properties": {"place": "neighbourhood", "name": "Ялангач"}}
        path = self.write("p.geojsonl", [point(69.30, 41.30, place="neighbourhood", name="Ялангач"), area])
        self.assertEqual(len(build_roads.collect_venues(path, places=True)), 2,
                         "узел не в рамке — это другое место")

    def test_namesakes_kilometres_apart_are_two_places(self):
        rows = [(N.VENUE_PLACE, "Дустлик", 69.20, 41.30), (N.VENUE_PLACE, "Дустлик", 69.2466, 41.30)]  # ~3,9 км
        cells = build_roads.venues_by_cell(rows)
        self.assertEqual(sum(len(c["venues"]) for c in cells.values()), 2)

    def test_payload_is_backward_compatible(self):
        cells = build_roads.venues_by_cell([
            (1, "A", 69.25, 41.30),
            (14, "Новза", 69.2236, 41.2918, [], ["Хамза"]),
            (15, "Ташкент", 69.27, 41.31, ["Toshkent"], []),
        ])
        rows = cells[build_roads.address_key(41.30, 69.25)]["venues"]
        self.assertIn([1, "A", 4130000, 6925000], rows)
        self.assertIn([14, "Новза", 4129180, 6922360, [], ["Хамза"]], rows)
        self.assertIn([15, "Ташкент", 4131000, 6927000, ["Toshkent"]], rows)
        for row in rows:
            code, name, lat, lon = row[:4]   # так читает старый клиент и telegram_bot.parse_cng
            self.assertIsInstance(name, str)

    def test_station_node_and_outline_are_one_record(self):
        rows = [(14, "Новза", 69.2236, 41.2918, [], ["Хамза"]),
                (14, "Новза", 69.2260, 41.2930)]   # ~240 м — контур той же станции
        cells = build_roads.venues_by_cell(rows)
        self.assertEqual(sum(len(c["venues"]) for c in cells.values()), 1)

    def test_merge_keeps_names_of_both_sources(self):
        osm = [(14, "Новза", 69.2236, 41.2918, [], ["Хамза"])]
        extra = [(9, "Bank", 69.30, 41.30)]
        self.assertEqual(build_roads.merge_venues(osm, extra), osm + extra)


class MetroCheckTests(unittest.TestCase):
    def test_stale_extract_without_metro_is_refused(self):
        tashkent = [(7, "Кафе", 69.28, 41.31)]
        with self.assertRaises(SystemExit):
            build_roads.check_metro(tashkent)
        self.assertEqual(build_roads.check_metro(tashkent, allow_missing=True), 0)
        self.assertEqual(build_roads.check_metro(tashkent + [(14, "Новза", 69.22, 41.29)]), 1)
        self.assertEqual(build_roads.check_metro([(7, "Кафе", 65.0, 39.0)]), 0, "без Ташкента — не ошибка")


class StreetNamesTests(Base):
    def roads(self):
        return self.write("roads.geojsonl", [
            line([[69.28, 41.31], [69.281, 41.311]], highway="primary", name="Amir Temur shoh ko'chasi",
                 **{"name:ru": "Амира Темура проспект", "old_name:ru": "Московская улица;Энгельса улица"}),
            line([[69.29, 41.31], [69.291, 41.311]], highway="primary", name="Amir Temur shoh ko'chasi",
                 **{"old_name": "Энгельса улица"}),
            line([[69.30, 41.31], [69.301, 41.311]], highway="residential", name="Lone ko'chasi"),
            line([[69.31, 41.31], [69.311, 41.311]], name="Не дорога", **{"name:ru": "Канал", "waterway": "canal"}),
        ])

    def addresses(self):
        return build_roads.addresses_by_cell([
            ("Amir Temur shoh ko'chasi", "5", 69.2801, 41.3101),
            ("Амира Темура проспект", "7", 69.2802, 41.3102),
            ("Lone ko'chasi", "1", 69.3001, 41.3101),
        ])

    def test_street_gets_all_names_of_its_roads(self):
        cells = self.addresses()
        before = json.loads(json.dumps(cells))
        touched = N.attach_street_names(cells, N.street_names(self.roads()))
        self.assertEqual(touched, 2)
        streets = {s["n"]: s for s in cells[build_roads.address_key(41.31, 69.28)]["streets"]}
        amir = streets["Amir Temur shoh ko'chasi"]
        self.assertEqual(amir["a"], ["Амира Темура проспект"])
        self.assertEqual(amir["o"], ["Энгельса улица", "Московская улица"], "чаще встречающееся — первым")
        self.assertEqual(streets["Амира Темура проспект"]["a"], ["Amir Temur shoh ko'chasi"])
        self.assertNotIn("a", streets["Lone ko'chasi"])
        # Старые поля не тронуты: старый клиент читает ровно их.
        old = {s["n"]: s for s in before[build_roads.address_key(41.31, 69.28)]["streets"]}
        for name, street in streets.items():
            self.assertEqual({k: street[k] for k in ("n", "h", "p")}, old[name])

    def test_missing_roads_file_is_no_names(self):
        self.assertEqual(N.street_names(None), {})
        self.assertEqual(N.street_names("/нет/такого"), {})


class AliasTests(Base):
    TSV = ("kind\tname_now\tname_old\tlang\tosm_id\tlat\tlon\tsource\tsource_date\n"
           "# комментарий\n"
           "metro\tNovza\tHamza\tuz\tn563751850\t41.2918\t69.2236\twiki\t2026-11-02\n"
           "metro\tНовза\tХамза метро\tru\t\t\t\twiki\t2026-11-02\n"
           "street\tAmir Temur shoh ko'chasi\tулица Энгельса\tru\t\t41.31\t69.28\thokimiyat\t2026-11-02\n"
           "street\tAmir Temur shoh ko'chasi\tДалеко\tru\t\t41.40\t69.40\thokimiyat\t2026-11-02\n"
           "street\tНет такой\tСтарое\tru\t\t\t\thokimiyat\t2026-11-02\n"
           "street\t\tпусто\tru\t\t\t\tx\t\n")

    def test_read_and_apply(self):
        path = os.path.join(self.work, "aliases_tashkent.tsv")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(self.TSV)
        rows = N.read_aliases(path)
        self.assertEqual(len(rows), 5, "комментарий и строка без имени пропущены")
        self.assertEqual(rows[0]["lat"], 41.2918)
        self.assertIsNone(rows[1]["lat"])
        addresses = build_roads.addresses_by_cell([("Amir Temur shoh ko'chasi", "5", 69.2801, 41.3101)])
        venues = build_roads.venues_by_cell([(14, "Новза", 69.2236, 41.2918, [], ["Хамза"])])
        applied, missed = N.apply_aliases(addresses, venues, rows)
        self.assertEqual(applied, 3)
        self.assertEqual([r["name_old"] for r in missed], ["Далеко", "Старое"])
        station = next(iter(venues.values()))["venues"][0]
        self.assertEqual(station[5], ["Хамза", "Хамза метро"], "Hamza = Хамза — не повтор")
        street = next(iter(addresses.values()))["streets"][0]
        self.assertEqual(street["o"], ["улица Энгельса"])

    def test_alias_paths_default_to_poi_folder(self):
        self.assertEqual(build_roads.alias_paths(["x.tsv"]), ["x.tsv"])
        for path in build_roads.alias_paths([]):
            self.assertTrue(os.path.basename(path).startswith("aliases_"))

    def test_missing_file_is_no_rows(self):
        self.assertEqual(N.read_aliases(None), [])
        self.assertEqual(N.read_aliases("/нет/такого.tsv"), [])


if __name__ == "__main__":
    unittest.main()
