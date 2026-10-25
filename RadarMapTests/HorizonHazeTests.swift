//
//  HorizonHazeTests.swift
//  RadarMapTests
//
//  Дымка у горизонта (29.F): плоская карта — без неё, сила растёт с
//  наклоном плавно, у края не глухая, к низу — прозрачная.
//

import XCTest
@testable import RadarMap

final class HorizonHazeTests: XCTestCase {

    func testFlatMapHasNoHaze() {
        XCTAssertEqual(HorizonHaze.look(pitchDegrees: 0).opacity, 0)
        XCTAssertEqual(HorizonHaze.look(pitchDegrees: AppConfig.hazeStartPitch).opacity, 0)
    }

    func testHazeGrowsMonotonicallyWithPitch() {
        var last = HorizonHaze.look(pitchDegrees: 0)
        for pitch in stride(from: 0.0, through: 60, by: 1) {
            let look = HorizonHaze.look(pitchDegrees: pitch)
            XCTAssertGreaterThanOrEqual(look.opacity, last.opacity)
            XCTAssertGreaterThanOrEqual(look.heightShare, last.heightShare)
            XCTAssertLessThanOrEqual(look.opacity, 1)
            last = look
        }
        XCTAssertEqual(HorizonHaze.look(pitchDegrees: AppConfig.engineMapPitchDegrees).opacity, 1)
        XCTAssertLessThanOrEqual(last.heightShare, AppConfig.hazeMaxHeightShare)
    }

    func testStopsFadeDownAndNeverOpaque() {
        for daylight in [true, false] {
            let stops = HorizonHaze.stops(daylight: daylight)
            XCTAssertEqual(stops.first?.at, 0)
            XCTAssertEqual(stops.last?.at, 1)
            XCTAssertEqual(stops.last?.alpha, 0, "к низу дымка прозрачна — шва нет")
            XCTAssertLessThan(stops.first?.alpha ?? 1, 0.9, "у края не глухая стена")
            XCTAssertEqual(stops.map(\.at), stops.map(\.at).sorted())
            XCTAssertEqual(stops.map(\.alpha), stops.map(\.alpha).sorted(by: >), "плотность только убывает")
            // К середине дымки — не плотнее половины: камера у верха кадра видна.
            let middle = stops.first { $0.at >= 0.5 }
            XCTAssertLessThanOrEqual(middle?.alpha ?? 1, 0.5)
        }
    }
}
