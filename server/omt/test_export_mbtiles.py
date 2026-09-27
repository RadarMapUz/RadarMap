import gzip, hashlib, json, os, shutil, sqlite3, sys, tempfile, unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import export_mbtiles


class ExportTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.db = os.path.join(self.dir, "t.mbtiles")
        conn = sqlite3.connect(self.db)
        conn.execute("CREATE TABLE tiles(zoom_level, tile_column, tile_row, tile_data)")
        conn.execute("CREATE TABLE metadata(name, value)")
        conn.executemany("INSERT INTO metadata VALUES (?, ?)", [("minzoom", "0"), ("maxzoom", "14")])
        conn.execute("INSERT INTO tiles VALUES (14, 11344, ?, ?)", ((1 << 14) - 1 - 6123, gzip.compress(b"tile")))
        conn.commit(); conn.close()

    def test_tms_row_becomes_xyz_and_body_is_decompressed(self):
        export_mbtiles.export(self.db, self.dir)
        path = os.path.join(self.dir, "omt", "14", "11344", "6123.pbf")
        self.assertEqual(open(path, "rb").read(), b"tile")

    def test_index_sha_is_over_the_body_the_phone_sees(self):
        export_mbtiles.export(self.db, self.dir)
        index = json.load(open(os.path.join(self.dir, "omt_index_payload.json")))
        self.assertEqual(index["tiles"]["14/11344/6123"]["sha256"], hashlib.sha256(b"tile").hexdigest())
        self.assertEqual(index["maxzoom"], 14)

    def test_index_bytes_are_stable(self):
        export_mbtiles.export(self.db, self.dir)
        first = open(os.path.join(self.dir, "omt_index_payload.json"), "rb").read()
        export_mbtiles.export(self.db, self.dir)
        self.assertEqual(first, open(os.path.join(self.dir, "omt_index_payload.json"), "rb").read())


if __name__ == "__main__":
    unittest.main()
