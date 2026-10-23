"""Тесты чистой части synth_navoiy.py — без torch и без модели."""

import math
import unittest

import kit_audio
import synth_navoiy as s
import validate

RATE = 48000


def tone(seconds, freq=220.0, amp=0.3):
    return [amp * math.sin(2 * math.pi * freq * i / RATE) for i in range(int(seconds * RATE))]


def silence(seconds):
    return [0.0] * int(seconds * RATE)


class TextTests(unittest.TestCase):

    def test_apostrophes_become_straight(self):
        self.assertEqual(s.spoken_text("Koʻchma radar oʻngda"), "Ko'chma radar o'ngda")
        self.assertEqual(s.spoken_text("Sunʼiy yoʻldosh"), "Sun'iy yo'ldosh")

    def test_plus_and_abbreviations_are_words(self):
        self.assertEqual(s.spoken_text("Intellektual kamera + radar"), "Intellektual kamera va radar")
        self.assertEqual(s.spoken_text("YPX posti"), "ye-pe-xa posti")
        self.assertEqual(s.spoken_text("YTH"), "ye-te-xa")

    def test_dash_is_a_pause(self):
        self.assertEqual(s.spoken_text("Safar boshlandi — kameralarni kuzatyapman"),
                         "Safar boshlandi, kameralarni kuzatyapman")

    def test_syllables_count_vowels_and_o_with_mark_once(self):
        self.assertEqual(s.syllables("oʻngga buriling"), 5)
        self.assertEqual(s.syllables("Statsionar radar"), 6)

    def test_position_decides_intonation(self):
        self.assertTrue(s.is_non_final("начало"))
        self.assertTrue(s.is_non_final("середина, конец"))
        self.assertTrue(s.is_non_final("начало, середина, отдельно"))
        self.assertFalse(s.is_non_final("конец"))
        self.assertFalse(s.is_non_final("конец, отдельно"))
        self.assertFalse(s.is_non_final("отдельно"))

    def test_carrier_takes_real_continuation_from_example(self):
        self.assertEqual(s.carrier("Oldinda tirbandlik", "Oldinda tirbandlik, taxminan uch yuz metr, qoʻshimcha toʻrt daqiqa"),
                         "Oldinda tirbandlik, taxminan uch yuz metr, qo'shimcha to'rt daqiqa.")

    def test_carrier_falls_back_to_neutral_tail(self):
        self.assertEqual(s.carrier("oldinda", "Statsionar kamera oldinda, besh yuz metr"), "oldinda, uch yuz metr.")
        # Продолжение из одного слова — мало контекста, берётся нейтральное.
        self.assertEqual(s.carrier("Yuborilmadi", "Yuborilmadi, aloqa"), "Yuborilmadi, uch yuz metr.")

    def test_plan_by_position(self):
        self.assertEqual(s.plan({"text": "Kamera", "example": "Kamera, uch yuz metr", "position": "начало"})[0],
                         "carrier")
        method, text = s.plan({"text": "chapga buriling", "example": "", "position": "середина, конец, отдельно"})
        self.assertEqual(method, "carrier")
        method, text = s.plan({"text": "Tezlik oshirildi", "example": "", "position": "отдельно"})
        self.assertEqual((method, text), ("standalone", "Tezlik oshirildi."))
        self.assertEqual(s.standalone("Rahmat!", final=True), "Rahmat!")
        self.assertEqual(s.standalone("oldinda", final=False), "oldinda")

    def test_references_are_names_not_paths(self):
        self.assertEqual(set(s.REFERENCES), {"female", "male"})
        for name in s.REFERENCES.values():
            self.assertNotIn("/", name)


class AudioTests(unittest.TestCase):

    def test_cut_point_finds_the_comma_pause(self):
        # «отрывок» 0,6 с, пауза 0,2 с, продолжение 1,2 с; отрывок — треть слогов.
        audio = silence(0.05) + tone(0.6) + silence(0.2) + tone(1.2) + silence(0.05)
        cut = s.cut_point(audio, RATE, segment_syllables=3, carrier_syllables=9)
        self.assertIsNotNone(cut)
        self.assertGreater(cut, 0.64)
        self.assertLess(cut, 0.70)

    def test_cut_point_skips_a_stop_closure_inside_the_word(self):
        # «qirq, uch yuz metr»: смычка 80 мс перед последним «q», потом пауза
        # запятой 200 мс — резать по запятой, а не посреди слова.
        audio = tone(0.30) + silence(0.08) + tone(0.10) + silence(0.20) + tone(1.1)
        cut = s.cut_point(audio, RATE, segment_syllables=1, carrier_syllables=4)
        self.assertGreater(cut, 0.48)
        self.assertLess(cut, 0.52)

    def test_cut_point_takes_the_pause_nearest_to_the_expected_place(self):
        # «Statsionar radar, oldinda, besh yuz metr»: две паузы запятых, отрывок
        # — 6 слогов из 15: первая.
        audio = tone(1.2) + silence(0.26) + tone(0.6) + silence(0.3) + tone(1.0)
        cut = s.cut_point(audio, RATE, segment_syllables=6, carrier_syllables=15)
        self.assertGreater(cut, 1.2)
        self.assertLess(cut, 1.25)

    def test_cut_point_rejects_a_pause_far_from_expected(self):
        # Пауза у самого начала — не конец отрывка из половины фразы.
        audio = tone(0.1) + silence(0.2) + tone(2.0)
        self.assertIsNone(s.cut_point(audio, RATE, segment_syllables=5, carrier_syllables=10))

    def test_cut_point_none_without_pause(self):
        self.assertIsNone(s.cut_point(tone(2.0), RATE, 3, 9))

    def test_duration_score_prefers_plausible_length(self):
        text = "Statsionar radar"   # 6 слогов, ~1,4 с
        self.assertLess(s.duration_score(1.4, text), s.duration_score(4.0, text))
        self.assertLess(s.duration_score(1.4, text), s.duration_score(0.4, text))

    def test_take_score_penalizes_a_stray_pause_without_punctuation(self):
        clean = tone(0.6) + silence(0.05) + tone(0.6)
        stray = tone(0.6) + silence(0.3) + tone(0.6)
        text = "Marshrut qayta qurildi"
        self.assertLess(s.take_score(clean, text), s.take_score(stray, text))
        # С запятой пауза законна — штрафа нет.
        comma = "Qabul qilindi, rahmat"
        self.assertLess(s.take_score(stray, comma) - s.duration_score(1.5, comma), 0.5)

    def test_resample_linear_length(self):
        self.assertEqual(len(s.resample_linear([0.0] * 24000, 24000, 48000)), 48000)

    def test_studio_spec_passes_validation(self):
        import os
        import tempfile
        audio = silence(0.3) + tone(0.9, amp=0.05) + silence(0.4)
        out = s.to_studio_spec(audio, RATE)
        with tempfile.TemporaryDirectory() as work:
            path = os.path.join(work, "x.wav")
            kit_audio.write_wav(path, out, RATE)
            issues = [i for i in validate.check_file("x", path) if i.level == "ошибка"]
        self.assertEqual(issues, [])
        self.assertAlmostEqual(kit_audio.loudness_lufs(out, RATE), -16.0, delta=0.5)
        self.assertLessEqual(kit_audio.db(kit_audio.peak(out)), -1.0)

    def test_studio_spec_gives_sound_from_first_sample_a_soft_lead(self):
        out = s.to_studio_spec(tone(0.8, amp=0.2), RATE)
        lead, tail = kit_audio.edge_silence(out, RATE)
        self.assertGreaterEqual(lead, validate.EDGE_MIN)
        self.assertLessEqual(lead, validate.EDGE_MAX)
        self.assertLessEqual(tail, validate.EDGE_MAX)

    def test_soft_limit_keeps_quiet_samples(self):
        self.assertEqual(s.soft_limit([0.1, -0.2]), [0.1, -0.2])
        self.assertLessEqual(max(abs(v) for v in s.soft_limit([0.99, -1.0])), 10 ** (-1.2 / 20) + 1e-9)


if __name__ == "__main__":
    unittest.main()
