"""PMTiles v3: TileID по спецификации, круговой путь запись → чтение, листья."""

import gzip
import hashlib
import os
import random
import tempfile
import unittest

import pmtiles


class TileIdTests(unittest.TestCase):
    def test_spec_vectors(self):
        # Таблица из спецификации PMTiles v3.
        self.assertEqual(pmtiles.zxy_to_tileid(0, 0, 0), 0)
        self.assertEqual(pmtiles.zxy_to_tileid(1, 0, 0), 1)
        self.assertEqual(pmtiles.zxy_to_tileid(1, 0, 1), 2)
        self.assertEqual(pmtiles.zxy_to_tileid(1, 1, 1), 3)
        self.assertEqual(pmtiles.zxy_to_tileid(1, 1, 0), 4)
        self.assertEqual(pmtiles.zxy_to_tileid(2, 0, 0), 5)
        self.assertEqual(pmtiles.zxy_to_tileid(12, 3423, 1763), 19078479)

    def test_roundtrip(self):
        rng = random.Random(1)
        for _ in range(500):
            z = rng.randint(0, 18)
            x, y = rng.randrange(1 << z), rng.randrange(1 << z)
            self.assertEqual(pmtiles.tileid_to_zxy(pmtiles.zxy_to_tileid(z, x, y)), (z, x, y))

    def test_out_of_grid_is_refused(self):
        with self.assertRaises(ValueError):
            pmtiles.zxy_to_tileid(2, 4, 0)


class DirectoryTests(unittest.TestCase):
    def test_roundtrip_with_contiguous_and_jumps(self):
        entries = [(5, 0, 10, 1), (6, 10, 7, 1), (9, 0, 10, 3), (100, 17, 4, 1)]
        self.assertEqual(pmtiles.deserialize_directory(pmtiles.serialize_directory(entries)), entries)


class ArchiveTests(unittest.TestCase):
    def write(self, tiles, **kw):
        handle, path = tempfile.mkstemp(suffix=".pmtiles")
        os.close(handle)
        self.addCleanup(os.remove, path)
        sha, info = pmtiles.write(path, tiles, {"name": "test"}, pmtiles.COMPRESSION_GZIP, **kw)
        return path, sha, info

    def test_every_tile_reads_back(self):
        rng = random.Random(2)
        tiles = {}
        for z in (11, 15):
            for _ in range(300):
                n = 1 << z
                key = (z, rng.randrange(n), rng.randrange(n))
                tiles[key] = gzip.compress(os.urandom(rng.randint(5, 50)), mtime=0)
        path, sha, info = self.write(tiles)
        reader = pmtiles.Reader(path)
        for (z, x, y), data in tiles.items():
            self.assertEqual(reader.get(z, x, y), data)
        self.assertIsNone(reader.get(15, 0, 0) if (15, 0, 0) not in tiles else None)
        with open(path, "rb") as handle:
            self.assertEqual(hashlib.sha256(handle.read()).hexdigest(), sha)
        self.assertEqual(reader.metadata["name"], "test")
        self.assertEqual((reader.min_zoom, reader.max_zoom), (11, 15))

    def test_duplicates_are_stored_once_and_runs_merge(self):
        same = b"\x1f\x8bempty"
        tiles = {(14, x, 0): same for x in range(64)}
        tiles[(14, 100, 100)] = b"other"
        path, _, info = self.write(tiles)
        self.assertEqual(info["contents"], 2)
        self.assertLess(info["entries"], 65)
        reader = pmtiles.Reader(path)
        self.assertEqual({(z, x, y): d for z, x, y, d in reader.all_tiles()}, tiles)

    def test_large_directory_goes_to_leaves_and_still_reads(self):
        # Разреженно и со случайными длинами — как страна, а не как плотная
        # сетка (её каталог сжимается в корень целиком).
        rng = random.Random(3)
        tiles = {}
        while len(tiles) < 40000:
            key = (15, rng.randrange(1 << 15), rng.randrange(1 << 15))
            tiles[key] = os.urandom(rng.randint(1, 900))
        path, _, info = self.write(tiles)
        self.assertTrue(info["leaves"])
        reader = pmtiles.Reader(path)
        self.assertLessEqual(reader.root_len, pmtiles.ROOT_LIMIT)
        for key in rng.sample(sorted(tiles), 300):
            self.assertEqual(reader.get(*key), tiles[key])

    def test_output_is_deterministic(self):
        tiles = {(12, x, 7): bytes([x]) * 20 for x in range(30)}
        _, a, _ = self.write(tiles)
        _, b, _ = self.write(dict(reversed(list(tiles.items()))))
        self.assertEqual(a, b)


if __name__ == "__main__":
    unittest.main()
