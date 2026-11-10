//
//  TripodFreshnessTests.swift
//  RadarMapTests
//
//  Пункт 82: свежесть отметки водителей — «Сообщили 5 мин назад»,
//  «Подтвердили 3 мин назад», «Не подтверждали 50 мин», голос называет
//  свежесть, только когда она меняет доверие, старый сервер — прежние строки.
//

import XCTest
@testable import RadarMap

final class TripodFreshnessTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func info(created minutesAgo: Double? = nil, confirmed confirmedAgo: Double? = nil,
                      trust: Int? = 0, doubted: Int = 0) -> TripodFreshness.Info {
        TripodFreshness.Info(created: minutesAgo.map { now.addingTimeInterval(-$0 * 60) },
                             lastConfirmed: confirmedAgo.map { now.addingTimeInterval(-$0 * 60) },
                             trust: trust, doubted: doubted, confirmed: confirmedAgo != nil)
    }

    func testReportedSaysWhenReported() {
        XCTAssertEqual(TripodFreshness.card(info(created: 5.3), now: now), "Сообщили 5 мин назад")
        XCTAssertEqual(TripodFreshness.card(info(created: 0.2), now: now), "Сообщили только что")
    }

    func testConfirmedSaysWhenConfirmedNotWhenReported() {
        XCTAssertEqual(TripodFreshness.card(info(created: 70, confirmed: 3, trust: 1), now: now),
                       "Подтвердили 3 мин назад")
    }

    func testLongWithoutConfirmationSaysSo() {
        let stale = Double(AppConfig.tripodStaleMinutes)
        XCTAssertEqual(TripodFreshness.card(info(created: stale + 10), now: now),
                       "Не подтверждали \(AppConfig.tripodStaleMinutes + 10) мин")
        XCTAssertEqual(TripodFreshness.card(info(created: 200, confirmed: 75, trust: 1), now: now),
                       "Не подтверждали больше часа")
    }

    func testOldServerKeepsReportAgeLines() {
        let old = info(created: 12.2, trust: nil)
        XCTAssertEqual(TripodFreshness.card(old, now: now),
                       ReportAge.card(created: old.created, confirmed: false, now: now))
        XCTAssertNil(TripodFreshness.state(old, now: now))
        XCTAssertEqual(TripodFreshness.voiceTail(old, now: now), .none, "без полей свежести голос прежний")
    }

    func testVoiceTailOnlyWhenTrustChanges() {
        XCTAssertEqual(TripodFreshness.voiceTail(info(created: 30, confirmed: 2, trust: 1), now: now),
                       .justConfirmed)
        XCTAssertEqual(TripodFreshness.voiceTail(info(created: 30, confirmed: 20, trust: 1), now: now), .none,
                       "подтверждена недавно, но не только что — хвост ничего не добавляет")
        XCTAssertEqual(TripodFreshness.voiceTail(info(created: 47), now: now), .unconfirmed(minutes: 40))
        XCTAssertEqual(TripodFreshness.voiceTail(info(created: 95), now: now), .unconfirmed(minutes: 60))
        XCTAssertEqual(TripodFreshness.voiceTail(info(created: 5), now: now), .none)
        XCTAssertEqual(TripodFreshness.voiceTail(nil, now: now), .none)
    }

    func testDoubtSilencesJustConfirmed() {
        let doubted = info(created: 30, confirmed: 2, trust: 0, doubted: 1)
        XCTAssertEqual(TripodFreshness.voiceTail(doubted, now: now), .none,
                       "«подтвердили только что» после «Уже нет» — неправда")
        XCTAssertEqual(TripodFreshness.doubt(doubted), "Водитель сообщил, что уже нет")
        XCTAssertTrue(TripodFreshness.isFaded(doubted))
    }

    func testFadedFollowsTrust() {
        XCTAssertTrue(TripodFreshness.isFaded(info(created: 5)))
        XCTAssertFalse(TripodFreshness.isFaded(info(created: 30, confirmed: 2, trust: 2)))
        XCTAssertTrue(TripodFreshness.isFaded(TripodFreshness.Info(trust: nil, confirmed: false)))
        XCTAssertFalse(TripodFreshness.isFaded(TripodFreshness.Info(trust: nil, confirmed: true)))
    }

    func testMapLabelIsAClockThatDoesNotGoStale() {
        let confirmed = info(created: 30, confirmed: 4, trust: 1)
        XCTAssertEqual(TripodFreshness.mapLabel(confirmed), "✓ " + NumberFormat.clock(confirmed.lastConfirmed!))
        let reported = info(created: 9)
        XCTAssertEqual(TripodFreshness.mapLabel(reported), NumberFormat.clock(reported.created!) + "?")
        XCTAssertEqual(TripodFreshness.mapLabel(TripodFreshness.Info(trust: 0, confirmed: false)), "")
    }

    func testBannerGoesFromLongToShort() {
        let banner = TripodFreshness.banner(info(created: 30, confirmed: 3, trust: 1), now: now)
        XCTAssertEqual(banner, ["Подтвердили 3 мин назад", "3 мин назад"])
        let doubted = TripodFreshness.banner(info(created: 30, confirmed: 3, trust: 0, doubted: 2), now: now)
        XCTAssertEqual(doubted?.first, "Подтвердили 3 мин назад · Водители сообщили, что уже нет")
        XCTAssertEqual(doubted?.count, 3)
    }

    func testVoiceTextRendersTheTail() {
        let call = VoiceEvent.CameraCall(kind: .tripod, form: .full(.ahead), meters: 300,
                                         fromDrivers: true, freshness: .unconfirmed(minutes: 40))
        XCTAssertTrue(VoiceText.camera(call).hasSuffix(", 40 минут без подтверждения"))
        XCTAssertNil(VoiceComposer.segments(for: .camera(call), in: .uz),
                     "отрывков хвоста нет — фраза целиком синтезатором, а не обрезанной записью")
        var plain = call
        plain.freshness = .none
        XCTAssertNotNil(VoiceComposer.segments(for: .camera(plain), in: .uz))
    }

    func testServerFieldsBecomeInfo() {
        let fresh = MobileCameraService.freshness(1_000, 1_600, trust: 2, doubted: nil, confirmed: true, skew: 10)
        XCTAssertEqual(fresh.created, Date(timeIntervalSince1970: 1_010))
        XCTAssertEqual(fresh.lastConfirmed, Date(timeIntervalSince1970: 1_610))
        XCTAssertEqual(fresh.trust, 2)
        XCTAssertEqual(fresh.doubted, 0)
        XCTAssertNil(MobileCameraService.freshness(1_000, nil, trust: 0, doubted: 0, confirmed: false,
                                                   skew: 0).lastConfirmed)
    }
}
