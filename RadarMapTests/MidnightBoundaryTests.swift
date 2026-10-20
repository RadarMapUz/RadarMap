//
//  MidnightBoundaryTests.swift
//  RadarMapTests
//
//  Сценарий E3 (12в): поездка 23:40–00:20 в последний день месяца. Она одна
//  в дневных итогах — в дне старта, а не размазана на два дня; месяц старта
//  её считает, следующий — нет; новая поездка после полуночи не склеивается
//  с ней (TripMerge.crossesDay).
//

import XCTest
@testable import RadarMap

final class MidnightBoundaryTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tashkent")!
        c.firstWeekday = 2
        return c
    }

    private func date(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private var lateTrip: TripRecord {
        let start = date(10, 31, 23, 40)
        return TripRecord(id: start.timeIntervalSince1970, startedAt: start, endedAt: date(11, 1, 0, 20),
                          distanceMeters: 25_000, maxSpeedKmh: 80, passed: [], score: 90)
    }

    func testTripAcrossMidnightIsOneDayOfItsStart() {
        let days = TripDayBook.rebuilt(from: [lateTrip], calendar: calendar)
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days.first?.day, calendar.startOfDay(for: date(10, 31, 12, 0)))
        XCTAssertEqual(days.first?.distanceMeters ?? 0, 25_000, accuracy: 1)
    }

    func testMonthOfTheStartCountsItTheNextDoesNot() {
        let days = TripDayBook.rebuilt(from: [lateTrip], calendar: calendar)
        let october = TripHistory.summary(days: days, history: [lateTrip], period: .month,
                                          anchor: date(10, 15, 12, 0), calendar: calendar)
        let november = TripHistory.summary(days: days, history: [lateTrip], period: .month,
                                           anchor: date(11, 15, 12, 0), calendar: calendar)
        XCTAssertEqual(october.trips, 1)
        XCTAssertEqual(november.trips, 0)
    }
}
