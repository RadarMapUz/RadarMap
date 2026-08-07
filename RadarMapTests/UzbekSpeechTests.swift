//
//  UzbekSpeechTests.swift
//  RadarMapTests
//
//  Узбекская речь турецким голосом. Проверяем главным образом числа и
//  диграфы: «камера, 300 метров» — это ровно та часть фразы, ради которой всё
//  и говорится, и прочитана она должна быть по-узбекски, а не по-турецки
//  и не по буквам.
//

import XCTest
@testable import RadarMap

final class UzbekSpeechTests: XCTestCase {

    // MARK: - Числительные

    func testUnitsAndTens() {
        XCTAssertEqual(UzbekSpeech.numeral(0), "nol")
        XCTAssertEqual(UzbekSpeech.numeral(7), "yetti")
        XCTAssertEqual(UzbekSpeech.numeral(10), "o‘n")
        XCTAssertEqual(UzbekSpeech.numeral(20), "yigirma")
        XCTAssertEqual(UzbekSpeech.numeral(45), "qirq besh")
        XCTAssertEqual(UzbekSpeech.numeral(90), "to‘qson")
    }

    func testHundredsAndThousands() {
        XCTAssertEqual(UzbekSpeech.numeral(100), "yuz", "сто по-узбекски просто «yuz»")
        XCTAssertEqual(UzbekSpeech.numeral(300), "uch yuz")
        XCTAssertEqual(UzbekSpeech.numeral(250), "ikki yuz ellik")
        XCTAssertEqual(UzbekSpeech.numeral(1000), "ming", "тысяча — «ming», не «bir ming»")
    }

    func testAllAnnouncedDistancesAreSpeakable() {
        // Радиус до километра, шаг 50 — весь диапазон, который может прозвучать.
        for distance in stride(from: 50, through: 1000, by: 50) {
            let words = UzbekSpeech.numeral(distance)
            XCTAssertFalse(words.contains(where: \.isNumber),
                           "\(distance) осталось цифрами: турецкий голос прочтёт его по-турецки")
            XCTAssertFalse(words.isEmpty)
        }
    }

    func testAllSpeedLimitsAreSpeakable() {
        for limit in stride(from: 20, through: 130, by: 10) {
            XCTAssertFalse(UzbekSpeech.numeral(limit).contains(where: \.isNumber))
        }
    }

    // MARK: - Орфография

    func testDigraphsSurviveAsSingleSounds() {
        // «sh» и «ch» разбираются раньше одиночных букв, иначе турецкий голос
        // произнесёт два звука вместо одного.
        XCTAssertEqual(UzbekSpeech.transliterate("shahar"), "şahar")
        XCTAssertEqual(UzbekSpeech.transliterate("cheklov"), "çeklov")
        XCTAssertEqual(UzbekSpeech.transliterate("oshirildi"), "oşirildi")
    }

    func testUzbekOnlyLettersAreMapped() {
        XCTAssertEqual(UzbekSpeech.transliterate("to‘rt"), "tört")
        XCTAssertEqual(UzbekSpeech.transliterate("qirq"), "kirk")
        XCTAssertEqual(UzbekSpeech.transliterate("xavf"), "havf")
        XCTAssertEqual(UzbekSpeech.transliterate("jami"), "cami")
    }

    func testNothingIsLeftUnreadable() {
        // После подстановки не должно остаться букв, которых нет в турецком
        // алфавите: их синтезатор либо пропустит, либо прочтёт по имени.
        let foreign = CharacterSet(charactersIn: "xqwXQW‘’ʼ")
        for phrase in ["Oldinda kameralar", "Tezlik oshirildi", "to‘qqiz yuz",
                       "qirq besh", "xavfli chorraha"] {
            let spoken = UzbekSpeech.transliterate(phrase)
            XCTAssertNil(spoken.rangeOfCharacter(from: foreign),
                         "в «\(spoken)» остались непроизносимые символы")
        }
    }

    // MARK: - Целиком

    func testFullAnnouncementIsSpoken() {
        // Числительные тоже проходят транслитерацию — иначе турецкий голос
        // прочтёт «uch» как «уч-х», а не как «уч».
        let phrase = UzbekSpeech.spoken("Kamera, 300 metr")
        XCTAssertEqual(phrase, "Kamera, uç yuz metr")
        XCTAssertFalse(phrase.contains(where: \.isNumber))
    }

    func testFullOverspeedPhrase() {
        let phrase = UzbekSpeech.spoken("Tezligingiz 95, cheklov 60")
        XCTAssertEqual(phrase, "Tezligingiz tökson beş, çeklov oltmiş")
    }

    func testRussianTextIsLeftAloneByTheCaller() {
        // Сам транслитератор к русскому не применяется — это забота AlertPlayer,
        // но убедимся, что кириллица через него проходит без порчи.
        XCTAssertEqual(UzbekSpeech.transliterate("Камера справа"), "Камера справа")
    }
}
