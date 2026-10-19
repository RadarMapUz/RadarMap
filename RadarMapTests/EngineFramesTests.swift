//
//  EngineFramesTests.swift
//  RadarMapTests
//
//  Частота кадров карты — прямо батарея (аудит энергии 19.10: политика не
//  была покрыта тестом вовсе).
//

import XCTest
@testable import RadarMap

#if canImport(MapLibre)
final class EngineFramesTests: XCTestCase {
    private typealias C = EngineMapView.Coordinator

    func testFollowingTheCarIsSmoothInTown() {
        XCTAssertEqual(C.framesPerSecond(browsing: false, performance: .full, lowPower: false),
                       AppConfig.engineFollowFPS)
    }

    func testHighwayCruiseFarFromCamerasDrawsLess() {
        XCTAssertEqual(C.framesPerSecond(browsing: false, performance: .full, lowPower: false, cruise: true),
                       AppConfig.engineWarmFPS)
        XCTAssertTrue(C.isCruise(tripActive: true, speedKmh: 90, approachingCamera: false, maneuverMeters: nil))
        XCTAssertTrue(C.isCruise(tripActive: true, speedKmh: 90, approachingCamera: false, maneuverMeters: 5000))
    }

    /// У камеры, у поворота, в городе и без поездки — полная плавность.
    func testCruiseNeverAppliesWhereTheDriverLooks() {
        XCTAssertFalse(C.isCruise(tripActive: true, speedKmh: 90, approachingCamera: true, maneuverMeters: nil))
        XCTAssertFalse(C.isCruise(tripActive: true, speedKmh: 90, approachingCamera: false, maneuverMeters: 400))
        XCTAssertFalse(C.isCruise(tripActive: true, speedKmh: 40, approachingCamera: false, maneuverMeters: nil))
        XCTAssertFalse(C.isCruise(tripActive: false, speedKmh: 90, approachingCamera: false, maneuverMeters: nil))
    }

    func testHandsOnTheMapGetFullRateUnlessHot() {
        XCTAssertEqual(C.framesPerSecond(browsing: true, performance: .full, lowPower: false, cruise: true), 0)
        XCTAssertEqual(C.framesPerSecond(browsing: true, performance: .reduced, lowPower: false),
                       AppConfig.engineWarmFPS)
    }

    func testCoveredAndHotPhoneAreTheLowest() {
        XCTAssertEqual(C.framesPerSecond(browsing: false, performance: .full, lowPower: false, covered: true),
                       AppConfig.engineHotFPS)
        XCTAssertEqual(C.framesPerSecond(browsing: false, performance: .minimal, lowPower: false),
                       AppConfig.engineHotFPS)
    }
}
#endif
