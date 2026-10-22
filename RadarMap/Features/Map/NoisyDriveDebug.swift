//
//  NoisyDriveDebug.swift
//  RadarMap
//
//  DEBUG-поездка с шумом GPS для замера плавности (27.A): `-demoRoute
//  -driveDemo -noisyDrive -logMarker`. Фиксы идут по линии построенного
//  маршрута на 50 км/ч с неровным интервалом 0,8–1,5 с и шумом вдоль дороги
//  3–5 м (знак случайный) и поперёк до 2 м — то, чего `simctl location start`
//  не умеет (у него ровный интервал и честные точки). Истинная точка пишется
//  в журнал строкой «МЕТКА истина», разбор — tools/marker_lag.py.
//
//  Фиксы входят тем же путём, что от CLLocationManager (делегат), — фильтр,
//  гейты, маршрут и значок видят их как настоящие.
//

#if DEBUG
import CoreLocation
import MapKit
import os

@MainActor
enum NoisyDriveDebug {

    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-noisyDrive") }

    /// Детерминированный шум (xorshift): прогоны «до» и «после» одинаковы.
    private struct Noise {
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        mutating func unit() -> Double {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Double(state % 1_000_001) / 1_000_000
        }
        mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * unit() }
    }

    static func run(env: AppEnvironment, speed: Double = 50 / 3.6) async {
        for _ in 0..<60 where !env.route.isActive { await Task.pause(seconds: 0.5) }
        guard let points = env.route.selected?.points, points.count >= 2 else { return }
        let coordinates = points.map(\.coordinate)
        let line = RouteCut.Line(coordinates)
        var noise = Noise()
        var along = 0.0
        let log = Logger(subsystem: "uz.radarmap.ios", category: "location")
        while along < line.length - 20 {
            let interval = noise.range(0.8, 1.5)
            await Task.pause(seconds: interval)
            along += speed * interval
            let truth = line.pose(at: along)
            let alongNoise = noise.range(3, 5) * (noise.unit() < 0.5 ? -1 : 1)
            let lateral = noise.range(-2, 2)
            let θ = truth.bearing * .pi / 180
            let shifted = MarkerPredictor.moved(truth.coordinate,
                                                east: alongNoise * sin(θ) + lateral * cos(θ),
                                                north: alongNoise * cos(θ) - lateral * sin(θ))
            let now = Date()
            log.notice("МЕТКА истина \(now.timeIntervalSince1970, format: .fixed(precision: 3), privacy: .public) \(truth.coordinate.latitude, format: .fixed(precision: 7), privacy: .public) \(truth.coordinate.longitude, format: .fixed(precision: 7), privacy: .public) \(speed, format: .fixed(precision: 2), privacy: .public)")
            let course = (truth.bearing + noise.range(-5, 5) + 360).truncatingRemainder(dividingBy: 360)
            let fix = CLLocation(coordinate: shifted, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                                 course: course, courseAccuracy: 10,
                                 speed: speed + noise.range(-0.5, 0.5), speedAccuracy: 1, timestamp: now)
            env.location.locationManager(env.location.manager, didUpdateLocations: [fix])
        }
    }
}
#endif
