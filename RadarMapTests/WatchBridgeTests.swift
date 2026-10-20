//
//  WatchBridgeTests.swift
//  RadarMapTests
//
//  Что уходит на часы (9.3): в спокойном режиме скорость не идёт вовсе —
//  она была старой цифрой на запястье и будила радио ради неё; в тревоге и
//  при превышении — идёт. Смена знака, превышения, камеры и уровня — повод
//  отправить сразу; бегущая дистанция — нет.
//

import XCTest
@testable import RadarMap

final class WatchBridgeTests: XCTestCase {
    private func payload(speed: Double = 64, title: String? = "Юнусабад", distance: Double? = 800,
                         level: Int = 0, limit: Int? = 60, over: Bool = false,
                         active: Bool = true) -> WatchBridgeService.Payload {
        WatchBridgeService.payload(isTripActive: active, speedKmh: speed, cameraTitle: title,
                                   cameraSymbol: "camera.fill", distanceMeters: distance,
                                   alertLevel: level, limitKmh: limit, isOverspeeding: over)
    }

    func testCalmModeSendsNoSpeed() {
        XCTAssertNil(payload().speed, "спокойно — без скорости")
        XCTAssertEqual(payload(speed: 61), payload(speed: 75), "скорость в спокойном режиме — не повод")
        XCTAssertEqual(payload(level: 2).speed, 64, "тревога — скорость идёт")
        XCTAssertEqual(payload(speed: 71, over: true).speed, 72, "превышение — скорость идёт, шаг 2")
        XCTAssertNil(payload(level: 2, active: false).speed, "вне поездки — нет")
    }

    func testMeaningChangesAreUrgent() {
        let old = payload()
        XCTAssertTrue(payload(limit: 40).isUrgent(comparedTo: old), "сменился знак")
        XCTAssertTrue(payload(over: true).isUrgent(comparedTo: old), "началось превышение")
        XCTAssertTrue(payload(title: "Чиланзар").isUrgent(comparedTo: old), "другая камера")
        XCTAssertTrue(payload(level: 1).isUrgent(comparedTo: old), "уровень тревоги")
        XCTAssertFalse(payload(distance: 700).isUrgent(comparedTo: old), "бегущая дистанция ждёт интервала")
        XCTAssertTrue(payload().isUrgent(comparedTo: nil), "первое состояние")
    }

    func testContextCarriesOnlyWhatIsKnown() {
        let context = payload(title: nil, distance: nil, limit: nil).context
        XCTAssertNil(context["dist"])
        XCTAssertNil(context["title"])
        XCTAssertNil(context["sym"], "без камеры — без значка типа")
        XCTAssertNil(context["limit"])
        XCTAssertNil(context["speed"])
        XCTAssertEqual(context["active"] as? Bool, true)
        let full = payload(level: 3, over: true).context
        XCTAssertEqual(full["limit"] as? Int, 60)
        XCTAssertEqual(full["over"] as? Bool, true)
        XCTAssertEqual(full["sym"] as? String, "camera.fill")
        XCTAssertEqual(full["speed"] as? Int, 64)
    }
}
