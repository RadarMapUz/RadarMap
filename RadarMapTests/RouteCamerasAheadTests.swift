//
//  RouteCamerasAheadTests.swift
//  RadarMapTests
//
//  Камеры впереди по маршруту (10.4): только те, что впереди точки
//  прогресса, ближние первыми, с остатком пути до каждой.
//

import XCTest
@testable import RadarMap

final class RouteCamerasAheadTests: XCTestCase {
    private func camera(_ id: Int) -> Camera {
        Camera(id: id, region: "Ташкент", city: "Ташкент", location: "Улица \(id)",
               lat: 41.3, lon: 69.28, type: "Стационар радар", violations: [], needsReview: nil)
    }

    func testOnlyAheadNearestFirst() {
        let cameras = [RouteService.RouteCamera(camera: camera(3), distanceAlong: 3_400),
                       RouteService.RouteCamera(camera: camera(1), distanceAlong: 800),
                       RouteService.RouteCamera(camera: camera(2), distanceAlong: 1_200)]
        let ahead = RouteCamerasAhead.list(cameras, progress: 1_000)
        XCTAssertEqual(ahead.map(\.camera.id), [2, 3], "проеханная (800 м при прогрессе 1000) — не впереди")
        XCTAssertEqual(ahead.map(\.meters), [200, 2_400])
    }

    func testAtTheCameraItIsBehind() {
        let cameras = [RouteService.RouteCamera(camera: camera(1), distanceAlong: 500)]
        XCTAssertTrue(RouteCamerasAhead.list(cameras, progress: 500).isEmpty)
    }

    func testLimitKeepsTheNearest() {
        let cameras = (1...5).map { RouteService.RouteCamera(camera: camera($0), distanceAlong: Double($0) * 1_000) }
        XCTAssertEqual(RouteCamerasAhead.list(cameras, progress: 0, limit: 2).map(\.camera.id), [1, 2])
        XCTAssertTrue(RouteCamerasAhead.list(cameras, progress: 0, limit: 0).isEmpty)
    }
}
