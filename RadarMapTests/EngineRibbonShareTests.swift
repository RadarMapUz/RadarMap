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

    private nonisolated final class User {}

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
        share.leave(c, user: ObjectIdentifier(car))
    }

    /// Смена плитка ↔ экран машины: прежнюю карту сносят раньше, чем новая
    /// возьмёт ленту. Запись без карт живёт drive3DShareKeepSeconds.
    func testOrphanedEntrySurvivesTheSwitchAndThenGoes() {
        let share = EngineRibbonShare.shared
        var line = points
        let route = MKPolyline(coordinates: &line, count: line.count)
        let car = User(), tile = User()
        let t0: CFTimeInterval = 1_000
        let a = share.entry(route: route, points: points, user: ObjectIdentifier(car), now: t0)
        share.leave(a, user: ObjectIdentifier(car), now: t0)
        XCTAssertTrue(share.entry(route: route, points: points, user: ObjectIdentifier(tile), now: t0 + 2) === a,
                      "плитка через 2 с берёт ту же запись")
        share.leave(a, user: ObjectIdentifier(tile), now: t0 + 3)
        let late = share.entry(route: route, points: points, user: ObjectIdentifier(car),
                               now: t0 + 3 + AppConfig.drive3DShareKeepSeconds)
        XCTAssertFalse(late === a, "без карт дольше срока — отпущена")
        share.leave(late, user: ObjectIdentifier(car), now: t0 + 50)

        // Новый маршрут, пока прежняя запись брошена, — прежняя уходит сразу.
        let b = share.entry(route: route, points: points, user: ObjectIdentifier(car), now: t0 + 100)
        share.leave(b, user: ObjectIdentifier(car), now: t0 + 100)
        var other = points.reversed() as [CLLocationCoordinate2D]
        let next = MKPolyline(coordinates: &other, count: other.count)
        let c = share.entry(route: next, points: other, user: ObjectIdentifier(car), now: t0 + 101)
        XCTAssertFalse(share.entry(route: route, points: points, user: ObjectIdentifier(tile), now: t0 + 102) === b,
                       "новый маршрут отпустил брошенную запись")
        share.leave(c, user: ObjectIdentifier(car), now: t0 + 103)
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
