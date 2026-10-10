//
//  FormattingTests.swift
//  RadarMapTests
//
//  Числа, которые водитель читает на ходу: расстояние, время, деньги, баллы.
//
//  Одно правило на всё приложение и виджет — раньше их было три, и цифры
//  расходились («129,5 км» в плитке против «130 км» в итогах). Здесь стерегут
//  ГРАНИЦЫ правил, а не текст единиц: «м»/«km» зависят от языка приложения,
//  а граница «до километра — в метрах» от языка не зависит.
//

import XCTest
@testable import RadarMap

final class FormattingTests: XCTestCase {

    private func hasDecimal(_ text: String, _ digits: String) -> Bool {
        text.contains(digits.replacingOccurrences(of: ".", with: ","))
            || text.contains(digits)
    }

    // MARK: - Расстояние

    func testMetersBelowAKilometre() {
        XCTAssertTrue(Formatting.distance(849.6).contains("850"))
        // 999 м — ещё метры: «1,0 км» при 999 метрах врало бы на метр, а
        // главное — прыгало бы туда-обратно на границе.
        XCTAssertTrue(Formatting.distance(999.4).contains("999"))
    }

    func testKilometresWithOneDecimalBelowAHundred() {
        XCTAssertTrue(hasDecimal(Formatting.distance(1_449), "1.4"))
        XCTAssertTrue(hasDecimal(Formatting.distance(12_400), "12.4"))
    }

    func testNoDecimalFromAHundredKilometres() {
        let text = Formatting.distance(123_456)
        XCTAssertTrue(text.contains("123"))
        XCTAssertFalse(hasDecimal(text, "123.5"), "дальше сотни — без десятой")
    }

    // MARK: - Время

    func testDurationSteps() {
        XCTAssertTrue(Formatting.duration(59).contains("59"), "меньше минуты — секунды")
        XCTAssertTrue(Formatting.duration(60).contains("1"))
        XCTAssertFalse(Formatting.duration(60).contains("60"), "ровно минута — уже минуты")
        let hour = Formatting.duration(3_661)
        XCTAssertNotEqual(hour, Formatting.duration(61), "час не сливается с минутой")
        XCTAssertTrue(hour.contains("1"))
    }

    func testDurationRoundsToWholeSeconds() {
        XCTAssertEqual(Formatting.duration(59.6), Formatting.duration(60))
    }

    // MARK: - Деньги

    func testSumsGroupThousandsWithNarrowSpace() {
        XCTAssertTrue(Formatting.money(440_000).contains("440\u{202F}000"))
    }

    func testMillionsKeepOneDecimalOnlyWhenNeeded() {
        let whole = Formatting.money(2_000_000)
        XCTAssertTrue(whole.contains("2"))
        XCTAssertFalse(hasDecimal(whole, "2.0"), "«2 млн», а не «2,0 млн»")
        // 1 250 000 → 12,5 сотен тысяч → округление вверх → 1,3 млн.
        XCTAssertTrue(hasDecimal(Formatting.money(1_250_000), "1.3"))
    }

    // MARK: - Баллы

    func testPointsShowZeroForNoise() {
        XCTAssertEqual(Formatting.points(0.04), "0")
        XCTAssertTrue(Formatting.points(12.6).hasPrefix("−12"))
    }
}
