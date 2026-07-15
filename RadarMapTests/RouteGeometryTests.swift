//
//  RouteGeometryTests.swift
//  RadarMapTests
//
//  Геометрия маршрута: коридор камер, проекция прогресса, пройденный префикс, манёвры.
//

import XCTest
import MapKit
@testable import RadarMap

final class RouteGeometryTests: XCTestCase {

    /// Прямой маршрут на восток вдоль широты 41.30: от 69.20 до 69.30 (~8.4 км).
    private var straightRoute: [MKMapPoint] {
        stride(from: 69.20, through: 69.30, by: 0.005).map {
            MKMapPoint(CLLocationCoordinate2D(latitude: 41.30, longitude: $0))
        }
    }

    private func camera(id: Int, lat: Double, lon: Double) -> Camera {
        Camera(id: id, region: "Тест", city: "", location: "тестовая",
               lat: lat, lon: lon, type: "Стационар радар",
               violations: [], needsReview: nil)
    }

    private func bbox(of pts: [MKMapPoint]) -> MKMapRect {
        var rect = MKMapRect.null
        for p in pts { rect = rect.union(MKMapRect(origin: p, size: MKMapSize())) }
        return rect
    }

    func testCamerasAlongFindsOnlyCorridorCameras() {
        let pts = straightRoute
        let cameras = [
            camera(id: 1, lat: 41.3001, lon: 69.25),   // ~11 м от линии — в коридоре
            camera(id: 2, lat: 41.31, lon: 69.25),     // ~1.1 км — мимо
            camera(id: 3, lat: 41.3000, lon: 69.21),   // на линии, ближе к старту
        ]
        let found = RouteService.camerasAlong(pts: pts, bbox: bbox(of: pts),
                                              centerLat: 41.30, cameras: cameras)
        XCTAssertEqual(found.map(\.id), [3, 1], "порядок — по расстоянию от старта")

        // Камера №3 стоит через ~0.01° долготы от старта ≈ 830 м.
        XCTAssertEqual(found[0].distanceAlong, 830, accuracy: 60)
    }

    func testProjectReturnsProgressAndDeviation() {
        let pts = straightRoute
        var hint = 0
        // Точка около середины маршрута, смещена на ~55 м к северу.
        let probe = MKMapPoint(CLLocationCoordinate2D(latitude: 41.3005, longitude: 69.25))
        let (along, deviation) = RouteService.project(probe, onto: pts, hint: &hint)

        XCTAssertEqual(deviation, 55, accuracy: 10)
        // Пройдено ~половина из ~8.4 км.
        XCTAssertEqual(along, 4180, accuracy: 150)
        XCTAssertGreaterThan(hint, 0, "подсказка сегмента должна сдвинуться к середине")
    }

    func testTraveledPrefixLength() {
        let pts = straightRoute
        guard let prefix = RouteService.traveledPrefix(points: pts, upTo: 1000) else {
            return XCTFail("префикс на 1 км должен существовать")
        }
        let coords = prefix.points()
        var length = 0.0
        for i in 1..<prefix.pointCount { length += coords[i - 1].distance(to: coords[i]) }
        XCTAssertEqual(length, 1000, accuracy: 5)

        XCTAssertNil(RouteService.traveledPrefix(points: pts, upTo: 30),
                     "первые метры не рисуем — нечего показывать")
    }

    func testManeuverStepMapping() {
        func step(_ type: String, _ modifier: String?, name: String = "", exit: Int? = nil) -> RouteStep? {
            RouteService.maneuverStep(
                RouteService.OSRMResponse.Step(
                    distance: 100, name: name,
                    maneuver: RouteService.OSRMResponse.Maneuver(type: type, modifier: modifier, exit: exit)),
                at: 500)
        }

        XCTAssertEqual(step("turn", "right")?.icon, "arrow.turn.up.right")
        XCTAssertEqual(step("turn", "left")?.icon, "arrow.turn.up.left")
        XCTAssertEqual(step("roundabout", nil, exit: 2)?.icon, "arrow.triangle.2.circlepath")
        XCTAssertEqual(step("arrive", nil)?.icon, "flag.checkered")
        XCTAssertNil(step("new name", "straight"), "смену названия улицы не озвучиваем")
        XCTAssertNil(step("depart", nil), "старт не озвучиваем")

        // Название улицы попадает в текст манёвра.
        let named = step("turn", "right", name: "Амира Темура")
        XCTAssertTrue(named?.text.contains("Амира Темура") == true)
        XCTAssertEqual(named?.distanceAlong, 500)
    }
}
