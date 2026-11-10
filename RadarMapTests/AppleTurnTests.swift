//
//  AppleTurnTests.swift
//  RadarMapTests
//
//  Тип поворота шага Apple по углу между линиями (76): не «прямо» на всё.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class AppleTurnTests: XCTestCase {

    private let junction = CLLocationCoordinate2D(latitude: 41.3, longitude: 69.25)

    /// Точка в `meters` от перекрёстка по курсу `bearing`.
    private func offset(_ bearing: Double, _ meters: Double) -> CLLocationCoordinate2D {
        let rad = bearing * .pi / 180
        return CLLocationCoordinate2D(
            latitude: junction.latitude + meters * cos(rad) / 111_320,
            longitude: junction.longitude + meters * sin(rad) / (111_320 * cos(junction.latitude * .pi / 180)))
    }

    /// Едем курсом `heading` к перекрёстку и уходим курсом `exit`.
    private func modifier(heading: Double, exit: Double) -> String? {
        let incoming = [offset(heading + 180, 200), offset(heading + 180, 60), junction]
        let outgoing = [junction, offset(exit, 60), offset(exit, 200)]
        return AppleTurn.modifier(incoming: incoming, outgoing: outgoing)
    }

    func testRightAngleTurns() {
        XCTAssertEqual(modifier(heading: 90, exit: 0), "left")
        XCTAssertEqual(modifier(heading: 90, exit: 180), "right")
        XCTAssertEqual(modifier(heading: 0, exit: 270), "left", "через север: 0 → 270 — налево")
    }

    func testSlightSharpAndStraight() {
        XCTAssertEqual(modifier(heading: 0, exit: 30), "slight right")
        XCTAssertEqual(modifier(heading: 0, exit: 330), "slight left")
        XCTAssertEqual(modifier(heading: 0, exit: 150), "sharp right")
        XCTAssertEqual(modifier(heading: 0, exit: 8), "straight")
        XCTAssertEqual(modifier(heading: 0, exit: 178), "uturn")
    }

    func testSignedTurnWrapsAroundNorth() {
        XCTAssertEqual(AppleTurn.signedTurn(from: 350, to: 10), 20, accuracy: 1e-9)
        XCTAssertEqual(AppleTurn.signedTurn(from: 10, to: 350), -20, accuracy: 1e-9)
    }

    func testTooShortLineIsNotJudged() {
        XCTAssertNil(AppleTurn.modifier(incoming: [junction], outgoing: [junction, offset(0, 50)]))
        XCTAssertNil(AppleTurn.modifier(incoming: [offset(180, 50), junction], outgoing: [junction]))
        XCTAssertNil(AppleTurn.modifier(incoming: [offset(180, 1), junction], outgoing: [junction, offset(90, 1)]))
    }

    func testIconsMatchOSRMManeuvers() {
        XCTAssertEqual(AppleTurn.icon(modifier: "left"), "arrow.turn.up.left")
        XCTAssertEqual(AppleTurn.icon(modifier: "slight right"), "arrow.up.right")
        XCTAssertEqual(AppleTurn.icon(modifier: "uturn"), "arrow.uturn.left")
        XCTAssertEqual(AppleTurn.icon(modifier: nil), "arrow.up")
        XCTAssertEqual(ManeuverKind.fromOSRM(modifier: modifier(heading: 90, exit: 0)), .left)
    }
}
