//
//  LanePathTests.swift
//  RadarMapTests
//
//  Лента «Вождения 3D» (LanePath, 43): во всю нашу сторону на прямой,
//  сужение к нужным полосам у манёвра S-кривой, по ПДД без ряда стрелок,
//  возврат после манёвра, разрез по мосту, без петель на тугом изгибе.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class LanePathTests: XCTestCase {

    private let frame = LanePath.Frame(origin: CLLocationCoordinate2D(latitude: 41.3, longitude: 69.28))

    private func c(_ x: Double, _ y: Double) -> CLLocationCoordinate2D { frame.coordinate(.init(x: x, y: y)) }

    /// Север 600 м, затем налево (на запад) 300 м; двусторонние 14 и 12 м, узел — `inner`.
    private func leftTurn(arrows: [LanePath.Arrow] = [], edge: LanePath.Edge? = .left, narrowing: Bool = true,
                          car: Double = 100, speed: Double = 11) -> LanePath.Input {
        LanePath.Input(
            route: [c(0, 0), c(0, 600), c(-300, 600)], from: car, length: 1500, car: car, speedMps: speed,
            window: 200,
            roads: [LanePath.Road(points: [c(0, -50), c(0, 580)], width: 14, oneway: false, bridge: false),
                    LanePath.Road(points: [c(-20, 600), c(-400, 600)], width: 12, oneway: false, bridge: false),
                    LanePath.Road(points: [c(0, 580), c(0, 620)], width: 20, oneway: false, bridge: false, inner: true)],
            arrows: arrows, maneuver: LanePath.Maneuver(along: 600, edge: edge, row: true), narrowing: narrowing)
    }

    /// Ряд за 40 м до узла на правой половине: левая полоса — наша.
    private let row = [(1.75, true), (5.25, false)]

    private func rowArrows(_ lanes: [(Double, Bool)], at y: Double = 560, bearing: Double = 0) -> [LanePath.Arrow] {
        lanes.map { LanePath.Arrow(coordinate: c($0.0, y), bearing: bearing, width: 3.5, ours: $0.1) }
    }

    private func offsets(_ r: LanePath.Ribbon, at s: Double) -> (Double, Double) {
        let i = r.along.firstIndex { $0 >= s } ?? (r.along.count - 1)
        return (r.leftOffset[i], r.rightOffset[i])
    }

    // MARK: - Прямая

    func testTwoWayRoadFillsTheRightHalf() {
        let r = LanePath.build(leftTurn(edge: nil))
        let (l, rr) = offsets(r, at: 300)
        XCTAssertEqual(l, 0, accuracy: 0.05)
        XCTAssertEqual(rr, 7, accuracy: 0.05)
        XCTAssertEqual(r.narrowing, .none)
        XCTAssertNil(r.narrowed)
    }

    func testOneWayRoadFillsTheWholeRibbon() {
        var input = leftTurn(edge: nil)
        input.roads[0].oneway = true
        let (l, rr) = offsets(LanePath.build(input), at: 300)
        XCTAssertEqual(l, -7, accuracy: 0.05)
        XCTAssertEqual(rr, 7, accuracy: 0.05)
    }

    /// Ось маршрута в стороне от оси ленты (другая сборка, скругление) —
    /// края всё равно на асфальте: смещения от оси совпавшей ленты.
    func testOffsetsFollowTheMatchedRoadNotTheRouteLine() {
        var input = leftTurn(edge: nil)
        input.route = [c(1.5, 0), c(1.5, 600), c(-300, 600)]
        let (l, rr) = offsets(LanePath.build(input), at: 300)
        XCTAssertEqual(l, -1.5, accuracy: 0.05)
        XCTAssertEqual(rr, 5.5, accuracy: 0.05)
    }

    func testUnknownRoadIsANarrowRibbonOnTheAxis() {
        var input = leftTurn(edge: nil)
        input.roads = []
        let r = LanePath.build(input)
        let (l, rr) = offsets(r, at: 300)
        XCTAssertEqual(l, -AppConfig.drive3DFallbackWidth / 2, accuracy: 0.01)
        XCTAssertEqual(rr, AppConfig.drive3DFallbackWidth / 2, accuracy: 0.01)
        XCTAssertEqual(r.matchedShare, 0)
    }

    /// Сужение `stub` у устья и шов тайла не дёргают край (медиана).
    func testShortStubDoesNotDentTheEdge() {
        var input = leftTurn(edge: nil)
        input.roads[0] = LanePath.Road(points: [c(0, -50), c(0, 300)], width: 14, oneway: false, bridge: false)
        input.roads.append(LanePath.Road(points: [c(0, 300), c(0, 306)], width: 6, oneway: false, bridge: false))
        input.roads.append(LanePath.Road(points: [c(0, 306), c(0, 580)], width: 14, oneway: false, bridge: false))
        let r = LanePath.build(input)
        for s in stride(from: 280.0, through: 330, by: 2) {
            XCTAssertEqual(offsets(r, at: s).1, 7, accuracy: 0.05, "край у \(s) м")
        }
    }

    // MARK: - Сужение у манёвра

    func testNarrowsExactlyToOurArrowsAndEndsBeforeTheRow() {
        let r = LanePath.build(leftTurn(arrows: rowArrows(row)))
        XCTAssertEqual(r.narrowing, .arrows)
        XCTAssertEqual(r.row ?? 0, 560, accuracy: 1)
        let end = 560 - AppConfig.drive3DRowGapMeters
        let (l, rr) = offsets(r, at: end)
        XCTAssertEqual(l, 0, accuracy: 0.05)
        XCTAssertEqual(rr, 3.5, accuracy: 0.05)
        // До перестроения — вся сторона; длина — одна полоса за max(45 м, 3,5 с).
        let start = end - max(AppConfig.drive3DShiftMeters, 11 * AppConfig.drive3DShiftSeconds)
        XCTAssertEqual(offsets(r, at: start - 4).1, 7, accuracy: 0.05)
        XCTAssertLessThan(offsets(r, at: start + 10).1, 7)
    }

    /// Оба края движутся синхронно S-кривой: без ступеньки и с плавным
    /// началом (касательная к прямой), шаг между станциями мал.
    func testShiftIsASmoothSCurve() {
        let r = LanePath.build(leftTurn(arrows: rowArrows(row)))
        var biggest = 0.0
        for i in 1..<r.along.count where r.along[i] < 600 {
            biggest = max(biggest, abs(r.rightOffset[i] - r.rightOffset[i - 1]))
        }
        // Наибольший наклон smootherstep — 15/8 от среднего: 3,5 м за 45 м.
        let steepest = 15.0 / 8 * 3.5 / 45 * AppConfig.drive3DStationMeters
        XCTAssertLessThan(biggest, steepest + 0.02, "ступенька края \(biggest) м на станцию")
        let start = 545 - 45.0
        XCTAssertLessThan(7 - offsets(r, at: start + 4).1, 0.05, "начало S-кривой — без излома")
    }

    func testWithoutArrowsLeftTurnGoesToTheLeftLaneByRules() {
        let r = LanePath.build(leftTurn())
        XCTAssertEqual(r.narrowing, .rules)
        let (l, rr) = offsets(r, at: 600 - AppConfig.drive3DNoRowGapMeters)
        XCTAssertEqual(l, 0, accuracy: 0.05)
        XCTAssertEqual(rr, AppConfig.drive3DLaneMeters, accuracy: 0.05)
    }

    func testWithoutArrowsRightTurnGoesToTheRightLane() {
        let r = LanePath.build(leftTurn(edge: .right))
        let (l, rr) = offsets(r, at: 600 - AppConfig.drive3DNoRowGapMeters)
        XCTAssertEqual(l, 7 - AppConfig.drive3DLaneMeters, accuracy: 0.05)
        XCTAssertEqual(rr, 7, accuracy: 0.05)
    }

    func testStraightWithoutArrowsIsNotNarrowed() {
        let r = LanePath.build(leftTurn(edge: nil))
        XCTAssertEqual(r.narrowing, .none)
    }

    /// Горячий телефон и плитка: только заливка.
    func testNarrowingSwitchedOffLeavesTheFullSide() {
        let r = LanePath.build(leftTurn(arrows: rowArrows(row), narrowing: false))
        XCTAssertEqual(r.narrowing, .none)
        XCTAssertEqual(offsets(r, at: 550).1, 7, accuracy: 0.05)
    }

    func testAfterTheManeuverTheRibbonFillsTheNewRoad() {
        let r = LanePath.build(leftTurn(arrows: rowArrows(row)))
        let (l, rr) = offsets(r, at: 600 + AppConfig.drive3DReleaseMeters + 20)
        XCTAssertEqual(l, 0, accuracy: 0.05)
        XCTAssertEqual(rr, 6, accuracy: 0.05)
    }

    /// Пересчёт у самого манёвра не дёргает ленту под машиной.
    func testShiftNeverStartsUnderTheCar() {
        let car = 520.0
        let r = LanePath.build(leftTurn(arrows: rowArrows(row), car: car))
        XCTAssertEqual(offsets(r, at: car + AppConfig.drive3DShiftLeadMeters - 2).1, 7, accuracy: 0.05)
    }

    /// Встречные стрелки и стрелки чужой стороны — не наш ряд.
    func testOncomingArrowsAreNotOurRow() {
        let oncoming = rowArrows([(-1.75, true), (-5.25, true)], bearing: 180)
        let r = LanePath.build(leftTurn(arrows: oncoming))
        XCTAssertEqual(r.narrowing, .rules)
    }

    func testRowWithoutOurArrowsFallsBackToRules() {
        let r = LanePath.build(leftTurn(arrows: rowArrows([(1.75, false), (5.25, false)])))
        XCTAssertEqual(r.narrowing, .rules)
    }

    // MARK: - Мост, срез, шевроны

    func testBridgeSplitsTheRibbonWithASharedStation() {
        var input = leftTurn(edge: nil)
        input.roads[0] = LanePath.Road(points: [c(0, -50), c(0, 250)], width: 14, oneway: false, bridge: false)
        input.roads.append(LanePath.Road(points: [c(0, 250), c(0, 400)], width: 14, oneway: false, bridge: true))
        input.roads.append(LanePath.Road(points: [c(0, 400), c(0, 580)], width: 14, oneway: false, bridge: false))
        let r = LanePath.build(input)
        let pieces = LanePath.pieces(r, from: 150, to: 500)
        XCTAssertEqual(pieces.map(\.bridge), [false, true, false])
        for (a, b) in zip(pieces, pieces.dropFirst()) {
            let end = a.centre.last!, start = b.centre.first!
            XCTAssertEqual(end.latitude, start.latitude, accuracy: 1e-9, "стык без щели")
            XCTAssertEqual(end.longitude, start.longitude, accuracy: 1e-9)
        }
    }

    func testPiecesStartAtTheCut() {
        let r = LanePath.build(leftTurn(edge: nil))
        let pieces = LanePath.pieces(r, from: 300)
        let start = frame.point(pieces[0].centre[0])
        XCTAssertEqual(start.y, 300, accuracy: AppConfig.drive3DStationMeters)
        XCTAssertEqual(pieces[0].ring.first?.latitude, pieces[0].ring.last?.latitude, "кольцо замкнуто")
    }

    func testStraightRunsAreThinnedOut() {
        let r = LanePath.build(leftTurn(edge: nil))
        let piece = LanePath.pieces(r, from: 150, to: 500)[0]
        XCTAssertLessThan(piece.left.count, 6, "прямая — двумя точками")
    }

    func testChevronsStayOnFixedMetres() {
        let a = LanePath.chevrons(LanePath.build(leftTurn(edge: nil, car: 100)), spacing: 50)
        let b = LanePath.chevrons(LanePath.build(leftTurn(edge: nil, car: 140)), spacing: 50)
        XCTAssertTrue(a.allSatisfy { $0.along.truncatingRemainder(dividingBy: 50) == 0 })
        let common = Set(a.map(\.along)).intersection(b.map(\.along))
        XCTAssertGreaterThan(common.count, 5)
        XCTAssertEqual(a.first { $0.along == 300 }?.bearing ?? -1, 0, accuracy: 1)
    }

    // MARK: - Ось

    /// Излом маршрута скруглён, мера метров — та же, что у маршрута.
    func testCornerIsRoundedAndMetresKeepTheRouteMeasure() {
        let r = LanePath.build(leftTurn(edge: nil))
        XCTAssertEqual(r.along.last ?? 0, 900, accuracy: 0.5)
        let corner = r.along.firstIndex { $0 >= 600 }!
        let p = r.centre[corner]
        XCTAssertGreaterThan(hypot(p.x - 0, p.y - 600), 1, "угол срезан дугой")
    }

    /// Разворот: внутренний край длиннее радиуса не даёт петли.
    func testUTurnEdgesDoNotCrossThemselves() {
        let input = LanePath.Input(
            route: [c(0, 0), c(0, 400), c(-8, 404), c(-16, 400), c(-16, 0)], from: 0, length: 900, car: 0,
            speedMps: 8, window: 150,
            roads: [LanePath.Road(points: [c(0, -20), c(0, 420)], width: 10, oneway: true, bridge: false),
                    LanePath.Road(points: [c(-16, 420), c(-16, -20)], width: 10, oneway: true, bridge: false)],
            arrows: [], maneuver: nil, narrowing: false)
        let r = LanePath.build(input)
        for edge in [r.left, r.right] {
            for i in 0..<(edge.count - 3) {
                for j in (i + 2)..<min(edge.count - 1, i + 60) {
                    XCTAssertNil(LanePath.intersection(edge[i], edge[i + 1], edge[j], edge[j + 1]),
                                 "петля края у станций \(i)…\(j)")
                }
            }
        }
    }

    func testSmootherstepHasFlatEnds() {
        XCTAssertEqual(LanePath.smootherstep(0), 0)
        XCTAssertEqual(LanePath.smootherstep(1), 1)
        XCTAssertEqual(LanePath.smootherstep(0.5), 0.5, accuracy: 1e-9)
        XCTAssertLessThan(LanePath.smootherstep(0.02), 0.0001)
    }
}
