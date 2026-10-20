//
//  OfflineRouteGraph.swift
//  RadarMap
//
//  Маршрут без сети (план 19.10, 12б.10). На трассе Ташкент — Бухара связь
//  пропадает на часы, а без ответа OSRM приложение оставалось без маршрута
//  вовсе. Этап 1 — междугородние дороги (trunk/primary/secondary) одним
//  подписанным файлом в формате дорожных тайлов (server/build_route_graph.py):
//  узлы графа — общие точки линий (одинаковые координаты 1e-5), рёбра — их
//  соседние точки. A* по времени: длина / типичная скорость класса.
//
//  Запретов поворотов в файле нет, поэтому маршрут честно подписан
//  «маршрут без сети, приблизительно», а когда сеть вернётся — его молча
//  заменяет серверный (RouteService).
//
//  Чистая логика — OfflineRouteGraphTests.
//

import Foundation
import CoreLocation

nonisolated struct OfflineRouteGraph: Sendable {
    /// Координаты узлов, в 1e-5°.
    let lat: [Int32]
    let lon: [Int32]
    /// Смежность: для узла — рёбра (куда, длина м, секунды).
    let edges: [[Edge]]
    /// Сеточный индекс 0.05° → узлы с рёбрами (входящими или исходящими) —
    /// для «ближайшего узла» без перебора. Конец односторонней — тоже узел,
    /// хоть из него и некуда ехать: в него приезжают.
    let grid: [Int: [Int32]]

    struct Edge: Sendable {
        let to: Int32
        let meters: Float
        let seconds: Float
    }

    struct Path: Sendable {
        let points: [CLLocationCoordinate2D]
        let distance: CLLocationDistance
        let travelTime: TimeInterval
    }

    var nodeCount: Int { lat.count }

    /// Типичная скорость класса на трассе, км/ч — для веса ребра. Не лимит
    /// и не обещание: порядок «трасса быстрее второстепенной».
    static func speedKmh(_ kind: RoadClass) -> Double {
        switch kind {
        case .motorway: return 90
        case .trunk: return 80
        case .primary: return 65
        case .secondary: return 50
        default: return 40
        }
    }

    static func cellKey(lat: Double, lon: Double) -> Int {
        Int(floor((lat + 90) / 0.05)) * 10_000 + Int(floor((lon + 180) / 0.05))
    }

    /// Граф из линий формата тайлов: соседние точки — ребро, одинаковые
    /// точки разных линий — один узел. Одностороннее — только по ходу линии.
    static func build(_ lines: [RoadLine]) -> OfflineRouteGraph {
        var index: [Int64: Int32] = [:]
        var lat: [Int32] = [], lon: [Int32] = []
        var edges: [[Edge]] = []
        func node(_ point: CLLocationCoordinate2D) -> Int32 {
            let la = Int32((point.latitude * 100_000).rounded()), lo = Int32((point.longitude * 100_000).rounded())
            let key = Int64(la) << 32 | Int64(UInt32(bitPattern: lo))
            if let id = index[key] { return id }
            let id = Int32(lat.count)
            index[key] = id
            lat.append(la); lon.append(lo); edges.append([])
            return id
        }
        for line in lines where line.points.count >= 2 {
            let speed = speedKmh(line.kind) / 3.6
            var previous = node(line.points[0])
            var previousPoint = line.points[0]
            for point in line.points.dropFirst() {
                let current = node(point)
                guard current != previous else { continue }
                let meters = GeoMath.fastDistance(previousPoint.latitude, previousPoint.longitude,
                                                  point.latitude, point.longitude)
                let edge = Edge(to: current, meters: Float(meters), seconds: Float(meters / speed))
                edges[Int(previous)].append(edge)
                // Кольцо в OSM одностороннее по ходу точек, хотя рисуем мы его
                // без шевронов (isOneWay у кольца снят ради картинки).
                if !(line.isOneWay || line.isRing) {
                    edges[Int(current)].append(Edge(to: previous, meters: edge.meters, seconds: edge.seconds))
                }
                previous = current
                previousPoint = point
            }
        }
        var connected = edges.map { !$0.isEmpty }
        for list in edges { for edge in list { connected[Int(edge.to)] = true } }
        var grid: [Int: [Int32]] = [:]
        for id in lat.indices where connected[id] {
            grid[cellKey(lat: Double(lat[id]) / 100_000, lon: Double(lon[id]) / 100_000), default: []]
                .append(Int32(id))
        }
        return OfflineRouteGraph(lat: lat, lon: lon, edges: edges, grid: grid)
    }

    func coordinate(_ id: Int32) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: Double(lat[Int(id)]) / 100_000, longitude: Double(lon[Int(id)]) / 100_000)
    }

    /// Ближайший узел с рёбрами не дальше `maxMeters` (по 3×3 клеткам сетки).
    func nearestNode(to point: CLLocationCoordinate2D, maxMeters: Double) -> Int32? {
        let row = Int(floor((point.latitude + 90) / 0.05)), column = Int(floor((point.longitude + 180) / 0.05))
        var best: (id: Int32, meters: Double)?
        for dr in -1...1 {
            for dc in -1...1 {
                for id in grid[(row + dr) * 10_000 + column + dc] ?? [] {
                    let c = coordinate(id)
                    let meters = GeoMath.fastDistance(point.latitude, point.longitude, c.latitude, c.longitude)
                    if meters <= maxMeters, best == nil || meters < best!.meters { best = (id, meters) }
                }
            }
        }
        return best?.id
    }

    /// A* по времени. Эвристика — прямая со скоростью трассы: никогда не
    /// переоценивает, поэтому путь — кратчайший по весам графа.
    func route(from start: Int32, to goal: Int32) -> Path? {
        guard Int(start) < nodeCount, Int(goal) < nodeCount else { return nil }
        if start == goal { return Path(points: [coordinate(start)], distance: 0, travelTime: 0) }
        let goalPoint = coordinate(goal)
        let fastest = Self.speedKmh(.motorway) / 3.6
        func heuristic(_ id: Int32) -> Double {
            let c = coordinate(id)
            return GeoMath.fastDistance(c.latitude, c.longitude, goalPoint.latitude, goalPoint.longitude) / fastest
        }
        var cost: [Int32: Double] = [start: 0]
        var meters: [Int32: Double] = [start: 0]
        var parent: [Int32: Int32] = [:]
        var heap = MinHeap()
        heap.push(heuristic(start), start)
        var closed = Set<Int32>()
        while let (_, current) = heap.pop() {
            if current == goal { break }
            guard closed.insert(current).inserted else { continue }
            let base = cost[current] ?? .infinity
            for edge in edges[Int(current)] where !closed.contains(edge.to) {
                let next = base + Double(edge.seconds)
                if next < cost[edge.to] ?? .infinity {
                    cost[edge.to] = next
                    meters[edge.to] = (meters[current] ?? 0) + Double(edge.meters)
                    parent[edge.to] = current
                    heap.push(next + heuristic(edge.to), edge.to)
                }
            }
        }
        guard let total = cost[goal] else { return nil }
        var ids: [Int32] = [goal]
        while let previous = parent[ids[ids.count - 1]] { ids.append(previous) }
        return Path(points: ids.reversed().map(coordinate), distance: meters[goal] ?? 0, travelTime: total)
    }

    /// Маршрут между точками: обе — к ближайшему узлу трассы. nil — точки
    /// дальше `snapMeters` от графа (в городе без офлайн-улиц) или пути нет.
    func route(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D,
               snapMeters: Double = AppConfig.offlineRouteSnapMeters) -> Path? {
        guard let start = nearestNode(to: from, maxMeters: snapMeters),
              let goal = nearestNode(to: to, maxMeters: snapMeters),
              let path = route(from: start, to: goal) else { return nil }
        // Подъезд к графу и от него — прямыми: честнее, чем делать вид, что
        // знаем улицы города.
        let head = GeoMath.fastDistance(from.latitude, from.longitude,
                                        path.points[0].latitude, path.points[0].longitude)
        let tail = GeoMath.fastDistance(to.latitude, to.longitude,
                                        path.points[path.points.count - 1].latitude,
                                        path.points[path.points.count - 1].longitude)
        let slow = Self.speedKmh(.unknown) / 3.6
        return Path(points: [from] + path.points + [to],
                    distance: path.distance + head + tail,
                    travelTime: path.travelTime + (head + tail) / slow)
    }
}

/// Двоичная куча по приоритету — для A*.
private nonisolated struct MinHeap {
    private var items: [(Double, Int32)] = []

    mutating func push(_ priority: Double, _ value: Int32) {
        items.append((priority, value))
        var child = items.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard items[child].0 < items[parent].0 else { break }
            items.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> (Double, Int32)? {
        guard !items.isEmpty else { return nil }
        items.swapAt(0, items.count - 1)
        let top = items.removeLast()
        var parent = 0
        while true {
            let left = 2 * parent + 1, right = left + 1
            var smallest = parent
            if left < items.count, items[left].0 < items[smallest].0 { smallest = left }
            if right < items.count, items[right].0 < items[smallest].0 { smallest = right }
            guard smallest != parent else { break }
            items.swapAt(parent, smallest)
            parent = smallest
        }
        return top
    }
}
