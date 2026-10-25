//
//  TurnBendTests.swift
//  RadarMapTests
//
//  Голос на изломе «прямо» (29.E): `continue` с поворотом улицы на
//  перекрёстке — команда, плавный изгиб проспекта — тишина. Ложное
//  «поверните налево» на изгибе хуже молчания: водитель свернёт.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class TurnBendTests: XCTestCase {

    private let lat0 = 41.30
    private let lon0 = 69.25
    private var lonMeters: Double { 111_320 * cos(lat0 * .pi / 180) }

    /// Точка в метрах от начала координат теста (x — восток, y — север).
    private func p(_ x: Double, _ y: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat0 + y / 111_320, longitude: lon0 + x / lonMeters)
    }

    /// На север 300 м, затем угол на `degrees` (минус — налево) и ещё 300 м.
    private func corner(_ degrees: Double) -> [CLLocationCoordinate2D] {
        var path = stride(from: 0.0, through: 300, by: 10).map { p(0, $0) }
        let heading = degrees * .pi / 180
        for d in stride(from: 10.0, through: 300, by: 10) {
            path.append(p(d * sin(heading), 300 + d * cos(heading)))
        }
        return path
    }

    /// На север 300 м, затем дуга радиуса `radius` налево на 90° и ещё 300 м
    /// на запад — изгиб проспекта.
    private func curve(radius: Double) -> (path: [CLLocationCoordinate2D], middle: Double) {
        var path = stride(from: 0.0, through: 300, by: 10).map { p(0, $0) }
        let arcSteps = 30
        for i in 1...arcSteps {
            let a = Double(i) / Double(arcSteps) * .pi / 2
            path.append(p(-radius + radius * cos(a), 300 + radius * sin(a)))
        }
        let end = path.last!
        for d in stride(from: 10.0, through: 300, by: 10) {
            path.append(CLLocationCoordinate2D(latitude: end.latitude, longitude: end.longitude - d / lonMeters))
        }
        return (path, 300 + radius * .pi / 4)
    }

    /// «Ступенька» через узел двух проезжих частей: на восток, у узла
    /// налево на 70° и через 80 м направо — дальше на восток той же улицей.
    private func jog() -> (path: [CLLocationCoordinate2D], left: Double, right: Double) {
        var path = stride(from: 0.0, through: 300, by: 10).map { p($0, 0) }
        let dx = 80 * sin(20 * Double.pi / 180), dy = 80 * cos(20 * Double.pi / 180)
        for i in 1...8 { path.append(p(300 + dx * Double(i) / 8, dy * Double(i) / 8)) }
        for d in stride(from: 10.0, through: 300, by: 10) { path.append(p(300 + dx + d, dy)) }
        return (path, 300, 380)
    }

    func testJunctionCornerIsABend() throws {
        let path = corner(-90)
        let cum = TurnBend.cumulative(path)
        let bend = try XCTUnwrap(TurnBend.measure(path: path, cumulative: cum, at: 300))
        XCTAssertEqual(bend.near, -90, accuracy: 3)
        XCTAssertEqual(bend.wide, -90, accuracy: 3)
        XCTAssertTrue(TurnBend.voices(type: "continue", modifier: "left", bend: bend, roads: 3))
        XCTAssertTrue(TurnBend.voices(type: "new name", modifier: "sharp left", bend: bend, roads: 4))
    }

    func testJogThroughAJunctionIsNotTwoTurns() throws {
        // Seul ko'chasi (аудит 25.10): у самой точки излом 45°+, но дорога
        // идёт прямо — «налево, затем направо» здесь была бы ложью.
        let (path, left, right) = jog()
        let cum = TurnBend.cumulative(path)
        let a = try XCTUnwrap(TurnBend.measure(path: path, cumulative: cum, at: left))
        let b = try XCTUnwrap(TurnBend.measure(path: path, cumulative: cum, at: right))
        XCTAssertLessThanOrEqual(a.near, -AppConfig.turnBendMinDegrees, "у точки — как поворот")
        XCTAssertGreaterThanOrEqual(b.near, AppConfig.turnBendMinDegrees)
        XCTAssertFalse(TurnBend.voices(type: "continue", modifier: "left", bend: a, roads: 3))
        XCTAssertFalse(TurnBend.voices(type: "continue", modifier: "right", bend: b, roads: 3))
        XCTAssertLessThan(abs(a.wide), AppConfig.turnBendWideMinDegrees)
        XCTAssertLessThan(abs(b.wide), AppConfig.turnBendWideMinDegrees)
    }

    func testAvenueCurveIsNotABend() throws {
        // Проспект с радиусом 150 м: на 70 м линии — меньше 30°.
        let (path, middle) = curve(radius: 150)
        let cum = TurnBend.cumulative(path)
        let bend = try XCTUnwrap(TurnBend.measure(path: path, cumulative: cum, at: middle))
        XCTAssertLessThan(abs(bend.near), 30)
        XCTAssertFalse(TurnBend.voices(type: "continue", modifier: "left", bend: bend, roads: 3),
                       "изгиб проспекта с примыкающей улицей — не команда")
        // Даже в любой точке дуги.
        for at in stride(from: 300.0, through: 300 + 150 * .pi / 2, by: 10) {
            let b = try XCTUnwrap(TurnBend.bend(path: path, cumulative: cum, at: at))
            XCTAssertLessThan(abs(b), AppConfig.turnBendMinDegrees, "точка \(at)")
        }
    }

    private func m(_ near: Double, _ wide: Double? = nil) -> TurnBend.Measure {
        TurnBend.Measure(near: near, wide: wide ?? near)
    }

    func testRules() {
        XCTAssertTrue(TurnBend.voices(type: "continue", modifier: "left", bend: m(-80), roads: 3))
        XCTAssertFalse(TurnBend.voices(type: "continue", modifier: "left", bend: m(-80), roads: 2),
                       "развилки нет — свернуть некуда, это просто дорога")
        XCTAssertFalse(TurnBend.voices(type: "continue", modifier: "slight left", bend: m(-80), roads: 3),
                       "«чуть левее» — не поворот")
        XCTAssertFalse(TurnBend.voices(type: "continue", modifier: "straight", bend: m(-80), roads: 3))
        XCTAssertFalse(TurnBend.voices(type: "continue", modifier: "right", bend: m(-80), roads: 3),
                       "линия ломается не туда, куда сказал движок — молчим")
        XCTAssertFalse(TurnBend.voices(type: "continue", modifier: "left", bend: m(-40), roads: 3))
        XCTAssertFalse(TurnBend.voices(type: "continue", modifier: "left", bend: m(-80, -30), roads: 3),
                       "широкое окно не подтвердило — ступенька, а не поворот")
        XCTAssertFalse(TurnBend.voices(type: "continue", modifier: "left", bend: m(-80, 38), roads: 3),
                       "широкое окно в другую сторону (Zargaron, Самарканд)")
        XCTAssertFalse(TurnBend.voices(type: "continue", modifier: "left", bend: nil, roads: 3))
        XCTAssertFalse(TurnBend.voices(type: "turn", modifier: "left", bend: m(-90), roads: 3),
                       "turn и так говорится")
    }

    func testWindowOutsideTheRouteGivesNothing() {
        let path = corner(-90)
        let cum = TurnBend.cumulative(path)
        XCTAssertNil(TurnBend.bend(path: path, cumulative: cum, at: 10), "до начала маршрута окна нет")
        XCTAssertNil(TurnBend.bend(path: path, cumulative: cum, at: cum.last! - 5))
    }

    // MARK: - Шаг маршрута

    private func step(_ type: String, _ modifier: String?, name: String, roads: Int,
                      bend: Double?, current: String? = nil) -> RouteStep? {
        let bend = bend.map { TurnBend.Measure(near: $0, wide: $0) }
        let bearings = Array([0, 90, 180, 270].prefix(roads))
        return RouteService.maneuverStep(
            RouteService.OSRMResponse.Step(
                distance: 100, name: name,
                maneuver: RouteService.OSRMResponse.Maneuver(type: type, modifier: modifier, exit: nil),
                intersections: [RouteService.OSRMResponse.Intersection(lanes: nil, bearings: bearings)]),
            at: 500, language: "ru", currentName: current, bend: bend)
    }

    func testContinueOnARealBendIsSpokenAsATurn() throws {
        let built = try XCTUnwrap(step("continue", "left", name: "Seul ko'chasi", roads: 3, bend: -77,
                                       current: "Seul ko'chasi"))
        XCTAssertEqual(built.text, String(localized: "поверните налево"), "своя улица — без названия")
        XCTAssertEqual(built.kind, .left)
        XCTAssertEqual(built.edge, .left, "край ряда — как у поворота")
        XCTAssertEqual(built.voiceAction, .turnLeft)
        let other = try XCTUnwrap(step("new name", "right", name: "Sharq Tongi ko'chasi", roads: 4, bend: 85,
                                       current: "Navbahor ko'chasi"))
        XCTAssertTrue(other.text.hasPrefix(String(localized: "поверните направо")))
        XCTAssertNotEqual(other.text, String(localized: "поверните направо"), "другая улица — называем")
    }

    func testContinueOnACurveStaysSilent() {
        XCTAssertNil(step("continue", "left", name: "Amir Temur shoh ko'chasi", roads: 3, bend: -25))
        XCTAssertNil(step("continue", "left", name: "Amir Temur shoh ko'chasi", roads: 2, bend: -80))
        XCTAssertNil(step("new name", "straight", name: "Navoi ko'chasi", roads: 3, bend: -60))
        XCTAssertNil(step("continue", "left", name: "", roads: 3, bend: nil), "излом не измерен — как до 29.E")
    }

    func testManeuverVertexIsFoundInOrder() {
        let path = corner(-90)
        let target = path[30]
        XCTAssertEqual(RouteService.vertexIndex(of: [target.longitude, target.latitude], in: path, from: 0), 30)
        XCTAssertNil(RouteService.vertexIndex(of: [target.longitude, target.latitude], in: path, from: 31),
                     "назад по линии не ищем")
        XCTAssertNil(RouteService.vertexIndex(of: [0, 0], in: path, from: 0))
    }
}
