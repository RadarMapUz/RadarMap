//
//  EngineRibbonShareTests.swift
//  RadarMapTests
//
//  Общая лента «Вождения 3D» (48): две карты одного маршрута получают одну
//  запись, новый маршрут — новую, без карт запись отпускается.
//

#if canImport(MapLibre)
import CoreLocation
import MapKit
import XCTest
@testable import RadarMap

final class EngineRibbonShareTests: XCTestCase {
    private let points = [CLLocationCoordinate2D(latitude: 41.30, longitude: 69.24),
                          CLLocationCoordinate2D(latitude: 41.31, longitude: 69.25)]

    private final class User {}

    func testTwoMapsOfOneRouteShareOneEntry() {
        let share = EngineRibbonShare.shared
        var line = points
        let route = MKPolyline(coordinates: &line, count: line.count)
        let car = User(), tile = User()
        let a = share.entry(route: route, points: points, user: ObjectIdentifier(car))
        let b = share.entry(route: route, points: points, user: ObjectIdentifier(tile))
        XCTAssertTrue(a === b, "экран машины и плитка — одна запись")
        XCTAssertEqual(a.cumulative.count, points.count)

        var other = points.reversed() as [CLLocationCoordinate2D]
        let next = MKPolyline(coordinates: &other, count: other.count)
        let c = share.entry(route: next, points: other, user: ObjectIdentifier(car))
        XCTAssertFalse(c === a, "другой маршрут — своя запись")
        XCTAssertNotEqual(c.id, a.id, "и свой номер для Drive3D.Plan")

        share.leave(a, user: ObjectIdentifier(car))
        XCTAssertTrue(share.entry(route: route, points: points, user: ObjectIdentifier(car)) === a,
                      "плитка ещё на маршруте — запись жива")
        share.leave(a, user: ObjectIdentifier(car))
        share.leave(a, user: ObjectIdentifier(tile))
        XCTAssertFalse(share.entry(route: route, points: points, user: ObjectIdentifier(car)) === a,
                       "без карт запись отпущена")
        share.leave(c, user: ObjectIdentifier(car))
    }

    func testInFlightComputeBlocksOnlyOthersAndGoesStale() {
        let share = EngineRibbonShare.shared
        let car = User(), tile = User()
        let entry = share.entry(route: nil, points: points, user: ObjectIdentifier(car))
        entry.computing = (ObjectIdentifier(car), 100)
        XCTAssertTrue(entry.isComputing(now: 101, except: ObjectIdentifier(tile)), "плитка ждёт расчёт машины")
        XCTAssertFalse(entry.isComputing(now: 101, except: ObjectIdentifier(car)), "свой расчёт себя не держит")
        XCTAssertFalse(entry.isComputing(now: 100 + AppConfig.drive3DShareStaleSeconds,
                                         except: ObjectIdentifier(tile)), "брошенный расчёт очередь не держит")
        share.leave(entry, user: ObjectIdentifier(car))
    }
}
#endif
