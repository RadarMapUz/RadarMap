//
//  ItogiCalendarTests.swift
//  RadarMapTests
//
//  Кольца дней и правила графика «Итогов».
//

import XCTest
@testable import RadarMap

final class ItogiCalendarTests: XCTestCase {

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Tashkent")!
        return value
    }

    private func date(_ day: Int, month: Int = 11, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    private func tripDay(_ date: Date, km: Double, score: Double = 90, over: Int = 0, edge: Int = 0) -> TripDay {
        var day = TripDay(day: date)
        day.trips = 1
        day.distanceMeters = km * 1000
        day.scoreSum = score * km
        day.scoreWeight = km
        day.overPasses = over
        day.edgePasses = edge
        return day
    }

    func testMonthStartsOnMonday() throws {
        // 1 ноября 2026 — воскресенье: шесть пустых клеток.
        let months = ItogiCalendar.months(days: [], now: date(9), calendar: calendar)
        XCTAssertEqual(months.count, 1)
        let month = try XCTUnwrap(months.first)
        XCTAssertEqual(month.leading, 6)
        XCTAssertEqual(month.cells.count, 30)
    }

    func testMonthsRunFromFirstTripToNow() {
        let days = [tripDay(date(20, month: 9), km: 10)]
        let months = ItogiCalendar.months(days: days, now: date(9), calendar: calendar)
        XCTAssertEqual(months.map { calendar.component(.month, from: $0.start) }, [9, 10, 11])
    }

    func testFutureDaysAreMarked() throws {
        let month = try XCTUnwrap(ItogiCalendar.months(days: [], now: date(9), calendar: calendar).first)
        XCTAssertFalse(month.cells[8].isFuture)
        XCTAssertTrue(month.cells[9].isFuture)
    }

    func testFineAndPerfectAreExclusive() {
        let fine = ItogiCalendar.ring(tripDay(date(2), km: 10, score: 100, over: 1), usualKm: 10)
        XCTAssertTrue(fine.fine)
        XCTAssertFalse(fine.perfect)
        let edge = ItogiCalendar.ring(tripDay(date(3), km: 10, score: 100, edge: 1), usualKm: 10)
        XCTAssertFalse(edge.perfect)
        let clean = ItogiCalendar.ring(tripDay(date(4), km: 10, score: 100), usualKm: 10)
        XCTAssertTrue(clean.perfect)
    }

    func testRoadIsCappedAtUsualDay() {
        XCTAssertEqual(ItogiCalendar.ring(tripDay(date(2), km: 5), usualKm: 10).road, 0.5, accuracy: 1e-9)
        XCTAssertEqual(ItogiCalendar.ring(tripDay(date(2), km: 50), usualKm: 10).road, 1, accuracy: 1e-9)
    }

    func testUsualDayIgnoresOneLongTrip() {
        let days = [10.0, 12, 14, 400].enumerated().map { tripDay(date($0.offset + 1), km: $0.element) }
        XCTAssertEqual(ItogiCalendar.usualKm(days), 13, accuracy: 1e-9)
        XCTAssertEqual(ItogiCalendar.usualKm([]), 1)
    }

    func testAverageSkipsFutureDays() throws {
        let bars = (0..<7).map { DayBar(day: date(2 + $0), km: $0 < 3 ? 30 : 0) }
        let average = try XCTUnwrap(ItogiCalendar.averageKm(bars: bars, now: date(4, hour: 12)))
        XCTAssertEqual(average, 30, accuracy: 1e-9)
        XCTAssertNil(ItogiCalendar.averageKm(bars: bars.map { DayBar(day: $0.day) }, now: date(4)))
    }

    func testShortPlaceTakesTheHead() {
        XCTAssertEqual(ItogiCalendar.shortPlace("Labzak koʻchasi Avtobus bekati, Toshkenboyev koʻchasi Kirish Oldiga"),
                       "Labzak koʻchasi Avtobus bekati")
        XCTAssertEqual(ItogiCalendar.shortPlace("Юнусабад"), "Юнусабад")
        XCTAssertEqual(ItogiCalendar.shortPlace(""), "")
    }

    func testDailyBarsSplitCommuteAndHoursSumUp() {
        let trip = TripRecord(id: 1, startedAt: date(4, hour: 9), endedAt: date(4, hour: 10),
                              distanceMeters: 20_000, maxSpeedKmh: 60, passed: [], score: 90)
        let daily = TripHistory.dailyKm([trip], days: 7, calendar: calendar, now: date(8, hour: 12),
                                        isCommute: { _ in true })
        let bar = daily.first { $0.km > 0 }
        XCTAssertEqual(bar?.commuteKm ?? 0, 20, accuracy: 1e-9)
        XCTAssertEqual(bar?.trips, 1)
        let hourly = TripHistory.hourlyKm([trip], day: date(4), calendar: calendar)
        XCTAssertEqual(hourly.count, 24)
        XCTAssertEqual(hourly[9].km, 20, accuracy: 1e-9)
        XCTAssertEqual(hourly.reduce(0) { $0 + $1.km }, 20, accuracy: 1e-9)
    }
}
