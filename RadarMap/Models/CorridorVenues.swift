//
//  CorridorVenues.swift
//  RadarMap
//
//  «По пути» (19.3): заправки под топливо машины, гостиницы и кафе не
//  дальше `corridorVenueMeters` от линии маршрута впереди — по порядку
//  ВДОЛЬ пути, а не по прямой.
//
//  Почему вдоль. На трассе с петлёй (серпантин Камчика, разворот на
//  развязке, объезд) ближайшая по прямой заправка бывает на обратной ветке
//  через сорок километров пути, а по-настоящему следующая — дальше по
//  прямой. Водителю нужен порядок, в котором заведения встретятся, поэтому
//  каждое проецируется на линию и сортируется по пройденному до проекции.
//
//  Только впереди: проекция ищется на ОСТАВШЕЙСЯ части линии (от прогресса
//  маршрута). Заведение, чья ближайшая точка — то место, где машина сейчас,
//  уже проезжают — в списке его нет.
//
//  Чистое — покрыто CorridorVenuesTests.
//

import CoreLocation
import Foundation
import MapKit

nonisolated enum CorridorVenues {

    struct Item: Identifiable, Equatable, Sendable {
        let venue: Venue
        /// Метры от старта маршрута до точки линии, ближайшей к заведению.
        let along: CLLocationDistance
        /// Метры от линии маршрута до заведения.
        let offset: CLLocationDistance

        var id: String { venue.id }

        /// Сколько ехать до заведения от прогресса `progress`.
        func ahead(of progress: CLLocationDistance) -> CLLocationDistance { along - progress }
    }

    /// Группы списка — чипы над ним.
    enum Group: String, CaseIterable, Sendable {
        case fuel, hotel, food
    }

    static func group(of kind: Venue.Kind) -> Group? {
        switch kind {
        case .fuel, .cng, .lpg, .charging: return .fuel
        case .hotel: return .hotel
        case .food: return .food
        default: return nil
        }
    }

    /// Виды «По пути» для машины: её топливо по порядку (`VehicleEnergy.stops`),
    /// потом гостиницы и кафе. Бензиновой машине метан и зарядки — шум.
    static func kinds(fuel: [Venue.Kind]) -> [Venue.Kind] {
        var out: [Venue.Kind] = []
        for kind in fuel + [.hotel, .food] where !out.contains(kind) { out.append(kind) }
        return out
    }

    // MARK: - Поиск

    /// Заведения `kinds` не дальше `corridor` от линии впереди `progress`,
    /// по порядку вдоль пути, без дублей одного вида ближе `dedup`.
    static func find(_ venues: [Venue], route: [MKMapPoint], progress: CLLocationDistance,
                     kinds: Set<Venue.Kind>,
                     corridor: CLLocationDistance = AppConfig.corridorVenueMeters,
                     minAhead: CLLocationDistance = AppConfig.corridorVenueAheadMeters,
                     dedup: CLLocationDistance = AppConfig.corridorVenueDedupMeters,
                     limit: Int = AppConfig.corridorVenueLimit) -> [Item] {
        guard let line = Line(route, from: progress, corridor: corridor) else { return [] }
        var items: [Item] = []
        for venue in venues where kinds.contains(venue.kind) {
            guard let hit = line.project(MKMapPoint(venue.point)),
                  hit.offset <= corridor, hit.along - progress >= minAhead else { continue }
            items.append(Item(venue: venue, along: hit.along, offset: hit.offset))
        }
        items.sort { ($0.along, $0.offset) < ($1.along, $1.offset) }
        return Array(deduplicated(items, meters: dedup).prefix(limit))
    }

    /// Дубли одного вида ближе `meters` — одно заведение. Остаётся первое по
    /// ходу; безымянное уступает имени («АЗС» хуже «Mustang» о той же
    /// колонке). Порядок не меняется.
    static func deduplicated(_ items: [Item], meters: CLLocationDistance) -> [Item] {
        guard meters > 0 else { return items }
        // Сетка ~`meters`: сосед ищется в своей клетке и восьми вокруг.
        let latStep = meters / 111_320
        func cell(_ p: CLLocationCoordinate2D) -> (Int, Int) {
            let lonStep = latStep / max(0.01, cos(p.latitude * .pi / 180))
            return (Int(floor(p.latitude / latStep)), Int(floor(p.longitude / lonStep)))
        }
        struct Key: Hashable { let kind: Int; let row: Int; let column: Int }
        var kept: [Item] = []
        var grid: [Key: [Int]] = [:]
        for item in items {
            let p = item.venue.point
            let (row, column) = cell(p)
            var twin: Int?
            search: for dr in -1...1 {
                for dc in -1...1 {
                    for index in grid[Key(kind: item.venue.kind.rawValue, row: row + dr, column: column + dc)] ?? [] {
                        let q = kept[index].venue.point
                        if GeoMath.fastDistance(p.latitude, p.longitude, q.latitude, q.longitude) <= meters {
                            twin = index
                            break search
                        }
                    }
                }
            }
            if let twin {
                if kept[twin].venue.name.isEmpty, !item.venue.name.isEmpty {
                    kept[twin] = Item(venue: item.venue, along: kept[twin].along, offset: kept[twin].offset)
                }
                continue
            }
            grid[Key(kind: item.venue.kind.rawValue, row: row, column: column), default: []].append(kept.count)
            kept.append(item)
        }
        return kept
    }

    // MARK: - Линия впереди

    /// Оставшаяся часть маршрута с сеткой отрезков: проекция точки смотрит
    /// только отрезки своей клетки и восьми соседних, а не всю линию. На
    /// 600 км это тысячи отрезков и тысячи заведений — перебор всех пар был
    /// бы десятками миллионов операций.
    struct Line {
        let points: [MKMapPoint]
        /// cum[i] — метры от старта маршрута до точки i.
        let cum: [CLLocationDistance]
        /// Первый отрезок впереди и доля, с которой он начинается (машина на нём).
        let firstSegment: Int
        let firstT: Double
        let cellSize: Double
        let grid: [Int64: [Int]]
        /// Рамка оставшейся линии с полосой — быстрый отсев заведений.
        let bounds: MKMapRect

        init?(_ points: [MKMapPoint], from progress: CLLocationDistance, corridor: CLLocationDistance) {
            let n = points.count
            guard n >= 2 else { return nil }
            var cum = [CLLocationDistance](repeating: 0, count: n)
            for i in 1..<n { cum[i] = cum[i - 1] + points[i - 1].distance(to: points[i]) }
            guard progress < cum[n - 1] else { return nil }
            // Отрезок, на котором прогресс: последний i с cum[i] <= progress.
            var first = 0
            while first + 1 < n - 1, cum[first + 1] <= progress { first += 1 }
            let span = cum[first + 1] - cum[first]
            firstT = span > 0 ? min(1, max(0, (progress - cum[first]) / span)) : 0
            firstSegment = first
            self.points = points
            self.cum = cum

            // Клетка не меньше полосы на самой северной точке: на север
            // метр — больше точек карты, и полоса в метрах обязана
            // помещаться в клетку везде, иначе сосед за клеткой потеряется.
            let north = points[first...].map(\.coordinate.latitude).max() ?? 0
            let size = max(1, corridor * MKMapPointsPerMeterAtLatitude(north))
            cellSize = size
            var grid: [Int64: [Int]] = [:]
            var rect = MKMapRect.null
            for i in first..<(n - 1) {
                let a = points[i], b = points[i + 1]
                let x0 = Int64(floor(min(a.x, b.x) / size)), x1 = Int64(floor(max(a.x, b.x) / size))
                let y0 = Int64(floor(min(a.y, b.y) / size)), y1 = Int64(floor(max(a.y, b.y) / size))
                for y in y0...y1 {
                    for x in x0...x1 { grid[Self.key(x, y), default: []].append(i) }
                }
                rect = rect.union(MKMapRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                            width: abs(a.x - b.x), height: abs(a.y - b.y)))
            }
            self.grid = grid
            bounds = rect.insetBy(dx: -size, dy: -size)
        }

        private static func key(_ x: Int64, _ y: Int64) -> Int64 { (y << 32) ^ (x & 0xFFFF_FFFF) }

        /// Ближайшая точка оставшейся линии: (метры от старта до неё, метры
        /// до линии). nil — далеко от линии (за полосой сетки).
        func project(_ p: MKMapPoint) -> (along: CLLocationDistance, offset: CLLocationDistance)? {
            guard bounds.contains(p) else { return nil }
            let cx = Int64(floor(p.x / cellSize)), cy = Int64(floor(p.y / cellSize))
            var best: (along: CLLocationDistance, offset: CLLocationDistance)?
            var seen = Set<Int>()
            for dy in -1...1 {
                for dx in -1...1 {
                    for i in grid[Self.key(cx + Int64(dx), cy + Int64(dy))] ?? [] where seen.insert(i).inserted {
                        let a = points[i], b = points[i + 1]
                        let low = i == firstSegment ? firstT : 0
                        let (q, t) = Self.closest(p, a, b, from: low)
                        let offset = p.distance(to: q)
                        let along = cum[i] + t * (cum[i + 1] - cum[i])
                        // Равные расстояния — раньше по ходу: петля проходит
                        // мимо дважды, и встреча — первая.
                        if best == nil || offset < best!.offset
                            || (offset == best!.offset && along < best!.along) {
                            best = (along, offset)
                        }
                    }
                }
            }
            return best
        }

        /// Ближайшая точка отрезка AB к P при t ∈ [low, 1].
        private static func closest(_ p: MKMapPoint, _ a: MKMapPoint, _ b: MKMapPoint,
                                    from low: Double) -> (MKMapPoint, Double) {
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            let raw = len2 == 0 ? 0 : ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
            let t = max(low, min(1, raw))
            return (MKMapPoint(x: a.x + t * dx, y: a.y + t * dy), t)
        }
    }
}
