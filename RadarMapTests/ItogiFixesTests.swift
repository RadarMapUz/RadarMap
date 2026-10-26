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

    func testRunningWeekGivesKilometres() {
        let change = summary(km: 40, previousKm: 100, complete: false).distanceChange
        XCTAssertNil(change?.percent, "идущая неделя против целой — всегда «−60 %»")
        XCTAssertEqual(change?.meters ?? 0, -60_000, accuracy: 0.1)
        XCTAssertEqual(change?.isUp, false)
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
