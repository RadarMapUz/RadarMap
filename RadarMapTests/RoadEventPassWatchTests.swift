//
//  RoadEventPassWatchTests.swift
//  RadarMapTests
//
//  «Ещё перекрыто?» / «Ремонт ещё идёт?» (12б.5): спрашиваем один раз и
//  только того, кто видел — подошёл вплотную по ходу события и отъехал.
//  Со встречки, с параллельной улицы, стоя или о своей отметке — молчим.
//

import XCTest
import CoreLocation
@testable import RadarMap

final class RoadEventPassWatchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let origin = CLLocationCoordinate2D(latitude: 41.30, longitude: 69.28)

    private func point(north: Double, east: Double = 0) -> CLLocationCoordinate2D {
        let along = GeoMath.destination(from: origin, bearing: 0, distanceMeters: north)
        return GeoMath.destination(from: along, bearing: 90, distanceMeters: east)
    }

    /// Событие в начале координат; отметивший ехал на север (курс 0).
    private func event(_ kind: RoadEvent.Kind = .closure, id: Int = 7, course: Double = 0,
                       expiresIn: TimeInterval = 3600) -> RoadEvent {
        RoadEvent(id: id, kind: kind, lat: origin.latitude, lon: origin.longitude, course: course,
                  expires: now.addingTimeInterval(expiresIn), confirmed: true)
    }

    /// Проехать по точкам (метры к северу, восток, курс) и собрать вопросы.
    private func drive(_ events: [RoadEvent], _ fixes: [(Double, Double, Double)],
                       excluded: Set<Int> = [],
                       tracks: inout [Int: RoadEventPassWatch.Track]) -> [Int?] {
        fixes.map { north, east, course in
            RoadEventPassWatch.update(tracks: &tracks, events: events,
                                      from: point(north: north, east: east), course: course,
                                      excluded: excluded, now: now)
        }
    }

    private func drive(_ events: [RoadEvent], _ fixes: [(Double, Double, Double)],
                       excluded: Set<Int> = []) -> [Int?] {
        var tracks: [Int: RoadEventPassWatch.Track] = [:]
        return drive(events, fixes, excluded: excluded, tracks: &tracks)
    }

    func testAsksOnlyAfterPassingAlongItsDirection() {
        let asked = drive([event()], [(-250, 0, 0), (-20, 0, 0), (20, 0, 0), (100, 0, 0), (200, 0, 0)])
        // Подъезжаем — рано; вплотную — тоже рано (смотреть на дорогу);
        // 100 м — дрожание у точки ещё не проезд; 200 м — вот теперь.
        XCTAssertEqual(asked, [nil, nil, nil, nil, 7])
    }

    func testOncomingCarriagewayIsNeverAsked() {
        // Встречка разделённого проспекта: перекрыта половина, которой мы
        // не видим, — «нет» оттуда сняло бы настоящее перекрытие.
        let asked = drive([event()], [(250, 10, 180), (10, 10, 180), (-200, 10, 180)])
        XCTAssertEqual(asked, [nil, nil, nil])
    }

    func testCrossStreetIsNotAlongWhenSideIsKnown() {
        // Поперёк перекрёстка: видно край, а не саму перекрытую полосу.
        let asked = drive([event()], [(0, -250, 90), (0, -10, 90), (0, 200, 90)])
        XCTAssertEqual(asked, [nil, nil, nil])
    }

    func testUnknownSideMeansAnyDirection() {
        // Курс отметки неизвестен — перекрыто, считаем, всё: видел любой.
        let asked = drive([event(course: -1)], [(0, -250, 90), (0, -10, 90), (0, 200, 90)])
        XCTAssertEqual(asked, [nil, nil, 7])
    }

    func testUnknownOwnCourseIsNoEvidence() {
        // Стояли рядом (курса нет) и ушли: на дорогу не смотрели.
        let asked = drive([event(course: -1)], [(0, 20, -1), (0, 40, -1), (0, 200, -1)])
        XCTAssertEqual(asked, [nil, nil, nil])
    }

    func testParallelStreetIsTooFar() {
        let asked = drive([event()], [(-250, 90, 0), (0, 90, 0), (250, 90, 0)])
        XCTAssertEqual(asked, [nil, nil, nil], "90 м сбоку — соседняя улица, а не полоса ремонта")
    }

    func testTurningBackAtTheClosureCounts() {
        // Перед перекрытием разворачиваются — подошедший по ходу его видел.
        let asked = drive([event()], [(-250, 0, 0), (-40, 0, 0), (-60, 3, 180), (-220, 3, 180)])
        XCTAssertEqual(asked, [nil, nil, nil, 7])
    }

    func testAsksOncePerSession() {
        var tracks: [Int: RoadEventPassWatch.Track] = [:]
        let first = drive([event()], [(-10, 0, 0), (200, 0, 0)], tracks: &tracks)
        XCTAssertEqual(first.last, 7)
        // Вернулись и проехали снова — второй раз не спрашиваем.
        let again = drive([event()], [(-200, 0, 0), (-10, 0, 0), (200, 0, 0)], tracks: &tracks)
        XCTAssertEqual(again, [nil, nil, nil])
    }

    func testOwnReportIsNotAsked() {
        let asked = drive([event()], [(-10, 0, 0), (200, 0, 0)], excluded: [7])
        XCTAssertEqual(asked, [nil, nil], "отметивший только что видел сам")
    }

    func testExpiredEventIsForgotten() {
        var tracks: [Int: RoadEventPassWatch.Track] = [:]
        _ = drive([event()], [(-10, 0, 0)], tracks: &tracks)
        XCTAssertEqual(tracks.count, 1)
        let asked = drive([event(expiresIn: -1)], [(200, 0, 0)], tracks: &tracks)
        XCTAssertEqual(asked, [nil], "о снятом по сроку не спрашиваем")
        XCTAssertTrue(tracks.isEmpty)
    }

    func testFarEventsKeepNoState() {
        var tracks: [Int: RoadEventPassWatch.Track] = [:]
        _ = drive([event()], [(-5000, 0, 0)], tracks: &tracks)
        XCTAssertTrue(tracks.isEmpty, "ремонты по стране не живут в памяти")
    }

    func testOneQuestionPerTick() {
        let events = [event(id: 1), event(.roadwork, id: 2)]
        var tracks: [Int: RoadEventPassWatch.Track] = [:]
        let asked = drive(events, [(-10, 0, 0), (200, 0, 0), (260, 0, 0)], tracks: &tracks)
        XCTAssertNotNil(asked[1])
        XCTAssertNil(asked[2], "оба отмечены спрошенными — второй вопрос следом не выскочит")
    }

    func testQuestionNamesTheEvent() {
        XCTAssertNotEqual(RoadEventPassWatch.question(for: .closure),
                          RoadEventPassWatch.question(for: .roadwork))
    }
}
