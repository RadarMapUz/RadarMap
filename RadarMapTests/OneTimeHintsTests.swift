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
        XCTAssertEqual(OneTimeHints.next(shown: [], radarVisible: false), .dashboard)
        XCTAssertEqual(OneTimeHints.next(shown: [.dashboard], radarVisible: false), .toggles)
        XCTAssertEqual(OneTimeHints.next(shown: [.dashboard, .toggles], radarVisible: true), .radar)
    }

    /// Подсказывать про жёлтую кнопку, когда её нет на экране (вне поездки), —
    /// значит путать, а не помогать: ждём поездки.
    func testRadarHintWaitsForVisibleButton() {
        XCTAssertNil(OneTimeHints.next(shown: [.dashboard, .toggles], radarVisible: false))
        XCTAssertEqual(OneTimeHints.next(shown: [.dashboard, .toggles], radarVisible: true), .radar)
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
}
