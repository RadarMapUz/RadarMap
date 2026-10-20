"""Нормализация адресов реестра (план 11.6): кириллица внутри латинских слов,
адреса целиком кириллицей, «Tuman» с заглавной."""

import unittest

import update_cameras as uc


class AddressTest(unittest.TestCase):
    def test_homoglyphs_inside_latin_words(self):
        self.assertEqual(uc.smart("Dаhаsi"), "Dahasi")          # «а» — кириллица
        self.assertEqual(uc.smart("Ulug‘bеk"), "Ulug‘bek")
        self.assertEqual(uc.smart("Аmir Temur"), "Amir Temur")
        self.assertNotRegex(uc.smart("Kеsishgan Chorrahаsi"), "[А-Яа-я]")
        # Опечатки реестра — тоже в латиницу.
        self.assertEqual(uc.fold_word("Sаnъаt"), "Sanʼat")
        self.assertEqual(uc.fold_word("Punktи"), "Punkti")
        self.assertEqual(uc.fold_word("Aulы"), "Auli")

    def test_cyrillic_only_address_is_transliterated(self):
        self.assertEqual(uc.to_latin("Алишер Навоий - Пахтакор Кўчаси"), "Alisher Navoiy - Paxtakor Ko‘chasi")
        self.assertEqual(uc.to_latin("Янги Юнусобод - Юнусота Кўчалари Чорраҳаси"),
                         "Yangi Yunusobod - Yunusota Ko‘chalari Chorrahasi")
        # Дальше — обычное причёсывание регистра, но без единой кириллической буквы.
        self.assertNotRegex(uc.smart("Янги Юнусобод - Юнусота Кўчалари Чорраҳаси"), "[А-Яа-яЎўҚқҒғҲҳ]")

    def test_ye_at_word_start(self):
        self.assertEqual(uc.to_latin("Ер"), "Yer")
        self.assertEqual(uc.to_latin("Тепа"), "Tepa")

    def test_tuman_is_lowercase(self):
        self.assertEqual(uc.smart("ASAKA TUMAN"), "Asaka tuman")

    def test_pure_latin_is_not_transliterated(self):
        self.assertEqual(uc.to_latin("A-373 toshkent-o‘sh"), "A-373 toshkent-o‘sh")
        self.assertEqual(uc.fold_word("Toshkent"), "Toshkent")

if __name__ == "__main__":
    unittest.main()
