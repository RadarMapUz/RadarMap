//
//  ChoiceRelabelGateTests.swift
//  RadarMapTests
//
//  Ярлыки вариантов на поздних данных (решение 28.10): до касания панели
//  выбора — за данными (и наш выбор вместе с «Быстрым»), после касания —
//  заморожены, выбор водителя сам не меняется никогда.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class ChoiceRelabelGateTests: XCTestCase {

    private func input(minutes: Double, cameras: Int = 0) -> RouteChoice.Input {
        let a = CLLocationCoordinate2D(latitude: 41.30, longitude: 69.24)
        let b = CLLocationCoordinate2D(latitude: 41.34, longitude: 69.28)
        return RouteChoice.Input(path: [a, b], distance: 6_000, travelTime: minutes * 60,
                                 cameraIDs: Array(0..<cameras), hardManeuvers: nil)
    }

    /// Профиль пришёл поздно: первый вариант на 26 мин по графу оказался 34 мин,
    /// второй — 27. До касания «Быстрый» и выбор переезжают на второй.
    func testUntouchedChoiceFollowsLateTraffic() throws {
        let early = RouteChoice.decide([input(minutes: 24), input(minutes: 27)], history: nil)
        XCTAssertEqual(early.recommended, 0)
        XCTAssertTrue(early.assessments[0].labels.contains(.fastest))
        let late = RouteChoice.decide([input(minutes: 34), input(minutes: 27)], history: nil)
        var gate = ChoiceRelabelGate()
        gate.shown()
        let fresh = try XCTUnwrap(gate.relabel(late, variantCount: 2))
        XCTAssertEqual(fresh.selected, 1)
        XCTAssertTrue(fresh.assessments[1].labels.contains(.fastest))
        XCTAssertFalse(fresh.assessments[0].labels.contains(.fastest))
    }

    func testTouchFreezesLabelsAndTheDriversChoice() {
        let late = RouteChoice.decide([input(minutes: 34), input(minutes: 27)], history: nil)
        var gate = ChoiceRelabelGate()
        gate.shown()
        gate.touch()
        XCTAssertNil(gate.relabel(late, variantCount: 2), "водитель коснулся — ярлыки и выбор не двигаются")
        // Новый набор (новая цель, перестроение с вариантами) — снова до касания.
        gate.shown()
        XCTAssertNotNil(gate.relabel(late, variantCount: 2))
    }

    func testNothingToRelabelWithOneVariantOrAMismatch() {
        var gate = ChoiceRelabelGate()
        gate.shown()
        let single = RouteChoice.decide([input(minutes: 30)], history: nil)
        XCTAssertNil(gate.relabel(single, variantCount: 1), "один вариант — выбирать не из чего")
        let pair = RouteChoice.decide([input(minutes: 34), input(minutes: 27)], history: nil)
        XCTAssertNil(gate.relabel(pair, variantCount: 3), "набор сменился, пока считали")
    }
}
