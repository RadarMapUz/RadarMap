//
//  TypeScaleTests.swift
//  RadarMapTests
//
//  Шкала кегля. Было 18 разных размеров на экранах карты — это не иерархия, а
//  след истории: каждый элемент подбирал себе размер на глаз рядом с соседом.
//

import SwiftUI
import UIKit
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

    /// Панель поверх карты: мелкий текст растёт до прежнего потолка 1.30.
    func testDenseSmallTextKeepsTheOldCeiling() {
        XCTAssertEqual(Font.typeFactor(raw: 1.6, size: 12, density: .dense), 1.30, accuracy: 0.001)
        XCTAssertEqual(Font.typeFactor(raw: 3.1, size: 12, density: .dense), 1.30, accuracy: 0.001)
        XCTAssertEqual(Font.typeFactor(raw: 1.2, size: 12, density: .dense), 1.20, accuracy: 0.001)
    }

    /// Крупный на панели — почти нет: цифра скорости и так видна, а карточка
    /// вокруг тесная, и рост на треть выбьет её за пределы.
    func testDenseLargeTextIsHeldBack() {
        for step in Font.typeSteps where step >= 30 {
            XCTAssertEqual(Font.typeFactor(raw: 3.1, size: step, density: .dense), 1.10, accuracy: 0.001)
        }
    }

    /// Множитель системного кегля для категории — как его видит само приложение.
    private func factor(_ category: UIContentSizeCategory) -> Double {
        let traits = UITraitCollection(preferredContentSizeCategory: category)
        return Double(UIFontMetrics(forTextStyle: .body).scaledValue(for: 17, compatibleWith: traits) / 17)
    }

    /// Экран чтения: основной текст (до ступени 19 — туда снапается 17)
    /// растёт до AX3 целиком. Прежние 1.30 гасили accessibility-кегли почти
    /// полностью.
    func testReadingCeilingCoversAX3() {
        let ax3 = factor(.accessibilityExtraExtraLarge)
        XCTAssertGreaterThan(ax3, 2.2, "AX3 — около 40 / 17")
        XCTAssertGreaterThanOrEqual(Font.readingCeiling, ax3)
        for step in Font.typeSteps where step <= 19 {
            XCTAssertEqual(Font.typeFactor(raw: ax3, size: step, density: .reading), ax3, accuracy: 0.001)
        }
    }

    /// AX4–AX5 упираются в потолок чтения: дальше строки списков ломаются.
    func testReadingStopsAtItsCeilingAboveAX3() {
        let ax5 = factor(.accessibilityExtraExtraExtraLarge)
        XCTAssertGreaterThan(ax5, Font.readingCeiling)
        XCTAssertEqual(Font.typeFactor(raw: ax5, size: 12, density: .reading), Font.readingCeiling, accuracy: 0.001)
    }

    /// Панель поверх карты на AX3 растёт заметно меньше экрана чтения.
    func testDenseCeilingIsLowerThanReading() {
        let ax3 = factor(.accessibilityExtraExtraLarge)
        for step in Font.typeSteps {
            XCTAssertLessThan(Font.typeFactor(raw: ax3, size: step, density: .dense),
                              Font.typeFactor(raw: ax3, size: step, density: .reading))
        }
    }

    /// Заголовки на экране чтения растут до 1.70, а между — наклон без ступеньки.
    func testReadingLargeTextGrowsModerately() {
        for step in Font.typeSteps where step >= 38 {
            XCTAssertEqual(Font.typeFactor(raw: 3.1, size: step, density: .reading), 1.70, accuracy: 0.001)
        }
        let ceilings = Font.typeSteps.map { Font.typeFactor(raw: 3.1, size: $0, density: .reading) }
        for (small, large) in zip(ceilings, ceilings.dropFirst()) {
            XCTAssertGreaterThanOrEqual(small, large, "потолок не должен расти с кеглем")
        }
    }

    /// Чтение никогда не растёт меньше панели: иначе разделение теряет смысл.
    func testReadingNeverGrowsLessThanDense() {
        for raw in stride(from: 0.5, through: 3.2, by: 0.05) {
            for step in Font.typeSteps {
                XCTAssertGreaterThanOrEqual(
                    Font.typeFactor(raw: raw, size: step, density: .reading),
                    Font.typeFactor(raw: raw, size: step, density: .dense))
            }
        }
    }

    /// Шкала остаётся шкалой при ЛЮБОМ системном кегле и в обоих контекстах.
    ///
    /// Регрессия, ради которой тест написан: потолок роста переключался
    /// порогом (`size >= 20 ? 1.10 : 1.30`), и на новой шкале эта ступенька
    /// легла ровно между 19 и 24. При максимальном системном кегле они
    /// давали 25 и 26 pt — отношение 1,04, то есть соседние ступени
    /// становились неразличимы. И проявлялось это только у тех, кто увеличил
    /// текст в настройках, — то есть у тех, кому размер важнее всех.
    func testTheScaleSurvivesEverySystemTextSize() {
        let ax1 = factor(.accessibilityMedium)
        for density in [TypeDensity.reading, .dense] {
            // 0.5…3.2 покрывает пол 0.9 и самый крупный accessibility-кегль (53 / 17).
            for raw in stride(from: 0.5, through: 3.2, by: 0.05) {
                // Выше AX1 экран чтения сводит соседние ступени, как и сама
                // iOS (title1 и largeTitle на AX3 — 48 и 52 pt, 1,08), но
                // порядок не теряет.
                let floor = density == .reading && raw > ax1 + 0.001 ? 1.08 : 1.15
                let scaled = Font.typeSteps.map { step in
                    (step * CGFloat(Font.typeFactor(raw: raw, size: step, density: density))).rounded()
                }
                for (small, large) in zip(scaled, scaled.dropFirst()) {
                    XCTAssertGreaterThanOrEqual(large / small, floor,
                        "\(density), кегль ×\(raw): ступени \(small) и \(large) сливаются")
                }
            }
        }
    }

    /// Кто уменьшил текст в системе — тоже человек, но не до нечитаемости.
    func testShrinkingIsAllowedButBounded() {
        XCTAssertEqual(Font.typeFactor(raw: 0.95, size: 12, density: .reading), 0.95, accuracy: 0.001)
        XCTAssertEqual(Font.typeFactor(raw: 0.5, size: 12, density: .dense), 0.9, accuracy: 0.001)
    }

    /// Обычная настройка ничего не меняет — сегодняшний вид остаётся собой.
    func testDefaultSettingChangesNothing() {
        for step in Font.typeSteps {
            XCTAssertEqual(Font.typeFactor(raw: 1, size: step, density: .reading), 1, accuracy: 0.001)
        }
    }
}
