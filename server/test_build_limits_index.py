#!/usr/bin/env python3
"""Индекс подписанных лимитов: sha, размеры, схема и ворота перед подписью.

Большинство тестов — про то, что НЕ должно уйти под подпись: пара v1/v2 из
разных прогонов крона, перепутанные файлы, обрезанная выгрузка. Подписанное
доезжает до всех телефонов, и ошибку там уже не отозвать тихо.
"""
import hashlib
import json
import os
import re
import tempfile
import unittest

import build_limits_index as bli

# Тот же забор, что принимает LimitsManifest.isSafeName на телефоне: имя
# — путь внутри вебрута, без «..» и без чужих символов.
CLIENT_NAME = re.compile(r"^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$")

MIN = 3  # порог сегментов для маленьких наборов в тестах


def modern_segments(count=4, limit=60):
    return [[limit + i % 3 * 10, 3, [41.3 + i * 1e-3, 69.2, 41.301 + i * 1e-3, 69.201]]
            for i in range(count)]


def files_for(segments, version=1_759_000_000):
    """Пара файлов ровно так, как её пишет extract_speed_limits.main()."""
    legacy = [[limit, flat] for limit, _cls, flat in segments]
    v1 = json.dumps({"version": version, "segments": legacy}, separators=(",", ":")).encode()
    v2 = json.dumps({"version": version, "format": 2, "segments": segments},
                    separators=(",", ":")).encode()
    return {1: v1, 2: v2}


class PayloadTest(unittest.TestCase):
    def setUp(self):
        self.files = files_for(modern_segments())
        self.payload = bli.build_payload(self.files, built=1_760_000_000, min_segments=MIN)

    def test_sha_and_size_are_of_the_exact_bytes(self):
        # Телефон хэширует РОВНО скачанные байты; любая перекодировка здесь
        # дала бы sha, которому не соответствует ни один файл на сервере.
        for entry in self.payload["files"]:
            data = self.files[entry["format"]]
            self.assertEqual(entry["sha256"], hashlib.sha256(data).hexdigest())
            self.assertEqual(entry["bytes"], len(data))

    def test_schema_is_the_client_contract(self):
        self.assertEqual(sorted(self.payload), ["built", "files", "format", "version"])
        self.assertEqual(self.payload["format"], bli.INDEX_FORMAT)
        self.assertEqual(self.payload["version"], 1_759_000_000)
        self.assertEqual(self.payload["built"], 1_760_000_000)
        for entry in self.payload["files"]:
            self.assertEqual(sorted(entry), ["bytes", "format", "name", "segments", "sha256"])
            self.assertRegex(entry["sha256"], r"^[0-9a-f]{64}$")
            self.assertRegex(entry["name"], CLIENT_NAME)
            self.assertNotIn("..", entry["name"])
            self.assertEqual(entry["segments"], 4)

    def test_newest_format_first(self):
        self.assertEqual([entry["format"] for entry in self.payload["files"]], [2, 1])

    def test_name_is_content_addressed(self):
        # Крон переписывает speed_limits*.json на месте; подписанная копия
        # обязана жить по адресу, содержимое которого не меняется никогда.
        entry = self.payload["files"][0]
        self.assertEqual(entry["name"],
                         "limits/speed_limits_v2.%s.json" % entry["sha256"][:16])
        other = bli.build_payload(files_for(modern_segments(limit=70)), min_segments=MIN)
        self.assertNotEqual(other["files"][0]["name"], entry["name"])
        same = bli.build_payload(files_for(modern_segments()), min_segments=MIN)
        self.assertEqual(same["files"][0]["name"], entry["name"])

    def test_encoding_is_deterministic(self):
        again = bli.build_payload(files_for(modern_segments()), built=1_760_000_000,
                                  min_segments=MIN)
        self.assertEqual(bli.encode_payload(again), bli.encode_payload(self.payload))
        self.assertEqual(json.loads(bli.encode_payload(self.payload)), self.payload)

    def test_v2_alone_is_enough(self):
        payload = bli.build_payload({2: self.files[2]}, min_segments=MIN)
        self.assertEqual([entry["format"] for entry in payload["files"]], [2])


class GateTest(unittest.TestCase):
    def test_pair_from_two_cron_runs_is_refused(self):
        # Главный сценарий: крон пишет v1, потом v2, а забрали посередине.
        old = files_for(modern_segments(), version=1)
        new = files_for(modern_segments(limit=70), version=2)
        with self.assertRaisesRegex(ValueError, "разных сборок"):
            bli.build_payload({1: new[1], 2: old[2]}, min_segments=MIN)

    def test_same_version_but_different_limits_is_refused(self):
        a = files_for(modern_segments())
        b = files_for(modern_segments(limit=80))
        with self.assertRaisesRegex(ValueError, "расходятся"):
            bli.build_payload({1: b[1], 2: a[2]}, min_segments=MIN)

    def test_different_lengths_are_refused(self):
        a = files_for(modern_segments(count=4))
        b = files_for(modern_segments(count=5))
        with self.assertRaisesRegex(ValueError, "разной длины"):
            bli.build_payload({1: b[1], 2: a[2]}, min_segments=MIN)

    def test_swapped_files_are_refused(self):
        files = files_for(modern_segments())
        with self.assertRaises(ValueError):
            bli.build_payload({1: files[2], 2: files[1]}, min_segments=MIN)

    def test_truncated_extract_is_refused(self):
        files = files_for(modern_segments(count=2))
        with self.assertRaisesRegex(ValueError, "обрезана"):
            bli.build_payload(files, min_segments=MIN)

    def test_default_threshold_is_the_cron_gate(self):
        # Порог один на весь конвейер: тот, что стоит у самого крона.
        files = files_for(modern_segments(count=10))
        with self.assertRaisesRegex(ValueError, "обрезана"):
            bli.build_payload(files)

    def test_broken_geometry_is_refused(self):
        segments = modern_segments()
        segments[1][2] = [41.3, 69.2, 41.31]          # нечётная длина
        with self.assertRaisesRegex(ValueError, "геометрия"):
            bli.build_payload({2: files_for(segments)[2]}, min_segments=MIN)
        segments[1][2] = [41.3, 69.2, True, 69.3]     # не число
        with self.assertRaisesRegex(ValueError, "геометрия"):
            bli.build_payload({2: files_for(segments)[2]}, min_segments=MIN)

    def test_non_integer_limit_is_refused(self):
        segments = modern_segments()
        segments[0][0] = "60"
        with self.assertRaisesRegex(ValueError, "не целое"):
            bli.build_payload({2: files_for(segments)[2]}, min_segments=MIN)

    def test_not_json_is_refused(self):
        with self.assertRaisesRegex(ValueError, "не JSON"):
            bli.build_payload({2: b"<html>502</html>"}, min_segments=MIN)

    def test_nothing_to_sign_is_refused(self):
        with self.assertRaises(ValueError):
            bli.build_payload({}, min_segments=MIN)
        with self.assertRaises(ValueError):
            bli.build_payload({3: b"{}"}, min_segments=MIN)


class StageTest(unittest.TestCase):
    def test_stage_holds_exactly_the_signed_bytes(self):
        # То, что уедет на VPS, обязано сходиться с тем, что подписано.
        files = files_for(modern_segments())
        payload = bli.build_payload(files, min_segments=MIN)
        with tempfile.TemporaryDirectory() as out:
            bli.write_stage(out, files, payload)
            for entry in payload["files"]:
                with open(os.path.join(out, entry["name"]), "rb") as handle:
                    self.assertEqual(hashlib.sha256(handle.read()).hexdigest(), entry["sha256"])
            with open(os.path.join(out, "index_payload.json"), "rb") as handle:
                self.assertEqual(handle.read(), bli.encode_payload(payload))

    def test_main_refuses_and_writes_nothing(self):
        files = files_for(modern_segments(count=2))
        with tempfile.TemporaryDirectory() as work:
            paths = {}
            for fmt, data in files.items():
                paths[fmt] = os.path.join(work, "in_%d.json" % fmt)
                with open(paths[fmt], "wb") as handle:
                    handle.write(data)
            out = os.path.join(work, "stage")
            code = bli.main(["--v1", paths[1], "--v2", paths[2], "--out", out])
            self.assertEqual(code, 1)
            self.assertFalse(os.path.exists(os.path.join(out, "index_payload.json")))


if __name__ == "__main__":
    unittest.main()
