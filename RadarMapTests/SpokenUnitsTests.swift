//
//  SpokenUnitsTests.swift
//  RadarMapTests
//
//  Подписи VoiceOver (14.6): числа те же, что на экране, а единицы — полными
//  словами в нужной форме («1 минута», «2 минуты», «5 минут»; uz «5 daqiqa»).
//  Главное, что ловится здесь: голос не должен разойтись с цифрой на экране —
//  `Formatting.duration` отбрасывает секунды, и голос обязан тоже.
//

import XCTest
@testable import RadarMap

final class SpokenUnitsTests: XCTestCase {
    private let ru = Locale(identifier: "ru")
    private let uz = Locale(identifier: "uz")

    func testDurationWordsAndForms() {
        XCTAssertEqual(SpokenUnits.duration(60, locale: ru), "1 минута")
        XCTAssertEqual(SpokenUnits.duration(120, locale: ru), "2 минуты")
        XCTAssertEqual(SpokenUnits.duration(2100, locale: ru), "35 минут")
        XCTAssertEqual(SpokenUnits.duration(3600, locale: ru), "1 час", "ноль минут не говорится")
        XCTAssertEqual(SpokenUnits.duration(4980, locale: ru), "1 час 23 минуты")
        XCTAssertEqual(SpokenUnits.duration(2100, locale: uz), "35 daqiqa")
        XCTAssertEqual(SpokenUnits.duration(4980, locale: uz), "1 soat 23 daqiqa")
    }

    func testDurationMatchesScreenNumber() {
        // 42 мин 59 с на экране — «42 мин», голосом — тоже 42, не 43.
        let seconds: TimeInterval = 42 * 60 + 59
        XCTAssertTrue(Formatting.duration(seconds).hasPrefix("42"))
        XCTAssertEqual(SpokenUnits.duration(seconds, locale: ru), "42 минуты")
        XCTAssertEqual(SpokenUnits.duration(45, locale: ru), "45 секунд", "меньше минуты — секундами, как на экране")
    }

    func testExactMinutes() {
        XCTAssertEqual(SpokenUnits.minutes(8, locale: ru), "8 минут")
        XCTAssertEqual(SpokenUnits.minutes(21, locale: ru), "21 минута")
        XCTAssertEqual(SpokenUnits.minutes(90, locale: ru), "1 час 30 минут")
        XCTAssertEqual(SpokenUnits.minutes(8, locale: uz), "8 daqiqa")
    }

    func testDistanceRoundsLikeScreen() {
        XCTAssertEqual(SpokenUnits.distance(330, locale: ru), "330 метров")
        XCTAssertEqual(SpokenUnits.distance(21.4, locale: ru), "21 метр")
        XCTAssertEqual(SpokenUnits.distance(1_400, locale: ru), "1,4 километра")
        XCTAssertEqual(SpokenUnits.distance(12_000, locale: ru), "12 километров",
                       "«12,0» голосом — лишние «ноль десятых»")
        XCTAssertEqual(SpokenUnits.distance(129_460, locale: ru), "129 километров", "от сотни — целыми")
        XCTAssertEqual(SpokenUnits.distance(330, locale: uz), "330 metr")
        XCTAssertEqual(SpokenUnits.distance(1_400, locale: uz), "1,4 kilometr")
    }

    func testNoAbbreviationsLeft() {
        // Ровно то, ради чего всё: ни «мин», ни «км», ни «м» отдельным словом.
        for text in [SpokenUnits.duration(2520, locale: ru), SpokenUnits.distance(850, locale: ru),
                     SpokenUnits.distance(64_300, locale: ru)] {
            let words = text.split(separator: " ").map(String.init)
            XCTAssertFalse(words.contains("мин"), text)
            XCTAssertFalse(words.contains("км"), text)
            XCTAssertFalse(words.contains("м"), text)
        }
    }
}
