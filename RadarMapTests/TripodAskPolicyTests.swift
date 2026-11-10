//
//  TripodAskPolicyTests.swift
//  RadarMapTests
//
//  Пункт 82: «Тренога ещё стоит?» — спрашиваем, где ответ нужен; только что
//  подтверждённую не спрашиваем, кроме редкой детерминированной выборки.
//

import XCTest
@testable import RadarMap

final class TripodAskPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func fresh(confirmedAgo seconds: TimeInterval?, trust: Int? = 1,
                       doubted: Int = 0) -> TripodFreshness.Info {
        TripodFreshness.Info(created: now.addingTimeInterval(-3600),
                             lastConfirmed: seconds.map { now.addingTimeInterval(-$0) },
                             trust: trust, doubted: doubted, confirmed: seconds != nil)
    }

    /// id, который выборка не задевает при этой соли.
    private func unsampledID(salt: Int) -> Int {
        (1...1000).first { !TripodAskPolicy.sampled(id: $0, salt: salt) }!
    }

    func testJustConfirmedIsNotAsked() {
        let id = unsampledID(salt: 7)
        XCTAssertFalse(TripodAskPolicy.worthAsking(id: id, fresh: fresh(confirmedAgo: 120), now: now, salt: 7))
    }

    func testLongUnconfirmedOrNeverConfirmedIsAsked() {
        let id = unsampledID(salt: 7)
        XCTAssertTrue(TripodAskPolicy.worthAsking(id: id, fresh: fresh(confirmedAgo: 30 * 60), now: now, salt: 7))
        XCTAssertTrue(TripodAskPolicy.worthAsking(id: id, fresh: fresh(confirmedAgo: nil, trust: 0),
                                                  now: now, salt: 7))
    }

    func testDoubtedIsAskedEvenIfFresh() {
        let id = unsampledID(salt: 7)
        XCTAssertTrue(TripodAskPolicy.worthAsking(id: id, fresh: fresh(confirmedAgo: 60, doubted: 1),
                                                  now: now, salt: 7))
    }

    func testUnknownFreshnessKeepsTheOldBehaviour() {
        XCTAssertTrue(TripodAskPolicy.worthAsking(id: 5, fresh: nil, now: now, salt: 7))
        XCTAssertTrue(TripodAskPolicy.worthAsking(id: 5, fresh: fresh(confirmedAgo: 60, trust: nil),
                                                  now: now, salt: 7), "старый сервер — спрашиваем, как раньше")
    }

    func testSampleIsRareStableAndDiffersByDevice() {
        let ids = 1...10_000
        let share = Double(ids.filter { TripodAskPolicy.sampled(id: $0, salt: 42) }.count) / Double(ids.count)
        XCTAssertEqual(share, 1 / Double(AppConfig.tripodAskSampleEvery), accuracy: 0.02)
        XCTAssertEqual(TripodAskPolicy.sampled(id: 77, salt: 42), TripodAskPolicy.sampled(id: 77, salt: 42))
        let a = Set(ids.filter { TripodAskPolicy.sampled(id: $0, salt: 1) })
        let b = Set(ids.filter { TripodAskPolicy.sampled(id: $0, salt: 2) })
        XCTAssertNotEqual(a, b, "у разных водителей выборка падает на разные отметки")
    }

    func testSaltIsStableAcrossLaunches() {
        XCTAssertEqual(TripodAskPolicy.salt(from: "ABC-123"), TripodAskPolicy.salt(from: "ABC-123"))
        XCTAssertNotEqual(TripodAskPolicy.salt(from: "ABC-123"), TripodAskPolicy.salt(from: "ABC-124"))
    }

    func testSkippedPicksOnlyFreshCameras() {
        let salt = 9
        let freshID = unsampledID(salt: salt)
        let staleID = freshID + 100_000
        func camera(_ id: Int, _ info: TripodFreshness.Info) -> Camera {
            Camera(id: id, region: "", city: "", location: "", lat: 41.3, lon: 69.2, type: "Тренога",
                   violations: [], needsReview: nil, mobileConfirmed: true, mobileFresh: info)
        }
        let skipped = TripodAskPolicy.skipped([camera(freshID, fresh(confirmedAgo: 60)),
                                               camera(staleID, fresh(confirmedAgo: 3600))],
                                              now: now, salt: salt)
        XCTAssertEqual(skipped, [freshID])
    }
}
