#!/usr/bin/env python3
"""Тесты старых имён Ташкента: разбор таблиц Википедии (rowspan, прежние
названия с датами), отказ от проектных названий, привязка к OSM, узбекская
кириллица и формат TSV для search_names.read_aliases. Без сети — на выгрузках
02.11.2026 из server/fixtures/aliases_*.
Запуск: python3 server/test_build_aliases.py
"""
import csv
import json
import os
import shutil
import tempfile
import unittest

import build_aliases as aliases

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "fixtures")


def fixture_json(name):
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as handle:
        return json.load(handle)


def metro_page():
    return fixture_json("aliases_ruwiki_metro.json")["parse"]


class NameTests(unittest.TestCase):
    def test_uzbek_cyrillic_follows_the_1995_alphabet(self):
        cases = {
            "Buyuk Ipak yo'li": "Буюк Ипак йўли",
            "Shahriston": "Шаҳристон",
            "Yangihayot": "Янгиҳаёт",
            "G'afur G'ulom": "Ғафур Ғулом",
            "Mustaqillik maydoni": "Мустақиллик майдони",
            "Eski Shahar": "Эски Шаҳар",
            "Amir Temur xiyoboni": "Амир Темур хиёбони",
            "Yunusobod": "Юнусобод",
        }
        for latin, cyrillic in cases.items():
            self.assertEqual(aliases.uz_cyrillic(latin), cyrillic)

    def test_fold_ties_scripts_together(self):
        self.assertEqual(aliases.fold("Хамза"), aliases.fold("Hamza"))
        self.assertEqual(aliases.skeleton("Чкаловская")[:4], aliases.skeleton("Chkalov")[:4])
        self.assertFalse(aliases.same_root("Творец", "Бунёдкор"))

    def test_russian_dates_become_iso(self):
        self.assertEqual(aliases.iso_date("до 16 июня 2015"), "2015-06-16")
        self.assertEqual(aliases.iso_date("проектное"), "")


class WikiTests(unittest.TestCase):
    def setUp(self):
        self.stations = aliases.parse_metro_list(metro_page()["wikitext"]["*"])
        self.by_ru = {station["ru"]: station for station in self.stations}

    def test_rowspan_carries_the_opening_date_down(self):
        self.assertEqual(self.by_ru["Пахтакор"]["opened"], "1977-11-06")
        self.assertEqual(self.by_ru["Хамид Алимджан"]["opened"], "1980-08-18")
        self.assertEqual(self.by_ru["Кипчак"]["opened"], "2024-03-11")

    def test_projected_stations_are_not_stations(self):
        self.assertNotIn("Бобур", self.by_ru)
        self.assertNotIn("Жанубий", self.by_ru)
        # Кольцевая: 14 станций, Чиланзарская: 17, Юнусабадская: 8.
        self.assertEqual(len(self.stations), 39)

    def test_former_names_keep_dates_and_flag_project_names(self):
        novza = {item["name"]: item for item in self.by_ru["Новза"]["former"]}
        self.assertTrue(novza["Мукими"]["project"])
        self.assertEqual(novza["Хамза"]["until"], "2015-06-16")
        self.assertFalse(novza["Хамза"]["project"])
        friendship = {item["name"]: item for item in self.by_ru["Халклар Дустлиги"]["former"]}
        self.assertEqual(friendship["Бунёдкор"]["since"], "2008-08-06")
        self.assertEqual(friendship["Бунёдкор"]["until"], "2018-05-03")
        self.assertEqual(friendship["Бунёдкор"]["variants"], [])

    def test_district_infobox_and_massifs(self):
        page = fixture_json("aliases_ruwiki_district_Яшнабадский.json")["parse"]
        olds, _ = aliases.parse_district(page["wikitext"]["*"], page["title"])
        self.assertEqual([name for name, _ in olds], ["Хамзинский район"])
        page = fixture_json("aliases_ruwiki_district_Мирзо-Улугбекский.json")["parse"]
        olds, massifs = aliases.parse_district(page["wikitext"]["*"], page["title"])
        self.assertIn(("Куйбышевский район", "1992-05-08"), olds)
        self.assertIn(("Буюк Ипак Йули", "Ц-1"), massifs)
        self.assertIn(("Хумоюн", "Ясный"), massifs)
        page = fixture_json("aliases_ruwiki_district_Юнусабадский.json")["parse"]
        olds, _ = aliases.parse_district(page["wikitext"]["*"], page["title"])
        self.assertEqual(olds, [("Кировский район", "1992-05-08")])


class BuildTests(unittest.TestCase):
    def setUp(self):
        stations = aliases.parse_metro_list(metro_page()["wikitext"]["*"])
        wikidata = aliases.parse_wikidata(fixture_json("aliases_wikidata_metro.json"))
        osm = aliases.read_jsonl(os.path.join(FIXTURES, "aliases_osm_metro.jsonl"))
        self.rows, self.table, self.warnings = aliases.metro_rows(
            stations, wikidata, osm, "test", "2026-11-02")

    def olds(self, name_now):
        return {(row["name_old"], row["lang"]) for row in self.rows if row["name_now"] == name_now}

    def test_hamza_finds_novza_in_three_forms(self):
        self.assertIn(("Хамза", "ru"), self.olds("Novza"))
        self.assertIn(("Hamza", "uz"), self.olds("Novza"))
        row = next(row for row in self.rows if row["name_old"] == "Хамза")
        self.assertEqual(row["osm_id"], "node/563751850")
        self.assertEqual(row["renamed"], "2015-06-16")

    def test_project_name_never_becomes_an_alias(self):
        """«Кипчак» был проектным именем «Чинора» и стал отдельной станцией:
        псевдоним отправил бы водителя на соседнюю станцию."""
        self.assertEqual(self.olds("Chinor"), set())
        self.assertFalse(any(row["name_old"] in ("Афросиёб", "Эхтиром", "Мукими") for row in self.rows))

    def test_redirected_wiki_title_still_finds_wikidata(self):
        friendship = next(row for row in self.table if row["name_ru"] == "Халклар Дустлиги")
        self.assertEqual(friendship["wikidata"], "Q4099275")
        self.assertIn(("Bunyodkor", "uz"), self.olds("Xalqlar doʻstligi"))
        self.assertNotIn("Халклар Дустлиги", {old for old, _ in self.olds("Xalqlar doʻstligi")})

    def test_cyrillic_copy_of_a_russian_name_is_not_repeated(self):
        self.assertNotIn(("Ҳамза", "uz-Cyrl"), self.olds("Novza"))

    def test_every_station_is_anchored_in_tashkent(self):
        self.assertEqual(self.warnings, [])
        for row in self.table:
            self.assertTrue(aliases.in_tashkent(row["lat"], row["lon"]), row["name_ru"])
            self.assertTrue(row["osm_id"])
            self.assertTrue(row["name_uz_cyrl"])

    def test_validate_rejects_short_or_foreign_sets(self):
        self.assertTrue(aliases.validate(self.rows, self.table[:3]))
        broken = dict(self.rows[0], lat=39.65, lon=66.96)
        self.assertTrue(aliases.validate([broken], self.table, min_stations=1))
        self.assertEqual(aliases.validate(self.rows, self.table, min_stations=1), [])


class FileTests(unittest.TestCase):
    def test_build_writes_tsv_that_search_names_can_read(self):
        raw = tempfile.mkdtemp()
        out = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, raw)
        self.addCleanup(shutil.rmtree, out)
        copies = {"aliases_ruwiki_metro.json": "ruwiki_metro.json",
                  "aliases_wikidata_metro.json": "wikidata_metro.json",
                  "aliases_osm_metro.jsonl": "osm_metro.jsonl",
                  "aliases_osm_places.jsonl": "osm_places.jsonl"}
        for stem in ("Яшнабадский", "Мирзо-Улугбекский", "Юнусабадский"):
            copies[f"aliases_ruwiki_district_{stem}.json"] = f"ruwiki_district_{stem}.json"
        for source, target in copies.items():
            shutil.copy(os.path.join(FIXTURES, source), os.path.join(raw, target))
        rows, table, _ = aliases.build(raw, out, "2026-11-02", min_stations=30)
        with open(os.path.join(out, "aliases_tashkent.tsv"), encoding="utf-8") as handle:
            lines = [line for line in handle if not line.startswith("#")]
        records = list(csv.reader(lines, delimiter="\t"))
        self.assertEqual(records[0][:9], ["kind", "name_now", "name_old", "lang", "osm_id",
                                          "lat", "lon", "source", "source_date"])
        self.assertEqual(len(records) - 1, len(rows))
        kinds = {record[0] for record in records[1:]}
        self.assertEqual(kinds, {"metro", "district", "neighbourhood"})
        yashnobod = [r for r in records[1:] if r[1] == "Yashnobod tumani"]
        self.assertIn("Hamza tumani", [r[2] for r in yashnobod])
        self.assertTrue(all(float(r[5]) and float(r[6]) for r in records[1:]))
        with open(os.path.join(out, "metro_tashkent.tsv"), encoding="utf-8") as handle:
            metro = [line for line in handle if not line.startswith("#")]
        self.assertEqual(len(metro) - 1, len(table))


if __name__ == "__main__":
    unittest.main()
