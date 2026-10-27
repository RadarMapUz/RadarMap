//
//  ItogiFixesTests.swift
//  RadarMapTests
//
//  Исправления «Итогов» 31E: «+178 % к прошлой» стало километрами (процент —
//  только у сопоставимых целых периодов), подсказка — действием у конкретной
//  камеры.
//

import XCTest
@testable import RadarMap

final class ItogiFixesTests: XCTestCase {

    private func summary(km: Double, previousKm: Double, complete: Bool) -> PeriodSummary {
        var result = PeriodSummary()
        result.trips = 1
        result.distance = km * 1000
        result.previousDistance = previousKm * 1000
        result.periodComplete = complete
        return result
    }

    func testTinyPreviousPeriodGivesKilometresNotPercent() {
        let change = summary(km: 25, previousKm: 9, complete: true).distanceChange
        XCTAssertNil(change?.percent, "«+178 %» от девяти километров")
        XCTAssertEqual(change?.meters ?? 0, 16_000, accuracy: 0.1)
    }

    /// Идущая неделя (34) сравнивается с теми же днями прошлой, не с целой:
    /// во вторник «−60 км к прошлой неделе» было минусом у каждого.
    func testRunningWeekComparesSameDays() {
        var running = summary(km: 40, previousKm: 100, complete: false)
        XCTAssertNil(running.distanceChange, "без тех же дней прошлой — сравнения нет")
        running.previousSoFarDistance = 30_000
        let change = running.distanceChange
        XCTAssertNil(change?.percent, "процент виджет читает как «к целой неделе»")
        XCTAssertEqual(change?.meters ?? 0, 10_000, accuracy: 0.1)
        XCTAssertEqual(change?.isUp, true)
        XCTAssertEqual(change?.soFar, true)
        XCTAssertEqual(summary(km: 40, previousKm: 100, complete: true).distanceChange?.soFar, false)
    }

    /// Вторник: прошлая неделя режется до понедельника и вторника.
    func testSoFarDistanceCutsPreviousWindow() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        utc.firstWeekday = 2
        func day(_ d: Int) -> Date { utc.date(from: DateComponents(year: 2026, month: 10, day: d))! }
        let days = [(19, 10_000.0), (20, 5_000.0), (21, 70_000.0), (26, 20_000.0)].map { d, meters -> TripDay in
            var row = TripDay(day: day(d))
            row.trips = 1
            row.distanceMeters = meters
            return row
        }
        let now = day(27).addingTimeInterval(9 * 3600)
        let current = StatsPeriod.week.interval(containing: now, calendar: utc)
        let previous = StatsPeriod.week.previousInterval(containing: now, calendar: utc)!
        let soFar = TripHistory.soFarDistance(days, period: .week, current: current, previous: previous,
                                              calendar: utc, now: now)
        XCTAssertEqual(soFar ?? 0, 15_000, accuracy: 0.1, "пн + вт прошлой недели, без среды")
        XCTAssertNil(TripHistory.soFarDistance(days, period: .day,
                                               current: StatsPeriod.day.interval(containing: now, calendar: utc),
                                               previous: StatsPeriod.day.previousInterval(containing: now, calendar: utc)!,
                                               calendar: utc, now: now), "сутки на часы не делятся")
        let later = now.addingTimeInterval(30 * 86400)
        XCTAssertNil(TripHistory.soFarDistance(days, period: .week, current: current, previous: previous,
                                               calendar: utc, now: later), "неделя кончилась")
    }

    func testComparablePeriodsKeepPercent() {
        XCTAssertEqual(summary(km: 120, previousKm: 100, complete: true).distanceChange?.percent, 20)
        XCTAssertNil(summary(km: 350, previousKm: 100, complete: true).distanceChange?.percent,
                     "в разы — проценты ничего не значат")
        XCTAssertNil(summary(km: 10, previousKm: 0.3, complete: true).distanceChange, "сравнивать не с чем")
    }

    func testPeriodCompleteComesFromTheClock() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let record = TripRecord(id: 1, startedAt: now - 3 * 86_400, endedAt: now - 3 * 86_400 + 600,
                                distanceMeters: 5000, maxSpeedKmh: 60, passed: [])
        let days = TripDayBook.rebuilt(from: [record], calendar: utc)
        let current = TripHistory.summary(days: days, history: [record], period: .week, anchor: now,
                                          calendar: utc, now: now)
        XCTAssertFalse(current.periodComplete)
        let later = TripHistory.summary(days: days, history: [record], period: .week, anchor: now,
                                        calendar: utc, now: now + 10 * 86_400)
        XCTAssertTrue(later.periodComplete)
    }

    func testActionHintNamesCameraPassesLimitAndMoney() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func pass(_ speed: Double, location: String = "Ц-1, Амир Темур", limit: Int = 60) -> PassedCamera {
            PassedCamera(id: UUID(), cameraID: 7, typeRaw: "Стационар радар", location: location,
                         speedKmh: speed, date: now - 3600, lat: 41.31, lon: 69.28, limitKmh: limit)
        }
        let record = TripRecord(id: 1, startedAt: now - 7200, endedAt: now - 3000, distanceMeters: 20_000,
                                maxSpeedKmh: 90, passed: [pass(80), pass(85), pass(55), pass(90, location: "Чиланзар")])
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let summary = TripHistory.summary(days: TripDayBook.rebuilt(from: [record], calendar: utc),
                                          history: [record], period: .week, anchor: now, calendar: utc, now: now)
        let hint = try XCTUnwrap(PeriodInsights.action(summary))
        XCTAssertEqual(hint.location, "Ц-1, Амир Темур")
        XCTAssertEqual(hint.over, 2)
        XCTAssertEqual(hint.passes, 3, "проезды — все у этой камеры, а не только с превышением")
        XCTAssertEqual(hint.limitKmh, 60)
        XCTAssertEqual(hint.fine, FineSchedule.fine(overKmh: 20) + FineSchedule.fine(overKmh: 25), accuracy: 0.5)
    }

    func testNoActionHintForCleanPeriod() {
        var clean = PeriodSummary()
        clean.trips = 2
        clean.cleanPasses = 4
        XCTAssertNil(PeriodInsights.action(clean))
    }
}
