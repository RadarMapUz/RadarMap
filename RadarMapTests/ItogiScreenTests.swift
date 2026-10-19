//
//  ItogiScreenTests.swift
//  RadarMapTests
//
//  Экран «Итогов» считается одним проходом вне main (6.4) — и обязан
//  показывать ровно то, что раньше считал body: ту же сводку, те же выводы,
//  те же поездки окна и то же напоминание о штрафах.
//

import XCTest
@testable import RadarMap

final class ItogiScreenTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(daysAgo: Double, km: Double, passes: [PassedCamera] = []) -> TripRecord {
        let start = now.addingTimeInterval(-daysAgo * 86400)
        return TripRecord(id: start.timeIntervalSince1970, startedAt: start,
                          endedAt: start.addingTimeInterval(1800),
                          distanceMeters: km * 1000, maxSpeedKmh: 80, passed: passes)
    }

    private func overspeed(daysAgo: Double) -> PassedCamera {
        PassedCamera(id: UUID(), cameraID: 1, typeRaw: "Стационар радар", location: "Юнусабад",
                     speedKmh: 95, date: now.addingTimeInterval(-daysAgo * 86400),
                     lat: 41.31, lon: 69.28, limitKmh: 60)
    }

    func testScreenIsWhatTheBodyUsedToCompute() {
        let history = [record(daysAgo: 1, km: 12), record(daysAgo: 3, km: 20),
                       record(daysAgo: 40, km: 50, passes: [overspeed(daysAgo: 40)])]
        for period in [StatsPeriod.week, .month] {
            let screen = ItogiScreen.build(days: [], history: history, period: period,
                                           anchor: now, now: now)
            let summary = TripHistory.summary(days: [], history: history, period: period, anchor: now)
            XCTAssertEqual(screen.summary, summary)
            XCTAssertEqual(screen.insights, PeriodInsights.hero(summary).map { [$0] } ?? [])
            XCTAssertEqual(screen.trips.map(\.id),
                           TripHistory.historyList(history, period: period, anchor: now).map(\.id))
        }
    }

    /// Напоминание — по всей истории, не по окну: зависший штраф старше
    /// месяца виден и из текущей недели.
    func testPendingFinesComeFromTheWholeHistory() {
        let history = [record(daysAgo: 1, km: 12), record(daysAgo: 40, km: 50, passes: [overspeed(daysAgo: 40)])]
        let screen = ItogiScreen.build(days: [], history: history, period: .week, anchor: now, now: now)
        let direct = TripHistory.pendingFineNudge(history, now: now)
        XCTAssertEqual(screen.pendingCount, direct?.count ?? 0)
        XCTAssertEqual(screen.pendingOldest, direct?.oldest)
    }
}
