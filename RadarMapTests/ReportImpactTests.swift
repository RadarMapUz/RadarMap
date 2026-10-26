//
//  ReportImpactTests.swift
//  RadarMapTests
//
//  Польза отметок (31E): окно 30 дней, подтверждения не убывают оттого, что
//  сервер забыл отметку, и «подтверждена» в живом списке — хотя бы одно.
//

import XCTest
@testable import RadarMap

final class ReportImpactTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func report(daysAgo: Double, confirmers: Int?, confirmed: Bool = false) -> ReportImpact.Report {
        ReportImpact.Report(at: now.addingTimeInterval(-daysAgo * 86_400), confirmers: confirmers,
                            confirmed: confirmed)
    }

    func testSummaryCountsOnlyTheWindow() {
        let summary = ReportImpact.summary([
            report(daysAgo: 1, confirmers: 3),
            report(daysAgo: 10, confirmers: 0),
            report(daysAgo: 29, confirmers: 2),
            report(daysAgo: 45, confirmers: 9),     // старше окна: сервер и UUID уже другие
        ], now: now)
        XCTAssertEqual(summary, ReportImpact.Summary(reports: 3, confirmedReports: 2, confirmations: 5))
    }

    func testLiveConfirmedFlagIsAtLeastOne() {
        let summary = ReportImpact.summary([report(daysAgo: 1, confirmers: nil, confirmed: true)], now: now)
        XCTAssertEqual(summary.confirmations, 1)
        XCTAssertEqual(summary.confirmedReports, 1)
    }

    func testServerForgettingDoesNotLowerTheCount() {
        XCTAssertEqual(ReportImpact.merged(known: 4, fetched: nil), 4, "стёртая на сервере отметка обнулила счёт")
        XCTAssertEqual(ReportImpact.merged(known: 4, fetched: 2), 4, "новый UUID/чистка уменьшили число")
        XCTAssertEqual(ReportImpact.merged(known: 1, fetched: 3), 3)
        XCTAssertEqual(ReportImpact.merged(known: nil, fetched: -5), 0, "мусор сервера — не минус")
        XCTAssertNil(ReportImpact.merged(known: nil, fetched: nil))
    }

    func testIsDue() {
        let recent = now.addingTimeInterval(-3600)
        XCTAssertTrue(ReportImpact.isDue(lastFetch: nil, now: now, newest: recent))
        XCTAssertFalse(ReportImpact.isDue(lastFetch: now.addingTimeInterval(-60), now: now, newest: recent))
        XCTAssertTrue(ReportImpact.isDue(lastFetch: now.addingTimeInterval(-1900), now: now, newest: recent))
        XCTAssertFalse(ReportImpact.isDue(lastFetch: nil, now: now, newest: nil), "своих отметок нет — не спрашиваем")
        XCTAssertFalse(ReportImpact.isDue(lastFetch: nil, now: now, newest: now.addingTimeInterval(-3 * 86_400),
                                          days: 2), "из опроса — только пока сервер помнит отметку")
        XCTAssertTrue(ReportImpact.isDue(lastFetch: now.addingTimeInterval(3600), now: now, newest: recent),
                      "часы перевели назад — не ждать «будущего» срока")
    }
}
