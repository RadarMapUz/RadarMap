//
//  TrafficData.swift
//  RadarMap
//
//  Пробки с сервера (server/traffic_build.py → traffic/now.json) и что из них
//  следует для маршрута.
//
//  Ребро — отрезок дороги OSM между двумя узлами, направленный (у проспекта
//  каждое направление — своё ребро): уровень 1 — свободно, 2 — медленно,
//  3 — пробка; текущая скорость и скорость графа (car.lua) на этом ребре.
//
//  Задержка маршрута честная и консервативная: участок маршрута получает
//  поправку, только если совпал с медленным ребром и МЕСТОМ (≤ 18 м), и
//  НАПРАВЛЕНИЕМ (≤ 35°) — иначе пробка на встречной полосе проспекта
//  удлиняла бы нашу дорогу. Свободные рёбра ETA не трогают: скорость графа и
//  так «свободная», а угадывать, что мы быстрее OSRM, — не наше дело.
//
//  Чистая логика, покрыта TrafficDataTests.
//

import CoreLocation
import Foundation

nonisolated struct TrafficEdge: Equatable, Sendable {
    let a: CLLocationCoordinate2D
    let b: CLLocationCoordinate2D
    /// 1 — свободно, 2 — медленно, 3 — пробка.
    let level: Int
    let kmh: Double
    let modelKmh: Double

    static func == (l: TrafficEdge, r: TrafficEdge) -> Bool {
        l.a.latitude == r.a.latitude && l.a.longitude == r.a.longitude
            && l.b.latitude == r.b.latitude && l.b.longitude == r.b.longitude
            && l.level == r.level && l.kmh == r.kmh && l.modelKmh == r.modelKmh
    }
}

nonisolated struct TrafficSnapshot: Sendable {
    let generated: Date
    let edges: [TrafficEdge]
    private let grid: [Int64: [Int32]]

    init(generated: Date, edges: [TrafficEdge]) {
        self.generated = generated
        self.edges = edges
        var grid: [Int64: [Int32]] = [:]
        for (index, edge) in edges.enumerated() {
            for key in Self.cells(edge.a, edge.b) { grid[key, default: []].append(Int32(index)) }
        }
        self.grid = grid
    }

    /// Разбор now.json. Формат версии 1:
    /// `{"v":1,"generated":t,"edges":[[ulat,ulon,vlat,vlon,level,kmh,model]]}`.
    /// Другая версия или битое ребро — nil/пропуск: показывать догадку о
    /// формате хуже, чем не показывать пробки.
    static func decode(_ data: Data) -> TrafficSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["v"] as? Int == 1,
              let generated = object["generated"] as? Double ?? (object["generated"] as? Int).map(Double.init),
              let raw = object["edges"] as? [[Double]] else { return nil }
        let edges = raw.compactMap { row -> TrafficEdge? in
            guard row.count >= 7, (1...3).contains(Int(row[4])), row[6] > 0 else { return nil }
            return TrafficEdge(a: CLLocationCoordinate2D(latitude: row[0], longitude: row[1]),
                               b: CLLocationCoordinate2D(latitude: row[2], longitude: row[3]),
                               level: Int(row[4]), kmh: max(0, row[5]), modelKmh: row[6])
        }
        return TrafficSnapshot(generated: Date(timeIntervalSince1970: generated), edges: edges)
    }

    /// Пробкам больше `trafficStaleSeconds` — данных нет (сборщик стоит).
    func isFresh(now: Date) -> Bool {
        now.timeIntervalSince(generated) <= AppConfig.trafficStaleSeconds
    }

    // MARK: - Маршрут

    /// Сколько секунд добавляют пробки к маршруту по точкам `route`.
    /// Участок маршрута бьётся на шаги по ~25 м; шаг, совпавший с медленным
    /// ребром по месту и направлению, едет со скоростью ребра вместо скорости
    /// графа. Свободные рёбра не учитываются (см. шапку файла).
    func delay(along route: [CLLocationCoordinate2D]) -> TimeInterval {
        guard route.count >= 2, !edges.isEmpty else { return 0 }
        var total: TimeInterval = 0
        for (p, q) in zip(route, route.dropFirst()) {
            let length = GeoMath.fastDistance(p.latitude, p.longitude, q.latitude, q.longitude)
            guard length > 0.5 else { continue }
            let course = GeoMath.bearing(from: p, to: q)
            let steps = max(1, Int((length / 25).rounded(.up)))
            let stepLength = length / Double(steps)
            for s in 0..<steps {
                let t = (Double(s) + 0.5) / Double(steps)
                let point = CLLocationCoordinate2D(latitude: p.latitude + (q.latitude - p.latitude) * t,
                                                   longitude: p.longitude + (q.longitude - p.longitude) * t)
                guard let edge = matchingEdge(at: point, course: course), edge.level >= 2 else { continue }
                let now = max(3, edge.kmh) / 3.6
                let free = edge.modelKmh / 3.6
                total += max(0, stepLength / now - stepLength / free)
            }
        }
        return total
    }

    /// Ребро под точкой маршрута: ближайшее в пределах trafficMatchMeters с
    /// направлением не дальше trafficMatchDegrees.
    func matchingEdge(at point: CLLocationCoordinate2D, course: Double) -> TrafficEdge? {
        var best: (edge: TrafficEdge, distance: Double)?
        for key in Self.cells(point, point) {
            for index in grid[key] ?? [] {
                let edge = edges[Int(index)]
                let distance = Self.distance(point, toSegment: edge.a, edge.b)
                guard distance <= AppConfig.trafficMatchMeters,
                      GeoMath.angleDifference(GeoMath.bearing(from: edge.a, to: edge.b), course)
                        <= AppConfig.trafficMatchDegrees else { continue }
                if best == nil || distance < best!.distance { best = (edge, distance) }
            }
        }
        return best?.edge
    }

    // MARK: - Сетка

    /// Ячейка ~550 м; отрезок кладётся во все ячейки своей рамки (рёбра OSM
    /// короткие — обычно одна-две).
    private static let cellDegrees = 0.005

    private static func cells(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> [Int64] {
        let pad = 0.0003   // ~30 м: точка у границы ячейки видит соседнюю
        let x0 = Int64(((min(a.longitude, b.longitude) - pad) / cellDegrees).rounded(.down))
        let x1 = Int64(((max(a.longitude, b.longitude) + pad) / cellDegrees).rounded(.down))
        let y0 = Int64(((min(a.latitude, b.latitude) - pad) / cellDegrees).rounded(.down))
        let y1 = Int64(((max(a.latitude, b.latitude) + pad) / cellDegrees).rounded(.down))
        var out: [Int64] = []
        for x in x0...x1 { for y in y0...y1 { out.append(x << 32 | (y & 0xFFFF_FFFF)) } }
        return out
    }

    /// Расстояние от точки до отрезка в метрах (плоское приближение — рёбра
    /// короткие).
    static func distance(_ p: CLLocationCoordinate2D, toSegment a: CLLocationCoordinate2D,
                         _ b: CLLocationCoordinate2D) -> Double {
        let k = cos(p.latitude * .pi / 180) * 111_320
        let ax = (a.longitude - p.longitude) * k, ay = (a.latitude - p.latitude) * 111_320
        let bx = (b.longitude - p.longitude) * k, by = (b.latitude - p.latitude) * 111_320
        let dx = bx - ax, dy = by - ay
        let len2 = dx * dx + dy * dy
        let t = len2 > 0 ? max(0, min(1, -(ax * dx + ay * dy) / len2)) : 0
        let x = ax + dx * t, y = ay + dy * t
        return (x * x + y * y).squareRoot()
    }
}
