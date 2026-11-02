#!/usr/bin/env python3
"""overrides_diff: что владелец видит перед подписью правок — без сети и без
ключа (подпись подменяется)."""
import base64
import contextlib
import io
import json
import os
import tempfile
import unittest

import overrides_diff as od

CAMERAS = {i: {"id": i, "city": "Ташкент", "location": f"ул. {i}", "type": "Стационар камера",
               "lat": 41.3, "lon": 69.2 + i * 0.001} for i in range(1, 201)}


def envelope(version, items, sig="c2ln"):
    payload = json.dumps({"version": version, "updatedAt": "2026-11-02", "items": items}).encode()
    return json.dumps({"payload": base64.b64encode(payload).decode(), "sig": sig}).encode()


class DiffTest(unittest.TestCase):

    def test_reports_was_and_now_per_camera(self):
        prev = [{"id": 1, "op": "hide"}, {"id": 2, "op": "retype", "type": "Стационар радар"},
                {"id": 3, "op": "hide"}]
        new = [{"id": 1, "op": "hide"}, {"id": 2, "op": "hide"},
               {"id": 4, "op": "move", "lat": 41.3005, "lon": 69.204}]
        changes = od.diff(prev, new)
        self.assertEqual([c[0] for c in changes], [2, 3, 4], "неизменная #1 в разницу не попадает")
        self.assertEqual(changes[1], (3, {"id": 3, "op": "hide"}, None), "камеру вернули")
        text = "\n".join(od.render(changes, prev, new, CAMERAS))
        self.assertIn("#2 Ташкент, ул. 2", text)
        self.assertIn("тип Стационар камера → Стационар радар", text)
        self.assertIn("стало: СКРЫТА", text)
        self.assertIn("стало: как в базе", text)
        self.assertIn("ПЕРЕНЕСЕНА на 56 м", text)
        self.assertIn("скрыта: было 2 → стало 2", text)
        self.assertIn("перенесена: было 0 → стало 1", text)
        self.assertIn("новых скрытий и переносов в этой выкладке: 2", text)

    def test_changed_move_target_is_a_change(self):
        prev = [{"id": 5, "op": "move", "lat": 41.3, "lon": 69.205}]
        new = [{"id": 5, "op": "move", "lat": 41.301, "lon": 69.205}]
        self.assertEqual(len(od.diff(prev, new)), 1)
        self.assertEqual(od.diff(prev, prev), [])

    def test_last_line_for_an_id_wins_like_the_app(self):
        new = [{"id": 7, "op": "hide"}, {"id": 7, "op": "retype", "type": "Стационар радар"}]
        changes = od.diff([], new)
        self.assertEqual(changes[0][2]["op"], "retype")
        self.assertEqual(od.counts(new)["hide"], 0)


class ProblemsTest(unittest.TestCase):

    def test_clean_file_passes(self):
        items = [{"id": 1, "op": "hide"}, {"id": 2, "op": "move", "lat": 41.3001, "lon": 69.202}]
        self.assertEqual(od.problems(3, items, 2, CAMERAS), [])

    def test_mass_moves_are_refused_like_on_the_phone(self):
        items = [{"id": i, "op": "move", "lat": 41.3001, "lon": 69.2 + i * 0.001} for i in range(1, 8)]
        found = od.problems(3, items, 2, CAMERAS)
        self.assertTrue(any("отвергнет файл целиком" in p for p in found), found)

    def test_hides_and_moves_share_the_limit(self):
        items = [{"id": i, "op": "hide"} for i in range(1, 7)] \
            + [{"id": i, "op": "move", "lat": 41.3001, "lon": 69.2 + i * 0.001} for i in range(7, 12)]
        self.assertTrue(od.problems(3, items, 2, CAMERAS))

    def test_rollback_far_move_foreign_point_and_empty_type(self):
        found = od.problems(1, [
            {"id": 1, "op": "move", "lat": 41.31, "lon": 69.201},
            {"id": 2, "op": "move", "lat": 47.5, "lon": 69.2},
            {"id": 3, "op": "retype", "type": ""},
        ], 2, CAMERAS)
        text = "\n".join(found)
        self.assertIn("меньше опубликованной", text)
        self.assertIn("дальше 500 м", text)
        self.assertIn("вне Узбекистана у камеры 2", text)
        self.assertIn("пустой тип у камеры 3", text)


class PreviousTest(unittest.TestCase):

    def test_only_a_verified_envelope_counts_and_the_newest_wins(self):
        good_old = ("локальная", envelope(2, [{"id": 1, "op": "hide"}], sig="b2s="))
        good_new = ("сервер", envelope(3, [{"id": 2, "op": "hide"}], sig="b2s="))
        forged = ("подделка", envelope(9, [], sig="eA=="))
        verify = lambda data, sig: sig == "b2s="
        version, items, notes = od.verified_previous([good_old, forged, good_new], verify=verify)
        self.assertEqual(version, 3)
        self.assertEqual(items, [{"id": 2, "op": "hide"}])
        self.assertTrue(any("подделка" in n and "не сходится" in n for n in notes))

    def test_nothing_verified_means_diff_from_empty(self):
        version, items, notes = od.verified_previous(
            [("сервер", envelope(5, [{"id": 1, "op": "hide"}]))], verify=lambda d, s: None)
        self.assertEqual((version, items), (0, []), "неподписанной прошлой не верим — показываем всё")
        self.assertTrue(any("нечем" in n for n in notes))
        self.assertTrue(any("показываю все" in n for n in notes))

    def test_garbage_envelope_is_skipped(self):
        version, _, notes = od.verified_previous([("мусор", b"{")], verify=lambda d, s: True)
        self.assertEqual(version, 0)
        self.assertTrue(any("не читается" in n for n in notes))


class CliTest(unittest.TestCase):

    def test_exit_code_follows_problems(self):
        with tempfile.TemporaryDirectory() as tmp, contextlib.redirect_stdout(io.StringIO()):
            cams = os.path.join(tmp, "cameras.json")
            with open(cams, "w", encoding="utf-8") as handle:
                json.dump(list(CAMERAS.values()), handle, ensure_ascii=False)
            new = os.path.join(tmp, "new.payload")
            with open(new, "w") as handle:
                json.dump({"version": 1, "items": [{"id": 1, "op": "hide"}]}, handle)
            self.assertEqual(od.main(["--new", new, "--cameras", cams]), 0)
            with open(new, "w") as handle:
                json.dump({"version": 1, "items": [{"id": i, "op": "hide"} for i in range(1, 30)]}, handle)
            self.assertEqual(od.main(["--new", new, "--cameras", cams]), 1)
            with open(new, "w") as handle:
                handle.write('{"version": 1, "items": [{"id": 1, "op": "delete"}]}')
            self.assertEqual(od.main(["--new", new, "--cameras", cams]), 1, "не по контракту")


if __name__ == "__main__":
    unittest.main()
