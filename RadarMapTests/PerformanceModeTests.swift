//
//  PerformanceModeTests.swift
//  RadarMapTests
//
//  Ступени самоурезания под перегревом. Главное, что здесь проверяется, —
//  порядок приоритетов: под нагрузкой уходят украшения карты, а оповещения
//  остаются. За рулём голос важнее картинки, и это должно быть записано не
//  только в комментарии.
//

import XCTest
@testable import RadarMap

final class PerformanceModeTests: XCTestCase {

    func testThermalStateMapsToMode() {
        XCTAssertEqual(PerformanceMode(thermalState: .nominal), .full)
        XCTAssertEqual(PerformanceMode(thermalState: .fair), .full,
                       "«тёплый» — это норма для телефона в держателе, урезаться рано")
        XCTAssertEqual(PerformanceMode(thermalState: .serious), .reduced)
        XCTAssertEqual(PerformanceMode(thermalState: .critical), .minimal)
    }

    func testModesAreOrdered() {
        XCTAssertLessThan(PerformanceMode.full, .reduced)
        XCTAssertLessThan(PerformanceMode.reduced, .minimal)
    }

    func testBudgetShrinksButNeverToZero() {
        var previous = Int.max
        for mode in [PerformanceMode.full, .reduced, .minimal] {
            let budget = mode.annotationBudget
            XCTAssertLessThan(budget, previous, "каждая ступень должна рисовать меньше")
            // Ноль означал бы пустую карту: камера должна оставаться либо
            // маркером, либо частью посчитанного кластера, но не исчезать.
            XCTAssertGreaterThan(budget, 0, "камера не имеет права просто пропасть")
            previous = budget
        }
        XCTAssertEqual(PerformanceMode.full.annotationBudget, AppConfig.maxVisibleAnnotations,
                       "в норме бюджет обязан совпадать с обычным")
    }

    func testRecomputeGetsRarerUnderHeat() {
        XCTAssertEqual(PerformanceMode.full.recomputeFactor, 1,
                       "в норме поведение карты не меняется вовсе")
        XCTAssertGreaterThan(PerformanceMode.reduced.recomputeFactor, 1)
        XCTAssertGreaterThan(PerformanceMode.minimal.recomputeFactor,
                             PerformanceMode.reduced.recomputeFactor)
    }

    func testDecorationsGoFirst() {
        XCTAssertTrue(PerformanceMode.full.drawsHeatLines)
        XCTAssertFalse(PerformanceMode.reduced.drawsHeatLines,
                       "тепловые линии — украшение, считается по всему треку")
        XCTAssertFalse(PerformanceMode.minimal.drawsHeatLines)
    }

    /// Любая урезанная ступень — нагревом или батареей (12.3) — имеет
    /// причину для плашки: молчаливая деградация читается как поломка.
    func testDegradationIsAlwaysExplained() {
        XCTAssertNil(AutoEconomy.reason(thermal: .full, savingBattery: false), "в норме объяснять нечего")
        for heat in [PerformanceMode.full, .reduced, .minimal] {
            for battery in [false, true] {
                let mode = AutoEconomy.mode(thermal: heat, savingBattery: battery)
                guard mode != .full else { continue }
                XCTAssertNotNil(AutoEconomy.reason(thermal: heat, savingBattery: battery),
                                "молчаливая деградация читается как поломка приложения")
            }
        }
    }
}
