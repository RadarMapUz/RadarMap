"""Тесты сегментации: маски из ломаных (синтетика), сохранение/загрузка
разметки, отбор кадров без утечки проверочной половины, перенос по трекам,
псевдоразметка. Без torch и без картинок с диска.

    python3 test_seg.py
"""
import json
import os
import tempfile
import unittest

import numpy as np

from camera import Camera, bev_axes, jpg_to_src
from seg_common import (CLS, IGNORE, ground_line_to_jpg, jpg_to_ground, load_label,
                        save_label, transfer_lines, validate)
from seg_masks import bev_mask, frame_mask, monotonic_pieces
from seg_pseudo import confident, inside_curbs
from seg_select import interleave, select, window_frames

# Камера как в calib.json (без чтения файла).
CAM = Camera(f=1123.6, k=0.3, pitch_deg=-3.8188, yaw_deg=-1.4022, h=1.3)


def gline(cls, x, z0=6.0, z1=20.0, n=6):
    zs = np.linspace(z0, z1, n)
    return {"cls": cls, "pts": ground_line_to_jpg(CAM, np.full_like(zs, x), zs)}


def pix(x, z):
    """Пиксель кадра (row, col) точки земли."""
    u, v = CAM.ground_to_src(np.array([x]), np.array([z]))
    from camera import src_to_jpg
    c, r = src_to_jpg(u, v)
    return int(r[0]), int(c[0])


def lab(lines, boxes=(), key="w1_f_0001", **kw):
    d = {"key": key, "lines": lines, "boxes": list(boxes)}
    d.update(kw)
    return d


class TestMasks(unittest.TestCase):
    def setUp(self):
        self.road = lab([gline("curb", -5.0), gline("dashed", -1.75), gline("solid", 1.75),
                         gline("curb", 5.0)])

    def test_line_pixels_and_width(self):
        m = frame_mask(self.road, CAM)
        self.assertEqual(m[pix(1.75, 10)], CLS["solid"])
        self.assertEqual(m[pix(-1.75, 10)], CLS["dashed"])
        self.assertEqual(m[pix(-5.0, 12)], CLS["curb"])
        self.assertEqual(m[pix(0.0, 10)], CLS["road"])
        self.assertEqual(m[pix(3.3, 10)], CLS["road"])
        self.assertEqual(m[pix(7.0, 10)], CLS["bg"])      # за бордюром — фон
        self.assertNotEqual(m[pix(2.1, 10)], CLS["solid"])
        # Ширина на земле ≈ 0,15 м: в строке через (1.75, 8) столько пикселей класса,
        # сколько помещается в 0,15 м на этой дальности (±2 px на округление).
        r, c = pix(1.75, 8)
        row = m[r]
        n = int((row[max(0, c - 40):c + 40] == CLS["solid"]).sum())
        r1, c1 = pix(1.75 + 0.15, 8)
        self.assertLessEqual(abs(n - abs(c1 - c)), 2)

    def test_far_line_not_thinner_than_2px(self):
        m = frame_mask(lab([gline("solid", 1.75, 6, 40, 10)]), CAM)
        r, c = pix(1.75, 38)
        self.assertGreaterEqual(int((m[r, c - 4:c + 5] == CLS["solid"]).sum()), 2)

    def test_double_wider_than_single(self):
        a = frame_mask(lab([gline("double", -1.75)]), CAM)
        b = frame_mask(lab([gline("solid", -1.75)]), CAM)
        self.assertGreater((a == CLS["double"]).sum(), 2 * (b == CLS["solid"]).sum())

    def test_missing_curb_is_unknown_not_background(self):
        # Справа бордюра нет: крайняя линия — граница дороги, за ней «не знаем».
        m = frame_mask(lab([gline("curb", -5.0), gline("dashed", 1.75)]), CAM)
        self.assertEqual(m[pix(0.0, 10)], CLS["road"])
        self.assertEqual(m[pix(4.0, 10)], IGNORE)
        self.assertEqual(m[pix(-7.0, 10)], CLS["bg"])

    def test_no_bounds_whole_ground_unknown(self):
        m = frame_mask(lab([]), CAM)
        self.assertEqual(m[pix(0.0, 10)], IGNORE)
        self.assertEqual(m[10, 640], CLS["bg"])           # небо — фон

    def test_beyond_labeled_range_unknown(self):
        m = frame_mask(self.road, CAM)
        self.assertEqual(m[pix(0.0, 30)], IGNORE)

    def test_boxes_and_skip(self):
        r, c = pix(0.0, 15)
        m = frame_mask(lab(self.road["lines"], [{"cls": "car_moving", "box": [c - 20, r - 30, c + 20, r + 5]}]), CAM)
        self.assertEqual(m[r - 2, c], CLS["car_moving"])
        sk = frame_mask(lab(self.road["lines"], skip=True), CAM)
        self.assertTrue((sk == IGNORE).all())

    def test_bev(self):
        m = bev_mask(self.road, CAM)
        xs, zs = bev_axes()
        col = lambda x: int(np.argmin(np.abs(xs - x)))
        row = lambda z: int(np.argmin(np.abs(zs - z)))
        self.assertEqual(m[row(10), col(1.75)], CLS["solid"])
        self.assertEqual(m[row(10), col(0.0)], CLS["road"])
        # 0,15 м при 5 см/px — 3 пикселя (±1).
        self.assertLessEqual(abs(int((m[row(10)] == CLS["solid"]).sum()) - 3), 1)
        self.assertEqual(m[-1, -1], IGNORE)               # X=12, Z=6 — вне кадра, не знаем

    def test_monotonic_pieces(self):
        X = np.array([0, 0, 0, 0, 0.0])
        Z = np.array([5, 10, 15, 12, 8.0])
        p = monotonic_pieces(X, Z)
        self.assertEqual(len(p), 2)
        for _, z in p:
            self.assertTrue((np.diff(z) > 0).all())


class TestLabelsIO(unittest.TestCase):
    def test_roundtrip(self):
        with tempfile.TemporaryDirectory() as d:
            src = lab([gline("dashed", 1.75)], [{"cls": "car_parked", "box": [900, 400, 800, 350]}],
                      key="w15474_f_0041", seconds=33.3, origin="prefill", win=15474, name="f_0041.jpg",
                      trip="t", src="window")
            path = save_label(src, d)
            self.assertTrue(path.endswith("w15474_f_0041.json"))
            got = load_label("w15474_f_0041", d)
            self.assertEqual(got["lines"][0]["cls"], "dashed")
            self.assertEqual(got["boxes"][0]["box"], [800.0, 350.0, 900.0, 400.0])  # углы упорядочены
            self.assertEqual(got["seconds"], 33.3)
            self.assertIn("saved", got)
            self.assertIsNone(load_label("w1_f_0002", d))
            self.assertIsNone(load_label("../etc", d))

    def test_validation_rejects(self):
        ok = lab([gline("solid", 1.0)])
        self.assertIsNotNone(validate(ok)[0])
        bad = [lab([{"cls": "zebra", "pts": [[1, 2], [3, 4]]}]),
               lab([{"cls": "solid", "pts": [[1, 2]]}]),
               lab([{"cls": "solid", "pts": [[1, 2], [5000, 4]]}]),
               lab([], [{"cls": "car", "box": [0, 0, 1, 1]}]),
               lab([], key="../../x")]
        for b in bad:
            self.assertIsNone(validate(b)[0], b)
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(ValueError):
                save_label(bad[0], d)

    def test_server_store_takes_origin_from_selection(self):
        import sys
        sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "label_ui"))
        from server import Store
        with tempfile.TemporaryDirectory() as d:
            sel = [{"key": "d42", "src": "db", "trip": "настоящая", "win": None, "name": None,
                    "frame_id": 42, "path": "/x.jpg", "round": 0}]
            sp = os.path.join(d, "selection.json")
            with open(sp, "w") as f:
                json.dump(sel, f)
            st = Store(selection=sp, labels=d, prefill=d, cam=CAM)
            st.save({"key": "d42", "trip": "подделка", "frame_id": 7, "lines": [], "boxes": [],
                     "seconds": 12})
            got = load_label("d42", d)
            self.assertEqual(got["trip"], "настоящая")
            self.assertEqual(got["frame_id"], 42)
            self.assertEqual(st.stats()["done"], 1)
            with self.assertRaises(ValueError):
                st.save({"key": "d43", "lines": [], "boxes": []})


class TestSelection(unittest.TestCase):
    def setUp(self):
        self.truth = [
            {"id": 1, "trip": "A", "half": "tune"}, {"id": 2, "trip": "B", "half": "tune"},
            {"id": 3, "trip": "T", "half": "test"}, {"id": 4, "trip": "U", "half": "test"}]
        names = [f"f_{i:04d}.jpg" for i in range(1, 101)]
        pts = [18.4 + i * 0.04 for i in range(100)]
        self.windows = [{"win": w, "trip": t, "names": names, "pts": pts, "pos": 20.4}
                        for w, t in ((1, "A"), (2, "B"), (3, "T"), (4, "U"), (50, "T"))]
        self.db = {
            "A": [(100 + i, i, 40.0, f"/a{i}.jpg", 120.0) for i in range(30)],
            "T": [(200 + i, i, 40.0, f"/t{i}.jpg", 120.0) for i in range(30)],
            "X": [(300 + i, i, 40.0 if i % 2 else 5.0, f"/x{i}.jpg", 120.0 if i < 20 else 20.0)
                  for i in range(30)],
        }

    def test_no_test_trip_leaks(self):
        items = select(self.windows, self.truth, self.db, per_trip=5)
        trips = {it["trip"] for it in items}
        self.assertFalse(trips & {"T", "U"})
        self.assertFalse({it["win"] for it in items} & {3, 4, 50})
        # Кадры БД — только поездок вне истины (A — в истине, его окна уже взяты).
        self.assertEqual({it["trip"] for it in items if it["src"] == "db"}, {"X"})
        # Медленные и тёмные кадры X отброшены.
        ids = {it["frame_id"] for it in items if it["src"] == "db"}
        self.assertTrue(all((i - 300) % 2 == 1 and i - 300 < 20 for i in ids))
        self.assertEqual(len({it["key"] for it in items}), len(items))

    def test_window_frames_even_and_spaced(self):
        names = self.windows[0]["names"]
        pts = self.windows[0]["pts"]
        fr = window_frames(names, pts, 20.4)
        self.assertEqual(len(fr), 4)
        idx = [names.index(n) for n in fr]
        self.assertTrue(all(i % 2 == 0 for i in idx))
        t = [pts[i] for i in idx]
        self.assertTrue(all(0.8 <= b - a <= 1.2 for a, b in zip(t, t[1:])))

    def test_rounds_first(self):
        items = select(self.windows, self.truth, {}, per_trip=5)
        rounds = [it["round"] for it in items]
        self.assertEqual(rounds, sorted(rounds))           # сначала первый круг всех окон
        self.assertEqual({it["trip"] for it in items[:2]}, {"A", "B"})

    def test_interleave(self):
        self.assertEqual(interleave({"a": [1, 2, 3], "b": [4]}), [1, 4, 2, 3])


class TestTransferAndPseudo(unittest.TestCase):
    def test_transfer_shifts_on_ground(self):
        src = [gline("dashed", 1.75, 6, 20)]
        out = transfer_lines(CAM, src, -0.4, 0.0, 0.0)
        X, Z = jpg_to_ground(CAM, out[0]["pts"])
        self.assertTrue(np.allclose(X, 1.35, atol=0.03))
        # наклонка B: X = x + s·(Z − 8)
        out = transfer_lines(CAM, src, 0.0, 0.0, 0.05)
        X, Z = jpg_to_ground(CAM, out[0]["pts"])
        self.assertTrue(np.allclose(X, 1.75 + 0.05 * (Z - 8), atol=0.03))

    def test_confident_windows_only_tune_and_matching(self):
        truth = [{"id": 1, "half": "tune", "judge": True, "lanes": 3},
                 {"id": 2, "half": "tune", "judge": True, "lanes": 2},
                 {"id": 3, "half": "test", "judge": True, "lanes": 3},
                 {"id": 4, "half": "tune", "judge": False, "lanes": None},
                 {"id": 5, "half": "tune", "judge": True, "lanes": 3}]
        res = [{"id": 1, "lanes": 3, "share": 0.8}, {"id": 2, "lanes": 3, "share": 0.9},
               {"id": 3, "lanes": 3, "share": 1.0}, {"id": 4, "lanes": 2, "share": 1.0},
               {"id": 5, "lanes": 3, "share": 0.5}]
        self.assertEqual(confident(truth, res), [1])

    def test_inside_curbs(self):
        lines = [gline("curb", -5.0), gline("dashed", -1.75), gline("dashed", 7.0), gline("curb", 4.0)]
        kept = inside_curbs(CAM, lines)
        self.assertEqual([l["cls"] for l in kept], ["curb", "dashed", "curb"])


if __name__ == "__main__":
    unittest.main()
