//
//  WatchBridgeTests.swift
//  RadarMapTests
//
//  Что уходит на часы (9.3): в спокойном режиме скорость не идёт вовсе —
//  она была старой цифрой на запястье и будила радио ради неё; в тревоге и
//  при превышении — идёт. Смена знака, превышения, камеры и уровня — повод
//  отправить сразу; бегущая дистанция — нет. С 14.5 — id камеры и время
//  отправки поверх прежних ключей: старая сборка часов их не читает.
//

import XCTest
@testable import RadarMap

final class WatchBridgeTests: XCTestCase {
    private func payload(speed: Double = 64, title: String? = "Юнусабад", distance: Double? = 800,
                         level: Int = 0, limit: Int? = 60, over: Bool = false,
                         active: Bool = true, cameraID: Int? = 3496) -> WatchBridgeService.Payload {
        WatchBridgeService.payload(isTripActive: active, speedKmh: speed, cameraTitle: title,
                                   cameraSymbol: "camera.fill", cameraID: cameraID,
                                   distanceMeters: distance, alertLevel: level, limitKmh: limit,
                                   isOverspeeding: over)
    }

    private let sentAt = Date(timeIntervalSince1970: 1_800_000_000)

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
        // Фронт вниз ждёт интервала: дребезг у самого лимита не будит радио.
        let over = payload(over: true)
        XCTAssertFalse(payload().isUrgent(comparedTo: over), "перестали превышать — не срочно")
        let alarm = payload(level: 1)
        XCTAssertFalse(payload(level: 1, over: false).isUrgent(comparedTo: alarm))
        XCTAssertTrue(payload().isUrgent(comparedTo: nil), "первое состояние")
    }

    func testContextCarriesOnlyWhatIsKnown() {
        let context = payload(title: nil, distance: nil, limit: nil).context(sentAt: sentAt)
        XCTAssertNil(context["dist"])
        XCTAssertNil(context["title"])
        XCTAssertNil(context["sym"], "без камеры — без значка типа")
        XCTAssertNil(context["cid"], "без камеры — без id")
        XCTAssertNil(context["limit"])
        XCTAssertNil(context["speed"])
        XCTAssertEqual(context["active"] as? Bool, true)
        let full = payload(level: 3, over: true).context(sentAt: sentAt)
        XCTAssertEqual(full["limit"] as? Int, 60)
        XCTAssertEqual(full["over"] as? Bool, true)
        XCTAssertEqual(full["sym"] as? String, "camera.fill")
        XCTAssertEqual(full["speed"] as? Int, 64)
    }

    // MARK: - 14.5: id камеры и время отправки

    func testAnotherCameraAtTheSameAddressIsUrgent() {
        let old = payload(cameraID: 3496)
        let twin = payload(cameraID: 3497)
        XCTAssertNotEqual(twin, old, "тот же адрес и значок, другая камера — другое состояние")
        XCTAssertTrue(twin.isUrgent(comparedTo: old), "другая камера — сразу, как смена адреса")
        XCTAssertFalse(payload(distance: 700, cameraID: 3496).isUrgent(comparedTo: old))
        XCTAssertNil(payload(title: nil, cameraID: 3496).cameraID, "без камеры id не уходит")
    }

    func testContextCarriesCameraIDAndSendTime() {
        let context = payload(cameraID: 3496).context(sentAt: sentAt)
        XCTAssertEqual(context["cid"] as? Int, 3496)
        XCTAssertEqual(context["t"] as? Double, sentAt.timeIntervalSince1970)
    }

    /// Старая сборка часов читает только прежние ключи с прежними типами —
    /// новые ключи рядом с ними её не задевают.
    func testOldWatchKeysAreUnchanged() {
        let context = payload(level: 2, over: true).context(sentAt: sentAt)
        XCTAssertEqual(context["active"] as? Bool, true)
        XCTAssertEqual(context["level"] as? Int, 2)
        XCTAssertEqual(context["over"] as? Bool, true)
        XCTAssertEqual(context["speed"] as? Int, 64)
        XCTAssertEqual(context["dist"] as? Int, 800)
        XCTAssertEqual(context["title"] as? String, "Юнусабад")
        XCTAssertEqual(context["sym"] as? String, "camera.fill")
        XCTAssertEqual(context["limit"] as? Int, 60)
        XCTAssertEqual(Set(context.keys).subtracting(["active", "level", "over", "speed", "dist",
                                                      "title", "sym", "limit"]),
                       ["cid", "t"], "новых ключей ровно два")
        // Словарь уходит property list'ом — только его типы.
        XCTAssertNoThrow(try PropertyListSerialization.data(fromPropertyList: context,
                                                             format: .binary, options: 0))
    }
}
