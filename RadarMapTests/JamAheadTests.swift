//
//  JamAheadTests.swift
//  RadarMapTests
//
//  «Впереди пробка» без маршрута: только по ходу и в нашем направлении,
//  только настоящая пробка, одна фраза на пробку.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class JamAheadTests: XCTestCase {

    private let car = CLLocationCoordinate2D(latitude: 41.300, longitude: 69.240)

    /// Медленные рёбра по 69.240 от `fromLat` на север (`north`) или на юг,
    /// шагом ~100 м.
    private func stretch(fromLat: Double, count: Int, north: Bool = true, lon: Double = 69.240,
                         kmh: Double = 8, level: Int = 3) -> [TrafficEdge] {
        (0..<count).map { i in
            let a = CLLocationCoordinate2D(latitude: fromLat + Double(i) * 0.0009, longitude: lon)
            let b = CLLocationCoordinate2D(latitude: fromLat + Double(i + 1) * 0.0009, longitude: lon)
            return north ? TrafficEdge(a: a, b: b, level: level, kmh: kmh, modelKmh: 50)
                         : TrafficEdge(a: b, b: a, level: level, kmh: kmh, modelKmh: 50)
        }
    }

    func testJamAheadOnOurRoad() throws {
        let jam = try XCTUnwrap(JamAhead.detect(edges: stretch(fromLat: 41.302, count: 8),
                                                position: car, course: 0))
        XCTAssertEqual(jam.startsIn, 220, accuracy: 60)
        XCTAssertEqual(jam.length, 800, accuracy: 30)
        XCTAssertGreaterThan(jam.delay, 4 * 60, "800 м на 8 км/ч вместо 50 — больше 4 минут")
    }

    func testOncomingJamIsNotOurs() {
        XCTAssertNil(JamAhead.detect(edges: stretch(fromLat: 41.302, count: 8, north: false),
                                     position: car, course: 0))
    }

    func testJamBehindIsSilent() {
        XCTAssertNil(JamAhead.detect(edges: stretch(fromLat: 41.290, count: 8), position: car, course: 0))
    }

    func testParallelStreetIsSilent() {
        // Соседняя улица в ~170 м восточнее.
        XCTAssertNil(JamAhead.detect(edges: stretch(fromLat: 41.302, count: 8, lon: 69.242),
                                     position: car, course: 0))
    }

    func testShortSlowPatchIsNotAJam() {
        XCTAssertNil(JamAhead.detect(edges: stretch(fromLat: 41.302, count: 2), position: car, course: 0))
        XCTAssertNil(JamAhead.detect(edges: stretch(fromLat: 41.302, count: 8, level: 1),
                                     position: car, course: 0), "свободные рёбра — не пробка")
    }

    func testFarJamWaits() {
        // Начало в ~1,3 км: сказать ещё рано.
        XCTAssertNil(JamAhead.detect(edges: stretch(fromLat: 41.3115, count: 2) + stretch(fromLat: 41.313, count: 3),
                                     position: car, course: 0))
    }

    func testNoCourseNoWords() {
        XCTAssertNil(JamAhead.detect(edges: stretch(fromLat: 41.302, count: 8), position: car, course: -1))
    }

    func testOnePhrasePerJam() throws {
        var announcer = JamAhead.Announcer()
        let jam = try XCTUnwrap(JamAhead.detect(edges: stretch(fromLat: 41.302, count: 8), position: car, course: 0))
        let t0 = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(announcer.shouldAnnounce(jam, at: t0))
        XCTAssertFalse(announcer.shouldAnnounce(jam, at: t0 + 60), "только что сказали")
        XCTAssertFalse(announcer.shouldAnnounce(jam, at: t0 + 400), "та же пробка — не раньше 15 минут")
        let other = JamAhead.Jam(startsIn: 300, length: 600, delay: 200,
                                 start: CLLocationCoordinate2D(latitude: 41.330, longitude: 69.240))
        XCTAssertTrue(announcer.shouldAnnounce(other, at: t0 + 400), "другая пробка через 3+ минуты")
    }
}
