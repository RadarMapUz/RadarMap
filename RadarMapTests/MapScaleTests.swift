//
//  MapScaleTests.swift
//  RadarMapTests
//
//  Крупнее в машине (29.F): множитель входит в каждую ступень, зум остаётся
//  на верхнем уровне — иначе движок отверг бы стиль целиком.
//

import XCTest
@testable import RadarMap

final class MapScaleTests: XCTestCase {

    func testInterpolateScalesEveryOutputNotTheStops() {
        let size: [Any] = ["interpolate", ["linear"], ["zoom"], 13, 10.0, 16, 12.0, 20, 16.0]
        let out = MapScale.scaled(size, by: 1.5) as? [Any]
        XCTAssertEqual(out?.count, size.count)
        XCTAssertEqual(out?[3] as? Int, 13, "ступень зума не трогается")
        XCTAssertEqual(out?[4] as? Double, 15)
        XCTAssertEqual(out?[6] as? Double, 18)
        XCTAssertEqual(out?[8] as? Double, 24)
        XCTAssertEqual((out?[2] as? [Any])?.first as? String, "zoom", "зум на верхнем уровне")
    }

    func testNumberAndStep() {
        XCTAssertEqual(MapScale.scaled(10.0, by: 1.2) as? Double ?? 0, 12, accuracy: 1e-9)
        XCTAssertEqual(MapScale.scaled(NSNumber(value: 5), by: 2) as? Double, 10)
        let step: [Any] = ["step", ["zoom"], 8.0, 15, 10.0]
        let out = MapScale.scaled(step, by: 2) as? [Any]
        XCTAssertEqual(out?[2] as? Double, 16)
        XCTAssertEqual(out?[3] as? Int, 15)
        XCTAssertEqual(out?[4] as? Double, 20)
    }

    func testDataExpressionIsWrappedAndNestedZoomIsLeftAlone() {
        let data: [Any] = ["get", "w"]
        let wrapped = MapScale.scaled(data, by: 2) as? [Any]
        XCTAssertEqual(wrapped?.first as? String, "*")
        let nested: [Any] = ["max", ["interpolate", ["linear"], ["zoom"], 1, 1, 2, 2], 3]
        XCTAssertEqual(String(describing: MapScale.scaled(nested, by: 2)), String(describing: nested))
    }
}
