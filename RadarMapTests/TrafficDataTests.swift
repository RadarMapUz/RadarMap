//
//  TrafficDataTests.swift
//  RadarMapTests
//
//  Пробки с сервера и время маршрута. Главное: пробка на встречной полосе
//  проспекта нашу дорогу не удлиняет, свободные рёбра ETA не трогают, а
//  файл другой версии или протухший — это «данных нет», а не догадка.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class TrafficDataTests: XCTestCase {

    private let base = CLLocationCoordinate2D(latitude: 41.3000, longitude: 69.2800)

    /// Точка в `meters` севернее базы.
    private func north(_ meters: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: base.latitude + meters / 111_320, longitude: base.longitude)
    }

    private func edge(from: Double, to: Double, level: Int, kmh: Double, model: Double = 60) -> TrafficEdge {
        TrafficEdge(a: north(from), b: north(to), level: level, kmh: kmh, modelKmh: model)
    }

    func testDecodesVersionOne() throws {
        let json = #"{"v":1,"generated":1760000000,"edges":[[41.3,69.28,41.301,69.28,3,8,60],[1,2,3,4,9,1,1]]}"#
        let snapshot = try XCTUnwrap(TrafficSnapshot.decode(Data(json.utf8)))
        XCTAssertEqual(snapshot.edges.count, 1, "битое ребро (уровень 9) пропускается")
        XCTAssertEqual(snapshot.edges.first?.level, 3)
        XCTAssertEqual(snapshot.generated, Date(timeIntervalSince1970: 1_760_000_000))
    }

    /// now.json — всегда «сейчас» (33H): лишняя колонка не делает ребро
    /// «обычным» — модель приходит только profile.json и в голос не идёт.
    func testExtraColumnsKeepTheEdgeLive() throws {
        let json = #"{"v":1,"generated":1760000000,"edges":[[41.3,69.28,41.301,69.28,3,8,60],"#
            + #"[41.3,69.28,41.302,69.28,1,50,60,1],[41.3,69.28,41.303,69.28,2,30,60,0],"#
            + #"[41.3,69.28,41.304,69.28,2,30,60,7]]}"#
        let snapshot = try XCTUnwrap(TrafficSnapshot.decode(Data(json.utf8)))
        XCTAssertEqual(snapshot.edges.count, 4)
        XCTAssertTrue(snapshot.edges.allSatisfy { $0.source == .live })
    }

    func testOtherVersionIsNoData() {
        XCTAssertNil(TrafficSnapshot.decode(Data(#"{"v":2,"generated":1,"edges":[]}"#.utf8)))
        XCTAssertNil(TrafficSnapshot.decode(Data("not json".utf8)))
    }

    func testStaleFileIsNoData() {
        let snapshot = TrafficSnapshot(generated: Date(timeIntervalSince1970: 1_000), edges: [])
        XCTAssertTrue(snapshot.isFresh(now: Date(timeIntervalSince1970: 1_000 + 60)))
        XCTAssertFalse(snapshot.isFresh(now: Date(timeIntervalSince1970: 1_000 + AppConfig.trafficStaleSeconds + 1)))
    }

    /// Километр пробки 10 км/ч при свободных 60: 360 − 60 = 300 с.
    func testJamAddsItsTime() {
        let snapshot = TrafficSnapshot(generated: .now, edges: [edge(from: 0, to: 1000, level: 3, kmh: 10)])
        let delay = snapshot.delay(along: [north(0), north(1000)])
        XCTAssertEqual(delay, 300, accuracy: 10)
    }

    func testOncomingJamDoesNotSlowUs() {
        // Пробка едет на юг (встречная), мы — на север.
        let snapshot = TrafficSnapshot(generated: .now, edges: [edge(from: 1000, to: 0, level: 3, kmh: 10)])
        XCTAssertEqual(snapshot.delay(along: [north(0), north(1000)]), 0)
    }

    func testFreeFlowDoesNotTouchETA() {
        let snapshot = TrafficSnapshot(generated: .now, edges: [edge(from: 0, to: 1000, level: 1, kmh: 80)])
        XCTAssertEqual(snapshot.delay(along: [north(0), north(1000)]), 0)
    }

    func testParallelStreetDoesNotMatch() {
        // Улица в 60 м восточнее — не наша.
        let east = 60 / (111_320 * cos(base.latitude * .pi / 180))
        let side = TrafficEdge(a: CLLocationCoordinate2D(latitude: base.latitude, longitude: base.longitude + east),
                               b: CLLocationCoordinate2D(latitude: north(1000).latitude, longitude: base.longitude + east),
                               level: 3, kmh: 5, modelKmh: 60)
        let snapshot = TrafficSnapshot(generated: .now, edges: [side])
        XCTAssertEqual(snapshot.delay(along: [north(0), north(1000)]), 0)
    }

    func testPartialOverlapCountsOnlyItsPart() {
        let snapshot = TrafficSnapshot(generated: .now, edges: [edge(from: 500, to: 1000, level: 2, kmh: 20)])
        // 500 м по 20 вместо 60: 90 − 30 = 60 с.
        XCTAssertEqual(snapshot.delay(along: [north(0), north(1000)]), 60, accuracy: 8)
    }

    func testPointToSegmentDistance() {
        let d = TrafficSnapshot.distance(north(500), toSegment: north(0), north(1000))
        XCTAssertEqual(d, 0, accuracy: 0.5)
        let beyond = TrafficSnapshot.distance(north(1100), toSegment: north(0), north(1000))
        XCTAssertEqual(beyond, 100, accuracy: 1)
    }
}
