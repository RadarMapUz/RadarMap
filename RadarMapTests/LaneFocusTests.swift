//
//  LaneFocusTests.swift
//  RadarMapTests
//
//  «Нужная полоса» на асфальте (28.C). Что проверяется: «наша» стрелка
//  узнаётся по ряду полос манёвра (номер полосы главнее набора поворотов),
//  без полос и на кольце — ничего; ряд — только перед нашим манёвром и по
//  ходу подъезда (встречные стрелки, поперечная улица, предыдущий перекрёсток
//  и ряд за манёвром в него не попадают); окно подъезда не гаснет при
//  торможении. Плюс контракт с тайлом: коды и имена значков — те же, что
//  в стиле приложения.
//

import CoreLocation
#if canImport(MapLibre)
import MapLibre
#endif
import XCTest
@testable import RadarMap

final class LaneFocusTests: XCTestCase {

    // MARK: - Контракт

    /// Коды `turn` и имена значков — те же, что в слое стрелок стиля
    /// (make_style «radar-arrows»): разъедутся — подсветка возьмёт не тот значок.
    func testTileIconsMatchTheBundledStyle() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RadarMap/Resources/MapStyle/map_style_light.json")
        let style = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let layers = try XCTUnwrap(style["layers"] as? [[String: Any]])
        let arrows = try XCTUnwrap(layers.first { $0["id"] as? String == "radar-arrows" })
        let layout = try XCTUnwrap(arrows["layout"] as? [String: Any])
        let match = try XCTUnwrap(layout["icon-image"] as? [Any])
        var names: [Int: String] = [:]
        var i = 2
        while i + 1 < match.count {
            names[try XCTUnwrap(match[i] as? Int)] = try XCTUnwrap(match[i + 1] as? String)
            i += 2
        }
        XCTAssertEqual(names, LaneFocus.tileIcons)
        XCTAssertEqual(Set(LaneFocus.tileTurns.keys), Set(LaneFocus.tileIcons.keys))
    }

    // MARK: - Какие стрелки наши

    private func lane(_ arrows: [LaneArrow], _ valid: Bool) -> LaneHint {
        LaneHint(arrows: arrows, isValid: valid)
    }

    /// Навои × Рашидов (OSRM, 23.10): «+left|+straight;left|-straight|-straight|-straight;right|-right».
    private var navoiRow: [LaneHint] {
        [lane([.left], true), lane([.straight, .left], true), lane([.straight], false),
         lane([.straight], false), lane([.straight, .right], false), lane([.right], false)]
    }

    func testLeftTurnHighlightsLeftAndStraightLeftArrows() {
        XCTAssertEqual(LaneFocus.ourCodes(kind: .left, lanes: navoiRow), [2, 7])
        XCTAssertEqual(LaneFocus.ourLanes(kind: .left, lanes: navoiRow),
                       [LaneFocus.OurLane(index: 0, codes: [2]), LaneFocus.OurLane(index: 1, codes: [7])])
    }

    func testStraightThroughUsesTheValidLanes() {
        let row = [lane([.left], false), lane([.straight], true), lane([.straight, .right], true)]
        XCTAssertEqual(LaneFocus.ourCodes(kind: .straight, lanes: row), [1, 8])
    }

    func testSharpAndMergeSpeakTheTileLanguage() {
        XCTAssertEqual(LaneFocus.ourCodes(kind: .sharpLeft, lanes: [lane([.sharpLeft], true)]), [2])
        XCTAssertEqual(LaneFocus.ourCodes(kind: .slightLeft, lanes: [lane([.mergeToLeft], true)]), [4])
    }

    /// Редкое сочетание без своего кода — по общему направлению подходящих полос.
    func testUnusualLaneFallsBackToTheCommonDirection() {
        let row = [lane([.left, .slightLeft], true), lane([.straight], false)]
        XCTAssertEqual(LaneFocus.ourCodes(kind: .left, lanes: row), [2, 7, 9])
    }

    /// Нет данных — нет подсветки: ни по модификатору, ни на кольце, ни на финише.
    func testNoLanesNoGuess() {
        XCTAssertEqual(LaneFocus.ourCodes(kind: .left, lanes: []), [])
        XCTAssertEqual(LaneFocus.ourCodes(kind: .left, lanes: [lane([.left], false)]), [])
        XCTAssertEqual(LaneFocus.ourCodes(kind: .roundabout, lanes: [lane([.left], true)]), [])
        XCTAssertEqual(LaneFocus.ourCodes(kind: .arrive, lanes: [lane([.left], true)]), [])
        XCTAssertEqual(LaneFocus.ourCodes(kind: nil, lanes: [lane([.left], true)]), [])
        XCTAssertNil(LaneFocus.step(next: step(at: 300, kind: .left, lanes: []), steps: [], notices: []))
        XCTAssertNil(LaneFocus.step(next: nil, steps: [], notices: []))
    }

    /// «налево | налево», годится одна: номер полосы решает; старый тайл без
    /// номера подсвечивает обе (стрелка честно ведёт налево).
    func testLaneIndexBeatsTheTurnSet() throws {
        let row = [lane([.left], true), lane([.left], false), lane([.straight], false)]
        let focus = try XCTUnwrap(LaneFocus.step(next: step(at: 300, kind: .left, lanes: row), steps: [], notices: []))
        XCTAssertTrue(focus.isOurs(.init(index: 0, count: 3, width: 3.3, turn: 2)))
        XCTAssertFalse(focus.isOurs(.init(index: 1, count: 3, width: 3.3, turn: 2)))
        XCTAssertFalse(focus.isOurs(.init(index: 2, count: 3, width: 3.3, turn: 1)))
        XCTAssertTrue(focus.isOurs(.init(index: nil, count: nil, width: nil, turn: 2)))
        XCTAssertFalse(focus.isOurs(.init(index: nil, count: nil, width: nil, turn: 1)))
        // На месте нашей полосы другая стрелка (данные разных лет) — не наша.
        XCTAssertFalse(focus.isOurs(.init(index: 0, count: 3, width: 3.3, turn: 1)))
        // В ряду тайла полос больше, чем у манёвра: номерам не верим.
        XCTAssertTrue(focus.isOurs(.init(index: 1, count: 4, width: 3.3, turn: 2)))
    }

    func testLaneKnowsWhereItLeads() {
        XCTAssertEqual(LaneFocus.Lane(index: 1, count: 6, width: 3.5, turn: 7).turns, [.straight, .left])
        XCTAssertEqual(LaneFocus.Lane(index: nil, count: nil, width: nil, turn: 0).turns, [])
    }

    // MARK: - Манёвр и предыдущий перекрёсток

    private func step(at along: Double, kind: ManeuverKind, lanes: [LaneHint]) -> RouteStep {
        RouteStep(distanceAlong: along, text: "манёвр", icon: "arrow.up", kind: kind, lanes: lanes)
    }

    func testFloorIsThePreviousJunctionOfTheRoute() throws {
        let next = step(at: 500, kind: .left, lanes: navoiRow)
        let steps = [step(at: 100, kind: .right, lanes: []), next, step(at: 900, kind: .right, lanes: [])]
        let notices = [LaneNotice(distanceAlong: 460, lanes: navoiRow), LaneNotice(distanceAlong: 700, lanes: navoiRow)]
        let focus = try XCTUnwrap(LaneFocus.step(next: next, steps: steps, notices: notices))
        XCTAssertEqual(focus.floor, 460 + AppConfig.laneFocusFloorMarginMeters)
        XCTAssertEqual(focus.laneCount, 6)
        let alone = try XCTUnwrap(LaneFocus.step(next: next, steps: [next], notices: []))
        XCTAssertEqual(alone.floor, -.infinity)
    }

    // MARK: - Окно подъезда

    func testGateEntersTheWindowAndHoldsWhileBraking() throws {
        let focus = try XCTUnwrap(LaneFocus.step(next: step(at: 1000, kind: .left, lanes: navoiRow),
                                                 steps: [], notices: []))
        var gate = LaneFocus.Gate()
        // 60 км/ч → 250 м окна: в 400 м ещё рано, в 240 — пора.
        XCTAssertNil(gate.update(focus, progress: 600, speedKmh: 60))
        XCTAssertEqual(gate.update(focus, progress: 760, speedKmh: 60), focus)
        // Тормозим до 10 км/ч (окно 150 м) в 200 м от манёвра — не гаснет.
        XCTAssertEqual(gate.update(focus, progress: 800, speedKmh: 10), focus)
        XCTAssertEqual(gate.update(focus, progress: 1005, speedKmh: 0), focus)
        // Прошли манёвр — гаснет и не возвращается.
        XCTAssertNil(gate.update(focus, progress: 1000 + AppConfig.laneFocusPassedMeters + 1, speedKmh: 20))
        XCTAssertNil(gate.update(focus, progress: 1020, speedKmh: 0))
        // Стоим у светофора в 100 м — окно 150 м.
        var standing = LaneFocus.Gate()
        XCTAssertEqual(standing.update(focus, progress: 900, speedKmh: 0), focus)
        XCTAssertNil(standing.update(nil, progress: 900, speedKmh: 0))
    }

    func testWindowFollowsTheTripCamera() {
        XCTAssertEqual(LaneFocus.window(speedKmh: 0), 150)
        XCTAssertEqual(LaneFocus.window(speedKmh: 72), 300, accuracy: 0.001)
        XCTAssertEqual(LaneFocus.window(speedKmh: 200), 450)
        XCTAssertEqual(LaneFocus.window(speedKmh: .nan), 150)
    }

    // MARK: - Коридор ряда

    private let origin = CLLocationCoordinate2D(latitude: 41.3189, longitude: 69.2712)

    /// Точка в метрах от начала: x — на восток, y — на север.
    private func at(_ x: Double, _ y: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: origin.latitude + y / 111_320,
                               longitude: origin.longitude + x / (111_320 * cos(origin.latitude * .pi / 180)))
    }

    /// Маршрут на восток 300 м, затем налево (на север).
    private var route: [CLLocationCoordinate2D] { [at(0, 0), at(150, 0), at(300, 0), at(300, 200)] }

    private func focus(floor: Double = -.infinity) -> LaneFocus.Step {
        LaneFocus.Step(along: 300, floor: floor, codes: [2, 7], laneCount: 6,
                       lanes: [.init(index: 0, codes: [2]), .init(index: 1, codes: [7])])
    }

    private func role(_ turn: Int, index: Int?, bearing: Double, _ x: Double, _ y: Double,
                      zone: LaneFocus.Zone) -> LaneFocus.Role? {
        LaneFocus.role(.init(index: index, count: index == nil ? nil : 6, width: 3.5, turn: turn),
                       bearing: bearing, at: at(x, y), zone: zone, step: focus())
    }

    func testRowBeforeTheManeuverIsFound() throws {
        let zone = try XCTUnwrap(LaneFocus.zone(route: route, step: focus()))
        XCTAssertEqual(zone.bearing, 90, accuracy: 1)
        // Ряд в 15 м до узла: левая полоса у оси, правые — южнее (правая половина).
        XCTAssertEqual(role(2, index: 0, bearing: 90, 285, -1.75, zone: zone), .ours)
        XCTAssertEqual(role(7, index: 1, bearing: 90, 285, -5.25, zone: zone), .ours)
        XCTAssertEqual(role(1, index: 2, bearing: 90, 285, -8.75, zone: zone), .other)
        XCTAssertEqual(role(3, index: 5, bearing: 90, 285, -12.0, zone: zone), .other)
        // Отодвинутый к светофору ряд — тоже наш.
        XCTAssertEqual(role(2, index: 0, bearing: 91, 230, -1.75, zone: zone), .ours)
    }

    func testForeignArrowsStayAsTheyWere() throws {
        let zone = try XCTUnwrap(LaneFocus.zone(route: route, step: focus()))
        // Встречная половина той же улицы.
        XCTAssertNil(role(2, index: 0, bearing: 270, 285, 5, zone: zone))
        // Поперечная улица у самого узла.
        XCTAssertNil(role(2, index: 0, bearing: 0, 295, -10, zone: zone))
        // Ряд предыдущего перекрёстка в 120 м до манёвра.
        XCTAssertNil(role(2, index: 0, bearing: 90, 180, -1.75, zone: zone))
        // За манёвром (ряд следующего перекрёстка по прямой).
        XCTAssertNil(role(2, index: 0, bearing: 90, 320, -1.75, zone: zone))
        // Параллельная улица в 25 м.
        XCTAssertNil(role(2, index: 0, bearing: 90, 285, -25, zone: zone))
    }

    func testCorridorStopsAtThePreviousJunction() throws {
        let zone = try XCTUnwrap(LaneFocus.zone(route: route, step: focus(floor: 260)))
        XCTAssertEqual(role(2, index: 0, bearing: 90, 285, -1.75, zone: zone), .ours)
        XCTAssertNil(role(2, index: 0, bearing: 90, 250, -1.75, zone: zone))
        // Перекрёсток вплотную: ряда нет — нет и подсветки.
        XCTAssertNil(LaneFocus.zone(route: route, step: focus(floor: 290)))
        XCTAssertNil(LaneFocus.zone(route: [at(0, 0)], step: focus()))
    }

    func testFacesWrapsAroundNorth() {
        XCTAssertTrue(LaneFocus.faces(355, 5))
        XCTAssertTrue(LaneFocus.faces(5, 355))
        XCTAssertFalse(LaneFocus.faces(180, 0))
        XCTAssertFalse(LaneFocus.faces(90 + AppConfig.laneFocusBearingDegrees + 1, 90))
    }

    // MARK: - Выражения стиля

    func testFiltersAreFlatExpressions() {
        let ours = LaneFocus.oursFilter(focus())
        XCTAssertEqual(ours.first as? String, "any")
        XCTAssertEqual(LaneFocus.turnFilter([2, 7]).count, 3)
        // Без подходящих полос по номеру — ни одна стрелка с номером не наша.
        let none = LaneFocus.Step(along: 300, floor: -.infinity, codes: [2], laneCount: 2, lanes: [])
        #if canImport(MapLibre)
        // Фильтры собираются в предикаты движка (без исключения ObjC).
        XCTAssertNotNil(NSPredicate(mglJSONObject: LaneFocus.oursFilter(none)))
        XCTAssertNotNil(NSPredicate(mglJSONObject: ours))
        XCTAssertNotNil(NSPredicate(mglJSONObject: LaneFocus.bearingFilter(90)))
        #endif
    }
}
