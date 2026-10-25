//
//  CompassRingTests.swift
//  RadarMapTests
//
//  Кольцо компаса у машины (29.B): север там, куда смотрит север на
//  экране, наклон сплющивает кольцо по вертикали, а не по горизонтали.
//

import XCTest
@testable import RadarMap

final class CompassRingTests: XCTestCase {

    func testNorthUpTopDown() {
        let g = CompassRing.geometry(radius: 30, mapDirection: 0, pitchDegrees: 0)
        XCTAssertEqual(g.radiusX, 30)
        XCTAssertEqual(g.radiusY, 30, accuracy: 1e-9)
        XCTAssertEqual(g.letters[0].x, 0, accuracy: 1e-9)    // N сверху
        XCTAssertEqual(g.letters[0].y, -30, accuracy: 1e-9)
        XCTAssertEqual(g.letters[1].x, 30, accuracy: 1e-9)   // E справа
        XCTAssertEqual(g.letters[3].x, -30, accuracy: 1e-9)  // W слева
    }

    func testMapTurnedEastPutsNorthOnTheLeft() {
        // Едем на восток: верх экрана — восток, север — слева.
        let g = CompassRing.geometry(radius: 30, mapDirection: 90, pitchDegrees: 0)
        XCTAssertEqual(g.letters[0].x, -30, accuracy: 1e-9)
        XCTAssertEqual(g.letters[0].y, 0, accuracy: 1e-9)
        XCTAssertEqual(g.letters[1].y, -30, accuracy: 1e-9)  // E сверху
    }

    func testPitchSquashesVerticallyOnly() {
        let g = CompassRing.geometry(radius: 30, mapDirection: 0, pitchDegrees: 60)
        XCTAssertEqual(g.radiusX, 30)
        XCTAssertEqual(g.radiusY, 15, accuracy: 1e-6)
        XCTAssertEqual(g.letters[0].y, -15, accuracy: 1e-6)
        XCTAssertEqual(g.letters[1].x, 30, accuracy: 1e-6)
        // Наклон за пределами — не ломает кольцо в линию или наизнанку.
        XCTAssertGreaterThan(CompassRing.geometry(radius: 30, mapDirection: 0, pitchDegrees: 120).radiusY, 0)
    }

    func testNorthIsMarkedAndThereAreFourSides() {
        XCTAssertEqual(CompassRing.marks.map(\.letter), ["N", "E", "S", "W"])
        XCTAssertEqual(CompassRing.marks.filter(\.isNorth).count, 1)
    }
}
