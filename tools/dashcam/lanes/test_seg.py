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

    def test_near_test_trips_banned(self):
        from seg_select import near_test
        truth = [{"trip": "T", "half": "test"}, {"trip": "A", "half": "tune"}]
        spans = {"T": (10000, 12000), "A": (12100, 13000), "X": (12500, 13000),
                 "Y": (20000, 21000), "Z": (5000, 9000)}
        self.assertEqual(near_test(spans, truth), {"X", "Z"})
        items = select(self.windows, self.truth, self.db, per_trip=5, also_banned={"X"})
        self.assertFalse(any(it["trip"] == "X" for it in items))

    def test_extend_keeps_order_and_no_leak(self):
        from seg_select import extend
        old = select(self.windows, self.truth, self.db, per_trip=3)
        new = select(self.windows, self.truth, self.db, per_trip=8)
        ext = extend(old, new)
        self.assertEqual(ext[:len(old)], old)
        self.assertGreater(len(ext), len(old))
        self.assertEqual(len({it["key"] for it in ext}), len(ext))
        self.assertTrue(all(it["src"] == "db" and it["trip"] == "X" for it in ext[len(old):]))

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


class TestSelfLabel(unittest.TestCase):
    """seg_selflabel: решение-классификация кандидатов → разметка."""

    def cand(self, cid, x, status="v2", kind="line", s=0.0):
        import seg_selflabel as sl
        c = sl.make_cand(CAM, cid, x, s, None, "", status, kind=kind)
        self.assertIsNotNone(c)
        return c

    def item(self, key="w1_f_0001"):
        return {"key": key, "src": "window", "trip": "t", "win": 1, "name": "f_0001.jpg", "frame_id": None}

    def test_refine_follows_paint_and_refuses_sparse(self):
        import seg_selflabel as sl
        rng = np.random.default_rng(1)
        Z = rng.uniform(6.5, 20, 400)
        X = 1.9 + 0.02 * (Z - 8) + rng.normal(0, 0.03, len(Z))
        r = sl.refine(X, Z, 1.75, 0.0)
        self.assertIsNotNone(r)
        (a, b, c), zmax = r
        self.assertAlmostEqual(a, 1.9, delta=0.03)
        self.assertAlmostEqual(b, 0.02, delta=0.01)
        self.assertLessEqual(abs(c), sl.CURV_MAX)
        self.assertIsNone(sl.refine(X[:10], Z[:10], 1.75, 0.0))        # точек мало
        self.assertIsNone(sl.refine(X, Z, 1.0, 0.0))                   # коридор пуст
        self.assertIsNone(sl.refine(X, Z, 1.75, 0.0, paint=False))     # бордюр не уточняем

    def test_junk_and_classes(self):
        import seg_selflabel as sl
        cands = {"cands": [self.cand(1, -1.75), self.cand(2, 1.75), self.cand(3, 4.5, "rej")]}
        dec = {"c": {"1": "dashed", "2": "solid", "3": "junk"}, "_from": "w1_f_0001"}
        lab, synth = sl.build_label("w1_f_0001", self.item(), dec, cands, CAM)
        self.assertEqual([l["cls"] for l in lab["lines"]], ["dashed", "solid"])
        self.assertEqual(synth, [False, False])
        self.assertEqual(lab["origin"], "manual")
        self.assertIsNone(validate(lab)[1])
        with self.assertRaises(ValueError):
            sl.build_label("w1_f_0001", self.item(), {"c": {"1": "лужа"}, "_from": "x"}, cands, CAM)

    def test_synth_offset_by_neighbour_width_or_default(self):
        import seg_selflabel as sl
        cands = {"cands": [self.cand(1, -1.6), self.cand(2, 1.6)]}
        dec = {"c": {"1": "dashed", "2": "dashed"}, "synth": [{"side": "right", "cls": "dashed"}],
               "_from": "w1"}
        lab, synth = sl.build_label("w1_f_0001", self.item(), dec, cands, CAM)
        self.assertEqual(synth, [False, False, True])
        X, Z = jpg_to_ground(CAM, lab["lines"][2]["pts"])
        ok = np.isfinite(X)
        self.assertTrue(np.allclose(X[ok], 4.8, atol=0.05))          # 1,6 + ширина 3,2
        self.assertEqual(lab["origin"], "transfer")
        # Одна линия краски — смещение 3,5 м.
        lab, _ = sl.build_label("w1_f_0001", self.item(),
                                {"c": {"1": "solid"}, "synth": [{"side": "left", "cls": "dashed"}],
                                 "_from": "w1"}, cands, CAM)
        X, _ = jpg_to_ground(CAM, lab["lines"][1]["pts"])
        self.assertTrue(np.allclose(X[np.isfinite(X)], -5.1, atol=0.05))
        # Не больше одной досочинённой с каждой стороны.
        with self.assertRaises(ValueError):
            sl.build_label("w1_f_0001", self.item(),
                           {"c": {"1": "solid"}, "synth": [{"side": "left"}, {"side": "left"}],
                            "_from": "w1"}, cands, CAM)

    def test_ghost_snaps_to_live_candidate_or_keeps_transfer(self):
        import seg_selflabel as sl
        ghost = self.cand(7, 2.0, "ghost")
        live = self.cand(12, 2.25, "rej")
        far = self.cand(13, 3.5, "rej")
        self.assertEqual(sl.snap_ghost(ghost, [ghost, live, far], {"7": "dashed"})["id"], 12)
        self.assertEqual(sl.snap_ghost(ghost, [ghost, far], {"7": "dashed"})["id"], 7)
        # На этом месте уже решённая линия кадра — второй не будет.
        self.assertIsNone(sl.snap_ghost(ghost, [ghost, live], {"7": "dashed", "12": "solid"}))

    def test_frame_decision_overrides_window(self):
        import seg_selflabel as sl
        with tempfile.TemporaryDirectory() as d:
            old = sl.DEC
            sl.DEC = d
            try:
                with open(os.path.join(d, "w5.json"), "w") as f:
                    json.dump({"c": {"1": "solid"}}, f)
                self.assertEqual(sl.load_decision("w5_f_0003")["_from"], "w5")
                with open(os.path.join(d, "w5_f_0003.json"), "w") as f:
                    json.dump({"skip": True}, f)
                self.assertTrue(sl.load_decision("w5_f_0003")["skip"])
                self.assertEqual(sl.load_decision("w5_f_0005")["_from"], "w5")
                self.assertIsNone(sl.load_decision("d42"))
            finally:
                sl.DEC = old


if __name__ == "__main__":
    unittest.main()
