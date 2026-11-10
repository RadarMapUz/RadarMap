//
//  ManeuverThenVoiceTests.swift
//  RadarMapTests
//
//  «Затем …» голосом (76): один раз на манёвр, только в ближней фразе или
//  в команде, не пока камера держит голос.
//

import XCTest
@testable import RadarMap

final class ManeuverThenVoiceTests: XCTestCase {

    func testSaidOnlyNearOrAtTheCommand() {
        XCTAssertFalse(ManeuverThen.voiced(stage: 2, alreadySaid: false, cameraHolds: false), "за 800 м рано")
        XCTAssertTrue(ManeuverThen.voiced(stage: 1, alreadySaid: false, cameraHolds: false))
        XCTAssertTrue(ManeuverThen.voiced(stage: 0, alreadySaid: false, cameraHolds: false))
    }

    func testSaidOnce() {
        XCTAssertFalse(ManeuverThen.voiced(stage: 0, alreadySaid: true, cameraHolds: false))
    }

    func testNotOverTheCameraAlert() {
        XCTAssertFalse(ManeuverThen.voiced(stage: 1, alreadySaid: false, cameraHolds: true))
    }

    func testPhraseNamesSecondManeuverWithoutItsStreet() {
        let second = RouteStep(distanceAlong: 380, text: "поверните налево на улицу Навои", icon: "arrow.turn.up.left",
                               kind: .left, shortText: "поверните налево")
        XCTAssertEqual(ManeuverThen.spoken("поверните направо", then: second),
                       String(format: String(localized: "%1$@. Затем %2$@"), "поверните направо", "поверните налево"))
    }
}
