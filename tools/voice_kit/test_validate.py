"""Проверка записей: ловит пропуск, лишнее, формат, перегруз, громкость, края."""

import math
import os
import random
import tempfile
import unittest
import wave

import kit_audio
import validate

RATE = 48000


def speech_like(seconds, amplitude=0.3, seed=1):
    """Слог-подобный сигнал: тон 220 Гц с гармониками и шумом под огибающей."""
    rnd = random.Random(seed)
    n = int(seconds * RATE)
    out = []
    for i in range(n):
        t = i / RATE
        # Атака и спад по 20 мс, как у слога; середина — ровная.
        envelope = min(1.0, i / (0.02 * RATE), (n - i) / (0.02 * RATE))
        tone = math.sin(2 * math.pi * 220 * t) + 0.5 * math.sin(2 * math.pi * 440 * t) \
            + 0.25 * math.sin(2 * math.pi * 1320 * t)
        out.append(amplitude * envelope * (tone / 1.75 + 0.05 * rnd.uniform(-1, 1)))
    return out


def delivered(seconds=0.8, edge=0.02, target=-16.0):
    """Отрывок «как из студии»: края `edge` с, громкость `target`."""
    body = kit_audio.normalize(speech_like(seconds), RATE, target, -1.5)
    pad = [0.0] * int(edge * RATE)
    return pad + body + pad


def write_raw(path, samples, rate=RATE, width=3, channels=1):
    with wave.open(path, "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(width)
        w.setframerate(rate)
        frames = bytearray()
        for s in samples:
            v = int(max(-1.0, min(1.0, s)) * ((1 << (8 * width - 1)) - 1))
            chunk = v.to_bytes(width, "little", signed=True)
            frames += chunk * channels
        w.writeframes(bytes(frames))


class LoudnessTest(unittest.TestCase):

    def test_sine_matches_bs1770_calibration(self):
        # 997 Гц синус с пиком −20 dBFS по BS.1770 — −23,0 LUFS (моно).
        samples = [0.1 * math.sin(2 * math.pi * 997 * i / RATE) for i in range(RATE * 2)]
        self.assertAlmostEqual(kit_audio.loudness_lufs(samples, RATE), -23.0, delta=0.3)

    def test_normalize_hits_target_without_exceeding_ceiling(self):
        samples = kit_audio.normalize(speech_like(1.0, amplitude=0.05), RATE, -16.0, -1.0)
        self.assertAlmostEqual(kit_audio.loudness_lufs(samples, RATE), -16.0, delta=0.5)
        self.assertLessEqual(kit_audio.db(kit_audio.peak(samples)), -1.0 + 1e-6)

    def test_silence_is_minus_infinity(self):
        self.assertEqual(kit_audio.loudness_lufs([0.0] * RATE, RATE), float("-inf"))

    def test_wav_round_trip_keeps_24_bit(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "x.wav")
            source = speech_like(0.3)
            kit_audio.write_wav(path, source)
            info = kit_audio.read_wav(path)
            self.assertEqual((info.rate, info.width, info.channels), (RATE, 3, 1))
            self.assertEqual(len(info.samples), len(source))
            self.assertLess(max(abs(a - b) for a, b in zip(info.samples, source)), 1e-6)


class ValidateTest(unittest.TestCase):

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = self.dir.name
        self.rows = [{"id": "kind.radar", "text": "Radar"}, {"id": "dist.300", "text": "uch yuz metr"}]

    def tearDown(self):
        self.dir.cleanup()

    def put(self, segment, samples=None, **kwargs):
        samples = delivered() if samples is None else samples
        if kwargs:
            write_raw(os.path.join(self.path, segment + ".wav"), samples, **kwargs)
        else:
            kit_audio.write_wav(os.path.join(self.path, segment + ".wav"), samples)

    def errors(self):
        return [(i.segment, i.message) for i in validate.validate(self.path, self.rows) if i.level == "ошибка"]

    def test_clean_delivery_passes(self):
        self.put("kind.radar", delivered(0.6))
        self.put("dist.300", delivered(1.0))
        self.assertEqual(self.errors(), [])

    def test_missing_and_extra_files(self):
        self.put("kind.radar")
        self.put("kind.raadar")
        errors = self.errors()
        self.assertIn("dist.300", [segment for segment, _ in errors])
        self.assertTrue(any(segment == "kind.raadar" and "лишний" in message for segment, message in errors))

    def test_wrong_format(self):
        self.put("kind.radar", delivered(), rate=44100)
        self.put("dist.300", delivered(), width=2, channels=2)
        messages = " ".join(message for _, message in self.errors())
        self.assertIn("44100", messages)
        self.assertIn("16 бит", messages)
        self.assertIn("моно", messages)

    def test_clipping(self):
        clipped = [max(-1.0, min(1.0, 4 * s)) for s in delivered()]
        self.put("kind.radar", clipped)
        self.put("dist.300")
        self.assertTrue(any("клиппинг" in message for _, message in self.errors()))

    def test_loudness_far_off_target(self):
        self.put("kind.radar", delivered(target=-30.0))
        self.put("dist.300")
        self.assertTrue(any("громкость" in message for _, message in self.errors()))

    def test_long_silence_at_edges(self):
        self.put("kind.radar", delivered(edge=0.2))
        self.put("dist.300")
        self.assertTrue(any("тишина по краям" in message for _, message in self.errors()))

    def test_too_short(self):
        self.put("kind.radar", delivered(seconds=0.05, edge=0.01))
        self.put("dist.300")
        self.assertTrue(any("коротко" in message for _, message in self.errors()))

    def test_script_reader_handles_quoted_commas(self):
        with tempfile.NamedTemporaryFile("w", suffix=".csv", delete=False, encoding="utf-8") as f:
            f.write('id,text,example,position,note\np.report_accepted,"Qabul qilindi, rahmat",x,отдельно,\n')
        try:
            rows = validate.read_script(f.name)
        finally:
            os.remove(f.name)
        self.assertEqual(rows[0]["text"], "Qabul qilindi, rahmat")

    def test_real_script_ids_are_file_names(self):
        here = os.path.dirname(os.path.abspath(__file__))
        rows = validate.read_script(os.path.join(here, "script_uz.csv"))
        self.assertGreater(len(rows), 100)
        self.assertEqual(len({r["id"] for r in rows}), len(rows))


if __name__ == "__main__":
    unittest.main()
