//
//  OneTimeHintsTests.swift
//  RadarMapTests
//
//  Разовые подсказки: по одной, по порядку, каждая один раз, и никогда — про
//  кнопку, которой не видно.
//

import XCTest
@testable import RadarMap

final class OneTimeHintsTests: XCTestCase {

    func testHintsComeInOrder() {
        XCTAssertEqual(OneTimeHints.next(shown: [], radarVisible: false), .toggles)
        XCTAssertNil(OneTimeHints.next(shown: [.toggles], radarVisible: false))
        XCTAssertEqual(OneTimeHints.next(shown: [.toggles], radarVisible: true), .radar)
    }

    /// В поездке «Радар!» впереди переключателей: кнопка уже на экране (40D).
    func testRadarComesFirstInTrip() {
        XCTAssertEqual(OneTimeHints.next(shown: [], radarVisible: true), .radar)
        XCTAssertEqual(OneTimeHints.next(shown: [.radar], radarVisible: true), .toggles)
    }

    /// До первой поездки подсказка за запуск не тратится на переключатели —
    /// иначе запуск первой поездки оставался без «Радар!».
    func testFirstTripKeepsLaunchForRadar() {
        XCTAssertNil(OneTimeHints.next(shown: [], radarVisible: false, hasDriven: false))
        XCTAssertEqual(OneTimeHints.next(shown: [], radarVisible: true, hasDriven: false), .radar)
        XCTAssertEqual(OneTimeHints.next(shown: [.radar], radarVisible: false, hasDriven: false), .toggles)
        XCTAssertEqual(OneTimeHints.next(shown: [], radarVisible: false, hasDriven: true), .toggles)
    }

    /// Подсказывать про жёлтую кнопку, когда её нет на экране (вне поездки), —
    /// значит путать, а не помогать: ждём поездки.
    func testRadarHintWaitsForVisibleButton() {
        XCTAssertNil(OneTimeHints.next(shown: [.toggles], radarVisible: false))
        XCTAssertEqual(OneTimeHints.next(shown: [.toggles], radarVisible: true), .radar)
    }

    func testNothingLeftMeansSilence() {
        XCTAssertNil(OneTimeHints.next(shown: Set(OneTimeHints.Hint.allCases),
                                       radarVisible: true))
    }

    /// Тексты подсказок непустые и различны — защита от копипасты при правках.
    func testHintTextsAreDistinct() {
        let texts = OneTimeHints.Hint.allCases.map(\.text)
        XCTAssertEqual(Set(texts).count, texts.count)
        XCTAssertFalse(texts.contains(where: \.isEmpty))
    }

    /// Умная тишина объясняется только когда она уже случилась: пока своих
    /// камер нет, объяснять нечего — как и с невидимой жёлтой кнопкой.
    func testSilenceHintWaitsForFirstFamiliarCamera() {
        let seen: Set<OneTimeHints.Hint> = [.toggles, .radar]
        XCTAssertNil(OneTimeHints.next(shown: seen, radarVisible: true,
                                       hasFamiliarCameras: false))
        XCTAssertEqual(OneTimeHints.next(shown: seen, radarVisible: true,
                                         hasFamiliarCameras: true), .smartSilence)
    }

    /// «Только в машине» — только тем, кому предложение положено (CarPlay
    /// уже был, ещё не ответили), и один раз.
    func testCarOnlyHintNeedsOffer() {
        let seen: Set<OneTimeHints.Hint> = [.toggles, .radar, .smartSilence]
        XCTAssertNil(OneTimeHints.next(shown: seen, radarVisible: true, offersCarOnly: false))
        XCTAssertEqual(OneTimeHints.next(shown: seen, radarVisible: true, offersCarOnly: true),
                       .carOnlyOffer)
        XCTAssertNil(OneTimeHints.next(shown: seen.union([.carOnlyOffer]), radarVisible: true,
                                       offersCarOnly: true))
    }
}
