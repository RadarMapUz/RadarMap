//
//  PaletteTests.swift
//  RadarMapTests
//
//  Палитра под замером, а не под честное слово.
//
//  Тема объявляет два правила: цвет кодирует СОСТОЯНИЕ, а тип объекта —
//  глиф, и «приглушённое семейство типов не спорит с состояниями». Правила
//  верные, но до сих пор их соблюдение держалось на внимательности: цвет
//  поста ДПС и акцент разошлись до ΔE = 12 (то есть сошлись), и заметить это
//  глазом было нельзя — оба голубые, отличаются яркостью.
//
//  Здесь считается ΔE в CIELAB и контраст по WCAG. Числа приблизительные
//  (ΔE76, D65, sRGB), но для вопроса «эти два цвета различимы?» их хватает:
//  ошибка метрики — единицы, а ловим мы разрывы в десятки.
//

import SwiftUI
import XCTest
@testable import RadarMap

final class PaletteTests: XCTestCase {

    // MARK: - Измерения

    private func components(_ color: Color) -> (Double, Double, Double) {
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
    }

    private func linear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private func luminance(_ color: Color) -> Double {
        let (r, g, b) = components(color)
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    private func contrast(_ a: Color, _ b: Color) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private func lab(_ color: Color) -> (Double, Double, Double) {
        let (r0, g0, b0) = components(color)
        let r = linear(r0), g = linear(g0), b = linear(b0)
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1.0 / 3) : 7.787 * t + 16.0 / 116 }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    private func deltaE(_ a: Color, _ b: Color) -> Double {
        let (l1, a1, b1) = lab(a), (l2, a2, b2) = lab(b)
        return ((l1 - l2) * (l1 - l2) + (a1 - a2) * (a1 - a2) + (b1 - b2) * (b1 - b2)).squareRoot()
    }

    // MARK: - Наборы

    private var states: [(String, Color)] {
        [("accent", Theme.accent), ("warning", Theme.warning),
         ("danger", Theme.danger), ("success", Theme.success)]
    }

    private var types: [(String, Color)] {
        [("camera", Theme.Types.camera), ("radar", Theme.Types.radar),
         ("intelligent", Theme.Types.intelligent), ("mobile", Theme.Types.mobile),
         ("post", Theme.Types.post)]
    }

    // MARK: - Правила

    /// Всё, что несёт смысл, читается на карточке. Порог WCAG AA — 4.5.
    func testEveryMeaningfulColourIsReadableOnSurface() {
        for (name, colour) in states + types {
            XCTAssertGreaterThanOrEqual(contrast(colour, Theme.surface), 4.5,
                                        "\(name) не читается на карточке")
        }
    }

    /// Состояния различимы между собой — иначе цвет ничего не кодирует.
    func testStatesAreDistinguishableFromEachOther() {
        for i in states.indices {
            for j in states.indices where j > i {
                XCTAssertGreaterThanOrEqual(deltaE(states[i].1, states[j].1), 40,
                    "\(states[i].0) и \(states[j].0) слишком близки")
            }
        }
    }

    /// ГЛАВНОЕ правило темы: тип объекта не должен читаться как состояние.
    ///
    /// Именно оно и было нарушено: `Types.post` отстоял от `accent` на 12
    /// единиц, то есть маркер поста ДПС выглядел элементом интерфейса.
    /// Порог 25 — это «видно, что цвета разные», а не «похожи, но не совсем».
    func testTypesDoNotCollideWithStates() {
        for (typeName, type) in types {
            for (stateName, state) in states {
                XCTAssertGreaterThanOrEqual(deltaE(type, state), 25,
                    "тип \(typeName) читается как состояние \(stateName)")
            }
        }
    }

    /// Типы различимы и между собой: иначе «другой вид точки» не считывается.
    func testTypesAreDistinguishableFromEachOther() {
        for i in types.indices {
            for j in types.indices where j > i {
                XCTAssertGreaterThanOrEqual(deltaE(types[i].1, types[j].1), 25,
                    "типы \(types[i].0) и \(types[j].0) слишком близки")
            }
        }
    }

    /// Красный и зелёный при дейтеранопии СЛИВАЮТСЯ, и это не лечится
    /// палитрой: уводя `success` к бирюзе, мы сажаем его на `accent`.
    ///
    /// Тест не требует невозможного — он фиксирует, что проблема существует,
    /// и тем самым объясняет, почему у состояния есть второй носитель
    /// (`Theme.symbol`). Если однажды палитру всё же разведут, тест упадёт и
    /// напомнит проверить, нужен ли ещё глиф.
    func testRedAndGreenNeedTheSecondCarrier() {
        XCTAssertLessThan(deltaE(Theme.danger, Theme.success), 200)
        // Второй носитель обязан существовать и различать состояния ФОРМОЙ.
        XCTAssertNotNil(Theme.symbol(.alarm))
        XCTAssertNotNil(Theme.symbol(.attention))
        XCTAssertNotEqual(Theme.symbol(.alarm), Theme.symbol(.attention))
        // У нормы значка нет: вечная галочка превращается в фон.
        XCTAssertNil(Theme.symbol(.normal))
        XCTAssertNil(Theme.symbol(.neutral))
    }

    /// Цвет и глиф говорят одно и то же — иначе второй носитель врёт.
    func testColourAndGlyphAgree() {
        // 66 при лимите 60 — штраф заработан.
        XCTAssertEqual(PassStyle.level(speed: 66, limit: 60), .alarm)
        XCTAssertEqual(PassStyle.symbol(speed: 66, limit: 60), Theme.symbol(.alarm))
        XCTAssertEqual(PassStyle.color(speed: 66, limit: 60), Theme.danger)
        // 58 при лимите 60 — чисто, значка нет.
        XCTAssertEqual(PassStyle.level(speed: 58, limit: 60), .normal)
        XCTAssertNil(PassStyle.symbol(speed: 58, limit: 60))
    }
}
