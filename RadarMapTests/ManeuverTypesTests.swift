//
//  ManeuverTypesTests.swift
//  RadarMapTests
//
//  Все типы манёвров OSRM v5 (76): кольцо без номера съезда не выдумывает
//  «1-й», малое кольцо — поворот, съезд налево — стрелка налево, служебные
//  шаги молчат.
//

import XCTest
@testable import RadarMap

final class ManeuverTypesTests: XCTestCase {

    private func step(_ type: String, _ modifier: String? = nil, exit: Int? = nil) -> RouteStep? {
        RouteService.maneuverStep(
            RouteService.OSRMResponse.Step(
                distance: 100, name: "",
                maneuver: RouteService.OSRMResponse.Maneuver(type: type, modifier: modifier, exit: exit)),
            at: 500, language: "ru")
    }

    func testRoundaboutWithoutExitHasNoInventedNumber() throws {
        for type in ["roundabout", "rotary"] {
            let ring = try XCTUnwrap(step(type, "right"))
            XCTAssertEqual(ring.text, String(localized: "въезжайте на кольцо"), type)
            XCTAssertEqual(ring.kind, .roundabout)
            XCTAssertNil(ring.voiceAction, "записанного «N-й съезд» без номера нет — синтезатор")
        }
    }

    func testRoundaboutWithExitNamesIt() throws {
        let ring = try XCTUnwrap(step("roundabout", "right", exit: 2))
        XCTAssertEqual(ring.text, String(format: String(localized: "на кольце %lld-й съезд"), 2))
        XCTAssertEqual(ring.voiceAction, .roundabout(exit: 2))
    }

    func testSmallRoundaboutIsReadAsTurn() throws {
        let turn = try XCTUnwrap(step("roundabout turn", "right"))
        XCTAssertEqual(turn.text, String(localized: "поверните направо"))
        XCTAssertEqual(turn.kind, .right)
        XCTAssertEqual(turn.icon, "arrow.turn.up.right")
        XCTAssertEqual(turn.voiceAction, .turnRight)
        XCTAssertEqual(turn.edge, .right)
    }

    func testRampIconFollowsItsSide() {
        XCTAssertEqual(step("off ramp", "slight left")?.icon, "arrow.up.left")
        XCTAssertEqual(step("off ramp", "slight right")?.icon, "arrow.up.right")
        XCTAssertEqual(step("on ramp", "left")?.icon, "arrow.up.left")
        XCTAssertEqual(step("ramp", "right")?.text, String(localized: "сверните на съезд"))
    }

    func testServiceStepsStaySilent() {
        for type in ["depart", "exit roundabout", "exit rotary", "use lane", "notification", "new name"] {
            XCTAssertNil(step(type, "straight"), type)
        }
    }

    func testEndOfRoadAndForkSpeak() {
        XCTAssertEqual(step("end of road", "left")?.text, String(localized: "поверните налево"))
        XCTAssertEqual(step("fork", "slight right")?.text, String(localized: "держитесь правее"))
        XCTAssertEqual(step("merge", "slight left")?.text, String(localized: "перестройтесь в поток"))
        XCTAssertEqual(step("continue", "uturn")?.kind, .uturn)
    }

    /// Каждый тип OSRM v5 с каждым модификатором разбирается без сюрпризов:
    /// озвученный шаг всегда с непустой фразой и иконкой.
    func testEveryOSRMTypeIsHandled() {
        let types = ["turn", "new name", "depart", "arrive", "merge", "ramp", "on ramp", "off ramp", "fork",
                     "end of road", "use lane", "continue", "roundabout", "rotary", "roundabout turn",
                     "notification", "exit roundabout", "exit rotary"]
        let modifiers = ["uturn", "sharp right", "right", "slight right", "straight", "slight left", "left",
                         "sharp left", nil]
        for type in types {
            for modifier in modifiers {
                guard let built = step(type, modifier) else { continue }
                XCTAssertFalse(built.text.isEmpty, "\(type)/\(modifier ?? "-")")
                XCTAssertFalse(built.icon.isEmpty, "\(type)/\(modifier ?? "-")")
            }
        }
    }
}
