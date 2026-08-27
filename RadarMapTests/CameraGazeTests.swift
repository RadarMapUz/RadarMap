//
//  CameraGazeTests.swift
//  RadarMapTests
//
//  Камера смотрит — и ровно настолько уверенно, насколько мы знаем.
//
//  Главный объект приложения был нарисован беднее всех: кружок, по которому
//  нельзя понять, ловит ли камера ТВОЁ направление. Но и рисовать направление
//  везде нельзя: `dir` в базе есть только у односторонних дорог, где OSM знает
//  его однозначно, а у двусторонней улицы куда смотрит камера, не знает никто.
//
//  Выдуманный конус водитель однажды поймает, и после этого перестанет верить
//  и правде. Поэтому здесь сторожится не картинка, а честность данных.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class CameraGazeTests: XCTestCase {

    private func camera(id: Int = 1, axis: Int? = nil, dir: Int? = nil,
                        lat: Double = 41.311, lon: Double = 69.279) -> Camera {
        Camera(id: id, region: "Ташкент", city: "Ташкент", location: "тест",
               lat: lat, lon: lon, type: "Стационар камера",
               violations: [], needsReview: false, axis: axis, dir: dir)
    }

    private func scene(_ cameras: [Camera], span: Double = 220) -> RoadSketch.Scene {
        RoadSketch.scene(alertCamera: nil, alertInRange: false,
                         cameras: cameras, networkBudget: 400,
                         showMinorRoads: true, precomputed: true,
                         areas: [], areaBudget: 200, points: [],
                         route: [], track: [],
                         anchor: CLLocationCoordinate2D(latitude: 41.311,
                                                        longitude: 69.279),
                         spanMeters: span)
    }

    func testDirectionIsCarriedWhenKnown() {
        let dot = scene([camera(axis: 90, dir: 270)]).cameras.first
        XCTAssertEqual(dot?.facing ?? 0, 270, accuracy: 0.001)
        XCTAssertEqual(dot?.axis ?? 0, 90, accuracy: 0.001)
    }

    func testTwoWayStreetHasNoDirection() {
        // У двусторонней улицы направления нет в данных — и на схеме его быть
        // не должно.
        let dot = scene([camera(axis: 90, dir: nil)]).cameras.first
        XCTAssertNil(dot?.facing)
        XCTAssertEqual(dot?.axis ?? 0, 90, accuracy: 0.001)
    }

    func testCameraWithoutProfileClaimsNothing() {
        let dot = scene([camera(axis: nil, dir: nil)]).cameras.first
        XCTAssertNotNil(dot, "камера обязана остаться на схеме")
        XCTAssertNil(dot?.facing)
        XCTAssertNil(dot?.axis)
    }

    func testEveryCameraInRangeKeepsItsIdentity() {
        // На ферганском чорраха их четыре, и одна точка прятала три остальные.
        let dots = scene([camera(id: 1), camera(id: 2, lat: 41.3112),
                          camera(id: 3, lat: 41.3114)]).cameras
        XCTAssertEqual(Swift.Set(dots.map(\.id)), [1, 2, 3])
    }

    func testAlertCameraIsDrawnEvenIfFiltered() {
        // Тревожная рисуется гарантированно: спрятать её вместе с мелкой
        // улицей значит промолчать о том, ради чего приложение существует.
        let alert = camera(id: 9, axis: 10, dir: 10)
        let built = RoadSketch.scene(
            alertCamera: alert, alertInRange: true, cameras: [],
            networkBudget: 400, showMinorRoads: false,
            precomputed: true, areas: [], areaBudget: 200, points: [],
            route: [], track: [],
            anchor: CLLocationCoordinate2D(latitude: 41.311, longitude: 69.279),
            spanMeters: 220)
        XCTAssertEqual(built.alertCameraID, 9)
        XCTAssertTrue(built.cameras.contains { $0.id == 9 })
        XCTAssertEqual(built.cameras.first(where: { $0.id == 9 })?.facing ?? 0,
                       10, accuracy: 0.001)
    }
}
