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
        let plan = Drive3D.Plan(route: 1, from: 100, maneuver: 900, narrowing: true, inWindow: false,
                                complete: true, verifiedEnd: 1500)
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
    }

    /// В окне подъезда до манёвра по пути не пересчитываем: пересчёт посреди
    /// перестроения перекраивал его под машиной (72 км/ч, окно 300 м > 250 м).
    func testNoDistanceRecomputeInsideTheApproachWindow() {
        let inside = Drive3D.Plan(route: 1, from: 620, maneuver: 900, narrowing: true, inWindow: true,
                                  complete: true, verifiedEnd: 2000)
        for car in stride(from: 620.0, to: 900, by: 10) {
            XCTAssertFalse(Drive3D.needsRecompute(last: inside, route: 1, car: car, maneuver: 900, window: 300,
                                                  narrowing: true), "машина на \(car) м")
        }
        XCTAssertTrue(Drive3D.needsRecompute(last: inside, route: 1, car: 905 + AppConfig.drive3DRecomputeMeters,
                                             maneuver: 900, window: 300, narrowing: true), "за манёвром — снова")
    }

    /// Неполный расчёт (карта без лент тайла) и конец прощупанного — повтор,
    /// но не чаще drive3DRetrySeconds.
    func testIncompleteAndEndOfProbedRetryWithThrottle() {
        let incomplete = Drive3D.Plan(route: 1, from: 100, maneuver: nil, narrowing: true, inWindow: false)
        XCTAssertFalse(Drive3D.needsRecompute(last: incomplete, route: 1, car: 110, maneuver: nil, window: 200,
                                              narrowing: true, sinceAttempt: 0.5))
        XCTAssertTrue(Drive3D.needsRecompute(last: incomplete, route: 1, car: 110, maneuver: nil, window: 200,
                                             narrowing: true, sinceAttempt: AppConfig.drive3DRetrySeconds))
        let short = Drive3D.Plan(route: 1, from: 100, maneuver: nil, narrowing: true, inWindow: false,
                                 complete: true, verifiedEnd: 300)
        XCTAssertTrue(Drive3D.needsRecompute(last: short, route: 1, car: 160, maneuver: nil, window: 200,
                                             narrowing: true), "у конца прощупанного")
    }

    /// Щупать карту — только при слежении, с 15-го и на дорисованном кадре.
    func testComputeOnlyOnAFollowedLoadedMap() {
        XCTAssertTrue(Drive3D.canCompute(following: true, zoom: 16.5, tilesComplete: true))
        XCTAssertFalse(Drive3D.canCompute(following: true, zoom: 13, tilesComplete: true), "обзор и превью")
        XCTAssertFalse(Drive3D.canCompute(following: false, zoom: 17, tilesComplete: true), "осмотр, панорама")
        XCTAssertFalse(Drive3D.canCompute(following: true, zoom: 17, tilesComplete: false), "тайлы не дорисованы")
    }

    func testCutStepGrowsWithSpeedAndHeat() {
        XCTAssertEqual(Drive3D.cutStep(speedMps: 5, hot: false), AppConfig.drive3DCutStepMeters)
        XCTAssertEqual(Drive3D.cutStep(speedMps: 28, hot: false), 14, accuracy: 0.01)
        XCTAssertEqual(Drive3D.cutStep(speedMps: 28, hot: true), 14 * AppConfig.drive3DCutHotFactor, accuracy: 0.01)
        XCTAssertTrue(Drive3D.cutDue(last: nil, now: 10))
        XCTAssertFalse(Drive3D.cutDue(last: 100, now: 104))
        XCTAssertTrue(Drive3D.cutDue(last: 100, now: 100 + AppConfig.drive3DCutStepMeters))
        XCTAssertTrue(Drive3D.cutDue(last: 100, now: 50), "назад — сразу")
    }

    /// Частота: минута на 100 км/ч, применение модели трижды в секунду. Источник
    /// пишется только на пересчёте (не каждые 8 м), срез — шагом.
    func testWritesPerMinuteAt100Kmh() {
        let speed = 100 / 3.6
        var plan: Drive3D.Plan?
        var computes = 0, cuts = 0
        var cut: Double?
        var lastAttempt = -Double.infinity
        for tick in 0..<180 {
            let t = Double(tick) / 3
            let car = 200 + speed * t
            let maneuver: Double = car < 1600 ? 1600 : 3200
            let window = LaneFocus.window(speedKmh: 100)
            if Drive3D.needsRecompute(last: plan, route: 1, car: car, maneuver: maneuver, window: window,
                                      narrowing: true, sinceAttempt: t - lastAttempt) {
                computes += 1
                lastAttempt = t
                plan = Drive3D.Plan(route: 1, from: car, maneuver: maneuver, narrowing: true,
                                    inWindow: Drive3D.inWindow(car: car, maneuver: maneuver, window: window),
                                    complete: true, verifiedEnd: car + 900)
            }
            if Drive3D.cutDue(last: cut, now: car, step: Drive3D.cutStep(speedMps: speed, hot: false)) {
                cuts += 1
                cut = car
            }
        }
        XCTAssertLessThanOrEqual(computes, 10, "записей источника за минуту")
        XCTAssertLessThanOrEqual(cuts, 130, "перестановок среза за минуту")
    }

    func testDefaultByPhoneClass() {
        XCTAssertFalse(Drive3D.defaultEnabled(machine: "iPhone11,8"), "XR, A12")
        XCTAssertFalse(Drive3D.defaultEnabled(machine: "iPhone12,8"), "SE 2, A13")
        XCTAssertTrue(Drive3D.defaultEnabled(machine: "iPhone13,2"), "12, A14")
        XCTAssertTrue(Drive3D.defaultEnabled(machine: "iPhone17,1"), "16 Pro")
        XCTAssertTrue(Drive3D.defaultEnabled(machine: "arm64"), "симулятор")
    }

    func testDashboardHasNoRibbonAndHotPhoneNoChevrons() {
        XCTAssertFalse(Drive3D.ribbon(surface: .dashboard))
        XCTAssertTrue(Drive3D.ribbon(surface: .car))
        XCTAssertFalse(Drive3D.chevrons(surface: .phone, hot: true))
        XCTAssertTrue(Drive3D.chevrons(surface: .phone, hot: false))
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
