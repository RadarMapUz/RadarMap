//
//  OSRMQueryTests.swift
//  RadarMapTests
//
//  Запрос к своему OSRM (29.E): три варианта и подъезд к цели с её стороны —
//  и прежний запрос, если сервер новые параметры не примет: маршрут обязан
//  построиться на любом сервере.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class OSRMQueryTests: XCTestCase {

    private func value(_ items: [URLQueryItem], _ name: String) -> String? {
        items.first { $0.name == name }?.value
    }

    func testAsksForAlternativesByNumberNotTrue() {
        // `true` у OSRM — одна альтернатива: третьей плашки не было никогда.
        let items = OSRMQuery.items(alternatives: true, heading: nil, waypoints: 2)
        XCTAssertEqual(value(items, "alternatives"), String(AppConfig.osrmAlternatives))
        XCTAssertEqual(value(OSRMQuery.items(alternatives: false, heading: nil, waypoints: 2), "alternatives"),
                       "false", "перестроение и остановка — без альтернатив, как раньше")
    }

    func testArrivesOnTheDestinationSide() {
        XCTAssertEqual(value(OSRMQuery.items(alternatives: true, heading: nil, waypoints: 2), "approaches"),
                       "unrestricted;curb", "старт — откуда угодно, цель — со своей стороны")
        XCTAssertEqual(value(OSRMQuery.items(alternatives: false, heading: 90, waypoints: 3), "approaches"),
                       "unrestricted;curb;curb", "АЗС по пути — тоже со своей стороны")
    }

    func testMyRoadViaPointsHaveNoSide() {
        let via = [MyRoad.Via(latitude: 41.3, longitude: 69.2, bearing: 90, along: 1000),
                   MyRoad.Via(latitude: 41.31, longitude: 69.21, bearing: 45, along: 2500)]
        let items = OSRMQuery.viaItems(heading: nil, via: via)
        XCTAssertEqual(value(items, "approaches"), "unrestricted;unrestricted;unrestricted;curb",
                       "у проходной точки нет прибытия — сторона ей не нужна")
        XCTAssertEqual(value(items, "waypoints"), "0;3")
        XCTAssertNil(value(OSRMQuery.viaItems(heading: nil, via: via, legacy: true), "approaches"))
    }

    func testLegacyQueryIsExactlyTheOldOne() {
        let legacy = OSRMQuery.items(alternatives: true, heading: 270.4, waypoints: 2, legacy: true)
        XCTAssertEqual(value(legacy, "alternatives"), "true")
        XCTAssertNil(value(legacy, "approaches"))
        XCTAssertEqual(value(legacy, "bearings"), "270,\(AppConfig.rerouteBearingRangeDegrees);",
                       "курс остаётся и в прежнем запросе")
        XCTAssertEqual(legacy.map(\.name), ["overview", "geometries", "alternatives", "steps", "bearings", "radiuses"])
    }

    func testRetriesOnlyWhenTheServerRefused() {
        XCTAssertTrue(OSRMQuery.retriesLegacy(status: 400), "InvalidOptions / NoRoute с нужной стороны")
        XCTAssertTrue(OSRMQuery.retriesLegacy(status: 414))
        XCTAssertFalse(OSRMQuery.retriesLegacy(status: 200))
        XCTAssertFalse(OSRMQuery.retriesLegacy(status: 502), "сервер лежит — прежний запрос упал бы так же")
    }

    /// Сервер отверг новые параметры — маршрут строится прежним запросом.
    func testRefusedQueryFallsBackAndTheRouteStillBuilds() async throws {
        var calls: [Bool] = []
        let answer = try await OSRMQuery.send { legacy in
            calls.append(legacy)
            return legacy
                ? OSRMQuery.Answer(status: 200, data: Data(#"{"code":"Ok"}"#.utf8))
                : OSRMQuery.Answer(status: 400, data: Data(#"{"code":"InvalidOptions"}"#.utf8))
        }
        XCTAssertEqual(calls, [false, true])
        XCTAssertEqual(answer.status, 200)
        XCTAssertTrue(answer.legacy)
        XCTAssertEqual(String(decoding: answer.data, as: UTF8.self), #"{"code":"Ok"}"#)
    }

    func testAcceptedQueryIsSentOnce() async throws {
        var calls = 0
        let answer = try await OSRMQuery.send { _ in
            calls += 1
            return OSRMQuery.Answer(status: 200, data: Data())
        }
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(answer.legacy)
    }

    func testServerDownIsNotRetried() async throws {
        var calls = 0
        let answer = try await OSRMQuery.send { _ in
            calls += 1
            return OSRMQuery.Answer(status: 503, data: Data())
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(answer.status, 503)
    }

    func testNoConnectionIsNotRetried() async {
        var calls = 0
        do {
            _ = try await OSRMQuery.send { _ in
                calls += 1
                throw RouteService.RouteError.noConnection
            }
            XCTFail("ошибка связи уходит наружу")
        } catch {
            XCTAssertEqual(error as? RouteService.RouteError, .noConnection)
        }
        XCTAssertEqual(calls, 1, "второй таймаут — ещё 12 с без маршрута")
    }
}
