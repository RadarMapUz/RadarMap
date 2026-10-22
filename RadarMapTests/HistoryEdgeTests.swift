//
//  HistoryEdgeTests.swift
//  RadarMapTests
//
//  Сценарий E1 (12в): пустая история и история под потолок. Пустая — ни
//  один движок «Итогов» не падает и не выдумывает цифр (рейтинг nil, а не
//  0, советов нет); потолок — 50 записей, старше месяца уходят, треки — только
//  у недели, а дневные итоги переживают чистку.
//

import XCTest
@testable import RadarMap

final class HistoryEdgeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testEmptyHistoryInventsNothing() async {
        for period in StatsPeriod.allCases {
            let summary = TripHistory.summary(days: [], history: [], period: period, anchor: now)
            XCTAssertEqual(summary.trips, 0)
            XCTAssertNil(summary.rating, "нет поездок — нет балла, а не ноль")
            XCTAssertTrue(PeriodInsights.build(summary).isEmpty, "советов из пустоты нет")
        }
        let screen = await RatingBreakdown.screen(records: [], days: [], period: .month, anchor: now)
        XCTAssertNotNil(screen)
        XCTAssertTrue(TripHistory.pruned([], now: now).isEmpty)
        XCTAssertNil(TripHistory.weightedRating([], within: 30 * 86_400, now: now))
    }

    private func record(daysAgo: Double) -> TripRecord {
        let start = now.addingTimeInterval(-daysAgo * 86_400)
        var record = TripRecord(id: start.timeIntervalSince1970, startedAt: start,
                                endedAt: start.addingTimeInterval(1_800), distanceMeters: 10_000,
                                maxSpeedKmh: 70, passed: [], score: 90)
        record.track = [41.3, 69.2, 50]
        return record
    }

    /// Шесть поездок в день две недели подряд (такси): хранится не больше 50,
    /// трек — только у недели и у семи последних.
    func testHeavyHistoryHitsTheCeiling() {
        let history = (0..<84).map { record(daysAgo: Double($0) / 6) }
        let pruned = TripHistory.pruned(history, retention: .legacy, now: now)
        XCTAssertEqual(pruned.count, TripHistory.maxHistory)
        XCTAssertTrue(pruned.allSatisfy { $0.startedAt > now.addingTimeInterval(-30 * 86_400) })
        let oldWithTrack = pruned.enumerated().filter { index, record in
            index >= TripHistory.visibleHistory && record.startedAt <= now.addingTimeInterval(-7 * 86_400)
                && record.track != nil
        }
        XCTAssertTrue(oldWithTrack.isEmpty, "трек старше недели не хранится")
    }

    /// Старше месяца запись уходит, но дневные итоги (а с ними километры и
    /// балл периода) остаются: «за всё время» не обнуляется чисткой.
    func testDayRollupsOutliveTheRecords() {
        let history = [record(daysAgo: 1), record(daysAgo: 45)]
        let days = TripDayBook.rebuilt(from: history)
        let pruned = TripHistory.pruned(history, now: now)
        XCTAssertEqual(pruned.count, 2, "в первых семи — держим")
        XCTAssertTrue(TripHistory.pruned((0..<10).map { record(daysAgo: Double($0) / 24) } + history,
                                         retention: .legacy, now: now)
            .allSatisfy { $0.startedAt > now.addingTimeInterval(-30 * 86_400) }, "за семью последними старше месяца — уходит")
        let all = TripDayBook.summary(days, in: DateInterval(start: now.addingTimeInterval(-50 * 86_400), end: now))
        XCTAssertEqual(all.trips, 2, "итоги дня переживают запись")
        XCTAssertEqual(all.distance, 20_000, accuracy: 1)
    }
}
