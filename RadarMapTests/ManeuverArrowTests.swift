//
//  ManeuverArrowTests.swift
//  RadarMapTests
//
//  Стрелка манёвра на линии маршрута (29.G). Что проверяется: древко идёт
//  по линии маршрута через сам поворот, наконечник — после него и смотрит
//  по курсу выезда; без поворота (прибытие, «прямо», нет типа) и у самого
//  конца маршрута стрелки нет, а не стрелка «назад».
//

import CoreLocation
import XCTest
@testable import RadarMap

final class ManeuverArrowTests: XCTestCase {

    /// Едем на север ~200 м, затем направо (на восток) ~200 м.
    private let route: [CLLocationCoordinate2D] = [
        CLLocationCoordinate2D(latitude: 41.3000, longitude: 69.2500),
        CLLocationCoordinate2D(latitude: 41.3018, longitude: 69.2500),
        CLLocationCoordinate2D(latitude: 41.3018, longitude: 69.2524),
    ]

    func testShaftThroughTheTurnAndHeadAlongTheExit() throws {
        let cumulative = ManeuverArrow.cumulative(route)
        let turn = cumulative[1]
        let shape = try XCTUnwrap(ManeuverArrow.shape(along: turn, kind: .right, route: route, cumulative: cumulative))
        // Сам поворот — вершина древка.
        XCTAssertTrue(shape.shaft.contains { $0.latitude == route[1].latitude && $0.longitude == route[1].longitude })
        // Наконечник — на выезде, курс на восток.
        XCTAssertEqual(shape.head.latitude, 41.3018, accuracy: 1e-6)
        XCTAssertGreaterThan(shape.head.longitude, route[1].longitude)
        XCTAssertEqual(shape.bearing, 90, accuracy: 2)
        // Начало древка — на подъезде, ~22 м до поворота.
        let start = try XCTUnwrap(shape.shaft.first)
        XCTAssertEqual(GeoMath.fastDistance(start.latitude, start.longitude, route[1].latitude, route[1].longitude),
                       AppConfig.maneuverArrowBackMeters, accuracy: 1.5)
    }

    func testNoArrowWithoutATurn() {
        let cumulative = ManeuverArrow.cumulative(route)
        for kind in [ManeuverKind.arrive, .straight] {
            XCTAssertNil(ManeuverArrow.shape(along: cumulative[1], kind: kind, route: route, cumulative: cumulative))
        }
        XCTAssertNil(ManeuverArrow.shape(along: cumulative[1], kind: nil, route: route, cumulative: cumulative))
        XCTAssertTrue(ManeuverArrow.draws(.uturn))
        XCTAssertTrue(ManeuverArrow.draws(.roundabout))
    }

    func testNoArrowAtTheVeryEndOrWithBrokenData() {
        let cumulative = ManeuverArrow.cumulative(route)
        let length = cumulative[cumulative.count - 1]
        // Финиш в 3 м за поворотом: наконечник лёг бы на сам поворот.
        XCTAssertNil(ManeuverArrow.shape(along: length - 3, kind: .right, route: route, cumulative: cumulative))
        XCTAssertNil(ManeuverArrow.shape(along: length + 10, kind: .right, route: route, cumulative: cumulative))
        XCTAssertNil(ManeuverArrow.shape(along: 50, kind: .right, route: route, cumulative: [0, 1]))
        XCTAssertNil(ManeuverArrow.shape(along: .nan, kind: .right, route: route, cumulative: cumulative))
    }

    func testCumulativeIsTheRouteServiceMeasure() {
        let cumulative = ManeuverArrow.cumulative(route)
        XCTAssertEqual(cumulative.count, route.count)
        XCTAssertEqual(cumulative[0], 0)
        // ~200 м на север.
        XCTAssertEqual(cumulative[1], 200, accuracy: 15)
    }
}
