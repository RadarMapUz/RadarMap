//
//  DriveCameraSim.swift
//  RadarMapTests
//
//  Синтетические поездки для камеры карты (25.A, «то уменьшается, то
//  увеличивается»): кинематика по прямой дороге, камеры базы на ней и на
//  соседних улицах, манёвры маршрута — и тот же выбор «ближайшей камеры», что
//  у LocationService (стоя и медленнее 10 км/ч гейты выключены и ближайшей
//  становится любая камера вокруг, на ходу — только наша впереди). На выходе —
//  ряд цели и кадра по времени и мерки «дыхания».
//
//  Файл без XCTest: тот же код собирается отдельно (swiftc) для замера до/после
//  — см. docs/drive_camera_2026-10-21.md.
//

import CoreLocation
import Foundation
#if canImport(RadarMap)
@testable import RadarMap
#endif

nonisolated enum DriveCameraSim {

    /// Камера базы в осях дороги: метров вдоль от старта и вбок (вправо +).
    struct Point: Sendable {
        var along: Double
        var lateral: Double
        /// Своя камера (CameraFamiliarity, «без голоса»).
        var familiar = false
    }

    /// Поездка: ключевые точки скорости (секунда, км/ч) — линейно между ними.
    struct Trip: Sendable {
        var name: String
        var speeds: [(t: Double, kmh: Double)]
        var cameras: [Point]
        /// Манёвры маршрута — метров вдоль; пусто и `route == false` — без маршрута.
        var maneuvers: [Double] = []
        var route = true

        var duration: Double { speeds.last?.t ?? 0 }

        func speed(at t: Double) -> Double {
            guard let first = speeds.first, let last = speeds.last else { return 0 }
            if t <= first.t { return first.kmh }
            if t >= last.t { return last.kmh }
            for (a, b) in zip(speeds, speeds.dropFirst()) where t <= b.t {
                let k = b.t > a.t ? (t - a.t) / (b.t - a.t) : 0
                return a.kmh + (b.kmh - a.kmh) * k
            }
            return last.kmh
        }
    }

    /// Экран: высота вида, незакрытая часть и где машина.
    struct Screen: Sendable {
        var name: String
        var kind: DriveCamera.Screen
        var height: Double
        var clear: DriveCamera.Clear
        var carY: @Sendable (Double) -> Double
    }

    struct Sample: Sendable {
        var t: Double
        var kmh: Double
        var along: Double
        var maneuver: Double?
        var keep: DriveCamera.Keep?
        var target: DriveCamera.Frame
        var frame: DriveCamera.Frame
    }

    static let latitude = 41.31
    static let maxPitch = 45.0
    /// Ниже — гейты направления выключены (AppConfig.directionalMinSpeedKmh).
    static let gatesMinKmh = 10.0
    /// Камера на маршруте позади ещё «ближайшая» (routePassedToleranceMeters).
    static let routePassedTolerance = 60.0
    /// Коридор «наша дорога» без маршрута: вбок не дальше, позади не дальше.
    static let corridorLateral = 25.0
    static let corridorBehind = 30.0

    // MARK: - Экраны

    /// Окно CarPlay со снимков владельца (2000×943 px, 21.10): бар сверху,
    /// док HUD снизу (100 + 12 pt), кнопки карты справа.
    static func car(height: Double = 471, width: Double = 940) -> Screen {
        let top = 50.0
        return Screen(name: "машина \(Int(height)) pt", kind: .car, height: height,
                      clear: DriveCamera.Clear(top: top / height, bottom: 112 / height,
                                               width: width, side: 120,
                                               topKeepPoints: DriveCamera.keepMarginPoints),
                      carY: { share in (top + 12 + (height - 12 - top - 12) * share) / height })
    }

    /// Телефон 402×760: HUD сверху, панель поездки снизу, кнопки справа.
    static let phone = Screen(name: "телефон 760 pt", kind: .phone, height: 760,
                              clear: DriveCamera.Clear(top: 0.17, bottom: 0.12, width: 402, side: 60),
                              carY: { _ in 0.72 })

    // MARK: - Поездки

    /// Город 10–40 км/ч с остановками у светофоров и пробкой, маршрут с двумя
    /// поворотами, камеры на дороге и на соседних улицах.
    static let city = Trip(
        name: "город",
        speeds: [(0, 0), (8, 0), (16, 35), (40, 38), (48, 0), (75, 0), (83, 25), (95, 30),
                 (100, 12), (106, 20), (112, 8), (118, 15), (124, 4), (130, 0), (140, 0),
                 (148, 28), (175, 40), (185, 40), (192, 0), (215, 0), (222, 20), (240, 30),
                 (250, 10), (255, 0), (262, 0), (270, 25), (300, 35)],
        cameras: [Point(along: 260, lateral: 0), Point(along: 420, lateral: 120),
                  Point(along: 700, lateral: 0), Point(along: 880, lateral: -140),
                  Point(along: 1_150, lateral: 0), Point(along: 1_400, lateral: 90),
                  Point(along: 1_650, lateral: 0)],
        maneuvers: [640, 1_320, 2_400])

    /// Снимок 63 (19:40): ползком около 10 км/ч, разворот через 580 м, камера
    /// впереди в 403 м, по сторонам — камеры соседних улиц.
    static let uTurn = Trip(
        name: "разворот",
        speeds: [(0, 10), (20, 12), (30, 8), (40, 11), (50, 3), (58, 3), (64, 10), (80, 14),
                 (95, 9), (105, 4), (112, 2), (120, 9), (140, 12), (160, 10), (175, 6),
                 (185, 10), (210, 12), (230, 8)],
        cameras: [Point(along: 403, lateral: 0), Point(along: 150, lateral: 140),
                  Point(along: 300, lateral: -160), Point(along: -60, lateral: 0)],
        maneuvers: [580])

    /// Стоянка у светофора: подъезд на 40, камеру проехали за 40 м до
    /// стоп-линии, сбоку камера в 136 м, впереди в 450 м; минута стоим, едем.
    static let standstill = Trip(
        name: "стоянка",
        speeds: [(0, 40), (12, 40), (22, 0), (82, 0), (90, 25), (110, 40), (130, 40)],
        cameras: [Point(along: 160, lateral: 0), Point(along: 210, lateral: 136),
                  Point(along: 650, lateral: 0)],
        route: false)

    /// Тот же разворот, но камера в 403 м — своя, как на снимке 63.
    static let uTurnFamiliar: Trip = {
        var trip = uTurn
        trip.name = "разворот, своя камера"
        trip.cameras[0].familiar = true
        return trip
    }()

    static let trips = [city, uTurn, uTurnFamiliar, standstill]

    // MARK: - Прогон

    /// Ближайшая камера, как её выбирает LocationService (+Nearest, LocationGates).
    static func nearest(_ trip: Trip, along s: Double, kmh: Double) -> Point? {
        let filtering = kmh >= gatesMinKmh
        var best: (point: Point, distance: Double)?
        for camera in trip.cameras {
            let forward = camera.along - s
            let straight = (forward * forward + camera.lateral * camera.lateral).squareRoot()
            let onRoute = trip.route && abs(camera.lateral) < 15
            var distance = straight
            if onRoute {
                guard forward > -routePassedTolerance else { continue }
                distance = max(0, forward)
            }
            let ours = !filtering || onRoute
                || (abs(camera.lateral) <= corridorLateral && forward >= -corridorBehind)
            guard ours else { continue }
            if best.map({ distance < $0.distance }) ?? true { best = (camera, distance) }
        }
        return best?.point
    }

    static func run(_ trip: Trip, on screen: Screen, step: Double = 0.25,
                    smoother initial: DriveCamera.Smoother = DriveCamera.Smoother(),
                    pitchAllowed: Bool = true) -> [Sample] {
        var smoother = initial
        var samples: [Sample] = []
        var s = 0.0
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var t = 0.0
        while t <= trip.duration + 1e-9 {
            let kmh = trip.speed(at: t)
            let maneuver = trip.route ? trip.maneuvers.first(where: { $0 > s }).map { $0 - s } : nil
            // Своя камера остаётся «ближайшей» (HUD, голос), но в кадре не держится.
            let keep = nearest(trip, along: s, kmh: kmh).flatMap {
                $0.familiar ? nil : DriveCamera.Keep(forward: $0.along - s, right: $0.lateral)
            }
            let target = DriveCamera.target(speedKmh: kmh, maneuverDistance: maneuver,
                                            pitchAllowed: pitchAllowed, maxPitch: maxPitch,
                                            screen: screen.kind, keep: keep,
                                            viewHeight: screen.height, latitude: latitude,
                                            clear: screen.clear, carY: screen.carY)
            let frame = smoother.step(toward: target, at: t0 + t)
            samples.append(Sample(t: t, kmh: kmh, along: s, maneuver: maneuver, keep: keep,
                                  target: target, frame: frame))
            s += kmh / 3.6 * step
            t += step
        }
        return samples
    }

    // MARK: - Мерки

    struct Metrics: Sendable {
        var minZoom, maxZoom: Double
        /// Наибольший размах кадра за любые 60 с.
        var swingPerMinute: Double
        /// То же у цели — что приходит в сглаживание.
        var targetSwingPerMinute: Double
        /// Смен направления зума (приближение ↔ отъезд).
        var reversals: Int
        /// Самый короткий промежуток между сменами направления, с.
        var shortestReversalGap: Double
        /// Самый быстрый отъезд и приближение за секунду, уровней.
        var fastestOut, fastestIn: Double
        /// Отсчётов, где манёвр ближе `DriveCamera.maneuverCloseMeters`, а в
        /// кадре его нет (до нижней кромки верхней панели).
        var turnMissed: Int
    }

    /// Шаг меньше этого — стоим (округление сглаживания 0,01).
    static let moveEpsilon = 0.005

    static func metrics(_ samples: [Sample], on screen: Screen) -> Metrics {
        let zooms = samples.map(\.frame.zoom), targets = samples.map(\.target.zoom)
        func swing(_ values: [Double]) -> Double {
            var worst = 0.0
            var start = 0
            for end in samples.indices {
                while samples[end].t - samples[start].t > 60 { start += 1 }
                let window = values[start...end]
                worst = max(worst, (window.max() ?? 0) - (window.min() ?? 0))
            }
            return worst
        }
        var reversals = 0, gap = Double.infinity, fastestOut = 0.0, fastestIn = 0.0
        var direction = 0
        var lastChange: Double?
        var start = 0
        for end in samples.indices {
            while samples[end].t - samples[start].t > 1 { start += 1 }
            guard samples[end].t - samples[start].t >= 1 - 1e-9 else { continue }
            let dz = samples[end].frame.zoom - samples[start].frame.zoom
            if dz < 0 { fastestOut = max(fastestOut, -dz) } else { fastestIn = max(fastestIn, dz) }
        }
        for (a, b) in zip(samples, samples.dropFirst()) {
            let dz = b.frame.zoom - a.frame.zoom
            guard abs(dz) > moveEpsilon else { continue }
            let now = dz > 0 ? 1 : -1
            if direction != 0, now != direction {
                reversals += 1
                if let last = lastChange { gap = min(gap, b.t - last) }
                lastChange = b.t
            }
            direction = now
        }
        let turnMissed = samples.filter { x in
            guard let d = x.maneuver, d <= DriveCamera.maneuverCloseMeters else { return false }
            return DriveCamera.visibleAhead(zoom: x.frame.zoom, pitchDegrees: x.frame.pitchDegrees,
                                            viewHeight: screen.height, carY: screen.carY(x.frame.carShare),
                                            latitude: latitude, clearTop: screen.clear.top) < d
        }.count
        return Metrics(minZoom: zooms.min() ?? 0, maxZoom: zooms.max() ?? 0,
                       swingPerMinute: swing(zooms), targetSwingPerMinute: swing(targets),
                       reversals: reversals, shortestReversalGap: gap,
                       fastestOut: fastestOut, fastestIn: fastestIn, turnMissed: turnMissed)
    }
}
