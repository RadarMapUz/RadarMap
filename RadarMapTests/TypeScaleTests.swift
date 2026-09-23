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

    /// Рабочие кегли карточек — движение на пункт, как и было.
    func testCommonSizesMoveByAtMostOnePoint() {
        XCTAssertEqual(Font.snapType(11), 12)
        XCTAssertEqual(Font.snapType(13), 12)
        XCTAssertEqual(Font.snapType(14), 15)
        XCTAssertEqual(Font.snapType(16), 15)
        XCTAssertEqual(Font.snapType(18), 19)
        XCTAssertEqual(Font.snapType(19), 19)
    }

    /// На равном расстоянии — вверх. За рулём крупнее безопаснее мельче.
    func testTiesRoundUp() {
        XCTAssertEqual(Font.snapType(17), 19)   // до 15 и до 19 по два
        XCTAssertEqual(Font.snapType(34), 38)   // до 30 и до 38 по четыре
    }

    /// Мельче двенадцати интерфейса НЕТ.
    ///
    /// Прежняя шкала начиналась с десяти, и на десятке жили 46 подписей. Это
    /// не экономия места: подпись, которую не прочесть на ходу, занимает место
    /// и не отдаёт ничего. Нижняя ступень поднята, и ниже неё не попасть
    /// никаким числом.
    func testNothingIsSmallerThanTwelve() {
        for size in stride(from: CGFloat(1), through: 12, by: 0.5) {
            XCTAssertEqual(Font.snapType(size), 12, "кегль \(size) ушёл ниже двенадцати")
        }
        XCTAssertFalse(Font.typeSteps.contains(10))
    }

    /// У героя есть куда вырасти.
    ///
    /// Прежний потолок 30 схлопывал всё выше себя: заголовок онбординга (44) и
    /// число в плитке метрики (28) выходили одного размера, хотя разницу
    /// закладывали трижды. Тест сторожит именно это — крупное обязано
    /// отличаться от просто большого.
    func testHeroSizesStayApartFromLargeOnes() {
        XCTAssertEqual(Font.snapType(44), 46)
        XCTAssertEqual(Font.snapType(28), 30)
        XCTAssertNotEqual(Font.snapType(44), Font.snapType(28))
        // Отношение «самое крупное / обычное» — не меньше трёх с половиной.
        let ratio = (Font.typeSteps.last ?? 1) / (Font.typeSteps.first ?? 1)
        XCTAssertGreaterThan(ratio, 3.5)
    }

    /// Ступеней стало меньше, а не больше: минимализм здесь измерим.
    func testTheScaleStaysShort() {
        XCTAssertLessThanOrEqual(Font.typeSteps.count, 7)
        // И каждая ступень отличается от соседней ЗАМЕТНО — не на пункт.
        // Прежние 15 и 17 давали 1,13: такую разницу глаз читает не как
        // замысел, а как небрежность.
        for (small, large) in zip(Font.typeSteps, Font.typeSteps.dropFirst()) {
            XCTAssertGreaterThanOrEqual(large / small, 1.2,
                                        "ступени \(small) и \(large) неразличимы на глаз")
        }
    }

    /// За краями шкалы — её края, а не экстраполяция.
    func testOutOfRangeClampsToTheEnds() {
        XCTAssertEqual(Font.snapType(4), 12)
        XCTAssertEqual(Font.snapType(9), 12)
        XCTAssertEqual(Font.snapType(60), 46)
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
