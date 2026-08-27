import json
import gzip
import os
import shutil
import tempfile
import unittest

import ml_candidates


class CandidateTests(unittest.TestCase):
    """Кандидат — предложение машины, а не данные.

    Он не едет в тайлы, не попадает в подписанный индекс и не виден на
    телефоне. Принятый становится обычной правкой и проходит ту же проверку,
    что нарисованное мышью.
    """

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)

    def square(self, lat, lon, meters=30.0):
        step = meters / 111_320.0
        return [[lon, lat], [lon + step, lat], [lon + step, lat + step],
                [lon, lat + step], [lon, lat]]

    def source(self, squares, gz=True, csv=False):
        name = "ml.csv.gz" if gz else "ml.geojsonl"
        path = os.path.join(self.dir, name)
        opener = gzip.open if gz else open
        with opener(path, "wt", encoding="utf-8") as handle:
            for ring in squares:
                row = json.dumps({"type": "Feature",
                                  "properties": {"height": -1.0,
                                                 "confidence": -1.0},
                                  "geometry": {"type": "Polygon",
                                               "coordinates": [ring]}})
                handle.write((f"121322232,{row}\n") if csv else (row + "\n"))
        return path

    def houses(self, squares):
        path = os.path.join(self.dir, "houses.geojsonl")
        with open(path, "w", encoding="utf-8") as handle:
            for ring in squares:
                json.dump({"type": "Feature", "properties": {"building": "yes"},
                           "geometry": {"type": "Polygon",
                                        "coordinates": [ring]}}, handle)
                handle.write("\n")
        return path

    def out(self):
        return os.path.join(self.dir, "cand")

    def test_candidates_land_in_their_cells(self):
        made = ml_candidates.build_candidates(
            self.source([self.square(41.30, 69.25),
                         self.square(41.36, 69.25)]), self.out())
        self.assertEqual(len(made), 2)
        self.assertEqual(sum(made.values()), 2)

    def test_files_are_not_tiles(self):
        # Файл кандидатов не должен выглядеть тайлом: индекс подписан и
        # описывает то, что едет на телефоны.
        ml_candidates.build_candidates(
            self.source([self.square(41.30, 69.25)]), self.out())
        for name in os.listdir(self.out()):
            self.assertTrue(name.startswith("cand_"), name)
            self.assertFalse(name.startswith(("road2_", "tile_")), name)

    def test_known_house_is_dropped(self):
        ring = self.square(41.30, 69.25)
        made = ml_candidates.build_candidates(
            self.source([ring]), self.out(), houses_path=self.houses([ring]))
        self.assertEqual(made, {}, "кандидат поверх известного дома остался")

    def test_house_a_few_metres_away_is_still_the_same_house(self):
        # Контур нейросети и контур OSM описывают одно здание с разницей в
        # несколько метров, и граница клетки проходит между ними примерно в
        # двух случаях из трёх. Без осмотра соседних клеток отсев падал с 78%
        # до 35% там, где OSM знает почти все дома.
        shift = 6.0 / 111_320.0
        made = ml_candidates.build_candidates(
            self.source([self.square(41.30 + shift, 69.25 + shift)]),
            self.out(), houses_path=self.houses([self.square(41.30, 69.25)]))
        self.assertEqual(made, {}, "тот же дом со сдвигом остался кандидатом")

    def test_far_house_stays_a_candidate(self):
        made = ml_candidates.build_candidates(
            self.source([self.square(41.32, 69.27)]), self.out(),
            houses_path=self.houses([self.square(41.30, 69.25)]))
        self.assertEqual(sum(made.values()), 1, "новый дом потерялся")

    def test_shed_is_dropped(self):
        made = ml_candidates.build_candidates(
            self.source([self.square(41.30, 69.25, meters=3)]), self.out())
        self.assertEqual(made, {})

    def test_bbox_limits_the_work(self):
        made = ml_candidates.build_candidates(
            self.source([self.square(41.30, 69.25), self.square(41.90, 69.25)]),
            self.out(), bbox=(41.29, 69.24, 41.31, 69.26))
        self.assertEqual(sum(made.values()), 1)

    def test_csv_wrapper_is_read_too(self):
        made = ml_candidates.build_candidates(
            self.source([self.square(41.30, 69.25)], csv=True), self.out())
        self.assertEqual(sum(made.values()), 1, "строка CSV не разобрана")

    def test_plain_geojsonl_is_read_too(self):
        made = ml_candidates.build_candidates(
            self.source([self.square(41.30, 69.25)], gz=False), self.out())
        self.assertEqual(sum(made.values()), 1)

    def test_order_is_stable(self):
        source = self.source([self.square(41.301, 69.251),
                              self.square(41.302, 69.252),
                              self.square(41.303, 69.253)])
        def body(key):
            with open(os.path.join(self.out(), f"cand_{key}.json"),
                      encoding="utf-8") as handle:
                return json.load(handle)

        first = ml_candidates.build_candidates(source, self.out())
        before = body(list(first)[0])
        ml_candidates.build_candidates(source, self.out())
        self.assertEqual(before, body(list(first)[0]))

    def test_missing_source_is_not_an_error(self):
        self.assertEqual(ml_candidates.build_candidates("/нет", self.out()), {})


if __name__ == "__main__":
    unittest.main()
