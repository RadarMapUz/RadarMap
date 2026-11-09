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

    /// Горячий телефон: только заливка; плитка (48) сужается, пока не тёплая;
    /// дымка гаснет на горячем.
    func testHotPhoneDropsTheNarrowingTileKeepsIt() {
        XCTAssertTrue(Drive3D.narrows(surface: .phone, hot: false))
        XCTAssertTrue(Drive3D.narrows(surface: .car, hot: false))
        XCTAssertFalse(Drive3D.narrows(surface: .phone, hot: true))
        XCTAssertTrue(Drive3D.narrows(surface: .dashboard, hot: false), "плитка 48 — с сужением")
        XCTAssertFalse(Drive3D.narrows(surface: .dashboard, hot: true), "тёплый телефон рисует плитку как горячую")
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
            if id != Drive3D.traveledLayer, !Drive3D.lineAccentLayers.contains(id) { XCTAssertFalse(id.hasPrefix("route"), id) }
        }
    }

    /// Отдаление карты в поездке: линия пройденного — весь маршрут, вблизи её
    /// заменяет лента, а на малых зумах она проступала старым маршрутом за
    /// машиной. В 3D её нет ни до готовности ленты, ни после.
    func testTraveledLineNeverReturnsWhenZoomingOut() {
        XCTAssertTrue(Drive3D.hiddenLayers.contains("route-traveled"))
        for id in ["route", "route-case", "route-near", "route-traffic", "route-arrows"] {
            XCTAssertFalse(Drive3D.hiddenLayers.contains(id), "линия впереди остаётся: \(id)")
        }
    }

    /// Проехали конец ленты без пересчёта (карта в осмотре, панорама, тоннель):
    /// её хвост лежал бы на пройденном — показывается линия с её срезом.
    func testRibbonNotShownOncePassedItsEnd() {
        XCTAssertTrue(Drive3D.showsRibbon(ready: true, car: 500, verifiedEnd: 900))
        XCTAssertFalse(Drive3D.showsRibbon(ready: false, car: 500, verifiedEnd: 900), "не готова")
        XCTAssertFalse(Drive3D.showsRibbon(ready: true, car: 901, verifiedEnd: 900), "проехали конец")
        XCTAssertFalse(Drive3D.showsRibbon(ready: true, car: 895, verifiedEnd: 900),
                       "начало хвоста уже за машиной")
        XCTAssertTrue(Drive3D.showsRibbon(ready: true, car: 889, verifiedEnd: 900))
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

    /// Прогон по пути: на каждом фиксе — решение «пересчитать?», расчёт даёт
    /// конец прощупанного `reach(car)` (nil — не готов), итог — Drive3D.settle.
    private func drive(from start: Double, to end: Double, speed: Double,
                       reach: (Double) -> Double?) -> [(car: Double, computed: Bool, wrote: Bool)] {
        var plan: Drive3D.Plan?
        var drawnEnd: Double?
        var lastAttempt = -Double.infinity
        var out: [(car: Double, computed: Bool, wrote: Bool)] = []
        var t = 0.0
        var car = start
        while car <= end {
            var computed = false, wrote = false
            if Drive3D.needsRecompute(last: plan, route: 1, car: car, maneuver: nil, window: 200, narrowing: true,
                                      sinceAttempt: t - lastAttempt) {
                computed = true
                lastAttempt = t
                var next = Drive3D.Plan(route: 1, from: car, maneuver: nil, narrowing: true, inWindow: false,
                                        verifiedEnd: plan?.verifiedEnd)
                if let plan, !plan.complete || plan.stalledEnd != nil { next.attempts = plan.attempts + 1 }
                let result = reach(car)
                let settled = Drive3D.settle(&next, ready: result != nil, end: result ?? car, previousEnd: drawnEnd,
                                             car: car)
                if settled == .write { wrote = true; drawnEnd = result }
                plan = next
            }
            out.append((car, computed, wrote))
            car += speed
            t += 1
        }
        return out
    }

    /// Тоннель (ленты тайла кончаются на 1000 м и вновь с 1300): у его начала
    /// после первого «не выросло» — ни записи, ни проб до проезда; в тоннеле —
    /// повторы с удвоением задержки и без записи.
    func testTunnelStopsTheRecomputeLoop() {
        let run = drive(from: 700, to: 1290, speed: 50 / 3.6) { car in
            car < 1000 ? min(car + 600, 1000) : nil
        }
        XCTAssertTrue(run.first!.wrote)
        let stall = run.firstIndex { $0.car >= 1000 - AppConfig.drive3DTailMarginMeters && $0.computed }!
        let beforePassing = run[(stall + 1)...].filter { $0.car < 1000 + AppConfig.drive3DStallPassMeters }
        XCTAssertFalse(beforePassing.contains { $0.computed }, "у начала тоннеля — без проб")
        let inside = run.filter { $0.car >= 1000 + AppConfig.drive3DStallPassMeters }
        XCTAssertFalse(inside.contains { $0.wrote }, "в тоннеле источник не пишется")
        XCTAssertLessThanOrEqual(inside.filter(\.computed).count, 5, "повторы с удвоением, а не раз в 1,5 с")
    }

    /// Пробел без лент тайла длиной 200 м: после проезда лента нарастает снова.
    func testGapIsLeftAfterPassing() {
        let run = drive(from: 300, to: 1600, speed: 50 / 3.6) { car in
            if car < 800 { return min(car + 600, 800) }
            if car < 1000 { return nil }
            return car + 600
        }
        XCTAssertTrue(run.contains { $0.car > 1000 && $0.wrote }, "за пробелом лента снова растёт")
        let nearGap = run.filter { $0.car >= 800 - AppConfig.drive3DTailMarginMeters
            && $0.car < 800 + AppConfig.drive3DStallPassMeters }
        XCTAssertEqual(nearGap.filter(\.computed).count, 1, "у пробела — один расчёт")
        XCTAssertFalse(nearGap.contains { $0.wrote }, "и без записи")
    }

    /// Финиш: последние 150 м маршрута — без повторов (конец ленты = конец маршрута).
    func testFinishHasNoRetries() {
        let run = drive(from: 1700, to: 2000, speed: 40 / 3.6) { car in min(car + 600, 2000) }
        let near = run.filter { $0.car >= 2000 - AppConfig.drive3DTailMarginMeters }
        XCTAssertLessThanOrEqual(near.filter(\.computed).count, 1, "один расчёт у финиша")
        XCTAssertFalse(near.contains { $0.wrote }, "и тот без записи")
    }

    func testRetryDelayDoublesUpToTheCeiling() {
        XCTAssertEqual(Drive3D.retryDelay(attempts: 1), AppConfig.drive3DRetrySeconds)
        XCTAssertEqual(Drive3D.retryDelay(attempts: 2), AppConfig.drive3DRetrySeconds * 2)
        XCTAssertEqual(Drive3D.retryDelay(attempts: 10), AppConfig.drive3DRetryMaxSeconds)
    }

    /// Пересчёт вдали от конца без роста — лента остаётся, застоя нет.
    func testNoGrowthFarFromTheEndIsNotAStall() {
        var plan = Drive3D.Plan(route: 1, from: 300, maneuver: nil, narrowing: true, inWindow: false)
        XCTAssertEqual(Drive3D.settle(&plan, ready: true, end: 900, previousEnd: 900, car: 300), .stalled)
        XCTAssertNil(plan.stalledEnd)
        XCTAssertTrue(plan.complete)
        XCTAssertEqual(Drive3D.settle(&plan, ready: true, end: 1100, previousEnd: 900, car: 320), .write)
        XCTAssertEqual(plan.verifiedEnd, 1100)
        var empty = Drive3D.Plan(route: 1, from: 0, maneuver: nil, narrowing: true, inWindow: false)
        XCTAssertEqual(Drive3D.settle(&empty, ready: false, end: 0, previousEnd: nil, car: 0), .incomplete)
    }

    func testDefaultByPhoneClass() {
        XCTAssertFalse(Drive3D.defaultEnabled(machine: "iPhone11,8"), "XR, A12")
        XCTAssertFalse(Drive3D.defaultEnabled(machine: "iPhone12,8"), "SE 2, A13")
        XCTAssertTrue(Drive3D.defaultEnabled(machine: "iPhone13,2"), "12, A14")
        XCTAssertTrue(Drive3D.defaultEnabled(machine: "iPhone17,1"), "16 Pro")
        XCTAssertTrue(Drive3D.defaultEnabled(machine: "arm64"), "симулятор")
        XCTAssertFalse(Drive3D.defaultEnabled(machine: "iPad13,18"), "iPad в режиме совместимости — как старый")
    }

    func testDashboardRibbonByTileLevelAndHotPhoneNoChevrons() {
        XCTAssertTrue(Drive3D.ribbon(surface: .dashboard), "плитка 48 — с лентой")
        XCTAssertTrue(Drive3D.ribbon(surface: .dashboard, tile: .lite), "тёплый — лента без сужения")
        XCTAssertFalse(Drive3D.ribbon(surface: .dashboard, tile: .flat), "горячий — только палитра")
        XCTAssertTrue(Drive3D.ribbon(surface: .car, tile: .flat), "ступень плитки экран машины не трогает")
        XCTAssertFalse(Drive3D.chevrons(surface: .phone, hot: true))
        XCTAssertTrue(Drive3D.chevrons(surface: .phone, hot: false))
    }

    /// Плитка упрощается первой: тёплый телефон или энергосбережение — уже
    /// `lite` (карта рисует как горячая), а экран машины ещё полный; горячий —
    /// `flat`. Ступень карты плитки на горячем — та, что есть, не мягче.
    func testTileSimplifiesFirst() {
        XCTAssertEqual(Drive3D.tileLevel(performance: .full, warm: false, lowPower: false), .full)
        XCTAssertEqual(Drive3D.tileLevel(performance: .full, warm: true, lowPower: false), .lite)
        XCTAssertEqual(Drive3D.tileLevel(performance: .full, warm: false, lowPower: true), .lite)
        XCTAssertEqual(Drive3D.tileLevel(performance: .reduced, warm: true, lowPower: false), .flat)
        XCTAssertEqual(Drive3D.tileLevel(performance: .minimal, warm: true, lowPower: true), .flat)
        XCTAssertEqual(Drive3D.tilePerformance(.full, mode: .full), .full)
        XCTAssertEqual(Drive3D.tilePerformance(.lite, mode: .full), .reduced)
        XCTAssertEqual(Drive3D.tilePerformance(.flat, mode: .minimal), .minimal)
        // Пока плитка `lite`, экран машины — полный: наклон разрешён, сужение есть.
        XCTAssertTrue(CarPlaySurface.car.pitchAllowed(performance: .full))
        XCTAssertTrue(CarPlaySurface.dashboard.pitchAllowed(performance: .full), "lite — наклон остаётся")
        XCTAssertFalse(CarPlaySurface.dashboard.pitchAllowed(performance: .reduced), "flat — плоско")
    }

    /// Плитка считает сама, только если телефон и экран машины молчат.
    func testTileTakesTheReadyRibbon() {
        XCTAssertTrue(Drive3D.computes(surface: .car, sincePrimary: 0))
        XCTAssertTrue(Drive3D.computes(surface: .phone, sincePrimary: 0))
        XCTAssertFalse(Drive3D.computes(surface: .dashboard, sincePrimary: 0.5), "экран машины жив — берём его")
        XCTAssertTrue(Drive3D.computes(surface: .dashboard, sincePrimary: AppConfig.drive3DShareYieldSeconds))
        XCTAssertTrue(Drive3D.computes(surface: .dashboard, sincePrimary: .infinity), "плитка одна")
    }

    /// Бюджет плитки строже машины по всем столбцам; срез в машине и на
    /// плитке — не чаще секунды пути (аудит 05.11, №3).
    func testTileBudgetIsCheaper() {
        let tile = Drive3D.budget(surface: .dashboard), car = Drive3D.budget(surface: .car)
        XCTAssertGreaterThan(tile.recomputeMeters, car.recomputeMeters)
        XCTAssertLessThan(tile.tailMarginMeters, car.tailMarginMeters)
        XCTAssertGreaterThan(tile.retrySeconds, car.retrySeconds)
        XCTAssertLessThan(tile.probeLimit, car.probeLimit)
        XCTAssertGreaterThanOrEqual(car.cutSeconds, 1)
        XCTAssertGreaterThanOrEqual(tile.cutSeconds, 1)
        XCTAssertEqual(Drive3D.budget(surface: .phone), .full)
        // 60 км/ч: машина режет раз в 16,7 м, телефон — раз в 8,3.
        XCTAssertEqual(Drive3D.cutStep(speedMps: 60 / 3.6, hot: false, seconds: car.cutSeconds), 16.67, accuracy: 0.01)
        XCTAssertEqual(Drive3D.cutStep(speedMps: 60 / 3.6, hot: false), 8.33, accuracy: 0.01)
    }

    /// Минута на 50 км/ч: машина и плитка в одном прогоне. Плитка пересчитывает
    /// не чаще машины, а срез на обеих — не чаще раза в секунду.
    func testTileComputesNoMoreThanTheCar() {
        func run(_ budget: Drive3D.Budget, ahead: Double) -> (computes: Int, cuts: Int) {
            let speed = 50 / 3.6
            var plan: Drive3D.Plan?
            var computes = 0, cuts = 0
            var cut: Double?
            var lastAttempt = -Double.infinity
            for tick in 0..<180 {
                let t = Double(tick) / 3
                let car = 200 + speed * t
                if Drive3D.needsRecompute(last: plan, route: 1, car: car, maneuver: nil, window: 200,
                                          narrowing: true, sinceAttempt: t - lastAttempt, budget: budget) {
                    computes += 1
                    lastAttempt = t
                    plan = Drive3D.Plan(route: 1, from: car, maneuver: nil, narrowing: true, inWindow: false,
                                        complete: true, verifiedEnd: car + ahead)
                }
                if Drive3D.cutDue(last: cut, now: car,
                                  step: Drive3D.cutStep(speedMps: speed, hot: false, seconds: budget.cutSeconds)) {
                    cuts += 1
                    cut = car
                }
            }
            return (computes, cuts)
        }
        // Машина видит ~260 м впереди, плитка 375 точек при 45° — ~250.
        let car = run(.car, ahead: 260), tile = run(.tile, ahead: 250)
        XCTAssertLessThanOrEqual(tile.computes, car.computes)
        XCTAssertLessThanOrEqual(tile.computes, 7, "плитка: пересчётов за минуту")
        XCTAssertLessThanOrEqual(car.cuts, 62, "машина: срез не чаще раза в секунду")
        XCTAssertLessThanOrEqual(tile.cuts, 62)
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

    // MARK: - Линия за лентой и манёвр (70)

    func testProbeReachesPastScreenButNotAnywhere() {
        XCTAssertTrue(Drive3D.probeInReach(x: 400, y: -500, width: 960, height: 360), "за верхом экрана — впереди дорога")
        XCTAssertTrue(Drive3D.probeInReach(x: -800, y: 100, width: 402, height: 874), "после поворота — вбок")
        XCTAssertFalse(Drive3D.probeInReach(x: 400, y: -5000, width: 960, height: 360))
        XCTAssertFalse(Drive3D.probeInReach(x: .nan, y: 0, width: 960, height: 360))
    }

    func testManeuverArrowOnlyWhereRibbonDoesNotShowTheTurn() {
        XCTAssertTrue(Drive3D.maneuverArrowShown(ribbonEnd: nil, maneuver: 100), "линия без ленты — со стрелкой")
        XCTAssertFalse(Drive3D.maneuverArrowShown(ribbonEnd: 700, maneuver: 100), "манёвр на ленте — без стрелки")
        XCTAssertTrue(Drive3D.maneuverArrowShown(ribbonEnd: 120, maneuver: 100), "манёвр на сходе — со стрелкой")
    }

    func testTailWidthIsLaneInMetersAndNeverThin() throws {
        let stops = Drive3D.tailWidth()
        func value(_ zoom: Double) throws -> Double {
            let rest = Array(stops.dropFirst(3))
            let i = try XCTUnwrap(stride(from: 0, to: rest.count, by: 2).first { rest[$0] as? Double == zoom })
            return try XCTUnwrap(rest[i + 1] as? Double)
        }
        XCTAssertEqual(try value(15), AppConfig.drive3DSpineFarPoints)
        XCTAssertEqual(try value(18), AppConfig.drive3DTailMeters * Drive3D.pointsPerMeter(zoom: 18), accuracy: 1e-6)
    }

    func testLineInDrive3DIsOneColour() {
        for id in ["route-core", "route-near-core", "route-maneuver", "route-near-maneuver"] {
            XCTAssertTrue(Drive3D.hiddenLayers.contains(id), id)
        }
    }
}
