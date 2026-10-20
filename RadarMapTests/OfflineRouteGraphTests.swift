//
//  OfflineRouteGraphTests.swift
//  RadarMapTests
//
//  Маршрут без сети (12б.10): A* на синтетическом графе — кратчайший по
//  времени, однонаправленные и кольца только по ходу, точка далеко от трасс
//  — маршрута нет, индекс графа без подписи/с чужим размером не принимается.
//

import XCTest
import CoreLocation
@testable import RadarMap

final class OfflineRouteGraphTests: XCTestCase {
    private func p(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private func line(_ points: [CLLocationCoordinate2D], _ kind: RoadClass = .primary,
                      oneWay: Bool = false, ring: Bool = false) -> RoadLine {
        RoadLine(points: points, kind: kind, isOneWay: oneWay, isDetailed: true, isRing: ring)
    }

    /// Квадрат 0.1° (~11 км): короткий путь по второстепенной A→B→D, длинный
    /// по трассе A→C→D быстрее.
    func testFastestByTimeNotByLength() throws {
        let a = p(41.0, 69.0), b = p(41.1, 69.0), c = p(41.0, 69.15), d = p(41.1, 69.1)
        let graph = OfflineRouteGraph.build([
            line([a, b], .secondary), line([b, d], .secondary),
            line([a, c], .motorway), line([c, d], .motorway),
        ])
        let path = try XCTUnwrap(graph.route(from: a, to: d, snapMeters: 100))
        XCTAssertTrue(path.points.contains { abs($0.longitude - 69.15) < 1e-6 }, "по трассе через C")
        XCTAssertGreaterThan(path.distance, 18_000)
    }

    func testOneWayAndRingFollowPointOrder() {
        let a = p(41.0, 69.0), b = p(41.05, 69.0)
        let oneway = OfflineRouteGraph.build([line([a, b], oneWay: true)])
        XCTAssertNotNil(oneway.route(from: a, to: b, snapMeters: 100))
        XCTAssertNil(oneway.route(from: b, to: a, snapMeters: 100), "против одностороннего — нет пути")
        let ring = OfflineRouteGraph.build([line([a, b], ring: true)])
        XCTAssertNil(ring.route(from: b, to: a, snapMeters: 100), "кольцо — по ходу точек, хоть шевронов и нет")
    }

    func testSharedPointsJoinWays() {
        let a = p(41.0, 69.0), j = p(41.02, 69.02), b = p(41.04, 69.0)
        let graph = OfflineRouteGraph.build([line([a, j]), line([j, b])])
        XCTAssertNotNil(graph.route(from: a, to: b, snapMeters: 100), "общая точка — узел, линии связаны")
        let apart = OfflineRouteGraph.build([line([a, j]), line([p(41.02001, 69.02), b])])
        XCTAssertNil(apart.route(from: a, to: b, snapMeters: 100), "разные точки — разные узлы")
    }

    func testFarFromHighwaysIsNoRoute() {
        let graph = OfflineRouteGraph.build([line([p(41.0, 69.0), p(41.1, 69.0)])])
        XCTAssertNil(graph.route(from: p(41.0, 69.2), to: p(41.1, 69.0)),
                     "17 км от трассы — без улиц города маршрут был бы враньём")
        let near = graph.route(from: p(41.001, 69.001), to: p(41.099, 69.0))
        XCTAssertEqual(near?.points.first?.latitude, 41.001, "подъезд к графу — от самой точки")
    }

    func testManifestRules() throws {
        func manifest(_ json: String) throws -> RouteGraphManifest {
            try JSONDecoder().decode(RouteGraphManifest.self, from: Data(json.utf8))
        }
        let good = try manifest(#"{"format":1,"version":3,"files":[{"format":1,"name":"route_graph.abcdef0123456789.json","sha256":"\#(String(repeating: "a", count: 64))","bytes":3000000}]}"#)
        XCTAssertNotNil(good.usableFile)
        let huge = try manifest(#"{"format":1,"version":3,"files":[{"format":1,"name":"route_graph.x.json","sha256":"\#(String(repeating: "a", count: 64))","bytes":99000000}]}"#)
        XCTAssertNil(huge.usableFile, "размер вне потолка — не верить")
        let path = try manifest(#"{"format":1,"version":3,"files":[{"format":1,"name":"../etc/passwd","sha256":"\#(String(repeating: "a", count: 64))","bytes":100}]}"#)
        XCTAssertNil(path.usableFile, "имя с путём — не верить")
    }

    /// Порядок величины: граф страны — сотни тысяч узлов. Сетка 200×200
    /// (40 000 узлов) строится и проходится из угла в угол за доли секунды
    /// даже в отладочной сборке — маршрут без сети не повиснет на минуту.
    func testRealisticSizeIsFast() throws {
        let n = 200, step = 0.002
        var lines: [RoadLine] = []
        for row in 0..<n {
            lines.append(line((0..<n).map { p(41.0 + Double(row) * step, 69.0 + Double($0) * step) }, .secondary))
        }
        for column in 0..<n {
            lines.append(line((0..<n).map { p(41.0 + Double($0) * step, 69.0 + Double(column) * step) }, .secondary))
        }
        let started = Date()
        let graph = OfflineRouteGraph.build(lines)
        let path = try XCTUnwrap(graph.route(from: p(41.0, 69.0), to: p(41.0 + Double(n - 1) * step, 69.0 + Double(n - 1) * step)))
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(graph.nodeCount, n * n)
        XCTAssertGreaterThan(path.points.count, n)
        XCTAssertLessThan(elapsed, 3.0, "сборка и A* на 40 000 узлов: \(elapsed) с")
    }
}
