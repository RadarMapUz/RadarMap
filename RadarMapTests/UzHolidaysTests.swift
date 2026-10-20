//
//  UzHolidaysTests.swift
//  RadarMapTests
//
//  Праздники Узбекистана как выходной класс (8.8.13): каждый год списка,
//  перенос праздника из выходного на ближайший рабочий день, и что срок
//  «быть к 9:00» и будничная выборка призрака их видят.
//

import XCTest
@testable import RadarMap

final class UzHolidaysTests: XCTestCase {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func holiday(_ year: Int, _ month: Int, _ d: Int) -> Bool {
        UzHolidays.isHoliday(day(year, month, d), calendar: utc)
    }

    /// 2026 — объявленные даты: Рамазан 20 марта (пт), Навруз 21-го (сб) →
    /// понедельник 23-го; 8 марта (вс) → 9-е; 9 мая (сб) → 11-е; Курбан
    /// 27 мая и нерабочие 28–29 мая.
    func test2026() {
        for (m, d) in [(1, 1), (3, 8), (3, 9), (3, 20), (3, 21), (3, 23), (5, 9), (5, 11),
                       (5, 27), (5, 28), (5, 29), (9, 1), (10, 1), (12, 8)] {
            XCTAssertTrue(holiday(2026, m, d), "2026-\(m)-\(d)")
        }
        for (m, d) in [(3, 24), (5, 26), (6, 1), (9, 2), (10, 20)] {
            XCTAssertFalse(holiday(2026, m, d), "будний 2026-\(m)-\(d)")
        }
    }

    /// 2027 (оценка хайитов): Рамазан 9 марта; Навруз в воскресенье → 22-е;
    /// 9 мая (вс) → 10-е; Курбан 16 мая (вс) → 17-е.
    func test2027() {
        for (m, d) in [(1, 1), (3, 8), (3, 9), (3, 21), (3, 22), (5, 9), (5, 10), (5, 16), (5, 17),
                       (9, 1), (10, 1), (12, 8)] {
            XCTAssertTrue(holiday(2027, m, d), "2027-\(m)-\(d)")
        }
        XCTAssertFalse(holiday(2027, 3, 10))
        XCTAssertFalse(holiday(2027, 5, 18))
    }

    /// 2028 (оценка): 1 января (сб) → 3-е; Рамазан 26 февраля (сб) → 28-е;
    /// Курбан 5 мая (пт).
    func test2028() {
        for (m, d) in [(1, 1), (1, 3), (2, 26), (2, 28), (3, 8), (3, 21), (5, 5), (5, 9), (9, 1),
                       (10, 1), (12, 8)] {
            XCTAssertTrue(holiday(2028, m, d), "2028-\(m)-\(d)")
        }
        XCTAssertFalse(holiday(2028, 2, 29), "один перенос на один праздник")
    }

    /// Год вне списка — постоянные праздники и перенос, без хайитов.
    func testYearOutsideTheListKeepsFixedHolidays() {
        XCTAssertTrue(holiday(2030, 1, 1))
        XCTAssertTrue(holiday(2030, 3, 21))
        XCTAssertFalse(holiday(2030, 3, 20))
    }

    func testDayOffAndWorkday() {
        XCTAssertTrue(UzHolidays.isDayOff(day(2026, 10, 17), calendar: utc), "суббота")
        XCTAssertTrue(UzHolidays.isDayOff(day(2026, 3, 23), calendar: utc), "перенос Навруза")
        XCTAssertTrue(UzHolidays.isWorkday(day(2026, 10, 20), calendar: utc), "вторник")
    }

    /// Срок «быть к 9:00» в праздник не действует — ни по будням, ни в
    /// субботу шестидневки.
    func testArrivalTargetIsOffOnHolidays() {
        var target = ArrivalTarget(minute: 540)
        target.saturday = true
        XCTAssertFalse(target.applies(on: day(2026, 3, 23), calendar: utc), "перенос Навруза, пн")
        XCTAssertFalse(target.applies(on: day(2026, 3, 21), calendar: utc), "Навруз, сб")
        XCTAssertTrue(target.applies(on: day(2026, 3, 24), calendar: utc))
    }

    /// Поездка в праздник ложится в выходной класс профиля, а не в будни.
    func testHolidayTripFoldsAsWeekend() {
        XCTAssertTrue(UzHolidays.isDayOff(day(2026, 5, 28), calendar: utc))
        XCTAssertFalse(utc.isDateInWeekend(day(2026, 5, 28)), "четверг — по календарю будний")
    }
}
