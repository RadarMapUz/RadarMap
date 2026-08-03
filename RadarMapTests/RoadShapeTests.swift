//
//  RoadShapeTests.swift
//  RadarMapTests
//
//  Дорога камеры: распаковка куска проезжей части, расстояние до него, ось на
//  кривой, ширина коридора от полос. Главный смысл этих данных — различать
//  стороны разделённой дороги: ось (0–179°) их не различает, и камера обратного
//  направления считалась «нашей».
//

import XCTest
import CoreLocation
@testable import RadarMap

final class RoadShapeTests: XCTestCase {

    private let base = CLLocationCoordinate2D(latitude: 41.3110, longitude: 69.2790)

    /// Камера с куском дороги: `bearing` — направление куска от точки камеры.
    private func camera(id: Int = 1, bearing: Double = 90, spanMeters: Double = 100,
                        points: Int = 3, lanes: Int? = nil, cls: String? = nil,
                        dir: Int? = nil, axis: Int? = nil,
                        at coordinate: CLLocationCoordinate2D? = nil) -> Camera {
        let center = coordinate ?? base
        var road: [Int] = []
        for step in 0..<points {
            let offset = spanMeters * (Double(step) / Double(points - 1) - 0.5) * 2
            let p = GeoMath.destination(from: center, bearing: bearing, distanceMeters: offset)
            road.append(Int(((p.latitude - center.latitude) * 1e6).rounded()))
            road.append(Int(((p.longitude - center.longitude) * 1e6).rounded()))
        }
        return Camera(id: id, region: "Т", city: "", location: "к",
                      lat: center.latitude, lon: center.longitude,
                      type: "Стационар радар", violations: [], needsReview: false,
                      axis: axis, dir: dir, lanes: lanes, cls: cls, bridge: nil, road: road)
    }

    // MARK: - Распаковка

    func testShapeDecodesDeltas() throws {
        let shape = try XCTUnwrap(RoadShape(camera: camera(points: 3)))
        XCTAssertEqual(shape.points.count, 3)
        // Средняя точка — сама камера.
        XCTAssertEqual(shape.points[1].latitude, base.latitude, accuracy: 1e-5)
        XCTAssertEqual(shape.points[1].longitude, base.longitude, accuracy: 1e-5)
    }

    func testShapeIsNilWithoutRoad() {
        let bare = Camera(id: 2, region: "Т", city: "", location: "к",
                          lat: base.latitude, lon: base.longitude,
                          type: "Стационар радар", violations: [], needsReview: false)
        XCTAssertNil(RoadShape(camera: bare), "старая база без куска дороги — не ошибка")
    }

    func testShapeIsNilOnBrokenPayload() {
        let broken = Camera(id: 3, region: "Т", city: "", location: "к",
                            lat: base.latitude, lon: base.longitude,
                            type: "Стационар радар", violations: [], needsReview: false,
                            road: [10, 20, 30])   // нечётное число чисел
        XCTAssertNil(RoadShape(camera: broken))
    }

    // MARK: - Расстояние до дороги

    /// Смысл всей затеи: параллельная проезжая часть в 20 м — это другая дорога.
    func testDistanceSeparatesParallelCarriageway() throws {
        let shape = try XCTUnwrap(RoadShape(camera: camera(bearing: 90)))
        let onRoad = GeoMath.destination(from: base, bearing: 90, distanceMeters: 40)
        let parallel = GeoMath.destination(from: base, bearing: 0, distanceMeters: 20)

        XCTAssertLessThan(shape.distance(from: onRoad), 3, "мы на этой дороге")
        XCTAssertEqual(shape.distance(from: parallel), 20, accuracy: 2,
                       "соседняя проезжая часть — 20 м от ломаной")
    }

    func testDistanceIsMeasuredToSegmentNotVertex() throws {
        // Кусок из двух далёких вершин: точка между ними лежит НА дороге,
        // хотя до каждой вершины далеко.
        let shape = try XCTUnwrap(RoadShape(camera: camera(bearing: 90, spanMeters: 100,
                                                           points: 2)))
        XCTAssertLessThan(shape.distance(from: base), 2)
    }

    // MARK: - Ось на кривой

    func testAxisFollowsLocalSegmentOnCurve() throws {
        // Дуга: первая половина на восток, вторая — на север.
        var road: [Int] = []
        var point = base
        for step in 0..<7 {
            road.append(Int(((point.latitude - base.latitude) * 1e6).rounded()))
            road.append(Int(((point.longitude - base.longitude) * 1e6).rounded()))
            point = GeoMath.destination(from: point, bearing: step < 3 ? 90 : 0,
                                        distanceMeters: 30)
        }
        let curved = Camera(id: 4, region: "Т", city: "", location: "к",
                            lat: base.latitude, lon: base.longitude,
                            type: "Стационар радар", violations: [], needsReview: false,
                            axis: 90, road: road)
        let shape = try XCTUnwrap(RoadShape(camera: curved))

        let onEastPart = GeoMath.destination(from: base, bearing: 90, distanceMeters: 30)
        XCTAssertEqual(shape.axis(near: onEastPart) ?? -1, 90, accuracy: 12,
                       "в начале дуги дорога идёт на восток")
        let onNorthPart = GeoMath.destination(
            from: GeoMath.destination(from: base, bearing: 90, distanceMeters: 90),
            bearing: 0, distanceMeters: 60)
        XCTAssertEqual(shape.axis(near: onNorthPart) ?? -1, 0, accuracy: 12,
                       "в конце дуги — на север, хотя ось всей дороги записана как 90")
    }

    // MARK: - Ширина коридора от полос

    func testHalfWidthGrowsWithLanes() {
        let street = RoadGeometry.halfWidth(lanes: 2, roadClass: .residential)
        let avenue = RoadGeometry.halfWidth(lanes: 6, roadClass: .primary)
        XCTAssertLessThan(street, avenue)
        XCTAssertEqual(street, 2 * AppConfig.laneWidthMeters / 2
                       + AppConfig.roadPositionSlackMeters, accuracy: 0.01)
    }

    func testHalfWidthFallsBackToRoadClass() {
        // Тега lanes в OSM часто нет — класс дороги даёт разумное предположение.
        XCTAssertGreaterThan(RoadGeometry.halfWidth(lanes: nil, roadClass: .motorway),
                             RoadGeometry.halfWidth(lanes: nil, roadClass: .residential))
    }

    // MARK: - Класс дороги

    func testRoadClassParsingAndContext() {
        XCTAssertTrue(RoadClass(raw: "trunk").isHighway)
        XCTAssertTrue(RoadClass(raw: "motorway_link").isHighway)
        XCTAssertTrue(RoadClass(raw: "residential").isCityStreet)
        XCTAssertFalse(RoadClass(raw: "primary").isHighway, "проспект — не трасса")
        XCTAssertFalse(RoadClass(raw: "primary").isCityStreet)
        XCTAssertEqual(RoadClass(raw: nil), .unknown)
        XCTAssertEqual(RoadClass(raw: "невнятное"), .unknown)
    }

    /// Класс дороги — мгновенный голос детектора: «trunk» переводит в режим
    /// трассы, не дожидаясь, пока устоится средняя скорость.
    func testHighwayClassSwitchesContextImmediately() {
        var detector = AlertPolicy.Detector()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        detector.update(roadLimitKmh: nil, camerasWithin3km: 0, speedKmh: 50,
                        roadClass: .trunk, now: now)
        XCTAssertEqual(detector.context, .highway)
    }

    func testResidentialClassKeepsCityQuiet() {
        var detector = AlertPolicy.Detector()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // Разогнались, камер рядом мало — но это жилая улица, режим города.
        detector.update(roadLimitKmh: nil, camerasWithin3km: 0, speedKmh: 95,
                        roadClass: .residential, now: now)
        XCTAssertEqual(detector.context, .city)
    }
}
