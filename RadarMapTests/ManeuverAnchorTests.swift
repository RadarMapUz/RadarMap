//
//  ManeuverAnchorTests.swift
//  RadarMapTests
//
//  Позиция манёвра — по вершине линии, а не по сумме длин шагов (76): на
//  трассе сумма уходит от линии, и манёвр звучал не там. Не нашли вершину —
//  прежняя сумма с поправкой, без шага назад; петля через один узел не
//  привязывает манёвр к чужому проходу.
//

import MapKit
import XCTest
@testable import RadarMap

final class ManeuverAnchorTests: XCTestCase {

    /// Прямая на север, вершины каждые ~100 м.
    private func line(_ count: Int) -> [CLLocationCoordinate2D] {
        (0..<count).map { CLLocationCoordinate2D(latitude: 41.0 + Double($0) * 0.0009, longitude: 69.0) }
    }

    private func cumulative(_ path: [CLLocationCoordinate2D]) -> [CLLocationDistance] {
        RouteService.cumulative(of: path.map(MKMapPoint.init))
    }

    private func location(_ point: CLLocationCoordinate2D) -> [Double] { [point.longitude, point.latitude] }

    func testManeuverSitsOnItsVertexWhenStepLengthsDrift() {
        let path = line(1001)                     // ~100 км
        let cum = cumulative(path)
        let vertices = [0, 400, 900, 1000]
        // Длины шагов OSRM на 0,4 % длиннее линии: к концу — сотни метров.
        let distances = zip(vertices, vertices.dropFirst()).map { (cum[$1] - cum[$0]) * 1.004 } + [0]
        let found = ManeuverAnchor.positions(locations: vertices.map { location(path[$0]) },
                                             distances: distances, path: path, cumulative: cum)
        XCTAssertEqual(found.map(\.vertex), vertices)
        for (position, vertex) in zip(found, vertices) {
            XCTAssertEqual(position.along, cum[vertex], accuracy: 0.001)
        }
        let bySum = distances.dropLast().reduce(0, +)
        XCTAssertGreaterThan(bySum - cum[1000], 300, "сумма длин ушла от линии — её и чиним")
    }

    func testMissingVertexFallsBackToSumWithDriftAndNeverGoesBack() {
        let path = line(101)
        let cum = cumulative(path)
        let distances = [cum[40] * 1.01, cum[70] - cum[40], cum[100] - cum[70], 0]
        let locations: [[Double]?] = [location(path[0]), location(path[40]), [0, 0], nil]
        let found = ManeuverAnchor.positions(locations: locations, distances: distances, path: path, cumulative: cum)
        XCTAssertEqual(found[1].vertex, 40)
        XCTAssertNil(found[2].vertex)
        // Поправка от найденной вершины 40 переносится на ненайденный шаг.
        XCTAssertEqual(found[2].along, cum[70], accuracy: 0.001)
        XCTAssertNil(found[3].vertex)
        XCTAssertEqual(found[3].along, cum[100], accuracy: 0.001)
        XCTAssertEqual(found.map(\.along), found.map(\.along).sorted(), "позиции не убывают")
    }

    func testLoopThroughTheSameNodeTakesItsOwnPass() {
        // Туда 3 км, обратно теми же вершинами: узел 10 пройден дважды.
        let out = line(31)
        let path = out + out.dropLast().reversed()
        let cum = cumulative(path)
        let second = path.count - 1 - 10
        let distances = [cum[second], cum[path.count - 1] - cum[second], 0]
        let locations = [location(path[0]), location(path[second]), location(path[path.count - 1])]
        let found = ManeuverAnchor.positions(locations: locations, distances: distances, path: path, cumulative: cum)
        XCTAssertEqual(found[1].vertex, second, "манёвр на обратном проходе, а не на первом")
        XCTAssertEqual(found[1].along, cum[second], accuracy: 0.001)
    }

    func testBrokenInputKeepsThePlainSum() {
        let found = ManeuverAnchor.positions(locations: [nil, nil], distances: [500, 300], path: [], cumulative: [])
        XCTAssertEqual(found.map(\.along), [0, 500])
    }
}
