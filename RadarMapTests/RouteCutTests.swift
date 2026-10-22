//
//  RouteCutTests.swift
//  RadarMapTests
//
//  Срез линии маршрута под значком (27.A): доля пути по предсказанной точке
//  на прямой, у излома, на развороте, при съезде и движении назад, после
//  перестроения; окно у машины; краска окна (до среза прозрачно, пробки и
//  манёвр на своих местах); стрелки прячутся ровно за срезом.
//
//  Метры точек здесь — 111 320 м на градус (MarkerPredictor.moved), а линия
//  меряет по MKMapPoint (геодезически, на 0,25 % короче по широте): отсюда
//  допуски в метр-полтора на сотнях метров.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class RouteCutTests: XCTestCase {

    private let origin = CLLocationCoordinate2D(latitude: 41.3000, longitude: 69.2800)

    /// Точка в метрах на восток/север от начала.
    private func at(_ east: Double, _ north: Double) -> CLLocationCoordinate2D {
        MarkerPredictor.moved(origin, east: east, north: north)
    }

    /// Прямая на север, 1 км.
    private lazy var straight = RouteCut.Line([at(0, 0), at(0, 500), at(0, 1_000)])
    /// 300 м на север, поворот направо, 300 м на восток.
    private lazy var corner = RouteCut.Line([at(0, 0), at(0, 300), at(300, 300)])

    private func advance(_ tracker: inout RouteCut.Tracker, line: RouteCut.Line,
                         _ point: CLLocationCoordinate2D, course: Double = 0,
                         fixAlong: Double, speed: Double = 14) -> Double {
        tracker.advance(pose: point, course: course, fixAlong: fixAlong, speedMps: speed, line: line)
    }

    // MARK: - Доля пути

    func testStraightCutFollowsThePredictedPoint() {
        var tracker = RouteCut.Tracker()
        // Фикс на 100 м, значок уехал вперёд на 12 м (14 м/с × 0,86 с).
        XCTAssertEqual(advance(&tracker, line: straight, at(0, 112), fixAlong: 100), 112, accuracy: 0.3)
        XCTAssertEqual(advance(&tracker, line: straight, at(0, 118), fixAlong: 100), 118, accuracy: 0.3)
        // Точка чуть в стороне от линии (прижим значка) — срез по проекции.
        XCTAssertEqual(advance(&tracker, line: straight, at(3, 124), fixAlong: 100), 124, accuracy: 0.3)
    }

    func testCutNeverRunsAheadOfTheMarkerHorizon() {
        var tracker = RouteCut.Tracker()
        // Точка на 200 м при фиксе на 100 м и 14 м/с — дальше горизонта значка.
        let cut = advance(&tracker, line: straight, at(0, 200), fixAlong: 100)
        XCTAssertEqual(cut, 100 + 14 * AppConfig.markerMaxLeadSeconds + AppConfig.routeCutLeadSlackMeters,
                       accuracy: 0.3)
    }

    func testCutStopsAtTheBendUntilTheFixPassesIt() {
        var tracker = RouteCut.Tracker()
        XCTAssertEqual(corner.bends.count, 1)
        XCTAssertEqual(corner.bends[0], 300, accuracy: 1)
        // Фикс за 5 м до угла; срезанный угол даёт точку у второй ветки (на 306 м
        // по линии) — граница ждёт у излома.
        XCTAssertEqual(advance(&tracker, line: corner, at(4, 299), course: 45, fixAlong: 295), corner.bends[0], accuracy: 0.01)
        // Фикс прошёл угол — граница идёт дальше.
        XCTAssertEqual(advance(&tracker, line: corner, at(12, 300), course: 90, fixAlong: 305), 312, accuracy: 1.5)
    }

    func testUTurnDoesNotJumpToTheReturnLeg() {
        // Разворот: 200 м на север и обратно по соседней полосе (4 м восточнее).
        let line = RouteCut.Line([at(0, 0), at(0, 200), at(4, 200), at(4, 0)])
        var tracker = RouteCut.Tracker()
        // Едем на север на 150 м: обратная ветка рядом, но против курса.
        XCTAssertEqual(advance(&tracker, line: line, at(2, 150), course: 0, fixAlong: 145), 150, accuracy: 0.5)
        // У самого разворота граница ждёт излома, а не уходит на обратную ветку.
        let cut = advance(&tracker, line: line, at(2, 199), course: 0, fixAlong: 196)
        XCTAssertLessThanOrEqual(cut, 200.01)
        XCTAssertGreaterThan(cut, 195)
        // Развернулись, фикс на обратной ветке (на 254 м линии) — граница за ним.
        XCTAssertEqual(advance(&tracker, line: line, at(4, 150), course: 180, fixAlong: 250), 254, accuracy: 1.5)
    }

    func testLeavingTheRouteFreezesTheCut() {
        var tracker = RouteCut.Tracker()
        advance(&tracker, line: straight, at(0, 300), fixAlong: 295)
        let before = tracker.cut
        // Ушли на соседнюю улицу в 60 м от линии — граница стоит.
        XCTAssertEqual(advance(&tracker, line: straight, at(60, 340), course: 45, fixAlong: 330), before)
        XCTAssertEqual(advance(&tracker, line: straight, at(90, 360), course: 45, fixAlong: 340), before)
    }

    func testDrivingBackDoesNotUncutTheLine() {
        var tracker = RouteCut.Tracker()
        advance(&tracker, line: straight, at(0, 400), fixAlong: 395)
        let before = tracker.cut
        // Развернулись и едем назад по самой линии.
        XCTAssertEqual(advance(&tracker, line: straight, at(0, 380), course: 180, fixAlong: 380), before)
        XCTAssertEqual(advance(&tracker, line: straight, at(0, 300), course: 180, fixAlong: 300), before)
    }

    func testRejoiningFurtherAlongCatchesUp() {
        var tracker = RouteCut.Tracker()
        advance(&tracker, line: straight, at(0, 100), fixAlong: 95)
        // Объезд по дублёру и возврат на линию на 700 м — прогресс фикса знает.
        XCTAssertEqual(advance(&tracker, line: straight, at(0, 705), fixAlong: 700), 705, accuracy: 2)
    }

    func testRerouteStartsTheCutAgain() {
        var tracker = RouteCut.Tracker()
        advance(&tracker, line: straight, at(0, 600), fixAlong: 595)
        XCTAssertGreaterThan(tracker.cut, 590)
        // Новый маршрут от машины на восток.
        let reroute = RouteCut.Line([at(0, 600), at(500, 600)])
        tracker.reset()
        XCTAssertEqual(tracker.cut, 0)
        XCTAssertEqual(advance(&tracker, line: reroute, at(10, 600), course: 90, fixAlong: 0), 10, accuracy: 0.5)
    }

    func testStandingStillCutsAtTheFix() {
        var tracker = RouteCut.Tracker()
        XCTAssertEqual(advance(&tracker, line: straight, at(0, 50), fixAlong: 50, speed: 0), 50, accuracy: 0.3)
    }

    // MARK: - Окно у машины

    func testWindowHoldsUntilTheReserveAndMovesForward() {
        let first = RouteCut.window(nil, cut: 10, routeLength: 5_000)
        XCTAssertEqual(first, RouteCut.Window(start: 4, end: 4 + AppConfig.routeCutWindowMeters))
        let inside = 4 + AppConfig.routeCutWindowMeters - AppConfig.routeCutWindowReserveMeters - 1
        XCTAssertEqual(RouteCut.window(first, cut: inside, routeLength: 5_000), first)
        let next = RouteCut.window(first, cut: inside + 2, routeLength: 5_000)
        XCTAssertNotEqual(next, first)
        XCTAssertEqual(next?.start ?? 0, inside + 2 - AppConfig.routeCutWindowBehindMeters, accuracy: 0.01)
    }

    func testWindowAtTheFinishCoversTheEndAndStays() {
        let window = RouteCut.window(nil, cut: 4_950, routeLength: 5_000)
        XCTAssertEqual(window?.end, 5_000)
        XCTAssertEqual(window?.length ?? 0, AppConfig.routeCutWindowMeters, accuracy: 0.01)
        XCTAssertEqual(RouteCut.window(window, cut: 4_999, routeLength: 5_000), window)
        // Короткий маршрут — окно на весь маршрут.
        XCTAssertEqual(RouteCut.window(nil, cut: 20, routeLength: 120), RouteCut.Window(start: 0, end: 120))
    }

    // MARK: - Краска окна

    private let colours = RouteCut.Colours(daylight: true)

    func testPaintIsClearBeforeTheCutAndColouredAfter() {
        let window = RouteCut.Window(start: 100, end: 356)
        let paint = RouteCut.paint(window: window, cut: 164, drawEnd: 356, traffic: [], maneuver: nil,
                                   colours: colours)
        XCTAssertEqual(paint.body, [RouteCut.Stop(at: 0, colour: .clear),
                                    RouteCut.Stop(at: 0.25, colour: colours.body)])
        XCTAssertEqual(paint.casing.last?.colour, colours.casing)
        XCTAssertEqual(paint.core.last?.colour, colours.core)
        XCTAssertEqual(paint.maneuver, [RouteCut.Stop(at: 0, colour: .clear)])
    }

    func testPaintStopsWhereTheOldRemainderStillDraws() {
        let window = RouteCut.Window(start: 100, end: 356)
        let paint = RouteCut.paint(window: window, cut: 164, drawEnd: 228, traffic: [], maneuver: nil,
                                   colours: colours)
        XCTAssertEqual(paint.body, [RouteCut.Stop(at: 0, colour: .clear),
                                    RouteCut.Stop(at: 0.25, colour: colours.body),
                                    RouteCut.Stop(at: 0.5, colour: .clear)])
    }

    func testTrafficAndManeuverLandOnTheirPlace() {
        let window = RouteCut.Window(start: 0, end: 256)
        let jam = RouteTraffic.Piece(level: 3, coordinates: [], from: 128, to: 192)
        let slowBehind = RouteTraffic.Piece(level: 2, coordinates: [], from: 0, to: 40)
        let paint = RouteCut.paint(window: window, cut: 64, drawEnd: 256, traffic: [jam, slowBehind],
                                   maneuver: 200...230, colours: colours)
        XCTAssertEqual(paint.body, [RouteCut.Stop(at: 0, colour: .clear),
                                    RouteCut.Stop(at: 0.25, colour: colours.body),
                                    RouteCut.Stop(at: 0.5, colour: colours.jam),
                                    RouteCut.Stop(at: 0.75, colour: colours.body)])
        XCTAssertEqual(paint.maneuver.map(\.at), [0, 200.0 / 256, 230.0 / 256])
        XCTAssertEqual(paint.maneuver[1].colour, colours.maneuver)
        // Манёвр позади среза не красится.
        let passed = RouteCut.paint(window: window, cut: 240, drawEnd: 256, traffic: [], maneuver: 200...230,
                                    colours: colours)
        XCTAssertEqual(passed.maneuver, [RouteCut.Stop(at: 0, colour: .clear)])
    }

    func testCutPastTheWindowPaintsNothing() {
        let paint = RouteCut.paint(window: RouteCut.Window(start: 0, end: 256), cut: 300, drawEnd: 256,
                                   traffic: [], maneuver: nil, colours: colours)
        XCTAssertEqual(paint, .clear)
    }

    func testGradientIsStrictlyIncreasingAndSharp() throws {
        let stops = [RouteCut.Stop(at: 0, colour: .clear), RouteCut.Stop(at: 0.25, colour: colours.body),
                     RouteCut.Stop(at: 0.25, colour: colours.jam), RouteCut.Stop(at: 1, colour: .clear)]
        let expression = RouteCut.gradient(stops)
        XCTAssertEqual(expression[0] as? String, "interpolate")
        let positions = stride(from: 3, to: expression.count, by: 2).compactMap { expression[$0] as? Double }
        XCTAssertEqual(positions.first, 0)
        XCTAssertEqual(positions.last, 1)
        XCTAssertEqual(positions, positions.sorted())
        XCTAssertEqual(Set(positions).count, positions.count, "входы interpolate строго возрастают")
        // Граница среза — две точки ближе сантиметра на окне 256 м.
        let cut = try XCTUnwrap(positions.firstIndex { $0 >= 0.25 })
        XCTAssertLessThan((positions[cut] - positions[cut - 1]) * 256, 0.01)
    }

    // MARK: - Стрелки

    func testArrowsAreEvenlySpacedWithRanks() {
        let arrows = RouteCut.arrows(straight, spacing: 15)
        XCTAssertEqual(arrows.count, 66)
        XCTAssertEqual(arrows[0].along, 15)
        XCTAssertEqual(arrows[0].rank, 0)
        XCTAssertEqual(arrows[1].rank, 1)
        XCTAssertEqual(arrows[31].rank, RouteCut.arrowMaxRank)
        XCTAssertEqual(arrows[0].bearing, 0, accuracy: 0.5)
        XCTAssertEqual(MarkerPredictor.distance(arrows[3].coordinate, at(0, 60)), 0, accuracy: 0.2)
        // Стрелки после поворота смотрят на восток.
        let east = RouteCut.arrows(corner, spacing: 15).last
        XCTAssertEqual(east?.bearing ?? 0, 90, accuracy: 0.5)
    }

    func testArrowRankThinsOutWhenZoomedOut() {
        XCTAssertEqual(RouteCut.arrowMinRank(zoom: 12), RouteCut.arrowMaxRank)
        XCTAssertEqual(RouteCut.arrowMinRank(zoom: 19), 0)
        XCTAssertEqual(RouteCut.arrowMinRank(zoom: 17), 2)
        XCTAssertGreaterThanOrEqual(RouteCut.arrowMinRank(zoom: 15), RouteCut.arrowMinRank(zoom: 17))
    }

    func testArrowThresholdHidesEverythingBehindTheCut() {
        let arrows = RouteCut.arrows(straight, spacing: 15)
        // Вблизи (ранг 0) — первая стрелка за срезом.
        XCTAssertEqual(RouteCut.arrowThreshold(arrows, cut: 100, minRank: 0), 105)
        // Срез ровно на стрелке — она уже позади.
        XCTAssertEqual(RouteCut.arrowThreshold(arrows, cut: 105, minRank: 0), 120)
        // Ранг 2 (каждая четвёртая, 60 м): порог — следующая видимая, 120 м.
        XCTAssertEqual(RouteCut.arrowThreshold(arrows, cut: 100, minRank: 2), 120)
        // За последней — за концом.
        XCTAssertGreaterThan(RouteCut.arrowThreshold(arrows, cut: 999, minRank: 0), arrows.last!.along)
    }
}
