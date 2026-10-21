//
//  RouteTrafficTests.swift
//  RadarMapTests
//
//  Пробки на линии маршрута (25.D): красится только наша сторона и только
//  «медленно»/«стоим»; свободное и встречное линию не трогают; мелочь
//  короче порога не мигает пятном.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class RouteTrafficTests: XCTestCase {

    private let base = CLLocationCoordinate2D(latitude: 41.3000, longitude: 69.2800)

    private func north(_ meters: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: base.latitude + meters / 111_320, longitude: base.longitude)
    }

    private func edge(_ from: Double, _ to: Double, level: Int) -> TrafficEdge {
        TrafficEdge(a: north(from), b: north(to), level: level, kmh: level == 3 ? 5 : 20, modelKmh: 60)
    }

    private func snapshot(_ edges: [TrafficEdge]) -> TrafficSnapshot {
        TrafficSnapshot(generated: Date(), edges: edges)
    }

    private let route: [CLLocationCoordinate2D] = [0.0, 400, 1_000].map {
        CLLocationCoordinate2D(latitude: 41.3000 + $0 / 111_320, longitude: 69.2800)
    }

    private func length(_ piece: RouteTraffic.Piece) -> Double {
        zip(piece.coordinates, piece.coordinates.dropFirst()).reduce(0) {
            $0 + GeoMath.fastDistance($1.0.latitude, $1.0.longitude, $1.1.latitude, $1.1.longitude)
        }
    }

    func testJamOnOurSideColoursThatStretch() {
        let pieces = RouteTraffic.pieces(along: route, snapshot: snapshot([edge(200, 600, level: 3)]))
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces.first?.level, 3)
        // Шаг 25 м и радиус совпадения 18 м: границы — с точностью до шага.
        XCTAssertEqual(length(pieces[0]), 400, accuracy: 60)
        let start = pieces[0].coordinates[0]
        XCTAssertEqual((start.latitude - base.latitude) * 111_320, 200, accuracy: 30)
    }

    func testOncomingJamDoesNotColourOurLine() {
        // То же место, обратное направление (встречная сторона проспекта).
        let oncoming = TrafficEdge(a: north(600), b: north(200), level: 3, kmh: 5, modelKmh: 60)
        XCTAssertTrue(RouteTraffic.pieces(along: route, snapshot: snapshot([oncoming])).isEmpty)
    }

    func testFreeFlowLeavesTheRouteBlue() {
        XCTAssertTrue(RouteTraffic.pieces(along: route, snapshot: snapshot([edge(0, 1_000, level: 1)])).isEmpty)
    }

    func testSlowAndJamSplitIntoTwoPieces() {
        let pieces = RouteTraffic.pieces(along: route, snapshot: snapshot([
            edge(100, 400, level: 2), edge(400, 800, level: 3)]))
        XCTAssertEqual(pieces.map(\.level), [2, 3])
        // Куски смыкаются: конец «медленно» — начало «стоим».
        let joint = pieces[0].coordinates.last!, next = pieces[1].coordinates.first!
        XCTAssertEqual(joint.latitude, next.latitude, accuracy: 1e-9)
    }

    func testShortBlipIsDropped() {
        // Ребро в метр совпадает с одним шагом (25 м) — короче порога 40 м.
        XCTAssertTrue(RouteTraffic.pieces(along: route, snapshot: snapshot([edge(312, 313, level: 3)])).isEmpty)
    }

    func testNoDataIsNoPieces() {
        XCTAssertTrue(RouteTraffic.pieces(along: route, snapshot: snapshot([])).isEmpty)
        XCTAssertTrue(RouteTraffic.pieces(along: [base], snapshot: snapshot([edge(0, 100, level: 3)])).isEmpty)
    }
}
