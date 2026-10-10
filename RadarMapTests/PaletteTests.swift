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
//  С 7 октября палитра адаптивная (светлая днём, графит ночью): каждое
//  правило проверяется в ОБЕИХ темах — цвет разрешается под стиль вручную.
//

import SwiftUI
import XCTest
@testable import RadarMap

final class PaletteTests: XCTestCase {

    // MARK: - Измерения

    /// Тема, в которой сейчас меряем (адаптивные токены разрешаются под неё).
    private var style: UIUserInterfaceStyle = .dark

    private func components(_ color: Color) -> (Double, Double, Double) {
        let ui = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
    }

    /// Прогнать проверку в обеих темах.
    private func inBothThemes(_ check: (String) -> Void) {
        for theme in [UIUserInterfaceStyle.light, .dark] {
            style = theme
            check(theme == .light ? "днём" : "ночью")
        }
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

    /// ΔE при дейтеранопии (матрица Machado 2009, полная тяжесть).
    private func deltaEDeutan(_ a: Color, _ b: Color) -> Double {
        func simulated(_ color: Color) -> (Double, Double, Double) {
            let (r0, g0, b0) = components(color)
            let r = linear(r0), g = linear(g0), b = linear(b0)
            let m = [[0.367322, 0.860646, -0.227968],
                     [0.280085, 0.672501, 0.047413],
                     [-0.011820, 0.042940, 0.968881]]
            let out = m.map { min(1, max(0, $0[0] * r + $0[1] * g + $0[2] * b)) }
            let x = (0.4124 * out[0] + 0.3576 * out[1] + 0.1805 * out[2]) / 0.95047
            let y = 0.2126 * out[0] + 0.7152 * out[1] + 0.0722 * out[2]
            let z = (0.0193 * out[0] + 0.1192 * out[1] + 0.9505 * out[2]) / 1.08883
            func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1.0 / 3) : 7.787 * t + 16.0 / 116 }
            return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
        }
        let (l1, a1, b1) = simulated(a), (l2, a2, b2) = simulated(b)
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

    /// Тип камеры → его заливка и глиф на ней (как рисует маркер).
    private var markers: [(String, Color, Color)] {
        [(CameraType.stationaryCamera, "camera"), (.stationaryRadar, "radar"),
         (.intelligentRadar, "intelligent"), (.mobileRadar, "mobile"), (.dpsPost, "post"),
         (.tripod, "tripod")].map { ($0.1, $0.0.tint, $0.0.glyphTint) }
    }

    // MARK: - Правила

    /// Цвет состояния бывает ТЕКСТОМ — он читается и на фоне, и на карточке,
    /// в обеих темах. Порог WCAG AA — 4.5.
    func testStatesAreReadableEverywhere() {
        inBothThemes { theme in
            for (name, colour) in states {
                XCTAssertGreaterThanOrEqual(contrast(colour, Theme.surface), 4.5,
                                            "\(name) не читается на карточке \(theme)")
                XCTAssertGreaterThanOrEqual(contrast(colour, Theme.background), 4.5,
                                            "\(name) не читается на фоне \(theme)")
            }
            for (name, colour) in [("textPrimary", Theme.textPrimary), ("textSecondary", Theme.textSecondary),
                                   ("textTertiary", Theme.textTertiary)] {
                XCTAssertGreaterThanOrEqual(contrast(colour, Theme.surface), 4.5, "\(name) \(theme)")
                XCTAssertGreaterThanOrEqual(contrast(colour, Theme.background), 4.5, "\(name) \(theme)")
            }
        }
    }

    /// Главная кнопка: тёмный текст на жёлтом.
    func testActionButtonIsReadable() {
        inBothThemes { theme in
            XCTAssertGreaterThanOrEqual(contrast(Theme.onAction, Theme.action), 7, theme)
        }
    }

    /// Синяя заливка (карточка манёвра, синие кнопки) несёт БЕЛЫЙ текст в
    /// обеих темах. Ради этого заливка — отдельный токен: ночной `accent`
    /// светлый, и белое на нём читалось бы 2,4:1.
    func testFilledAccentCarriesWhiteText() {
        inBothThemes { theme in
            XCTAssertGreaterThanOrEqual(contrast(Theme.onAccentFill, Theme.accentFill), 4.5,
                                        "белый на синей заливке \(theme)")
            XCTAssertGreaterThanOrEqual(contrast(Theme.onAccentFillSecondary, Theme.accentFill), 4.5,
                                        "вторая строка на синей заливке \(theme)")
        }
    }

    /// Маршрут — не «в норме». Он был зелёным, и «твой путь» красился тем же
    /// цветом, что «в лимите»; теперь синий, и это держит тест.
    func testRouteIsNotTheSuccessColour() {
        inBothThemes { theme in
            XCTAssertGreaterThanOrEqual(deltaE(Theme.route, Theme.success), 40,
                                        "маршрут сливается с «в норме» \(theme)")
        }
    }

    /// Маркер камеры на линии маршрута читается отдельно от неё.
    func testMarkersStandOutOnTheRoute() {
        inBothThemes { theme in
            for (name, type) in types {
                XCTAssertGreaterThanOrEqual(deltaE(type, Theme.route), 25,
                                            "маркер \(name) тонет в линии маршрута \(theme)")
            }
        }
    }

    /// Значок на маркере читается: белый на тёмных заливках, тёмный на радаре.
    func testMarkerGlyphsAreReadable() {
        inBothThemes { theme in
            for (name, fill, glyph) in markers {
                XCTAssertGreaterThanOrEqual(contrast(glyph, fill), 4.5, "значок на \(name) \(theme)")
            }
        }
    }

    /// Состояния различимы между собой — иначе цвет ничего не кодирует.
    func testStatesAreDistinguishableFromEachOther() {
        inBothThemes { theme in
            for i in states.indices {
                for j in states.indices where j > i {
                    XCTAssertGreaterThanOrEqual(deltaE(states[i].1, states[j].1), 40,
                        "\(states[i].0) и \(states[j].0) слишком близки \(theme)")
                }
            }
        }
    }

    /// Маркер не должен читаться элементом интерфейса.
    ///
    /// Пост ДПС когда-то отстоял от `accent` на ΔE 12, а в первом наброске
    /// новой палитры так же сел «интеллектуальный» синий — маркер выглядел
    /// кнопкой. Красная «камера» намеренно близка к `danger` (язык Яндекс
    /// Навигатора: камера красная); тревогу несёт ореол и размер маркера,
    /// а не его заливка, поэтому с состояниями тип сверяется только по
    /// цвету интерфейса.
    func testTypesDoNotLookLikeInterface() {
        inBothThemes { theme in
            for (name, type) in types {
                XCTAssertGreaterThanOrEqual(deltaE(type, Theme.accent), 25,
                    "тип \(name) читается как элемент интерфейса \(theme)")
            }
        }
    }

    /// Типы различимы между собой — и при дейтеранопии (у ~6 % водителей).
    /// Камера и радар разведены СВЕТЛОТОЙ, поэтому не сливаются и тогда.
    func testTypesAreDistinguishableFromEachOther() {
        inBothThemes { theme in
            for i in types.indices {
                for j in types.indices where j > i {
                    XCTAssertGreaterThanOrEqual(deltaE(types[i].1, types[j].1), 25,
                        "типы \(types[i].0) и \(types[j].0) слишком близки \(theme)")
                    XCTAssertGreaterThanOrEqual(deltaEDeutan(types[i].1, types[j].1), 15,
                        "типы \(types[i].0) и \(types[j].0) сливаются при дейтеранопии \(theme)")
                }
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
