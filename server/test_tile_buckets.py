"""Корзины индекса тайлов: контракт с TileDigestIndex.swift и полнота покрытия."""

import hashlib
import json
import os
import struct
import tempfile
import unittest

import tile_buckets as tb


def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


class PackingTests(unittest.TestCase):
    def test_key_matches_swift_formula(self):
        # TileDigestIndex.packed: z << 48 | x << 24 | y
        self.assertEqual(tb.packed(15, 22686, 12246), (15 << 48) | (22686 << 24) | 12246)

    def test_out_of_range_is_refused(self):
        with self.assertRaises(ValueError):
            tb.packed(25, 0, 0)
        with self.assertRaises(ValueError):
            tb.packed(15, 1 << 24, 0)


class BucketTests(unittest.TestCase):
    def test_bucket_is_the_z10_ancestor(self):
        self.assertEqual(tb.bucket_of(15, 22686, 12246), f"{22686 >> 5}_{12246 >> 5}")
        self.assertEqual(tb.bucket_of(10, 708, 382), "708_382")
        self.assertEqual(tb.bucket_of(11, 1417, 765), "708_382")

    def test_small_zooms_go_to_low(self):
        self.assertEqual(tb.bucket_of(9, 354, 191), tb.LOW)
        self.assertEqual(tb.bucket_of(0, 0, 0), tb.LOW)

    def test_every_tile_lands_in_exactly_one_bucket(self):
        tiles = {"15/22686/12246": sha("a"), "15/22687/12246": sha("b"),
                 "11/1417/765": sha("c"), "9/354/191": sha("d"), "14/11343/6123": sha("e")}
        buckets = tb.buckets_for(tiles, 7)
        seen = {}
        for name, blob in buckets.items():
            version, entries = tb.parse(blob)
            self.assertEqual(version, 7)
            for key in entries:
                self.assertNotIn(key, seen)
                seen[key] = name
        self.assertEqual(len(seen), len(tiles))
        for key, digest in tiles.items():
            packed = tb.packed(*tb.parse_key(key))
            _, entries = tb.parse(buckets[seen[packed]])
            self.assertEqual(entries[packed].hex(), digest)


class FormatTests(unittest.TestCase):
    def test_layout_is_rmti_v1(self):
        blob = tb.serialize(3, [(tb.packed(15, 2, 1), bytes(32)), (tb.packed(15, 1, 1), b"\x01" * 32)])
        self.assertEqual(blob[:4], b"RMTI")
        self.assertEqual(blob[4], 1)
        self.assertEqual(struct.unpack_from("<qI", blob, 5), (3, 2))
        self.assertEqual(len(blob), 17 + 2 * 40)
        # Ключи по возрастанию — на этом стоит двоичный поиск в приложении,
        # и дайджесты идут в ТОМ ЖЕ порядке.
        first, second = struct.unpack_from("<2Q", blob, 17)
        self.assertLess(first, second)
        self.assertEqual(blob[17 + 16:17 + 48], b"\x01" * 32)

    def test_duplicate_key_is_refused(self):
        key = tb.packed(15, 1, 1)
        with self.assertRaises(ValueError):
            tb.serialize(1, [(key, bytes(32)), (key, bytes(32))])

    def test_parse_refuses_damage(self):
        blob = tb.serialize(1, [(tb.packed(15, 1, 1), bytes(32))])
        with self.assertRaises(ValueError):
            tb.parse(blob[:-1])
        with self.assertRaises(ValueError):
            tb.parse(b"XXXX" + blob[4:])


class BuildTests(unittest.TestCase):
    def setUp(self):
        self.tiles = {f"15/{22680 + i}/{12240 + i}": sha(str(i)) for i in range(70)}
        self.tiles["11/1417/765"] = sha("far")
        self.omt = {"9/354/191": sha("o9"), "14/11343/6123": sha("o14")}

    def build(self, out):
        return tb.build(4, {"mvt": {"path": "mvt", "ext": "mvt", "tiles": self.tiles},
                            "omt": {"path": "omt", "ext": "pbf", "tiles": self.omt}}, out)

    def test_root_hashes_match_written_buckets(self):
        with tempfile.TemporaryDirectory() as out:
            root = self.build(out)
            self.assertEqual(root["version"], 4)
            self.assertEqual(root["bucketZoom"], 10)
            for name, spec in root["sets"].items():
                total = 0
                for bucket, digest in spec["buckets"].items():
                    with open(os.path.join(out, "idx", name, bucket + ".bin"), "rb") as handle:
                        blob = handle.read()
                    self.assertEqual(hashlib.sha256(blob).hexdigest(), digest)
                    total += len(tb.parse(blob)[1])
                self.assertEqual(total, spec["tiles"])
            self.assertIn(tb.LOW, root["sets"]["omt"]["buckets"])

    def test_build_is_deterministic(self):
        with tempfile.TemporaryDirectory() as a, tempfile.TemporaryDirectory() as b:
            self.assertEqual(json.dumps(self.build(a), sort_keys=True),
                             json.dumps(self.build(b), sort_keys=True))

    def test_payload_with_meta_objects_and_plain_hex(self):
        self.assertEqual(tb.tiles_from_payload({"tiles": {"15/1/1": {"sha256": "ab", "bytes": 3}}}),
                         {"15/1/1": "ab"})
        self.assertEqual(tb.tiles_from_payload({"tiles": {"15/1/1": "ab"}}), {"15/1/1": "ab"})


if __name__ == "__main__":
    unittest.main()
