//
//  RouteRebuildTests.swift
//  RadarMapTests
//
//  Перестроение в пути (76): ведём по старой линии, голос старых поворотов —
//  только если мы снова на ней.
//

import XCTest
@testable import RadarMap

final class RouteRebuildTests: XCTestCase {

    func testOldLineVoicedWhenNotRebuilding() {
        XCTAssertTrue(RouteService.voicesOldLine(rebuilding: false, deviation: 400))
    }

    func testOldLineSilentWhileOffItDuringRebuild() {
        XCTAssertFalse(RouteService.voicesOldLine(rebuilding: true,
                                                  deviation: AppConfig.rerouteDeviationMeters + 1))
    }

    func testOldLineVoicedWhenBackOnItDuringRebuild() {
        XCTAssertTrue(RouteService.voicesOldLine(rebuilding: true, deviation: 20))
    }
}
