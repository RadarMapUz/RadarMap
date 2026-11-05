//
//  ItogiIconsTests.swift
//  RadarMapTests
//
//  Значки «Итогов» (34b): только системные SF Symbols, все существуют, без
//  повторов в словаре и без «одного смысла двумя символами» в главных строках.
//  Доступность на iOS 18 (минимум приложения) проверена по
//  name_availability.plist при подборе: все символы — не новее iOS 17.
//

import UIKit
import XCTest
@testable import RadarMap

final class ItogiIconsTests: XCTestCase {

    func testEverySymbolExists() {
        for name in Icon.itogiSymbols {
            XCTAssertNotNil(UIImage(systemName: name), "нет символа \(name)")
        }
    }

    func testVocabularyHasNoDuplicates() {
        XCTAssertEqual(Set(Icon.itogiSymbols).count, Icon.itogiSymbols.count)
    }

    /// Один смысл — один символ: штраф, поездки, пробки и камера не делят
    /// значок ни с чем другим в разделе.
    func testMainConceptsAreDistinct() {
        let concepts = [Icon.fines, Icon.trips, Icon.trafficLayer, Icon.cameras, Icon.maintenance,
                        Icon.shifts, Icon.community, Icon.lifetime, Icon.archive, Icon.goal,
                        Icon.overLimit, Icon.smoothness, Icon.byTrips, Icon.byDays]
        XCTAssertEqual(Set(concepts).count, concepts.count)
    }

    /// Глифы трёх состояний проезда — из словаря раздела и все разные:
    /// форма значка — второй носитель состояния рядом с цветом (дейтеранопия).
    func testVerdictSymbolsAreInVocabulary() {
        let states: [PassVerdict] = [.clean, .edge, .over, .unknown]
        for state in states {
            XCTAssertTrue(Icon.itogiSymbols.contains(state.symbol), "\(state) → \(state.symbol)")
        }
        XCTAssertEqual(Set(states.map(\.symbol)).count, states.count)
    }
}
