//
//  MyRoadDemo.swift
//  RadarMap
//
//  DEBUG: «Моя дорога» (24.4) на снимок без сети. `-demoMyRoad` — маршрут
//  с работы домой (демо-места TripStats): два варианта движка и своя дорога
//  лесенкой через квартал, проезженная шесть раз в этот час. Пути
//  подставные; разбор, выбор, ярлык и время по своим поездкам — настоящие
//  (RouteService.seedDemoMyRoad). В релизную сборку не попадает.
//

#if DEBUG
import CoreLocation
import Foundation
import MapKit

enum MyRoadDemo {
    @MainActor
    static func seed(_ env: AppEnvironment) async -> MKMapRect? {
        let work = TripStats.demoWork, home = TripStats.demoHome
        let k = 111_320 * cos(work.latitude * .pi / 180)
        // Метры от работы: x — восток, y — север.
        func at(_ x: Double, _ y: Double) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: work.latitude + y / 111_320, longitude: work.longitude + x / k)
        }
        let dx = (home.longitude - work.longitude) * k, dy = (home.latitude - work.latitude) * 111_320
        func path(_ corners: [(Double, Double)]) -> [CLLocationCoordinate2D] {
            var out = [at(corners[0].0, corners[0].1)]
            for (a, b) in zip(corners, corners.dropFirst()) {
                let n = max(1, Int((hypot(b.0 - a.0, b.1 - a.1) / 50).rounded(.up)))
                for i in 1...n {
                    let t = Double(i) / Double(n)
                    out.append(at(a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t))
                }
            }
            return out
        }
        let fast = path([(0, 0), (dx, 0), (dx, dy)])
        let south = path([(0, 0), (0, dy), (dx, dy)])
        let mine = path([(0, 0), (dx * 0.35, 0), (dx * 0.35, dy * 0.5), (dx * 0.75, dy * 0.5),
                         (dx * 0.75, dy), (dx, dy)])

        // Профиль дороги домой: шесть поездок в этот же час этого дня недели,
        // ~27 мин на весь путь.
        let frame = CommuteProfile.Frame(latitude: work.latitude)
        let length = CommuteProfile.Geometry.length(mine.map { frame.xy($0.latitude, $0.longitude) })
        let ends = CommuteProfile.boundaries(length: length)
        let now = Date()
        let rows = (1...6).map { week -> CommuteProfile.Row in
            let departure = now.addingTimeInterval(-Double(week) * 7 * 86_400)
            return CommuteProfile.Row(tripID: departure.timeIntervalSince1970, departure: departure,
                                      weekend: UzHolidays.isDayOff(now), arrivalMinute: 0,
                                      seconds: [UInt16](repeating: UInt16(27 * 60 / ends.count + week % 2),
                                                        count: ends.count))
        }
        var packed: [Int32] = []
        for c in mine {
            packed.append(Int32((c.latitude * 1e5).rounded()))
            packed.append(Int32((c.longitude * 1e5).rounded()))
        }
        let variant = CommuteProfile.Variant(id: UUID(), line: packed, ends: ends.map(Float.init),
                                             limitKmh: [], rows: rows, lastUsed: now)
        guard let plan = MyRoad.plan(variants: [variant], direction: .toHome, source: work,
                                     destination: home, home: home, work: work) else { return nil }
        let name = env.settings.appLanguage == .uz ? "Uy" : "Дом"
        await env.route.seedDemoMyRoad(name: name, destination: home,
                                       engine: [(fast, 24 * 60), (south, 28 * 60)],
                                       mine: (mine, 26 * 60), plan: plan, cameras: env.cameras.cameras)
        var rect = MKMapRect.null
        for variant in env.route.variants { rect = rect.union(variant.polyline.boundingMapRect) }
        return rect.isNull ? nil : rect
    }
}
#endif
