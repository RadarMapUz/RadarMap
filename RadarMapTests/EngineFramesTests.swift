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
        XCTAssertTrue(C.isCruise(was: false, tripActive: true, speedKmh: 90, approachingCamera: false, maneuverMeters: nil))
        XCTAssertTrue(C.isCruise(was: false, tripActive: true, speedKmh: 90, approachingCamera: false, maneuverMeters: 5000))
    }

    /// У камеры, у поворота, в городе и без поездки — полная плавность.
    func testCruiseNeverAppliesWhereTheDriverLooks() {
        XCTAssertFalse(C.isCruise(was: true, tripActive: true, speedKmh: 90, approachingCamera: true, maneuverMeters: nil))
        XCTAssertFalse(C.isCruise(was: true, tripActive: true, speedKmh: 90, approachingCamera: false, maneuverMeters: 400))
        XCTAssertFalse(C.isCruise(was: false, tripActive: true, speedKmh: 55, approachingCamera: false, maneuverMeters: nil),
                       "городской проспект — не крейсер")
        XCTAssertFalse(C.isCruise(was: true, tripActive: false, speedKmh: 90, approachingCamera: false, maneuverMeters: nil))
    }

    /// На пороге частота не мигает: вошли с 70, держимся до 60.
    func testCruiseHasHysteresis() {
        XCTAssertFalse(C.isCruise(was: false, tripActive: true, speedKmh: 65, approachingCamera: false, maneuverMeters: nil))
        XCTAssertTrue(C.isCruise(was: true, tripActive: true, speedKmh: 65, approachingCamera: false, maneuverMeters: nil))
        XCTAssertFalse(C.isCruise(was: true, tripActive: true, speedKmh: 59, approachingCamera: false, maneuverMeters: nil))
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
