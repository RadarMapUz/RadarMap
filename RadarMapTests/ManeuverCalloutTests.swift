//
//  ManeuverCalloutTests.swift
//  RadarMapTests
//
//  Выноска манёвра на карте (29.G). Что проверяется: ряд полос — только по
//  данным и только когда из него есть что выбирать; на прибытии, кольце и
//  «прямо» выноски нет; ряд появляется в окне подъезда и не гаснет при
//  торможении; подпись расстояния — только на ближних 300 м и шагами;
//  место — в свободной части экрана, мимо значка «я», камер и подъезда, со
//  стороны против поворота, и прежнее место держится, пока оно годно.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class ManeuverCalloutTests: XCTestCase {

    private func step(_ kind: ManeuverKind?, lanes: [LaneHint] = [], at along: Double = 500) -> RouteStep {
        RouteStep(distanceAlong: along, text: "поверните", icon: "arrow.turn.up.right", kind: kind, lanes: lanes)
    }

    private let rightOnly = [LaneHint(arrows: [.left], isValid: false), LaneHint(arrows: [.straight], isValid: false),
                             LaneHint(arrows: [.right], isValid: true)]

    // MARK: - Что

    func testLanesOnlyWhenThereIsAChoice() {
        XCTAssertEqual(ManeuverCallout.content(step: step(.right, lanes: rightOnly))?.lanes.count, 3)
        // Годятся все — выбирать нечего: только расстояние.
        let all = [LaneHint(arrows: [.right], isValid: true), LaneHint(arrows: [.right], isValid: true)]
        XCTAssertEqual(ManeuverCallout.content(step: step(.right, lanes: all))?.lanes, [])
        // Ни одна не годится (сломанные данные) — тоже без ряда.
        let none = [LaneHint(arrows: [.left], isValid: false), LaneHint(arrows: [.straight], isValid: false)]
        XCTAssertEqual(ManeuverCallout.content(step: step(.right, lanes: none))?.lanes, [])
        // Полос нет — выноска есть, ряда нет.
        XCTAssertEqual(ManeuverCallout.content(step: step(.left))?.lanes, [])
        // Девять полос не помещаются — без ряда (у карточки тот же предел).
        let nine = (0..<9).map { LaneHint(arrows: [.straight], isValid: $0 == 0) }
        XCTAssertEqual(ManeuverCallout.content(step: step(.right, lanes: nine))?.lanes, [])
    }

    func testNoCalloutWithoutATurn() {
        XCTAssertNil(ManeuverCallout.content(step: nil))
        XCTAssertNil(ManeuverCallout.content(step: step(.arrive)))
        XCTAssertNil(ManeuverCallout.content(step: step(.roundabout)))
        XCTAssertNil(ManeuverCallout.content(step: step(.straight)))
        // MKDirections: тип манёвра неизвестен — места поворота не знаем.
        XCTAssertNil(ManeuverCallout.content(step: step(nil)))
        XCTAssertNotNil(ManeuverCallout.content(step: step(.uturn)))
    }

    // MARK: - Когда

    func testDistanceMarkOnlyNearAndInSteps() {
        XCTAssertNil(ManeuverCallout.markMeters(301))
        XCTAssertEqual(ManeuverCallout.markMeters(300), 300)
        XCTAssertEqual(ManeuverCallout.markMeters(184), 180)
        XCTAssertEqual(ManeuverCallout.markMeters(97), 95)
        XCTAssertEqual(ManeuverCallout.markMeters(36), 35)
        // У самой точки — уже под машиной.
        XCTAssertNil(ManeuverCallout.markMeters(5))
        XCTAssertNil(ManeuverCallout.markMeters(.nan))
    }

    func testLaneRowAppearsInTheApproachWindowAndHoldsThroughBraking() throws {
        var gate = ManeuverCallout.Gate()
        let content = try XCTUnwrap(ManeuverCallout.content(step: step(.right, lanes: rightOnly)))
        // 60 км/ч: окно 250 м. За 400 м — ни ряда, ни подписи.
        var shown = gate.update(content: content, distance: 400, speedKmh: 60)
        XCTAssertTrue(shown.isEmpty)
        shown = gate.update(content: content, distance: 240, speedKmh: 60)
        XCTAssertTrue(shown.lanes)
        XCTAssertEqual(shown.meters, 240)
        // Затормозили до 20 км/ч: окно сузилось до 150 м, а ряд остаётся.
        shown = gate.update(content: content, distance: 200, speedKmh: 20)
        XCTAssertTrue(shown.lanes)
        // Проехали манёвр — пусто, и следующий манёвр начинает с чистого листа.
        shown = gate.update(content: content, distance: 3, speedKmh: 20)
        XCTAssertTrue(shown.isEmpty)
        let next = try XCTUnwrap(ManeuverCallout.content(step: step(.right, lanes: rightOnly, at: 900)))
        shown = gate.update(content: next, distance: 200, speedKmh: 20)
        XCTAssertFalse(shown.lanes, "окно 150 м на 20 км/ч — ряд нового манёвра ещё рано")
        XCTAssertEqual(shown.meters, 200)
    }

    func testNoLaneRowWithoutLaneData() throws {
        var gate = ManeuverCallout.Gate()
        let content = try XCTUnwrap(ManeuverCallout.content(step: step(.left)))
        let shown = gate.update(content: content, distance: 100, speedKmh: 30)
        XCTAssertFalse(shown.lanes)
        XCTAssertEqual(shown.meters, 100)
    }

    // MARK: - Где

    private let screen = CGRect(x: 8, y: 300, width: 320, height: 400)
    private let size = CGSize(width: 160, height: 40)

    func testPrefersAboveTheTurn() throws {
        let place = try XCTUnwrap(ManeuverCallout.place(anchor: CGPoint(x: 160, y: 500), size: size, clear: screen,
                                                        avoid: [], previous: nil, turn: .right))
        XCTAssertEqual(place.side, .above)
        XCTAssertEqual(place.frame.maxY, 500 - AppConfig.maneuverCalloutTailPoints)
        XCTAssertTrue(screen.contains(place.frame))
    }

    func testTurnAtThePanelEdgeGoesBesideAgainstTheTurn() throws {
        // Поворот у самой кромки верхней панели (кадр подъезда держит его
        // наверху): ни над ним, ни ровно сбоку места нет. Направо — выноска
        // снизу-слева (выезд направо виден), налево — снизу-справа; линия
        // подъезда, идущая из точки вниз, не закрыта.
        let anchor = CGPoint(x: 200, y: 310)
        let approach = [ManeuverCallout.box(CGPoint(x: 200, y: 365), radius: AppConfig.maneuverCalloutApproachRadius),
                        ManeuverCallout.box(CGPoint(x: 200, y: 405), radius: AppConfig.maneuverCalloutApproachRadius)]
        let right = try XCTUnwrap(ManeuverCallout.place(anchor: anchor, size: size, clear: screen,
                                                        avoid: approach, previous: nil, turn: .right))
        XCTAssertEqual(right.side, .belowLeft)
        XCTAssertLessThanOrEqual(right.frame.maxX, anchor.x - AppConfig.maneuverCalloutApproachRadius)
        let left = try XCTUnwrap(ManeuverCallout.place(anchor: CGPoint(x: 120, y: 310), size: size, clear: screen,
                                                       avoid: [], previous: nil, turn: .left))
        XCTAssertEqual(left.side, .belowRight)
        // Есть место по центру сбоку — ровно сбоку, против поворота.
        let middle = try XCTUnwrap(ManeuverCallout.place(anchor: CGPoint(x: 200, y: 330), size: size, clear: screen,
                                                         avoid: approach, previous: nil, turn: .right))
        XCTAssertEqual(middle.side, .left)
    }

    func testNeverCoversTheCursorOrACamera() throws {
        let anchor = CGPoint(x: 160, y: 500)
        // Камера прямо над поворотом — выноска уходит с неё.
        let camera = ManeuverCallout.box(CGPoint(x: 160, y: 465), radius: 22)
        let place = try XCTUnwrap(ManeuverCallout.place(anchor: anchor, size: size, clear: screen,
                                                        avoid: [camera], previous: nil, turn: .right))
        XCTAssertFalse(place.frame.intersects(camera))
        // Всё вокруг закрыто — выноски нет, а не выноска на камере.
        let everywhere = ManeuverCallout.box(anchor, radius: 300)
        XCTAssertNil(ManeuverCallout.place(anchor: anchor, size: size, clear: screen,
                                           avoid: [everywhere], previous: nil, turn: .right))
    }

    func testTurnUnderAPanelHasNoCallout() {
        XCTAssertNil(ManeuverCallout.place(anchor: CGPoint(x: 160, y: 200), size: size, clear: screen,
                                           avoid: [], previous: nil))
        XCTAssertNil(ManeuverCallout.place(anchor: CGPoint(x: 160, y: CGFloat.nan), size: size, clear: screen,
                                           avoid: [], previous: nil))
    }

    func testKeepsItsSideWhileItFits() throws {
        // Прошлый кадр — сбоку слева; над точкой место освободилось, но
        // выноска не перепрыгивает, пока слева годно.
        let anchor = CGPoint(x: 200, y: 500)
        let previous = ManeuverCallout.Placement(side: .left, shift: 0, frame: .zero, tip: .zero)
        let kept = try XCTUnwrap(ManeuverCallout.place(anchor: anchor, size: size, clear: screen,
                                                       avoid: [], previous: previous, turn: .right))
        XCTAssertEqual(kept.side, .left)
        // Слева стало тесно (край экрана) — тогда меняет сторону.
        let squeezed = try XCTUnwrap(ManeuverCallout.place(anchor: CGPoint(x: 60, y: 500), size: size, clear: screen,
                                                           avoid: [], previous: previous, turn: .right))
        XCTAssertNotEqual(squeezed.side, .left)
    }

    func testClearRectLeavesPanelsAndColumn() {
        let rect = ManeuverCallout.clearRect(width: 400, height: 800, topShare: 0.3, bottomShare: 0.15,
                                             left: 0, right: 60, margin: 8)
        XCTAssertEqual(rect, CGRect(x: 8, y: 248, width: 324, height: 424))
        XCTAssertEqual(ManeuverCallout.clearRect(width: 400, height: 800, topShare: 0.6, bottomShare: 0.5,
                                                 left: 0, right: 60, margin: 8), .zero)
    }

    // MARK: - Точка на линии

    func testPointAlongRoute() throws {
        let route = [CLLocationCoordinate2D(latitude: 41.30, longitude: 69.20),
                     CLLocationCoordinate2D(latitude: 41.30, longitude: 69.21),
                     CLLocationCoordinate2D(latitude: 41.31, longitude: 69.21)]
        let cumulative = ManeuverArrow.cumulative(route)
        let mid = try XCTUnwrap(ManeuverCallout.point(along: cumulative[1] / 2, route: route, cumulative: cumulative))
        XCTAssertEqual(mid.longitude, 69.205, accuracy: 1e-6)
        let end = try XCTUnwrap(ManeuverCallout.point(along: 1e9, route: route, cumulative: cumulative))
        XCTAssertEqual(end.latitude, 41.31, accuracy: 1e-9)
        XCTAssertNil(ManeuverCallout.point(along: 10, route: route, cumulative: [0]))
    }
}
