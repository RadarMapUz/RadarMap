"""Сборка пакета: обрезка, громкость, манифест с sha, бюджет, AAC."""

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

import build_pack
import kit_audio
import make_placeholder
from test_validate import RATE, delivered, speech_like


def copy_encoder(source, target, bitrate):
    """Кодер для тестов: без afconvert, файл как есть."""
    shutil.copyfile(source, target)


class ProcessTest(unittest.TestCase):

    def test_trims_edges_and_levels(self):
        samples = [0.0] * int(0.3 * RATE) + kit_audio.apply_gain(speech_like(0.8), -12) + [0.0] * int(0.3 * RATE)
        out = build_pack.process(samples, RATE)
        lead, tail = kit_audio.edge_silence(out, RATE)
        self.assertLessEqual(lead, 0.05)
        self.assertLessEqual(tail, 0.05)
        self.assertAlmostEqual(kit_audio.loudness_lufs(out, RATE), -16.0, delta=0.8)
        self.assertLessEqual(kit_audio.db(kit_audio.peak(out)), -1.0 + 1e-6)
        self.assertEqual(out[0], 0.0, "мягкий вход: первый сэмпл в нуле")


class BuildTest(unittest.TestCase):

    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.recordings = os.path.join(self.work.name, "rec")
        self.out = os.path.join(self.work.name, "voice-uz.bundle")
        os.makedirs(self.recordings)
        self.rows = [{"id": "kind.radar", "text": "Radar"}, {"id": "dist.300", "text": "uch yuz metr"}]
        for row, seconds in zip(self.rows, (0.6, 1.0)):
            kit_audio.write_wav(os.path.join(self.recordings, row["id"] + ".wav"), delivered(seconds))

    def tearDown(self):
        self.work.cleanup()

    def test_manifest_lists_every_segment_with_sha(self):
        manifest = build_pack.build(self.recordings, self.rows, self.out, "uz", "тест",
                                    encoder=copy_encoder)
        self.assertEqual(manifest["format"], 1)
        self.assertFalse(manifest["placeholder"])
        self.assertEqual(manifest["sampleRate"], 48000)
        self.assertEqual(set(manifest["segments"]), {"kind.radar", "dist.300"})
        for segment, entry in manifest["segments"].items():
            path = os.path.join(self.out, entry["file"])
            with open(path, "rb") as f:
                self.assertEqual(entry["sha256"], hashlib.sha256(f.read()).hexdigest())
            self.assertGreater(entry["duration"], 0.3)
        with open(os.path.join(self.out, "manifest.json"), encoding="utf-8") as f:
            self.assertEqual(json.load(f), manifest)

    def test_placeholder_flag_and_stale_files_removed(self):
        os.makedirs(self.out)
        with open(os.path.join(self.out, "old.segment.m4a"), "wb") as f:
            f.write(b"stale")
        manifest = build_pack.build(self.recordings, self.rows, self.out, "uz", "say", placeholder=True,
                                    encoder=copy_encoder)
        self.assertTrue(manifest["placeholder"])
        self.assertFalse(os.path.exists(os.path.join(self.out, "old.segment.m4a")))

    def test_refuses_when_validation_fails(self):
        os.remove(os.path.join(self.recordings, "dist.300.wav"))
        with self.assertRaises(build_pack.BuildError):
            build_pack.build(self.recordings, self.rows, self.out, "uz", "тест", encoder=copy_encoder)

    def test_refuses_over_budget(self):
        with self.assertRaises(build_pack.BuildError):
            build_pack.build(self.recordings, self.rows, self.out, "uz", "тест", encoder=copy_encoder,
                             budget=1000)

    @unittest.skipUnless(sys.platform == "darwin" and shutil.which("afconvert"), "afconvert только на macOS")
    def test_real_aac_keeps_48k_and_duration(self):
        manifest = build_pack.build(self.recordings, self.rows, self.out, "uz", "тест", bitrate=32000)
        entry = manifest["segments"]["dist.300"]
        info = subprocess.run(["afinfo", os.path.join(self.out, entry["file"])],
                              capture_output=True, text=True, check=True).stdout
        self.assertIn("48000 Hz", info, "низкий битрейт не должен уронить частоту")
        frames = int(info.split(" valid frames")[0].split()[-1])
        self.assertAlmostEqual(frames / 48000.0, entry["duration"], delta=0.001,
                               msg="задержка кодера учтена в контейнере — без паузы на стыке")


class PlaceholderTest(unittest.TestCase):

    def test_transliteration_matches_app_synthesizer(self):
        # Те же замены, что UzbekSpeech в приложении.
        self.assertEqual(make_placeholder.transliterate("oʻngga buriling"), "öngga buriling")
        self.assertEqual(make_placeholder.transliterate("Oldinda tirbandlik"), "Oldinda tirbandlik")
        self.assertEqual(make_placeholder.transliterate("keyinroq yuboraman"), "keyinrok yuboraman")
        self.assertEqual(make_placeholder.transliterate("chiqish"), "çikiş")
        self.assertEqual(make_placeholder.transliterate("Intellektual kamera + radar"),
                         "Intellektual kamera va radar")


if __name__ == "__main__":
    unittest.main()
