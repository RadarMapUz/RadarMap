//
//  SunTests.swift
//  RadarMapTests
//
//  Восход/закат по NOAA против опубликованных таблиц для Ташкента.
//  Допуск ±10 минут: алгоритм даёт ~2 минуты, запас — на границы зон.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class SunTests: XCTestCase {

    private let tashkent = CLLocationCoordinate2D(latitude: 41.31, longitude: 69.28)
    private var tashkentCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tashkent")!
        return calendar
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        tashkentCalendar.date(from: DateComponents(year: y, month: m, day: d,
                                                   hour: h, minute: min))!
    }

    /// Летнее солнцестояние: восход ~04:52, закат ~19:59 (таблицы timeanddate).
    func testSummerSolsticeTashkent() throws {
        let noon = date(2026, 6, 21, 12, 0)
        let day = try XCTUnwrap(Sun.daylight(at: tashkent, on: noon,
                                             calendar: tashkentCalendar))
        XCTAssertEqual(day.sunrise.timeIntervalSince(date(2026, 6, 21, 4, 52)), 0,
                       accuracy: 600)
        XCTAssertEqual(day.sunset.timeIntervalSince(date(2026, 6, 21, 19, 59)), 0,
                       accuracy: 600)
    }

    /// Зимнее солнцестояние: восход ~07:38, закат ~17:01. Ровно тот случай,
    /// где будильник 6–19 врал: в 18:00 уже час как темно.
    func testWinterSolsticeTashkent() throws {
        let noon = date(2026, 12, 21, 12, 0)
        let day = try XCTUnwrap(Sun.daylight(at: tashkent, on: noon,
                                             calendar: tashkentCalendar))
        XCTAssertEqual(day.sunrise.timeIntervalSince(date(2026, 12, 21, 7, 38)), 0,
                       accuracy: 600)
        XCTAssertEqual(day.sunset.timeIntervalSince(date(2026, 12, 21, 17, 1)), 0,
                       accuracy: 600)
    }

    func testIsDaytimeFollowsTheSunNotTheClock() {
        // Декабрь, 18:30 — по будильнику «день», по солнцу давно ночь.
        XCTAssertFalse(Sun.isDaytime(at: tashkent, now: date(2026, 12, 21, 18, 30),
                                     calendar: tashkentCalendar))
        // Июнь, 05:30 — по будильнику «ночь», по солнцу утро.
        XCTAssertTrue(Sun.isDaytime(at: tashkent, now: date(2026, 6, 21, 5, 30),
                                    calendar: tashkentCalendar))
        // Полдень есть полдень.
        XCTAssertTrue(Sun.isDaytime(at: tashkent, now: date(2026, 3, 15, 12, 0),
                                    calendar: tashkentCalendar))
    }

    /// Без координаты — честный откат к прежним часам, а не гадание.
    func testFallbackWithoutCoordinate() {
        XCTAssertTrue(Sun.isDaytime(at: nil, now: date(2026, 6, 21, 12, 0),
                                    calendar: tashkentCalendar))
        XCTAssertFalse(Sun.isDaytime(at: nil, now: date(2026, 6, 21, 22, 0),
                                     calendar: tashkentCalendar))
    }
}
