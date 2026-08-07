//
//  MapCameraTests.swift
//  RadarMapTests
//
//  Автозум ведения карты: чистые функции высоты камеры и точки взгляда.
//

import XCTest
@testable import RadarMap

final class MapCameraTests: XCTestCase {

    func testCameraDistanceGrowsWithSpeed() {
        let standing = MapState.cameraDistance(forSpeedKmh: 0, pitched: true)
        let city = MapState.cameraDistance(forSpeedKmh: 50, pitched: true)
        let highway = MapState.cameraDistance(forSpeedKmh: 100, pitched: true)
        XCTAssertLessThan(standing, city)
        XCTAssertLessThan(city, highway)
        // Потолок: выше зума схема перестаёт отвечать на «что прямо передо мной».
        XCTAssertLessThanOrEqual(MapState.cameraDistance(forSpeedKmh: 200, pitched: true), 1300)
    }

    /// Ступени по 100 м: шум скорости ±2 км/ч не должен заставлять карту дышать.
    func testCameraDistanceIsQuantized() {
        let a = MapState.cameraDistance(forSpeedKmh: 60, pitched: true)
        let b = MapState.cameraDistance(forSpeedKmh: 61, pitched: true)
        XCTAssertEqual(a, b, "соседние скорости — одна ступень")
        XCTAssertEqual(a.truncatingRemainder(dividingBy: 100), 0)
    }

    func testUnpitchedKeepsClassicDistance() {
        XCTAssertEqual(MapState.cameraDistance(forSpeedKmh: 90, pitched: false), 900)
    }

    func testLookAheadGrowsWithSpeedAndIsBounded() {
        XCTAssertLessThan(MapState.lookAheadMeters(forSpeedKmh: 0),
                          MapState.lookAheadMeters(forSpeedKmh: 90))
        XCTAssertLessThanOrEqual(MapState.lookAheadMeters(forSpeedKmh: 300), 280)
        XCTAssertGreaterThanOrEqual(MapState.lookAheadMeters(forSpeedKmh: 0), 120)
    }
}
