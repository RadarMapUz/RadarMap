//
//  ManeuverThenTests.swift
//  RadarMapTests
//
//  «Затем …» под карточкой манёвра (29.G). Что проверяется: второй манёвр
//  называется только когда он близко за первым; после прибытия и для
//  «прямо» — ничего; последний манёвр — ничего.
//

import XCTest
@testable import RadarMap

final class ManeuverThenTests: XCTestCase {

    private func step(_ along: Double, _ kind: ManeuverKind?) -> RouteStep {
        RouteStep(distanceAlong: along, text: "манёвр", icon: "arrow.up", kind: kind)
    }

    func testCloseSecondTurnIsNamed() {
        let steps = [step(300, .right), step(380, .left), step(2000, .arrive)]
        XCTAssertEqual(ManeuverThen.following(0, in: steps)?.distanceAlong, 380)
        // Финиш за 1,6 км — далеко.
        XCTAssertNil(ManeuverThen.following(1, in: steps))
    }

    func testFarSecondTurnIsNotNamed() {
        let steps = [step(300, .right), step(300 + AppConfig.maneuverThenMeters + 1, .left)]
        XCTAssertNil(ManeuverThen.following(0, in: steps))
        let edge = [step(300, .right), step(300 + AppConfig.maneuverThenMeters, .left)]
        XCTAssertNotNil(ManeuverThen.following(0, in: edge))
    }

    func testArrivalRightAfterTheTurnIsNamed() {
        let steps = [step(300, .left), step(360, .arrive)]
        XCTAssertEqual(ManeuverThen.following(0, in: steps)?.kind, .arrive)
    }

    func testNothingAfterArrivalOrForStraightOrOutOfRange() {
        XCTAssertNil(ManeuverThen.following(0, in: [step(300, .arrive), step(320, .left)]))
        XCTAssertNil(ManeuverThen.following(0, in: [step(300, .right), step(350, .straight)]))
        XCTAssertNil(ManeuverThen.following(0, in: [step(300, .right)]))
        XCTAssertNil(ManeuverThen.following(5, in: [step(300, .right), step(350, .left)]))
        // Битые данные: второй манёвр не дальше первого.
        XCTAssertNil(ManeuverThen.following(0, in: [step(300, .right), step(300, .left)]))
    }
}
