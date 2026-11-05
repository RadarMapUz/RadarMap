//
//  Drive3DTests.swift
//  RadarMapTests
//
//  «Вождение 3D» (43): где включается, что гаснет на горячем телефоне,
//  шевроны с гистерезисом, когда пересчитывать ленту и резать её под
//  машиной; разницы стиля в бандле разбираются целиком.
//

import XCTest
@testable import RadarMap

final class Drive3DTests: XCTestCase {

    private func bundled(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "json")
            ?? Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "MapStyle"),
                                "\(name).json нет в бандле")
        return try Data(contentsOf: url)
    }

    func testSurfaces() {
        XCTAssertEqual(Drive3D.surface(enabled: true, phoneTrip: true), .phone)
        XCTAssertNil(Drive3D.surface(enabled: true, phoneTrip: false), "без поездки — карта как была")
        XCTAssertNil(Drive3D.surface(enabled: false, phoneTrip: true), "выключено в настройках")
        XCTAssertEqual(Drive3D.surface(enabled: true, car: .car), .car)
        XCTAssertEqual(Drive3D.surface(enabled: true, car: .dashboard), .dashboard)
        XCTAssertNil(Drive3D.surface(enabled: true, car: .cluster), "приборка — карта поездки")
        XCTAssertNil(Drive3D.surface(enabled: false, car: .car))
    }

    func testActiveOnlyDrivingOnTheNewMap() {
        XCTAssertTrue(Drive3D.isActive(surface: .phone, driving: true, modernStyle: true))
        XCTAssertFalse(Drive3D.isActive(surface: .phone, driving: true, modernStyle: false))
        XCTAssertFalse(Drive3D.isActive(surface: .phone, driving: false, modernStyle: true))
        XCTAssertFalse(Drive3D.isActive(surface: nil, driving: true, modernStyle: true))
    }

    /// Горячий телефон и плитка: только заливка; дымка гаснет на горячем.
    func testHotPhoneAndDashboardDropTheNarrowing() {
        XCTAssertTrue(Drive3D.narrows(surface: .phone, hot: false))
        XCTAssertTrue(Drive3D.narrows(surface: .car, hot: false))
        XCTAssertFalse(Drive3D.narrows(surface: .phone, hot: true))
        XCTAssertFalse(Drive3D.narrows(surface: .dashboard, hot: false))
        XCTAssertFalse(Drive3D.chevrons(surface: .dashboard))
        XCTAssertTrue(Drive3D.hazeShown(hot: false))
        XCTAssertFalse(Drive3D.hazeShown(hot: true))
    }

    func testNoGlowAndDayRouteOnLightAsphalt() {
        XCTAssertEqual(Drive3D.glowOpacity, 0)
        XCTAssertTrue(Drive3D.routeDaylight(daylight: true))
        XCTAssertFalse(Drive3D.routeDaylight(daylight: false))
    }

    /// Камеры, разметка, стрелки полос и светофоры не гасятся никогда.
    func testHiddenLayersNeverTouchCamerasOrMarkings() {
        for id in Drive3D.hiddenLayers {
            XCTAssertFalse(id.hasPrefix("camera"), id)
            XCTAssertFalse(id.hasPrefix("radar-markings"), id)
            XCTAssertFalse(id.hasPrefix("radar-arrows"), id)
            XCTAssertFalse(id.contains("signal"), id)
            XCTAssertFalse(id.hasPrefix("route"), id)
        }
    }

    func testChevronGateHasHysteresis() {
        var gate = Drive3D.ChevronGate()
        XCTAssertTrue(gate.update(speedKmh: 40))
        XCTAssertTrue(gate.update(speedKmh: 59))
        XCTAssertFalse(gate.update(speedKmh: 61))
        XCTAssertFalse(gate.update(speedKmh: 57), "на 57–60 не мигают")
        XCTAssertTrue(gate.update(speedKmh: 50))
    }

    func testRecomputeOnlyOnEvents() {
        let plan = Drive3D.Plan(route: 1, from: 100, maneuver: 900, narrowing: true, inWindow: false)
        func needs(route: Int = 1, car: Double = 150, maneuver: Double? = 900, narrowing: Bool = true) -> Bool {
            Drive3D.needsRecompute(last: plan, route: route, car: car, maneuver: maneuver, window: 300,
                                   narrowing: narrowing)
        }
        XCTAssertTrue(Drive3D.needsRecompute(last: nil, route: 1, car: 0, maneuver: nil, window: 300, narrowing: true))
        XCTAssertFalse(needs(), "обычный тик — без пересчёта")
        XCTAssertTrue(needs(route: 2), "новый маршрут")
        XCTAssertTrue(needs(maneuver: 1400), "новый манёвр")
        XCTAssertTrue(needs(narrowing: false), "нагрелся телефон")
        XCTAssertTrue(needs(car: 100 + AppConfig.drive3DRecomputeMeters), "уехали от начала участка")
        XCTAssertTrue(needs(car: 610), "вошли в окно подъезда")
        var inside = plan
        inside.inWindow = true
        XCTAssertFalse(Drive3D.needsRecompute(last: inside, route: 1, car: 620, maneuver: 900, window: 300,
                                              narrowing: true), "в окне — один раз")
    }

    func testCutIsWrittenByStepsNotEveryFrame() {
        XCTAssertTrue(Drive3D.cutDue(last: nil, now: 10))
        XCTAssertFalse(Drive3D.cutDue(last: 100, now: 104))
        XCTAssertTrue(Drive3D.cutDue(last: 100, now: 100 + AppConfig.drive3DCutStepMeters))
        XCTAssertTrue(Drive3D.cutDue(last: 100, now: 50), "назад — сразу")
        XCTAssertEqual(Drive3D.quantizedCut(13), 8)
        XCTAssertEqual(Drive3D.quantizedCut(-5), 0)
    }

    /// Разница в бандле — только известные свойства (иначе KVC уронил бы
    /// приложение) и свет без чужих ключей.
    func testBundledDifferencesParse() throws {
        for daylight in [true, false] {
            let data = try bundled(Drive3D.resource(daylight: daylight))
            let overrides = try DriveAsphalt.overrides(from: data)
            XCTAssertGreaterThan(overrides.count, 50)
            XCTAssertNotNil(try DriveAsphalt.lightIntensity(from: data))
            XCTAssertFalse(overrides.contains { $0.layer.hasPrefix("camera") })
        }
    }
}
