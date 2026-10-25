//
//  StopDriveDebug.swift
//  RadarMap
//
//  DEBUG-поездка с остановками для снимков и замера «вида на остановке»
//  (29.D): `-demoRoute -driveDemo -driveDemoStops -stopScene <сцена>`.
//  `simctl location start` не умеет стоять посреди маршрута и трогаться, а
//  остановка — это то, ради чего этап. Фиксы идут тем же путём, что от
//  CLLocationManager (делегат), — фильтр, гейты, маршрут и карта видят их как
//  настоящие. Симулятор ставить в начало маршрута: первый фикс — там же.
//
//  Сцены:
//    turn   — доехать и встать за `-stopBefore` м (200) до первой развилки
//             не ближе 300 м от старта, перед которой нет другой; стоять.
//    go     — то же, через `-goAfter` с (25) тронуться до 40 км/ч и ехать.
//    free   — встать там, где до следующей развилки ≥ 450 м; стоять.
//    jam    — встать на `-stopAlong` м (по маршруту) и стоять (с -demoTraffic).
//    crawl  — пробка «ползком»: 12 с стоим, 8 с 3–9 км/ч, по кругу.
//    drive  — ехать весь маршрут на `-stopSpeed` км/ч (40).
//  Подъезд к точке остановки — `-stopRunKmh` (60), торможение ~3 м/с².
//  Каждая фаза пишется в журнал строкой «СТОП фаза …».
//

#if DEBUG
import CoreLocation
import MapKit
import os

@MainActor
enum StopDriveDebug {

    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-driveDemoStops") }

    private static let log = Logger(subsystem: "uz.radarmap.ios", category: "location")

    private static func argument(_ name: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        return args.firstIndex(of: name).flatMap { args.dropFirst($0 + 1).first }
    }

    private static func number(_ name: String, _ fallback: Double) -> Double {
        argument(name).flatMap(Double.init) ?? fallback
    }

    static func run(env: AppEnvironment) async {
        for _ in 0..<60 where !env.route.isActive { await Task.pause(seconds: 0.5) }
        guard let variant = env.route.selected, variant.points.count >= 2 else { return }
        let line = RouteCut.Line(variant.points.map(\.coordinate))
        let scene = argument("-stopScene") ?? "turn"
        let maneuvers = variant.steps.filter { $0.kind?.isDrawable == true }.map(\.distanceAlong)
        let before = number("-stopBefore", 200)
        // Развилка, до которой можно встать за `before` м, не стоя у прошлой.
        let firstTurn = zip([0] + maneuvers, maneuvers)
            .first { prev, turn in turn >= 300 && turn - prev >= before + 60 }?.1
            ?? min(line.length - 50, 500)
        let run = number("-stopRunKmh", 60) / 3.6
        var driver = Driver(line: line, env: env)
        log.notice("СТОП сцена \(scene, privacy: .public), развилка \(Int(firstTurn), privacy: .public) м, длина \(Int(line.length), privacy: .public) м")

        switch scene {
        case "turn", "go":
            let stop = max(10, firstTurn - before)
            await driver.drive(to: stop, cruise: run)
            log.notice("СТОП фаза стоим, до развилки \(Int(firstTurn - stop), privacy: .public) м")
            if scene == "turn" {
                await driver.stand(seconds: .infinity)
            } else {
                await driver.stand(seconds: number("-goAfter", 25))
                log.notice("СТОП фаза трогаемся")
                await driver.drive(to: line.length - 20, cruise: 40 / 3.6, accel: 1.5, brakeAtEnd: false)
            }
        case "free":
            var at = 300.0
            for (a, b) in zip([0] + maneuvers, maneuvers + [line.length]) where b - a >= 650 && b - 450 >= 300 {
                at = b - 450
                break
            }
            await driver.drive(to: at, cruise: run)
            log.notice("СТОП фаза стоим без развилки")
            await driver.stand(seconds: .infinity)
        case "jam":
            let stop = min(line.length - 50, number("-stopAlong", 600))
            // Пробка по самой линии: от 20 м позади до `-jamAhead` м впереди
            // (300), дальше — «медленно» на 60 м и свободно.
            let edges = jamEdges(line, from: stop - 20, to: stop + number("-jamAhead", 300))
            env.traffic.seedDemo(edges: edges)
            await driver.drive(to: stop, cruise: run)
            // Настоящий now.json мог прийти за время подъезда — посеять снова.
            env.traffic.seedDemo(edges: edges)
            log.notice("СТОП фаза стоим в пробке")
            await driver.stand(seconds: .infinity)
        case "crawl":
            await driver.drive(to: min(line.length - 50, number("-stopAlong", 300)), cruise: run)
            log.notice("СТОП фаза ползём")
            var noise = Noise()
            while driver.along < line.length - 30 {
                await driver.stand(seconds: 12)
                for _ in 0..<8 { await driver.tick(speed: noise.range(3, 9) / 3.6) }
            }
        default:
            log.notice("СТОП фаза едем")
            await driver.drive(to: line.length - 20, cruise: number("-stopSpeed", 40) / 3.6,
                               accel: 2.5, brakeAtEnd: false)
        }
    }

    /// Рёбра пробки по линии маршрута шагом 20 м: «стоим» на [from, to],
    /// «медленно» 60 м после, «свободно» ещё 200 м.
    private static func jamEdges(_ line: RouteCut.Line, from: Double, to: Double) -> [TrafficEdge] {
        var edges: [TrafficEdge] = []
        var along = max(0, from)
        while along < min(line.length - 20, to + 260) {
            let level = along < to ? 3 : (along < to + 60 ? 2 : 1)
            let a = line.pose(at: along).coordinate, b = line.pose(at: along + 20).coordinate
            edges.append(TrafficEdge(a: a, b: b, level: level, kmh: [0, 50, 20, 5][level], modelKmh: 50))
            along += 20
        }
        return edges
    }

    /// Детерминированный шум (xorshift): прогоны «до» и «после» одинаковы.
    private struct Noise {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func unit() -> Double {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Double(state % 1_000_001) / 1_000_000
        }
        mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * unit() }
    }

    /// Машина на линии маршрута: фикс раз в секунду.
    private struct Driver {
        let line: RouteCut.Line
        let env: AppEnvironment
        var along = 0.0
        var speed = 0.0
        var bearing = 0.0

        init(line: RouteCut.Line, env: AppEnvironment) {
            self.line = line
            self.env = env
        }

        /// Доехать до `target` (м по линии): разгон `accel`, ход `cruise`,
        /// торможение ~3 м/с² к точке, если `brakeAtEnd`.
        mutating func drive(to target: Double, cruise: Double, accel: Double = 3,
                            brakeAtEnd: Bool = true) async {
            while along < target - 0.5 {
                let left = target - along
                var next = min(cruise, speed + accel)
                if brakeAtEnd { next = min(next, max(1, (2 * 3 * left).squareRoot())) }
                await tick(speed: next, limit: brakeAtEnd ? target : nil)
            }
            if brakeAtEnd { speed = 0 }
        }

        /// Стоять `seconds` секунд: фикс раз в секунду, скорость 0, курса нет.
        mutating func stand(seconds: Double) async {
            var waited = 0.0
            while waited < seconds {
                await tick(speed: 0)
                waited += 1
            }
        }

        mutating func tick(speed new: Double, limit: Double? = nil) async {
            await Task.pause(seconds: 1)
            speed = new
            along = min(limit ?? .infinity, along + speed)
            let pose = line.pose(at: along)
            if speed > 0.5 { bearing = pose.bearing }
            let fix = CLLocation(coordinate: pose.coordinate, altitude: 0, horizontalAccuracy: 5,
                                 verticalAccuracy: 5,
                                 course: speed > 0.5 ? bearing : -1, courseAccuracy: speed > 0.5 ? 10 : -1,
                                 speed: speed, speedAccuracy: 1, timestamp: Date())
            env.location.locationManager(env.location.manager, didUpdateLocations: [fix])
        }
    }
}
#endif
