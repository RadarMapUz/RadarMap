//
//  TripodZone.swift
//  RadarMap
//
//  Участок треноги на асфальте (83, вариант C владельца): у ближайшей
//  треноги впереди — кусок НАШЕЙ проезжей части, где она меряет, красной
//  штриховкой; у зоны «здесь часто ставят» — янтарной, самой спокойной.
//  Значок треноги остаётся у её точки (слой камер), знак лимита — в начале
//  участка, если лимит дороги известен.
//
//  Длина — `tripodZoneBeforeMeters` перед отметкой и `tripodZoneAfterMeters`
//  после (обоснование — в AppConfig). Сторона — по ходу движения:
//    • с маршрутом — кусок линии маршрута у отметки (линия и есть наша
//      полоса; отметка на встречной половине разделённой дороги всё равно
//      рисуется на нашей стороне — тренога предупреждает в обе стороны);
//    • без маршрута с курсом — проезжая часть по сети дорог: из осей у
//      отметки, идущих вдоль курса, — правая (правостороннее движение), не
//      встречная односторонняя; у одной двусторонней оси — её правая половина;
//    • без курса (стоим) — каждая проезжая часть дороги по своему ходу.
//
//  Ступень — из отметки: подтверждена (полная), не подтверждена (реже штрих,
//  слабее), «часто ставят» (янтарь, без значка и без лимита). Вход доверия
//  пока один — `confirmed` отметки (ветка 82 даст свою модель — подставится
//  в `Candidate.grade`).
//
//  ТОЛЬКО КАРТИНКА: оповещения, гейты и проезды это не читают
//  (TripodZoneTests сверяет исходники). Геометрия считается на смене цели,
//  а источник движка пишется только при смене участка или ступени.
//
//  Чистая логика; TripodZoneTests.
//

import CoreLocation
import MapKit

nonisolated enum TripodZone {

    enum Grade: String, Sendable, CaseIterable {
        case confirmed, unconfirmed, hotspot
    }

    /// Возможная цель: отметка треноги или зона «часто ставят».
    struct Candidate: Equatable, Sendable {
        /// id камеры отметки; у зоны «часто ставят» — отрицательный ключ места.
        let key: Int
        let latitude: Double
        let longitude: Double
        let grade: Grade

        init(key: Int, coordinate: CLLocationCoordinate2D, grade: Grade) {
            self.key = key
            latitude = coordinate.latitude
            longitude = coordinate.longitude
            self.grade = grade
        }

        var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    }

    /// Кусок одной проезжей части: точки по ходу движения, от начала участка.
    struct Piece: Equatable, Sendable {
        let points: [CameraOnLine.Point]
        /// Ширина штриховки, м.
        let widthMeters: Double
        /// Сдвиг вправо по ходу, м: у двусторонней дороги — своя половина.
        let offsetMeters: Double
        /// Кусок линии маршрута: на нём краснеет и кайма линии.
        let onRoute: Bool
    }

    /// Знак лимита в начале участка.
    struct Limit: Equatable, Sendable {
        let point: CameraOnLine.Point
        let kmh: Int
    }

    struct Band: Equatable, Sendable {
        let key: Int
        let grade: Grade
        let pieces: [Piece]
        let limits: [Limit]

        var latitude: Double { pieces.first?.points.first?.latitude ?? 0 }
    }

    /// Ступень мягкого конца: часть куска и её сила (0…1).
    struct Ramp: Equatable, Sendable {
        let points: [CameraOnLine.Point]
        let alpha: Double
    }

    // MARK: - Ключ зоны «часто ставят»

    /// Устойчивый отрицательный ключ места (id камер — положительные).
    static func hotspotKey(latitude: Double, longitude: Double) -> Int {
        let a = Int((latitude * 10_000).rounded()), b = Int((longitude * 10_000).rounded())
        return -1 - Int((a &* 1_000_003 &+ b).magnitude % 1_000_000_000)
    }

    // MARK: - Какая цель

    /// Ближайшая цель впереди: тренога, а без неё — зона «часто ставят».
    /// - Parameters:
    ///   - routeAlong: места целей на линии маршрута (м от старта); nil — маршрута нет.
    ///   - progress: где мы на линии маршрута.
    ///   - course: наш курс; < 0 — неизвестен (стоим).
    static func target(tripods: [Candidate], hotspots: [Candidate], me: CLLocationCoordinate2D,
                       course: Double, routeAlong: [Int: Double]?, progress: Double?,
                       ahead: Double = AppConfig.tripodZoneAheadMeters,
                       passed: Double = AppConfig.tripodZoneAfterMeters + 20,
                       stand: Double = AppConfig.tripodZoneStandMeters,
                       lateral: Double = AppConfig.tripodZoneLateralMeters) -> Candidate? {
        func pick(_ list: [Candidate]) -> Candidate? {
            if let routeAlong, let progress {
                var best: (Candidate, Double)?
                for candidate in list {
                    guard let along = routeAlong[candidate.key],
                          along >= progress - passed, along - progress <= ahead else { continue }
                    if best.map({ along < $0.1 }) ?? true { best = (candidate, along) }
                }
                return best?.0
            }
            let flat = Flat(origin: me)
            if course >= 0 {
                let heading = unit(course)
                var best: (Candidate, Double)?
                for candidate in list {
                    let v = flat.xy(candidate.coordinate)
                    let along = dot(v, heading)
                    guard along >= -passed, along <= ahead, abs(cross(heading, v)) <= lateral else { continue }
                    if best.map({ along < $0.1 }) ?? true { best = (candidate, along) }
                }
                return best?.0
            }
            var best: (Candidate, Double)?
            for candidate in list {
                let distance = length(flat.xy(candidate.coordinate))
                guard distance <= stand else { continue }
                if best.map({ distance < $0.1 }) ?? true { best = (candidate, distance) }
            }
            return best?.0
        }
        return pick(tripods) ?? pick(hotspots)
    }

    // MARK: - Участок по линии маршрута

    /// Место точки на линии маршрута (м от старта) или nil — точка дальше
    /// `maxMeters` от линии.
    static func along(of point: CLLocationCoordinate2D, route: [MKMapPoint],
                      maxMeters: Double = AppConfig.tripodZoneRouteMeters) -> Double? {
        guard route.count >= 2 else { return nil }
        let p = MKMapPoint(point)
        let metersPerPoint = MKMetersPerMapPointAtLatitude(point.latitude)
        let reach = maxMeters / metersPerPoint
        var walked = 0.0
        var best: (distance: Double, along: Double)?
        for index in 1..<route.count {
            let a = route[index - 1], b = route[index]
            let length = a.distance(to: b)
            defer { walked += length }
            // Грубая рамка: отрезок, до которого заведомо дальше порога, не считаем.
            if p.x < min(a.x, b.x) - reach || p.x > max(a.x, b.x) + reach
                || p.y < min(a.y, b.y) - reach || p.y > max(a.y, b.y) + reach { continue }
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            let t = len2 > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2)) : 0
            let foot = MKMapPoint(x: a.x + dx * t, y: a.y + dy * t)
            let distance = foot.distance(to: p)
            guard distance <= maxMeters else { continue }
            if best.map({ distance < $0.distance }) ?? true { best = (distance, walked + length * t) }
        }
        return best?.along
    }

    /// Кусок линии маршрута у места `along`.
    static func routePiece(route: [MKMapPoint], along: Double,
                           before: Double = AppConfig.tripodZoneBeforeMeters,
                           after: Double = AppConfig.tripodZoneAfterMeters,
                           minBefore: Double = AppConfig.tripodZoneMinBeforeMeters,
                           width: Double = AppConfig.tripodZoneWidthMeters) -> Piece? {
        guard route.count >= 2 else { return nil }
        var cumulative = [0.0]
        for index in 1..<route.count {
            cumulative.append(cumulative[index - 1] + route[index - 1].distance(to: route[index]))
        }
        let total = cumulative[cumulative.count - 1]
        let from = max(0, along - before), to = min(total, along + after)
        guard along - from >= minBefore, to > from else { return nil }
        func point(at target: Double) -> MKMapPoint {
            var index = 1
            while index < cumulative.count - 1, cumulative[index] < target { index += 1 }
            let a = route[index - 1], b = route[index]
            let length = cumulative[index] - cumulative[index - 1]
            let t = length > 0 ? (target - cumulative[index - 1]) / length : 0
            return MKMapPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        var points = [point(at: from)]
        for index in cumulative.indices where cumulative[index] > from && cumulative[index] < to {
            points.append(route[index])
        }
        points.append(point(at: to))
        return Piece(points: points.map { CameraOnLine.Point(latitude: $0.coordinate.latitude,
                                                             longitude: $0.coordinate.longitude) },
                     widthMeters: width, offsetMeters: 0, onRoute: true)
    }

    // MARK: - Участок по сети дорог

    /// Куски проезжих частей у отметки: с курсом — один (наш), без курса —
    /// по одному на каждое направление дороги. Пусто — доказательства нет.
    static func roadPieces(lines: [RoadLine], tripod: CLLocationCoordinate2D, course: Double,
                           before: Double = AppConfig.tripodZoneBeforeMeters,
                           after: Double = AppConfig.tripodZoneAfterMeters,
                           minBefore: Double = AppConfig.tripodZoneMinBeforeMeters,
                           snap: Double = AppConfig.tripodZoneSnapMeters) -> [Piece] {
        let flat = Flat(origin: tripod)
        let polys = lines.filter { $0.kind.isVehicleRoad && $0.points.count >= 2 }
            .map { Poly(points: $0.points.map(flat.xy), line: $0) }
        let directions: [Double]
        if course >= 0 {
            directions = [course]
        } else {
            // Ось дороги — ближайший к отметке отрезок.
            var nearest: (distance: Double, bearing: Double)?
            for poly in polys {
                for index in 1..<poly.points.count {
                    let a = poly.points[index - 1], b = poly.points[index]
                    let foot = Self.foot(of: .zero, a: a, b: b)
                    let distance = length(foot.point)
                    guard distance <= snap else { continue }
                    if nearest.map({ distance < $0.distance }) ?? true {
                        nearest = (distance, bearing(b - a))
                    }
                }
            }
            guard let nearest else { return [] }
            directions = [nearest.bearing, (nearest.bearing + 180).truncatingRemainder(dividingBy: 360)]
        }
        return directions.compactMap {
            piece(polys: polys, direction: $0, flat: flat, before: before, after: after,
                  minBefore: minBefore, snap: snap)
        }
    }

    private struct Poly {
        let points: [SIMD2<Double>]
        let line: RoadLine
    }

    private static func piece(polys: [Poly], direction: Double, flat: Flat, before: Double, after: Double,
                              minBefore: Double, snap: Double) -> Piece? {
        let heading = unit(direction)
        let right = SIMD2(heading.y, -heading.x)
        struct Hit { let poly: Int; let lateral: Double; let forward: Bool; let opposing: Bool }
        var hits: [Hit] = []
        for (index, poly) in polys.enumerated() {
            var best: (distance: Double, hit: Hit)?
            for s in 1..<poly.points.count {
                let a = poly.points[s - 1], b = poly.points[s]
                let foot = Self.foot(of: .zero, a: a, b: b)
                let distance = length(foot.point)
                guard distance <= snap else { continue }
                let segment = bearing(b - a)
                guard GeoMath.axisDifference(course: direction, axis: segment.truncatingRemainder(dividingBy: 180))
                        <= AppConfig.tripodZoneMaxAxisDegrees else { continue }
                let forward = GeoMath.angleDifference(direction, segment) <= 90
                let hit = Hit(poly: index, lateral: dot(foot.point, right), forward: forward,
                              opposing: poly.line.isOneWay && !forward)
                if best.map({ distance < $0.distance }) ?? true { best = (distance, hit) }
            }
            if let best { hits.append(best.hit) }
        }
        // Наша — правая из осей вдоль курса; встречная односторонняя — не наша.
        guard let chosen = hits.filter({ !$0.opposing }).max(by: { $0.lateral < $1.lateral }) else { return nil }
        let line = polys[chosen.poly].line
        // Слева есть другая проезжая часть — наша ось и есть вся проезжая часть.
        let partner = hits.contains { $0.poly != chosen.poly
            && $0.lateral < chosen.lateral - AppConfig.tripodZoneSameAxisMeters }
        let full = line.isOneWay || partner
        let width = line.isDetailed ? line.widthMeters : AppConfig.tripodZoneWidthMeters
        // Ось по ходу движения и продолжение через стыки отрезков.
        var used: Set<Int> = [chosen.poly]
        var chain: [SIMD2<Double>] = chosen.forward ? polys[chosen.poly].points : polys[chosen.poly].points.reversed()
        func extend(backward: Bool) {
            for _ in 0..<8 {
                let (end, inner) = backward ? (chain[0], chain[1]) : (chain[chain.count - 1], chain[chain.count - 2])
                let heading = backward ? bearing(inner - end) : bearing(end - inner)
                var best: (angle: Double, index: Int, points: [SIMD2<Double>])?
                for (index, poly) in polys.enumerated() where !used.contains(index) {
                    let first = poly.points[0], last = poly.points[poly.points.count - 1]
                    var oriented: [SIMD2<Double>]?
                    if backward {
                        // Кусок, кончающийся у начала цепи.
                        if length(last - end) <= AppConfig.tripodZoneJoinMeters { oriented = poly.points }
                        else if length(first - end) <= AppConfig.tripodZoneJoinMeters, !poly.line.isOneWay {
                            oriented = poly.points.reversed()
                        }
                    } else {
                        if length(first - end) <= AppConfig.tripodZoneJoinMeters { oriented = poly.points }
                        else if length(last - end) <= AppConfig.tripodZoneJoinMeters, !poly.line.isOneWay {
                            oriented = poly.points.reversed()
                        }
                    }
                    guard let oriented, oriented.count >= 2 else { continue }
                    let joinBearing = backward
                        ? bearing(oriented[oriented.count - 1] - oriented[oriented.count - 2])
                        : bearing(oriented[1] - oriented[0])
                    let angle = GeoMath.angleDifference(joinBearing, heading)
                    guard angle <= AppConfig.tripodZoneMaxAxisDegrees else { continue }
                    if best.map({ angle < $0.angle }) ?? true { best = (angle, index, oriented) }
                }
                guard let best else { return }
                used.insert(best.index)
                chain = backward ? Array(best.points.dropLast()) + chain : chain + best.points.dropFirst()
                if covered(backward: backward) { return }
            }
        }
        func covered(backward: Bool) -> Bool {
            let (along, total) = position(of: .zero, on: chain)
            return backward ? along >= before : total - along >= after
        }
        if !covered(backward: true) { extend(backward: true) }
        if !covered(backward: false) { extend(backward: false) }
        let cumulative = Self.cumulative(chain)
        let (along, total) = position(of: .zero, on: chain)
        let from = max(0, along - before), to = min(total, along + after)
        guard along - from >= minBefore, to > from else { return nil }
        let sliced = slice(chain, cumulative: cumulative, from: from, to: to)
        return Piece(points: sliced.map { flat.point($0) },
                     widthMeters: full ? width : width / 2,
                     offsetMeters: full ? 0 : width / 4,
                     onRoute: false)
    }

    // MARK: - Мягкие концы

    /// Кусок ступенями: сила растёт на `fadeIn` метрах, гаснет на `fadeOut`.
    /// Штриховка движка не берёт градиент, поэтому концы — ступенями.
    static func ramps(_ piece: Piece, fadeIn: Double = AppConfig.tripodZoneFadeInMeters,
                      fadeOut: Double = AppConfig.tripodZoneFadeOutMeters,
                      inSteps: Int = 4, outSteps: Int = 3) -> [Ramp] {
        guard let origin = piece.points.first, piece.points.count >= 2 else { return [] }
        let flat = Flat(origin: origin.coordinate)
        let pts = piece.points.map { flat.xy($0.coordinate) }
        let cumulative = Self.cumulative(pts)
        let total = cumulative[cumulative.count - 1]
        guard total > 0 else { return [] }
        let scale = min(1, total / max(fadeIn + fadeOut, 1))
        let inLength = fadeIn * scale, outLength = fadeOut * scale
        var stops: [(from: Double, to: Double, alpha: Double)] = []
        for k in 0..<inSteps {
            stops.append((inLength * Double(k) / Double(inSteps), inLength * Double(k + 1) / Double(inSteps),
                          Double(k + 1) / Double(inSteps + 1)))
        }
        stops.append((inLength, total - outLength, 1))
        for k in 0..<outSteps {
            let start = total - outLength + outLength * Double(k) / Double(outSteps)
            stops.append((start, start + outLength / Double(outSteps),
                          Double(outSteps - k) / Double(outSteps + 1)))
        }
        return stops.compactMap { stop -> Ramp? in
            guard stop.to - stop.from > 0.01 else { return nil }
            let part = slice(pts, cumulative: cumulative, from: stop.from, to: stop.to)
            return Ramp(points: part.map { flat.point($0) }, alpha: stop.alpha)
        }
    }

    // MARK: - Знак лимита и участок целиком

    /// Знак в начале участка — сбоку от проезжей части, справа по ходу.
    static func limitMark(_ piece: Piece, kmh: Int?,
                          side: Double = AppConfig.tripodZoneLimitSideMeters) -> Limit? {
        guard let kmh, kmh > 0, piece.points.count >= 2 else { return nil }
        let start = piece.points[0].coordinate
        let heading = GeoMath.bearing(from: start, to: piece.points[1].coordinate)
        let point = GeoMath.destination(from: start, bearing: heading + 90,
                                        distanceMeters: piece.widthMeters / 2 + piece.offsetMeters + side)
        return Limit(point: CameraOnLine.Point(latitude: point.latitude, longitude: point.longitude), kmh: kmh)
    }

    /// Курс в начале куска — для лимита дороги там.
    static func startBearing(_ piece: Piece) -> Double? {
        guard piece.points.count >= 2 else { return nil }
        return GeoMath.bearing(from: piece.points[0].coordinate, to: piece.points[1].coordinate)
    }

    /// Участок цели. Лимит — только известный (`limit` → nil — знака нет) и
    /// не у зоны «часто ставят»: это догадка, а не место замера.
    static func band(candidate: Candidate, pieces: [Piece],
                     limit: (CLLocationCoordinate2D, Double) -> Int?) -> Band? {
        guard !pieces.isEmpty else { return nil }
        let limits: [Limit] = candidate.grade == .hotspot ? [] : pieces.compactMap { piece in
            guard let heading = startBearing(piece) else { return nil }
            return limitMark(piece, kmh: limit(piece.points[0].coordinate, heading))
        }
        return Band(key: candidate.key, grade: candidate.grade, pieces: pieces, limits: limits)
    }

    // MARK: - Плоская геометрия

    private struct Flat {
        let origin: CLLocationCoordinate2D
        let metersPerLon: Double

        init(origin: CLLocationCoordinate2D) {
            self.origin = origin
            metersPerLon = 111_320 * cos(origin.latitude * .pi / 180)
        }

        func xy(_ c: CLLocationCoordinate2D) -> SIMD2<Double> {
            SIMD2((c.longitude - origin.longitude) * metersPerLon, (c.latitude - origin.latitude) * 111_320)
        }

        func point(_ v: SIMD2<Double>) -> CameraOnLine.Point {
            CameraOnLine.Point(latitude: origin.latitude + v.y / 111_320,
                               longitude: origin.longitude + v.x / metersPerLon)
        }
    }

    private static func unit(_ degrees: Double) -> SIMD2<Double> {
        SIMD2(sin(degrees * .pi / 180), cos(degrees * .pi / 180))
    }

    private static func dot(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x * b.x + a.y * b.y }
    private static func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x * b.y - a.y * b.x }
    private static func length(_ v: SIMD2<Double>) -> Double { (v.x * v.x + v.y * v.y).squareRoot() }

    private static func bearing(_ v: SIMD2<Double>) -> Double {
        (atan2(v.x, v.y) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    private static func foot(of p: SIMD2<Double>, a: SIMD2<Double>, b: SIMD2<Double>) -> (point: SIMD2<Double>, t: Double) {
        let ab = b - a
        let len2 = dot(ab, ab)
        let t = len2 > 0 ? max(0, min(1, dot(p - a, ab) / len2)) : 0
        return (a + ab * t, t)
    }

    private static func cumulative(_ pts: [SIMD2<Double>]) -> [Double] {
        var out = [0.0]
        for index in 1..<max(pts.count, 1) { out.append(out[index - 1] + length(pts[index] - pts[index - 1])) }
        return out
    }

    /// Место ближайшей к `p` точки цепи и её полная длина.
    private static func position(of p: SIMD2<Double>, on chain: [SIMD2<Double>]) -> (along: Double, total: Double) {
        var walked = 0.0
        var best: (distance: Double, along: Double)?
        for index in 1..<chain.count {
            let a = chain[index - 1], b = chain[index]
            let foot = Self.foot(of: p, a: a, b: b)
            let distance = length(foot.point - p)
            let segment = length(b - a)
            if best.map({ distance < $0.distance }) ?? true { best = (distance, walked + segment * foot.t) }
            walked += segment
        }
        return (best?.along ?? 0, walked)
    }

    private static func slice(_ pts: [SIMD2<Double>], cumulative: [Double],
                              from: Double, to: Double) -> [SIMD2<Double>] {
        func point(at target: Double) -> SIMD2<Double> {
            var index = 1
            while index < cumulative.count - 1, cumulative[index] < target { index += 1 }
            let a = pts[index - 1], b = pts[index]
            let segment = cumulative[index] - cumulative[index - 1]
            let t = segment > 0 ? (target - cumulative[index - 1]) / segment : 0
            return a + (b - a) * t
        }
        var out = [point(at: from)]
        for index in cumulative.indices where cumulative[index] > from && cumulative[index] < to {
            out.append(pts[index])
        }
        out.append(point(at: to))
        return out
    }
}
