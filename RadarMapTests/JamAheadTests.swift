//
//  JamAheadTests.swift
//  RadarMapTests
//
//  «Впереди пробка» без маршрута: только по связной цепочке от своего ребра
//  и в нашем направлении, только настоящая пробка, одна фраза на пробку.
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

    /// Свободная дорога под машиной: 41.2993 → 41.302, дальше — что приложат.
    private var approach: [TrafficEdge] { stretch(fromLat: 41.2993, count: 3, kmh: 48, level: 1) }

    private func detect(_ edges: [TrafficEdge], course: Double = 0) -> JamAhead.Jam? {
        JamAhead.detect(in: TrafficSnapshot(generated: Date(timeIntervalSince1970: 0), edges: edges),
                        position: car, course: course)
    }

    /// Рёбра по точкам ломаной.
    private func chain(_ points: [CLLocationCoordinate2D], kmh: Double = 8, level: Int = 3) -> [TrafficEdge] {
        zip(points, points.dropFirst()).map { TrafficEdge(a: $0, b: $1, level: level, kmh: kmh, modelKmh: 50) }
    }

    func testJamAheadOnOurRoad() throws {
        let jam = try XCTUnwrap(detect(approach + stretch(fromLat: 41.302, count: 8)))
        XCTAssertEqual(jam.startsIn, 220, accuracy: 30)
        XCTAssertEqual(jam.length, 800, accuracy: 30)
        XCTAssertGreaterThan(jam.delay, 4 * 60, "800 м на 8 км/ч вместо 50 — больше 4 минут")
    }

    func testStandingInTheJamCountsWhatIsLeft() throws {
        let jam = try XCTUnwrap(detect(stretch(fromLat: 41.2993, count: 8)))
        XCTAssertEqual(jam.startsIn, 0)
        XCTAssertEqual(jam.length, 720, accuracy: 30)
    }

    func testOncomingJamIsNotOurs() {
        XCTAssertNil(detect(approach + stretch(fromLat: 41.302, count: 8, north: false)))
        XCTAssertNil(detect(stretch(fromLat: 41.2993, count: 11, north: false)), "под машиной только встречное ребро")
        // Из конца своего ребра выходит только встречное (разворот) — оно стоит, но не наше.
        XCTAssertNil(detect(approach + stretch(fromLat: 41.2993, count: 11, north: false)))
    }

    func testJamBehindIsSilent() {
        XCTAssertNil(detect(stretch(fromLat: 41.290, count: 8) + stretch(fromLat: 41.2972, count: 6, kmh: 48, level: 1)))
    }

    func testNoOwnEdgeNoWords() {
        XCTAssertNil(detect(stretch(fromLat: 41.302, count: 8)), "под машиной никто не мерил")
        // Соседняя улица в ~170 м восточнее.
        XCTAssertNil(detect(stretch(fromLat: 41.2993, count: 11, lon: 69.242)))
    }

    func testFrontageRoadIsNotAddedToTheAvenue() throws {
        // Дублёр в ~25 м восточнее стоит на 800 м, проспект — на 400.
        let avenue = approach + stretch(fromLat: 41.302, count: 4)
        let frontage = stretch(fromLat: 41.2993, count: 3, lon: 69.2403, kmh: 48, level: 1)
            + stretch(fromLat: 41.302, count: 8, lon: 69.2403)
        let jam = try XCTUnwrap(detect(avenue + frontage))
        XCTAssertEqual(jam.length, 400, accuracy: 20)
        XCTAssertNil(detect(approach + stretch(fromLat: 41.302, count: 3, kmh: 48, level: 1) + frontage),
                     "проспект свободен — пробка дублёра не наша")
    }

    func testJamBeyondTheBendIsFound() throws {
        // 200 м на север, поворот дугой на восток и 600 м пробки уже на восток.
        var points = [CLLocationCoordinate2D(latitude: 41.2993, longitude: 69.240)]
        for heading in [0.0, 0, 20, 45, 70, 90, 90, 90, 90, 90, 90] {
            points.append(GeoMath.destination(from: points[points.count - 1], bearing: heading, distanceMeters: 100))
        }
        let edges = chain(Array(points.prefix(6)), kmh: 48, level: 1) + chain(Array(points.suffix(7)))
        let jam = try XCTUnwrap(detect(edges))
        XCTAssertEqual(jam.length, 600, accuracy: 20)
        XCTAssertEqual(jam.startsIn, 420, accuracy: 40)
    }

    func testForkFollowsTheStraightRoad() {
        // Прямо свободно, съезд под 40° стоит — это не «впереди».
        let fork = CLLocationCoordinate2D(latitude: 41.2993 + 3 * 0.0009, longitude: 69.240)
        var exit = [fork]
        for _ in 0..<6 { exit.append(GeoMath.destination(from: exit[exit.count - 1], bearing: 40, distanceMeters: 100)) }
        XCTAssertNil(detect(approach + stretch(fromLat: 41.302, count: 8, kmh: 48, level: 1) + chain(exit)))
        // Прямо никто не мерил, съезд под 60° стоит — тоже молчим.
        var side = [fork]
        for _ in 0..<6 { side.append(GeoMath.destination(from: side[side.count - 1], bearing: 60, distanceMeters: 100)) }
        XCTAssertNil(detect(approach + chain(side)))
    }

    func testForkTakesTheSmallestTurn() throws {
        // Прямо стоит 800 м, съезд под 30° свободен: пробка — прямо, длина без съезда.
        let fork = CLLocationCoordinate2D(latitude: 41.2993 + 3 * 0.0009, longitude: 69.240)
        var exit = [fork]
        for _ in 0..<6 { exit.append(GeoMath.destination(from: exit[exit.count - 1], bearing: 30, distanceMeters: 100)) }
        let straight = try XCTUnwrap(detect(approach + stretch(fromLat: 41.302, count: 8) + chain(exit, kmh: 48, level: 1)))
        XCTAssertEqual(straight.length, 800, accuracy: 30)
        // Обе ветви — под углом (20° и 40°): идём по меньшему отклонению.
        var left = [fork], right = [fork]
        for _ in 0..<6 {
            left.append(GeoMath.destination(from: left[left.count - 1], bearing: 340, distanceMeters: 100))
            right.append(GeoMath.destination(from: right[right.count - 1], bearing: 40, distanceMeters: 100))
        }
        let gentle = try XCTUnwrap(detect(approach + chain(left) + chain(right, kmh: 48, level: 1)))
        XCTAssertEqual(gentle.length, 600, accuracy: 30)
        XCTAssertNil(detect(approach + chain(left, kmh: 48, level: 1) + chain(right)), "стоит более крутая ветвь")
    }

    func testSmallGapKeepsOneJam() throws {
        // Свободное ребро в 100 м между медленными — одна пробка, но в длину не идёт.
        let free = try XCTUnwrap(detect(approach + stretch(fromLat: 41.302, count: 4)
                                        + stretch(fromLat: 41.3056, count: 1, kmh: 48, level: 1)
                                        + stretch(fromLat: 41.3065, count: 4)))
        XCTAssertEqual(free.length, 800, accuracy: 30)
        // То же, но ребро никто не мерил.
        let hole = try XCTUnwrap(detect(approach + stretch(fromLat: 41.302, count: 4)
                                        + stretch(fromLat: 41.3065, count: 4)))
        XCTAssertEqual(hole.length, 800, accuracy: 30)
    }

    func testWideGapEndsTheJam() throws {
        let free = try XCTUnwrap(detect(approach + stretch(fromLat: 41.302, count: 4)
                                        + stretch(fromLat: 41.3056, count: 3, kmh: 48, level: 1)
                                        + stretch(fromLat: 41.3083, count: 4)))
        XCTAssertEqual(free.length, 400, accuracy: 20)
        let hole = try XCTUnwrap(detect(approach + stretch(fromLat: 41.302, count: 4)
                                        + stretch(fromLat: 41.3083, count: 4)))
        XCTAssertEqual(hole.length, 400, accuracy: 20)
    }

    func testShortSlowPatchIsNotAJam() {
        XCTAssertNil(detect(approach + stretch(fromLat: 41.302, count: 2)))
        XCTAssertNil(detect(approach + stretch(fromLat: 41.302, count: 8, level: 1)), "свободные рёбра — не пробка")
    }

    func testFarJamWaits() {
        // Начало в ~1,3 км: сказать ещё рано.
        XCTAssertNil(detect(stretch(fromLat: 41.2993, count: 14, kmh: 48, level: 1)
                            + stretch(fromLat: 41.3119, count: 5)))
    }

    func testNoCourseNoWords() {
        XCTAssertNil(detect(approach + stretch(fromLat: 41.302, count: 8), course: -1))
    }

    func testOnePhrasePerJam() throws {
        var announcer = JamAhead.Announcer()
        let jam = try XCTUnwrap(detect(approach + stretch(fromLat: 41.302, count: 8)))
        let t0 = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(announcer.shouldAnnounce(jam, at: t0))
        XCTAssertFalse(announcer.shouldAnnounce(jam, at: t0 + 60), "только что сказали")
        XCTAssertFalse(announcer.shouldAnnounce(jam, at: t0 + 400), "та же пробка — не раньше 15 минут")
        let other = JamAhead.Jam(startsIn: 300, length: 600, delay: 200,
                                 start: CLLocationCoordinate2D(latitude: 41.330, longitude: 69.240))
        XCTAssertTrue(announcer.shouldAnnounce(other, at: t0 + 400), "другая пробка через 3+ минуты")
    }
}
