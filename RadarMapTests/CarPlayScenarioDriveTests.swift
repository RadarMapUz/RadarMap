//
//  CarPlayScenarioDriveTests.swift
//  RadarMapTests
//
//  Поездка глазами экрана машины, секунда за секундой: что уходит в
//  карточку манёвра и панель прибытия (CarPlayGuidanceMapping), как камера
//  карты ведёт себя на всех скоростях и на горячем телефоне (DriveCamera,
//  CarPlaySurface, CarPlayCluster, Drive3D), и что лента «Вождения 3D» не
//  зацикливается за две часа трассы с тоннелями и финишем. Строки матрицы —
//  docs/carplay_test_matrix.md, разделы «Вид», «Данные» и «Устойчивость».
//
//  Два теста фиксировали дефекты отчёта QA 05.11 («1000 м» и гистерезис
//  состояния манёвра) с XCTExpectFailure; исправлены в 48, пометки сняты.
//

import CarPlay
import CoreLocation
import XCTest
@testable import RadarMap

final class CarPlayScenarioDriveTests: XCTestCase {

    private typealias Map = CarPlayGuidanceMapping
    private let tashkent = 41.31

    // MARK: - Данные: карточка манёвра и панель прибытия

    /// Д-3: подъезд к повороту на 50 км/ч с 2,5 км, маршрут 4 км, фикс раз в
    /// секунду. Карточка: от километра — км с десятой, ближе — метры кратно
    /// 10; панель прибытия — всегда км и не «0» до приезда; состояние манёвра
    /// только вперёд; отправок в машину не больше, чем секунд.
    func testManeuverApproachSecondBySecond() {
        let speed = 50 / 3.6
        let turnAt = 2_500.0, routeLength = 4_000.0
        var car = 0.0, t = 0.0
        var lastState: Int?
        var sentStep: Double?, sentAt = -Double.infinity, sends = 0, ticks = 0
        let order: [CPManeuverState] = [.initial, .continue, .prepare, .execute]
        while car < turnAt {
            let left = turnAt - car
            let card = Map.distance(meters: left)
            // Порог — по округлённому до 10 м (995 м — уже «1 км», не «1000 м»).
            if (left / 10).rounded() * 10 >= 1_000 {
                XCTAssertEqual(card.unit, UnitLength.kilometers, "\(left) м")
            } else {
                XCTAssertEqual(card.unit, UnitLength.meters, "\(left) м")
                XCTAssertEqual(card.value.truncatingRemainder(dividingBy: 10), 0, "\(left) м")
            }
            let trip = Map.tripDistance(meters: routeLength - car)
            XCTAssertEqual(trip.unit, UnitLength.kilometers)
            XCTAssertGreaterThan(trip.value, 0, "до приезда не «0 км»")
            let state = Map.maneuverState(distance: left, sinceShown: t)
            let index = try? XCTUnwrap(order.firstIndex(of: state))
            if let index, let lastState {
                XCTAssertGreaterThanOrEqual(index, lastState, "состояние не откатывается: \(left) м")
            }
            lastState = index ?? lastState
            if Map.shouldUpdate(previous: sentStep, current: left, elapsed: t - sentAt) {
                sends += 1
                sentStep = left
                sentAt = t
            }
            ticks += 1
            car += speed
            t += 1
        }
        XCTAssertEqual(lastState, order.firstIndex(of: .execute), "у поворота — «выполняй»")
        XCTAssertLessThanOrEqual(sends, ticks)
        XCTAssertGreaterThanOrEqual(sends, ticks / 4, "оценки идут, а не стоят")
    }

    /// Д-3б, дефект: за 995–999 м до поворота карточка получает «1000 м»
    /// (метры, округление вверх), а с 1000 м — «1 км». Водитель видит
    /// «1 км» → «1 000 м» → «990 м»; ожидалось «1 км» сразу.
    /// `CarPlayGuidance.swift`, `distance(meters:)`: порог проверяется до
    /// округления. Исправление — сравнивать с 1000 уже округлённое.
    func testCardNeverSaysOneThousandMetres() {
        for meters in stride(from: 990.0, through: 1_000, by: 1) {
            let card = Map.distance(meters: meters)
            XCTAssertFalse(card.unit == UnitLength.meters && card.value >= 1_000, "\(meters) м → \(card)")
        }
    }

    /// Д-3в, дефект (только с метаданными приборки): стоим на красном в
    /// 48–53 м до поворота, позиция дрожит на ±3 м — состояние манёвра
    /// прыгает «выполняй ↔ готовься» на каждом фиксе, и каждый прыжок уходит
    /// в машину (`CarPlayGuidance.updateEstimates`, `session.maneuverState`).
    /// Порог без гистерезиса (`carPlayManeuverExecuteMeters`). Исправление —
    /// не откатывать состояние того же манёвра назад.
    func testStandingAtTheExecuteThresholdDoesNotFlickerTheClusterState() {
        for threshold in [AppConfig.carPlayManeuverExecuteMeters, AppConfig.carPlayManeuverPrepareMeters] {
            let jitter = [threshold - 2, threshold + 3, threshold - 1, threshold + 2, threshold - 3]
            var sent: CPManeuverState?
            let states = jitter.map { distance -> CPManeuverState in
                let state = Map.maneuverState(distance: distance, sinceShown: 30, previous: sent)
                sent = state
                return state
            }
            XCTAssertEqual(Set(states).count, 1, "стоя у порога \(threshold) м: \(states)")
        }
        // Уехали за полосу (разворот, перестроение) — состояние честно откатывается.
        XCTAssertEqual(Map.maneuverState(distance: AppConfig.carPlayManeuverExecuteMeters
                                            + AppConfig.carPlayManeuverStateHysteresisMeters + 1,
                                         sinceShown: 30, previous: .execute), .prepare)
    }

    /// Д-3г: стоим в пробке 5 минут, расстояние не меняется — в машину уходит
    /// только освежение по часам, а не поток одинаковых оценок.
    func testStandingInAJamRefreshesOnlyByTheClock() {
        var sent: Double?, sentAt = -Double.infinity, sends = 0
        for second in 0..<300 {
            let t = Double(second)
            if Map.shouldUpdate(previous: sent, current: 1_234, elapsed: t - sentAt) {
                sends += 1
                sent = 1_234
                sentAt = t
            }
        }
        XCTAssertEqual(sends, Int((300 / AppConfig.carPlayEstimateMaxInterval).rounded(.up)))
    }

    /// Д-4 / У-4: два часа по трассе на 100 км/ч, 200 км до цели. Панель
    /// прибытия: всегда км, от сотни — целые, ближе — десятые; число только
    /// убывает и не «0» до самого конца.
    func testTwoHourHighwayTripDistance() {
        var previous = Double.infinity
        var meters = 200_000.0
        while meters > 0 {
            let trip = Map.tripDistance(meters: meters)
            XCTAssertEqual(trip.unit, UnitLength.kilometers)
            XCTAssertGreaterThan(trip.value, 0)
            XCTAssertLessThanOrEqual(trip.value, previous, "\(meters) м")
            let tenths = trip.value * 10
            XCTAssertEqual(tenths, tenths.rounded(), accuracy: 1e-6, "не больше одной десятой: \(trip.value)")
            if trip.value >= 100 { XCTAssertEqual(trip.value, trip.value.rounded(), "\(meters) м") }
            previous = trip.value
            meters -= 100 / 3.6
        }
        XCTAssertEqual(Map.tripDistance(meters: 0).value, 0)
    }

    // MARK: - Вид: скорость и нагрев

    private func carFrame(_ kmh: Double, pitch: Bool, height: Double,
                          turn: Double? = nil) -> DriveCamera.Frame {
        DriveCamera.target(speedKmh: kmh, maneuverDistance: turn, pitchAllowed: pitch,
                           maxPitch: AppConfig.engineMapPitchDegrees, screen: .car,
                           viewHeight: height, latitude: tashkent, carY: { _ in 0.7 })
    }

    /// В-5: экран машины на всех скоростях — стоя, ползком, город, трасса —
    /// на 800×480 и 1920×720: наклон не круче потолка движка, масштаб
    /// конечный, и чем быстрее едем, тем дальше видно впереди.
    func testSpeedSweepOnTheCarScreen() {
        for height in [382.0, 480] {
            var lastAhead = 0.0
            for kmh in [0.0, 5, 15, 30, 50, 70, 90, 110, 130] {
                let frame = carFrame(kmh, pitch: true, height: height)
                XCTAssertTrue(frame.zoom.isFinite && frame.pitchDegrees.isFinite, "\(kmh) км/ч")
                XCTAssertLessThanOrEqual(frame.pitchDegrees, AppConfig.engineMapPitchDegrees + 1e-9)
                XCTAssertGreaterThanOrEqual(frame.pitchDegrees, 0)
                XCTAssertTrue((12...20).contains(frame.zoom), "\(kmh) км/ч: z\(frame.zoom)")
                let ahead = DriveCamera.visibleAhead(zoom: frame.zoom, pitchDegrees: frame.pitchDegrees,
                                                     viewHeight: height, carY: 0.7, latitude: tashkent)
                XCTAssertGreaterThanOrEqual(ahead, lastAhead - 1, "\(height) pt, \(kmh) км/ч")
                lastAhead = ahead
            }
        }
    }

    /// В-4: телефон в держателе греется во время поездки с CarPlay. Полный
    /// режим — наклон и сужение ленты; тёплый и горячий — плоско и без
    /// сужения; на горячем первой гаснет карта приборки. Экран машины при
    /// этом карту не теряет.
    func testHotPhoneChainOnTheCarScreen() {
        for mode in [PerformanceMode.full, .reduced, .minimal] {
            let hot = mode != .full
            let pitchAllowed = CarPlaySurface.car.pitchAllowed(performance: mode)
            XCTAssertEqual(pitchAllowed, !hot, "\(mode)")
            let frame = carFrame(50, pitch: pitchAllowed, height: 382)
            if hot { XCTAssertEqual(frame.pitchDegrees, 0, "\(mode): плоско") }
            XCTAssertEqual(Drive3D.narrows(surface: .car, hot: hot), !hot, "\(mode)")
            XCTAssertEqual(Drive3D.hazeShown(hot: hot), !hot)
            XCTAssertEqual(CarPlayCluster.showsMap(onScreen: true, performance: mode), mode != .minimal,
                           "\(mode): приборка")
        }
        XCTAssertFalse(CarPlaySurface.cluster.pitchAllowed(performance: .full), "приборка всегда плоская")
    }

    // MARK: - Устойчивость: лента 3D за два часа

    /// В-6 / У-4: два часа по трассе на 90 км/ч, 180 км, манёвр каждые 3 км,
    /// тоннель по 300 м каждые 30 км (лент тайла в нём нет), финиш. Лента не
    /// пишется в тоннеле, у его въезда нет петли пересчётов (застой 43), у
    /// финиша — один расчёт без записи, и пересчётов в среднем не больше
    /// десяти в минуту.
    func testTwoHourDriveRibbonHasNoLoop() {
        let speed = 90 / 3.6
        let length = 180_000.0
        let window = LaneFocus.window(speedKmh: 90)
        let tunnels = stride(from: 15_000.0, to: length, by: 30_000).map { ($0, $0 + 300) }
        func inTunnel(_ x: Double) -> Bool { tunnels.contains { x >= $0.0 && x < $0.1 } }
        func reach(_ car: Double) -> Double? {
            guard !inTunnel(car) else { return nil }
            let nextTunnel = tunnels.first { $0.0 > car }?.0 ?? length
            return min(car + 900, nextTunnel, length)
        }
        func maneuver(_ car: Double) -> Double? {
            let next = (floor(car / 3_000) + 1) * 3_000
            return next < length ? next : nil
        }

        // Как EngineDriveRibbon.compute: попытки копятся на том же маршруте,
        // «прежний конец» — только у ленты того же манёвра.
        var plan: Drive3D.Plan?
        var drawn: (end: Double, maneuver: Double?)?
        var lastAttempt = -Double.infinity
        var computesBySecond: [Int] = []
        var wroteInTunnel = false
        var nearFinish = (computes: 0, writes: 0)
        var t = 0.0, car = 0.0
        while car <= length {
            var computed = 0
            let next = maneuver(car)
            if Drive3D.needsRecompute(last: plan, route: 1, car: car, maneuver: next, window: window,
                                      narrowing: true, sinceAttempt: t - lastAttempt) {
                computed = 1
                lastAttempt = t
                var fresh = Drive3D.Plan(route: 1, from: car, maneuver: next, narrowing: true,
                                         inWindow: Drive3D.inWindow(car: car, maneuver: next, window: window),
                                         complete: false, verifiedEnd: plan?.verifiedEnd)
                if let plan, !plan.complete || plan.stalledEnd != nil { fresh.attempts = plan.attempts + 1 }
                let previousEnd = drawn.flatMap { $0.maneuver == next ? $0.end : nil }
                let result = reach(car)
                let settled = Drive3D.settle(&fresh, ready: result != nil, end: result ?? car,
                                             previousEnd: previousEnd, car: car)
                let finish = car >= length - AppConfig.drive3DTailMarginMeters
                if settled == .write, let result {
                    drawn = (result, next)
                    if inTunnel(car) { wroteInTunnel = true }
                    if finish { nearFinish.writes += 1 }
                }
                if finish { nearFinish.computes += 1 }
                plan = fresh
            }
            computesBySecond.append(computed)
            car += speed
            t += 1
        }
        XCTAssertFalse(wroteInTunnel, "в тоннеле лента не пишется")
        XCTAssertLessThanOrEqual(nearFinish.computes, 1, "у финиша не больше одного расчёта")
        XCTAssertEqual(nearFinish.writes, 0, "и тот без записи")
        let minutes = Double(computesBySecond.count) / 60
        let total = computesBySecond.reduce(0, +)
        XCTAssertLessThanOrEqual(Double(total) / minutes, 10, "пересчётов в минуту в среднем")
        // Ни одной минуты с петлёй: худшая минута — не больше двадцати.
        var worst = 0
        for start in stride(from: 0, to: computesBySecond.count, by: 10) {
            worst = max(worst, computesBySecond[start..<min(start + 60, computesBySecond.count)].reduce(0, +))
        }
        XCTAssertLessThanOrEqual(worst, 20, "худшая минута")
    }

    // MARK: - Устойчивость: разницы стиля

    /// У-1 (2.2.43): падение в машине на rgba-строке в разнице «Вождения 3D».
    /// DriveAsphaltTests проверяет разницы по списку имён — этот тест находит
    /// их в бандле сам, чтобы новая разница не прошла мимо проверки.
    func testEveryStyleDifferenceInTheBundleIsFoundAndParsable() throws {
        var urls: [String: URL] = [:]
        for directory in [nil, "MapStyle"] as [String?] {
            for url in Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: directory) ?? [] {
                let name = url.deletingPathExtension().lastPathComponent
                guard name.hasPrefix("map_"), !name.hasPrefix("map_style_") else { continue }
                urls[name] = url
            }
        }
        for known in ["map_drive_light", "map_drive_dark", "map_car_light", "map_car_dark",
                      "map_drive3d_light", "map_drive3d_dark"] {
            XCTAssertNotNil(urls[known], "\(known).json нет в бандле")
        }
        for (name, url) in urls.sorted(by: { $0.key < $1.key }) {
            for item in try DriveAsphalt.overrides(from: Data(contentsOf: url)) {
                XCTAssertFalse(DriveAsphalt.isUnsafeColourString(property: item.property, value: item.value),
                               "\(name): \(item.layer).\(item.property) = \(item.value)")
            }
        }
    }
}
