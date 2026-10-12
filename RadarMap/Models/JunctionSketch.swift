//
//  JunctionSketch.swift
//  RadarMap
//
//  Схема развязки для карточки манёвра в машине (CPManeuver.junctionImage).
//
//  Стрелка «направо» на сложном узле — Малая кольцевая, выезды из города,
//  двойные съезды — не говорит, КАКОЙ из трёх правых съездов наш. У Яндекса
//  и Amap на этот случай есть схема развязки сверху. Здесь — она же из того,
//  что у нас уже есть: линия маршрута и подписанная сеть дорог вокруг
//  (RoadNetworkService — свои тайлы, иначе индекс лимитов).
//
//  Схема повёрнута «по ходу»: подъезд снизу вверх, точка манёвра чуть ниже
//  центра — впереди важнее, чем позади. Окно — `junctionRadiusMeters`
//  вокруг манёвра. Здесь только геометрия в точках картинки; рисует
//  CarPlayGuidance (цвета темы машины). Чистая логика; JunctionSketchTests.
//

import CoreGraphics
import CoreLocation
import Foundation

nonisolated enum JunctionSketch {

    struct Plan: Equatable, Sendable {
        /// Наш путь через узел: подъезд и съезд одной линией, точки картинки.
        let path: [CGPoint]
        /// Остальные дороги узла.
        let roads: [[CGPoint]]
        let size: CGSize
    }

    /// Точка манёвра на картинке: по центру, чуть ниже середины.
    static let anchor = CGPoint(x: 0.5, y: 0.62)

    /// План схемы или nil — линии маршрута у манёвра нет.
    /// - Parameters:
    ///   - route: точки маршрута от старта.
    ///   - maneuverAlong: метры от старта до манёвра.
    ///   - roads: дороги вокруг манёвра (любые — лишнее отрежет окно).
    static func plan(route: [CLLocationCoordinate2D], maneuverAlong: CLLocationDistance,
                     roads: [[CLLocationCoordinate2D]],
                     size: CGSize = CGSize(width: 140, height: 100)) -> Plan? {
        let radius = AppConfig.junctionRadiusMeters
        guard route.count >= 2,
              let center = point(on: route, at: maneuverAlong),
              let before = point(on: route, at: max(0, maneuverAlong - AppConfig.junctionApproachMeters))
        else { return nil }
        let approach = GeoMath.bearing(from: before, to: center)
        guard approach.isFinite else { return nil }
        // Масштаб: окно радиуса R укладывается по высоте с запасом сверху.
        let scale = Double(size.height) * (1 - anchor.y * 0.25) / (radius * 1.25)
        let origin = CGPoint(x: size.width * anchor.x, y: size.height * anchor.y)

        func project(_ c: CLLocationCoordinate2D) -> CGPoint {
            // Локальная плоскость вокруг манёвра (м), затем поворот «по ходу».
            let k = cos(center.latitude * .pi / 180) * 111_320
            let east = (c.longitude - center.longitude) * k
            let north = (c.latitude - center.latitude) * 111_320
            let a = approach * .pi / 180
            // Ось «вперёд» — азимут подъезда: вперёд — вверх картинки.
            let forward = east * sin(a) + north * cos(a)
            let right = east * cos(a) - north * sin(a)
            return CGPoint(x: origin.x + right * scale, y: origin.y - forward * scale)
        }

        // Съезд короче подъезда: стрелка на его конце обязана остаться в кадре
        // и на прямом проезде (вверх места меньше, чем вниз).
        let pathCoords = slice(route, from: maneuverAlong - radius, to: maneuverAlong + radius * 0.7)
        guard pathCoords.count >= 2 else { return nil }
        let window = radius * 1.1
        let clipped = roads.flatMap { clip($0, around: center, within: window) }.map { $0.map(project) }
        return Plan(path: pathCoords.map(project), roads: clipped, size: size)
    }

    // MARK: - Линия

    /// Куски дороги внутри круга. По отрезкам, а не по вершинам: поперечная
    /// улица с вершинами за окном проходит через сам узел — её надо видеть.
    static func clip(_ road: [CLLocationCoordinate2D], around center: CLLocationCoordinate2D,
                     within radius: CLLocationDistance) -> [[CLLocationCoordinate2D]] {
        func inside(_ c: CLLocationCoordinate2D) -> Bool {
            GeoMath.fastDistance(c.latitude, c.longitude, center.latitude, center.longitude) <= radius
        }
        var runs: [[CLLocationCoordinate2D]] = []
        var current: [CLLocationCoordinate2D] = []
        for (p, q) in zip(road, road.dropFirst()) {
            let length = GeoMath.fastDistance(p.latitude, p.longitude, q.latitude, q.longitude)
            let steps = max(1, Int((length / 10).rounded(.up)))
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let point = CLLocationCoordinate2D(latitude: p.latitude + (q.latitude - p.latitude) * t,
                                                   longitude: p.longitude + (q.longitude - p.longitude) * t)
                if inside(point) {
                    current.append(point)
                } else if !current.isEmpty {
                    if current.count >= 2 { runs.append(current) }
                    current = []
                }
            }
        }
        if current.count >= 2 { runs.append(current) }
        return runs
    }

    /// Точка на ломаной в `along` метрах от начала.
    static func point(on line: [CLLocationCoordinate2D], at along: CLLocationDistance) -> CLLocationCoordinate2D? {
        guard line.count >= 2 else { return nil }
        var travelled: CLLocationDistance = 0
        for (p, q) in zip(line, line.dropFirst()) {
            let length = GeoMath.fastDistance(p.latitude, p.longitude, q.latitude, q.longitude)
            if travelled + length >= along, length > 0 {
                let t = max(0, (along - travelled) / length)
                return CLLocationCoordinate2D(latitude: p.latitude + (q.latitude - p.latitude) * t,
                                              longitude: p.longitude + (q.longitude - p.longitude) * t)
            }
            travelled += length
        }
        return line.last
    }

    /// Кусок ломаной между `from` и `to` метров от начала (с концами).
    static func slice(_ line: [CLLocationCoordinate2D], from: CLLocationDistance,
                      to: CLLocationDistance) -> [CLLocationCoordinate2D] {
        guard line.count >= 2, to > from else { return [] }
        var out: [CLLocationCoordinate2D] = []
        if let start = point(on: line, at: max(0, from)) { out.append(start) }
        var travelled: CLLocationDistance = 0
        for (p, q) in zip(line, line.dropFirst()) {
            travelled += GeoMath.fastDistance(p.latitude, p.longitude, q.latitude, q.longitude)
            if travelled > max(0, from), travelled < to { out.append(q) }
            if travelled >= to { break }
        }
        if let end = point(on: line, at: to) { out.append(end) }
        return out
    }
}
