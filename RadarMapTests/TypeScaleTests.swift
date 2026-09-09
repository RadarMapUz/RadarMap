//
//  TypeScaleTests.swift
//  RadarMapTests
//
//  Шкала кегля. Было 18 разных размеров на экранах карты — это не иерархия, а
//  след истории: каждый элемент подбирал себе размер на глаз рядом с соседом.
//

import SwiftUI
import XCTest
@testable import RadarMap

final class TypeScaleTests: XCTestCase {

    /// Ступень остаётся собой — иначе шкала «плыла» бы при каждом проходе.
    func testEveryStepIsItsOwnFixedPoint() {
        for step in Font.typeSteps {
            XCTAssertEqual(Font.snapType(step), step)
        }
    }

    /// Любой размер попадает НА шкалу, а не рядом с ней.
    func testAnySizeLandsOnTheScale() {
        for size in stride(from: CGFloat(4), through: 60, by: 0.5) {
            XCTAssertTrue(Font.typeSteps.contains(Font.snapType(size)),
                          "кегль \(size) ушёл мимо шкалы")
        }
    }

    /// Соседние ступени — те, что были в коде чаще всего; движение на пункт.
    func testCommonSizesMoveByAtMostOnePoint() {
        XCTAssertEqual(Font.snapType(11), 12)
        XCTAssertEqual(Font.snapType(13), 12)
        XCTAssertEqual(Font.snapType(14), 15)
        XCTAssertEqual(Font.snapType(18), 17)
        XCTAssertEqual(Font.snapType(19), 20)
        XCTAssertEqual(Font.snapType(23), 22)
    }

    /// На равном расстоянии — вверх. За рулём крупнее безопаснее мельче.
    func testTiesRoundUp() {
        XCTAssertEqual(Font.snapType(16), 17)   // до 15 и до 17 по пункту
        XCTAssertEqual(Font.snapType(21), 22)   // до 20 и до 22 по пункту
    }

    /// За краями шкалы — её края, а не экстраполяция.
    func testOutOfRangeClampsToTheEnds() {
        XCTAssertEqual(Font.snapType(4), 10)
        XCTAssertEqual(Font.snapType(9), 10)
        XCTAssertEqual(Font.snapType(48), 30)
    }

    // MARK: - Системное «Размер текста» (Д2)

    /// Мелкий текст растёт полностью — он и есть нечитаемый.
    func testSmallTextGrowsToTheFullCeiling() {
        XCTAssertEqual(Font.typeFactor(raw: 1.6, size: 12), 1.30, accuracy: 0.001)
        XCTAssertEqual(Font.typeFactor(raw: 1.2, size: 12), 1.20, accuracy: 0.001)
    }

    /// Крупный — почти нет: цифра скорости и так видна, а карточка вокруг
    /// тесная, и рост на треть выбьет её за пределы.
    func testLargeTextIsHeldBack() {
        XCTAssertEqual(Font.typeFactor(raw: 1.6, size: 30), 1.10, accuracy: 0.001)
        XCTAssertEqual(Font.typeFactor(raw: 1.6, size: 20), 1.10, accuracy: 0.001)
    }

    /// Кто уменьшил текст в системе — тоже человек, но не до нечитаемости.
    func testShrinkingIsAllowedButBounded() {
        XCTAssertEqual(Font.typeFactor(raw: 0.95, size: 12), 0.95, accuracy: 0.001)
        XCTAssertEqual(Font.typeFactor(raw: 0.5, size: 12), 0.9, accuracy: 0.001)
    }

    /// Обычная настройка ничего не меняет — сегодняшний вид остаётся собой.
    func testDefaultSettingChangesNothing() {
        for step in Font.typeSteps {
            XCTAssertEqual(Font.typeFactor(raw: 1, size: step), 1, accuracy: 0.001)
        }
    }
}
