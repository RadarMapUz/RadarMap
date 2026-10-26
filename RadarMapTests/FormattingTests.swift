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
        XCTAssertFalse(Formatting.duration(3600).contains("0"), "ровно час — без «0 мин»")
        XCTAssertTrue(Formatting.duration(3660).contains("1"))
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

    // MARK: - Локаль чисел и неразрывность (Итоги, 11.10)

    /// Дробь — через запятую по языку приложения, а не точкой по региону
    /// телефона: «64.3 км» посреди русского текста.
    func testDecimalUsesCommaForRussianAndUzbek() {
        XCTAssertEqual(Formatting.decimal(1.25, locale: Locale(identifier: "ru")), "1,3")
        XCTAssertEqual(Formatting.decimal(1.25, locale: Locale(identifier: "uz")), "1,3")
        XCTAssertEqual(Formatting.decimal(12.04, locale: Locale(identifier: "ru")), "12,0")
    }

    /// Число не отрывается от единицы переносом строки: «2,2 / млн сум».
    func testNumbersStickToUnits() {
        XCTAssertFalse(Formatting.money(2_200_000).contains(" "))
        XCTAssertFalse(Formatting.money(440_000).contains(" "))
        XCTAssertFalse(Formatting.distance(12_400).contains(" "))
        XCTAssertFalse(Formatting.distance(850).contains(" "))
    }

    /// Заголовок поездки: день словами и время, год — только чужой.
    func testTripTitleSpeaksLikeAPerson() {
        let calendar = Calendar.current
        let now = Date()
        let today = Formatting.tripTitle(now, calendar: calendar, now: now)
        XCTAssertTrue(today.hasPrefix(Formatting.dayTitle(now, calendar: calendar)))
        let lastYear = calendar.date(byAdding: .year, value: -1, to: now)!
        let year = calendar.component(.year, from: lastYear)
        XCTAssertTrue(Formatting.tripTitle(lastYear, calendar: calendar, now: now).contains("\(year)"))
        XCTAssertFalse(today.contains("\(calendar.component(.year, from: now))"),
                       "текущий год в заголовке — шум")
    }

    // MARK: - Даты на языке приложения (отчёт качества 22.10, п. 7)

    /// Месяц и день недели — на языке приложения, не системы: при английской
    /// системе «October» посреди русского текста.
    func testDatesFollowTheAppLanguage() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tashkent")!
        let october = Date(timeIntervalSince1970: 1_792_000_000)   // октябрь 2026
        let ru = StatsPeriod.month.rangeTitle(containing: october, calendar: calendar,
                                              now: october, locale: Locale(identifier: "ru"))
        let uz = StatsPeriod.month.rangeTitle(containing: october, calendar: calendar,
                                              now: october, locale: Locale(identifier: "uz"))
        XCTAssertTrue(ru.lowercased().contains("октябр"), ru)
        XCTAssertNotEqual(ru, uz, "узбекский — своими словами")
        XCTAssertFalse((ru + uz).contains("October"))
        XCTAssertEqual(Formatting.date(october, .dateTime.month(.wide)),
                       october.formatted(.dateTime.month(.wide).locale(NumberFormat.locale)))
    }

    /// Дата со временем: дата — языком приложения, время — `clock` (12/24 ч
    /// по региону, единственное исключение из правила).
    func testDateAndClockJoinsAppDateWithRegionalClock() {
        let date = Date(timeIntervalSince1970: 1_792_000_000)
        let text = Formatting.dateAndClock(date)
        XCTAssertEqual(text, Formatting.date(date, Date.FormatStyle(date: .abbreviated, time: .omitted))
                       + ", " + Formatting.clock(date))
        XCTAssertEqual(Formatting.clock(date), NumberFormat.clock(date))
    }

    // MARK: - Подпись под числом (этап 31)

    /// Русское правило: 1, 21, 101 — одна; 2–4, 22–24 — несколько; 0, 5–20,
    /// 25–30, 111–114 — много. 11–14 — «много» при любой последней цифре.
    func testRussianPluralRule() {
        for n in [1, 21, 31, 101, 1001] { XCTAssertEqual(PluralRu.form(n), .one, "\(n)") }
        for n in [2, 3, 4, 22, 34, 102] { XCTAssertEqual(PluralRu.form(n), .few, "\(n)") }
        for n in [0, 5, 9, 10, 11, 12, 13, 14, 19, 20, 25, 111, 112, 114] {
            XCTAssertEqual(PluralRu.form(n), .many, "\(n)")
        }
    }

    /// Плитка «1 / камер» читалась «1 камер»: подпись склоняется по числу,
    /// а само число в ней не печатается — оно стоит в плитке крупно.
    func testMetricLabelsDeclineAndOmitTheNumber() {
        for count in [0, 1, 2, 5, 11, 21, 104] {
            XCTAssertFalse(Formatting.camerasLabel(count).contains { $0.isNumber })
            XCTAssertFalse(Formatting.tripsLabel(count).contains { $0.isNumber })
        }
        guard Bundle.main.preferredLocalizations.first == "ru" else { return }
        XCTAssertEqual(Formatting.camerasLabel(1), "камера")
        XCTAssertEqual(Formatting.camerasLabel(3), "камеры")
        XCTAssertEqual(Formatting.camerasLabel(5), "камер")
        XCTAssertEqual(Formatting.camerasLabel(21), "камера")
        XCTAssertEqual(Formatting.tripsLabel(1), "поездка")
        XCTAssertEqual(Formatting.tripsLabel(12), "поездок")
    }
}
