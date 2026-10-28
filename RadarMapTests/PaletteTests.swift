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

    /// Заливки значков (29.C2): камера — одна на все типы камер; пост и ДТП.
    private var types: [(String, Color)] {
        [("camera", Theme.Types.camera), ("post", Theme.Types.post), ("accident", Theme.Types.accident)]
    }

    /// Тип камеры → его заливка и глиф на ней (как рисует маркер). С 29.C —
    /// и ДТП с «прочим»: у них тоже значок «Монета» с белым глифом.
    private var markers: [(String, Color, Color)] {
        [(CameraType.stationaryCamera, "camera"), (.stationaryRadar, "radar"),
         (.intelligentRadar, "intelligent"), (.mobileRadar, "mobile"), (.dpsPost, "post"),
         (.tripod, "tripod"), (.accident, "accident"), (.other(""), "other")]
            .map { ($0.1, $0.0.tint, $0.0.glyphTint) }
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

    /// Белый текст на красной и зелёной заливке («Стоп», «Завершить поездку»,
    /// «Да»/«Нет» на приборке) читается в обеих темах. Ночные `danger` и
    /// `success` светлые, белое на них было 2,2–2,6:1 — поэтому заливки свои.
    func testStateFillsCarryWhiteText() {
        inBothThemes { theme in
            XCTAssertGreaterThanOrEqual(contrast(Color.white, Theme.dangerFill), 4.5,
                                        "белый на красной заливке \(theme)")
            XCTAssertGreaterThanOrEqual(contrast(Color.white, Theme.successFill), 4.5,
                                        "белый на зелёной заливке \(theme)")
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
    /// С 29.C2 их три: камера, пост ДПС, ДТП. Камера и ДТП — оба красные
    /// намеренно (красный = опасность впереди) и различаются ГЛИФОМ — это
    /// держит CameraGlyphTests.testGlyphsAreDistinguishableBySilhouette;
    /// цветом от них обоих отличается пост.
    func testTypesAreDistinguishableFromEachOther() {
        inBothThemes { theme in
            for i in types.indices {
                for j in types.indices where j > i && !(types[i].0 == "camera" && types[j].0 == "accident") {
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

    // MARK: - Знаки-иконки (IconBadge, 12.10)

    /// Глиф знака — не текст, но его ищут глазом: ≥ 3:1 и на карточке, и на
    /// собственной плашке (14 % того же цвета поверх карточки), в обеих темах.
    func testIconTintsAreReadable() {
        let tints: [(String, Color)] = [
            ("time", Theme.Icon.time), ("distance", Theme.Icon.distance), ("speed", Theme.Icon.speed),
            ("money", Theme.Icon.money), ("rating", Theme.Icon.rating), ("camera", Theme.Icon.camera),
            ("home", Theme.Icon.home), ("work", Theme.Icon.work), ("streak", Theme.Icon.streak),
        ]
        inBothThemes { theme in
            for (name, tint) in tints {
                XCTAssertGreaterThanOrEqual(contrast(tint, Theme.surface), 3, "\(name) на карточке, \(theme)")
            }
        }
    }
}

// MARK: - «Строгий навигатор» (31D, 27.10)

extension PaletteTests {

    /// Красный — только камера (и штраф). Ни выделение, ни заливка, ни один
    /// значок-смысл, кроме камеры, не читается её красным. Прежняя «серия»
    /// (#C2410C) стояла от камеры на ΔE 15 — значок серии выглядел камерой.
    func testOnlyTheCameraIsRed() {
        let others: [(String, Color)] = [
            ("accent", Theme.accent), ("accentFill", Theme.accentFill), ("action", Theme.action),
            ("time", Theme.Icon.time), ("distance", Theme.Icon.distance), ("speed", Theme.Icon.speed),
            ("money", Theme.Icon.money), ("rating", Theme.Icon.rating), ("home", Theme.Icon.home),
            ("work", Theme.Icon.work), ("streak", Theme.Icon.streak), ("route", Theme.route),
            ("settingsTile", Theme.settingsTile),
        ]
        inBothThemes { theme in
            for (name, colour) in others {
                XCTAssertGreaterThanOrEqual(deltaE(colour, Theme.Types.camera), 25,
                                            "\(name) читается красным камеры \(theme)")
            }
        }
    }

    /// Плитка раздела настроек — графит под белым символом, ≥ 4,5:1.
    func testSettingsTileCarriesWhiteGlyph() {
        inBothThemes { theme in
            XCTAssertGreaterThanOrEqual(contrast(Color.white, Theme.settingsTile), 4.5, theme)
        }
    }

    /// Нейтральная плашка под значком и текстом: цвет смысла поверх неё
    /// читается так же, как на карточке (≥ 4,5:1, обе темы). Плашка — чернила
    /// с прозрачностью, поэтому меряем её смешанной с карточкой.
    func testQuietFillKeepsTextReadable() {
        inBothThemes { theme in
            let traits = UITraitCollection(userInterfaceStyle: style)
            let ink = UIColor(Theme.quietFill).resolvedColor(with: traits)
            let card = UIColor(Theme.surface).resolvedColor(with: traits)
            var ir: CGFloat = 0, ig: CGFloat = 0, ib: CGFloat = 0, ia: CGFloat = 0
            var cr: CGFloat = 0, cg: CGFloat = 0, cb: CGFloat = 0, ca: CGFloat = 0
            ink.getRed(&ir, green: &ig, blue: &ib, alpha: &ia)
            card.getRed(&cr, green: &cg, blue: &cb, alpha: &ca)
            let plate = Color(uiColor: UIColor(red: cr * (1 - ia) + ir * ia, green: cg * (1 - ia) + ig * ia,
                                               blue: cb * (1 - ia) + ib * ia, alpha: 1))
            for (name, colour) in [("textPrimary", Theme.textPrimary), ("textSecondary", Theme.textSecondary),
                                   ("textTertiary", Theme.textTertiary), ("accent", Theme.accent),
                                   ("danger", Theme.danger), ("warning", Theme.warning),
                                   ("success", Theme.success)] {
                XCTAssertGreaterThanOrEqual(contrast(colour, plate), 4.5, "\(name) на плашке \(theme)")
            }
        }
    }

    /// Свой синий: интерфейс и линия маршрута днём — один азурный тон, а не
    /// два соседних синих (31D). Ночью линия светлее, но того же рода.
    func testRouteIsTheInterfaceBlueByDay() {
        style = .light
        XCTAssertLessThan(deltaE(Theme.route, Theme.accent), 3)
        style = .dark
        XCTAssertLessThan(deltaE(Theme.route, Theme.accent), 10)
    }
}

// MARK: - Линия маршрута «богаче» (25.D, 21.10)

extension PaletteTests {

    /// Полотно дороги новой карты — server/omt/make_style.py PALETTES
    /// (road, road_trunk, road_secondary, road_tertiary, minor, затем то же
    /// полотно вблизи near_primary, near_trunk, near_secondary,
    /// near_tertiary, near_minor) и фон, по темам; test_palette_check
    /// сверяет копию с генератором. С 28.A («Чистый»): днём улицы и
    /// проспекты белые, тёплая только магистраль, ночью нейтральный графит,
    /// светлее с каждым классом. С 28.L днём вблизи (с z15–16) размеченное
    /// полотно — светло-серый асфальт под белой краской, магистраль темнее.
    private func asphalt(_ theme: String) -> [Color] {
        let hex: [UInt32] = theme == "днём"
            ? [0xFFFFFF, 0xFFE2A8, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF,
               0xD2D6DD, 0xECD096, 0xD2D6DD, 0xD2D6DD, 0xFFFFFF, 0xF2F3F5]
            : [0x40454F, 0x626874, 0x383C45, 0x33373F, 0x30343C,
               0x40454F, 0x626874, 0x383C45, 0x33373F, 0x30343C, 0x16181C]
        return hex.map { Color(uiColor: Theme.rgb($0)) }
    }

    /// Линия отделяется от полотна телом или каймой — не ниже 3:1 (линия —
    /// графический объект, WCAG 1.4.11). Белая кайма днём держала 1,4–2,1:1
    /// и линия на светлом проспекте читалась «синей ниткой».
    func testRouteStandsOutOnTheAsphalt() {
        inBothThemes { theme in
            for road in asphalt(theme) {
                let best = max(contrast(Theme.route, road), contrast(Theme.routeCasing, road))
                XCTAssertGreaterThanOrEqual(best, 3, "линия маршрута на полотне \(theme)")
            }
        }
    }

    /// Другой вариант маршрута при выборе (27.D): бледнее выбранного, но на
    /// полотне любого класса читается (≥ 3:1 телом или каймой), отличим от
    /// выбранного и при дейтеранопии и не похож ни на пробку, ни на пройденное.
    func testAlternativeRouteIsPaleButReadable() {
        inBothThemes { theme in
            for road in asphalt(theme) {
                let best = max(contrast(Theme.routeAlternative, road), contrast(Theme.routeAlternativeCasing, road))
                XCTAssertGreaterThanOrEqual(best, 3, "другой вариант на полотне \(theme)")
            }
            XCTAssertGreaterThanOrEqual(deltaE(Theme.routeAlternative, Theme.route), 25, "вариант ≠ выбранный \(theme)")
            XCTAssertGreaterThanOrEqual(deltaEDeutan(Theme.routeAlternative, Theme.route), 25,
                                        "вариант ≠ выбранный, дейтеранопия \(theme)")
            XCTAssertGreaterThanOrEqual(deltaE(Theme.routeAlternative, Theme.routeJam), 40, "вариант ≠ пробка \(theme)")
            XCTAssertGreaterThanOrEqual(deltaE(Theme.routeAlternative, Theme.routeSlow), 40, "вариант ≠ медленно \(theme)")
            XCTAssertGreaterThanOrEqual(deltaE(Theme.routeAlternative, Theme.routeTraveled), 15,
                                        "вариант ≠ пройденное \(theme)")
        }
    }

    /// Пройденное — бледнее и заметно другим цветом: не путается с «впереди».
    func testTraveledIsPalerThanTheRouteAhead() {
        inBothThemes { theme in
            XCTAssertGreaterThanOrEqual(deltaE(Theme.routeTraveled, Theme.route), 25, "пройденное \(theme)")
        }
    }

    /// Пробка и «медленно» на линии — не синий маршрут и не одно и то же;
    /// и отличимы от каймы линии, внутри которой лежат.
    func testTrafficOnTheRouteIsItsOwnColour() {
        inBothThemes { theme in
            XCTAssertGreaterThanOrEqual(deltaE(Theme.routeJam, Theme.route), 40, "пробка ≠ маршрут \(theme)")
            XCTAssertGreaterThanOrEqual(deltaE(Theme.routeSlow, Theme.route), 40, "медленно ≠ маршрут \(theme)")
            XCTAssertGreaterThanOrEqual(deltaE(Theme.routeSlow, Theme.routeJam), 25, "медленно ≠ пробка \(theme)")
            // Внутри каймы цвет пробки читается оттенком, а не яркостью.
            XCTAssertGreaterThanOrEqual(deltaE(Theme.routeJam, Theme.routeCasing), 40, "пробка на кайме \(theme)")
            XCTAssertGreaterThanOrEqual(deltaE(Theme.routeSlow, Theme.routeCasing), 40, "медленно на кайме \(theme)")
        }
    }

    /// Стрелка направления — белый шеврон с каймой линии: держится на любом
    /// цвете под ним, потому что контраст несёт её собственный край.
    func testRouteArrowCarriesItsOwnEdge() {
        let arrow = Color(uiColor: Theme.rgb(RouteColors.arrow))
        inBothThemes { theme in
            XCTAssertGreaterThanOrEqual(contrast(arrow, Theme.routeCasing), 4.5, "стрелка на своей кайме \(theme)")
        }
    }

    /// Светлая середина — не белая полоса: доля белого умеренная в обеих темах.
    func testRouteCoreIsAHighlightNotAStripe() {
        for alpha in [RouteColors.coreAlpha.day, RouteColors.coreAlpha.night] {
            XCTAssertGreaterThan(alpha, 0.15)
            XCTAssertLessThan(alpha, 0.5)
        }
    }

    /// Стиль движка берёт те же числа, что токены, — второго списка цветов нет.
    func testEngineHexMatchesTheTokens() {
        XCTAssertEqual(RouteColors.hex(0x0B62D0), "#0b62d0")
        inBothThemes { theme in
            let day = theme == "днём"
            let (r, g, b) = components(Theme.route)
            let value = RouteColors.hex(day ? RouteColors.body.day : RouteColors.body.night)
            let expected = String(format: "#%02x%02x%02x", Int((r * 255).rounded()),
                                  Int((g * 255).rounded()), Int((b * 255).rounded()))
            XCTAssertEqual(value, expected, "маршрут \(theme)")
        }
    }
}

// MARK: - Пробки на улицах (33H)

extension PaletteTests {

    private func rgb(_ value: UInt32) -> Color { Color(uiColor: Theme.rgb(value)) }

    /// Палитра «Сигнал» (выбор владельца 28.10), обе темы: (тема,
    /// уровни 1…4, маршрут, фон и тёмные полотна темы).
    private func trafficCases() -> [(String, [UInt32], UInt32, [UInt32])] {
        let c = TrafficPalette.active
        return [
            ("днём", [c.free.day, c.slow.day, c.jam.day, c.stand.day], RouteColors.body.day, [0xF2F3F5, 0xFFFFFF]),
            ("ночью", [c.free.night, c.slow.night, c.jam.night, c.stand.night], RouteColors.body.night,
             [0x16181C, 0x30343C, 0x33373F]),
        ]
    }

    /// Красный на карте — только камера: пробка и «стоят» не читаются её
    /// красным (ΔE ≥ 20 — спецификация 33H) ни днём, ни ночью — ни живые, ни
    /// «обычно». До 33H пробка днём была побайтово красным камеры.
    func testTrafficJamIsNotTheCameraRed() {
        let camera = Theme.Types.camera
        for (name, levels, _, _) in trafficCases() {
            for (index, level) in levels.enumerated() where index >= 2 {
                XCTAssertGreaterThanOrEqual(deltaE(rgb(level), camera), 20, "\(name): уровень \(index + 1) ≈ камера")
            }
        }
        for level in 3...4 {
            let usual = TrafficPalette.usual(TrafficPalette.level(level))
            XCTAssertGreaterThanOrEqual(deltaE(rgb(usual.day), camera), 20, "«обычно» \(level) днём ≈ камера")
            XCTAssertGreaterThanOrEqual(deltaE(rgb(usual.night), camera), 20, "«обычно» \(level) ночью ≈ камера")
        }
        XCTAssertGreaterThanOrEqual(deltaEDeutan(Theme.trafficJam, camera), 20, "пробка ≈ камера при дейтеранопии")
    }

    /// Четыре уровня различимы между собой и при дейтеранопии (там — ниже
    /// порог: второй носитель — яркость и наконечник направления).
    func testTrafficLevelsAreDistinguishable() {
        for (name, levels, _, _) in trafficCases() {
            for i in 0..<levels.count {
                for j in (i + 1)..<levels.count {
                    XCTAssertGreaterThanOrEqual(deltaE(rgb(levels[i]), rgb(levels[j])), 20,
                                                "\(name): уровни \(i + 1) и \(j + 1)")
                    XCTAssertGreaterThanOrEqual(deltaEDeutan(rgb(levels[i]), rgb(levels[j])), 12,
                                                "\(name): уровни \(i + 1) и \(j + 1), дейтеранопия")
                }
            }
            // Главная пара для дейтеранопа — «свободно» и «пробка».
            XCTAssertGreaterThanOrEqual(deltaEDeutan(rgb(levels[0]), rgb(levels[2])), 20, "\(name): зелёный ↔ пробка")
        }
    }

    /// Пробки — не маршрут: линия маршрута над ними должна оставаться
    /// главным предметом карты.
    func testTrafficIsNotTheRoute() {
        for (name, levels, route, _) in trafficCases() {
            for (index, level) in levels.enumerated() {
                XCTAssertGreaterThanOrEqual(deltaE(rgb(level), rgb(route)), 25, "\(name): уровень \(index + 1) ≈ маршрут")
            }
        }
    }

    /// Ночью линия видна на графите сама: свободно, медленно, пробка и
    /// «стоят» — ≥ 3:1 (WCAG 1.4.11 для графики). Днём линию держит кайма.
    func testTrafficLinesStandOutAtNight() {
        let (_, levels, _, grounds) = trafficCases()[1]
        for ground in grounds {
            for (index, level) in levels.enumerated() {
                XCTAssertGreaterThanOrEqual(contrast(rgb(level), rgb(ground)), 3,
                                            "ночью: уровень \(index + 1) на #\(String(ground, radix: 16))")
            }
        }
    }

    /// Днём линия на белой улице держится каймой: кайма + линия ≥ 3:1.
    func testTrafficCasingCarriesTheDayLine() {
        let c = TrafficPalette.active
        for level in [c.free.day, c.slow.day, c.jam.day, c.stand.day] {
            let best = max(contrast(rgb(level), rgb(0xFFFFFF)), contrast(rgb(TrafficPalette.casing.day), rgb(0xFFFFFF)))
            XCTAssertGreaterThanOrEqual(best, 3, "линия или кайма на белой улице")
        }
    }

    /// «Обычно» — тот же цвет, но заметно светлее/глуше живого.
    func testUsualIsPalerThanLive() {
        for level in 1...4 {
            let live = TrafficPalette.level(level)
            let usual = TrafficPalette.usual(live)
            XCTAssertGreaterThanOrEqual(deltaE(rgb(live.day), rgb(usual.day)), 10, "\(level) днём")
            XCTAssertGreaterThanOrEqual(deltaE(rgb(live.night), rgb(usual.night)), 10, "\(level) ночью")
        }
    }

    /// Наконечник направления отличается от своей линии — иначе знака нет.
    func testTrafficArrowStandsOnItsLine() {
        for level in 1...4 {
            let pair = TrafficPalette.level(level)
            for (line, day) in [(pair.day, true), (pair.night, false)] {
                let arrow = TrafficPalette.arrow(on: line, daylight: day)
                XCTAssertGreaterThanOrEqual(deltaE(rgb(arrow.fill), rgb(line)), 15, "\(level) \(day ? "днём" : "ночью")")
            }
        }
    }

    /// Пробка на линии маршрута — цвет палитры пробок (один язык с улицами).
    func testRouteJamIsTheTrafficJam() {
        XCTAssertEqual(RouteColors.jam.day, TrafficPalette.active.jam.day)
        XCTAssertEqual(RouteColors.slow.night, TrafficPalette.active.slow.night)
    }
}

// MARK: - Палитра пробок «Сигнал» (33H3)

extension PaletteTests {

    /// Тона нашей карты, с которыми пробки не должны путаться
    /// (server/omt/make_style.py PALETTES): парки и кроны деревьев; тёплая
    /// магистраль, её кромка и ночное свечение; кайма линии пробок ночью.
    private var mapParks: (day: [UInt32], night: [UInt32]) {
        ([0xCDEAC0, 0xC1E3B0, 0xB3DB9C, 0x93C77C], [0x16271E, 0x14241B, 0x1D3628, 0x2A4A37])
    }
    private var mapTrunk: (day: [UInt32], night: [UInt32]) {
        ([0xFFE2A8, 0xEEB65E, 0xE9AB55, 0xECD096, 0xFFD896, 0xF0C46E], [0x9A8352, 0xA88C55])
    }

    private func chroma(_ color: Color) -> Double {
        let (_, a, b) = lab(color)
        return (a * a + b * b).squareRoot()
    }

    /// Все условия 33H3 для одной палитры в обеих темах.
    private func checkPalette(_ name: String, _ c: TrafficPalette.Colors) {
        let camera = Theme.Types.camera
        let levels: [TrafficPalette.Pair] = [c.free, c.slow, c.jam, c.stand]
        for day in [true, false] {
            let theme = "\(name) \(day ? "днём" : "ночью")"
            style = day ? .light : .dark
            let live = levels.map { rgb(day ? $0.day : $0.night) }
            let usual = levels.map { pair -> Color in
                let u = TrafficPalette.usual(pair)
                return rgb(day ? u.day : u.night)
            }
            // Уровни различимы между собой, и при дейтеранопии.
            for i in 0..<4 {
                for j in (i + 1)..<4 {
                    XCTAssertGreaterThanOrEqual(deltaE(live[i], live[j]), 20, "\(theme): \(i + 1)/\(j + 1)")
                    XCTAssertGreaterThanOrEqual(deltaEDeutan(live[i], live[j]), 12, "\(theme): \(i + 1)/\(j + 1) дейт.")
                    XCTAssertGreaterThanOrEqual(deltaE(usual[i], usual[j]), 12, "\(theme): «обычно» \(i + 1)/\(j + 1)")
                }
            }
            XCTAssertGreaterThanOrEqual(deltaEDeutan(live[0], live[2]), 20, "\(theme): свободно ↔ пробка, дейт.")
            XCTAssertGreaterThanOrEqual(deltaE(live[1], live[2]), 25, "\(theme): медленно ↔ пробка")
            // Красный — только камера (и штраф): ни пробка, ни «стоят», ни их «обычно».
            let danger = rgb(day ? 0xC62828 : 0xFF7A70)
            for index in 2...3 {
                XCTAssertGreaterThanOrEqual(deltaE(live[index], camera), 20, "\(theme): \(index + 1) ≈ камера")
                XCTAssertGreaterThanOrEqual(deltaE(usual[index], camera), 20, "\(theme): «обычно» \(index + 1) ≈ камера")
                XCTAssertGreaterThanOrEqual(deltaE(live[index], danger), 20, "\(theme): \(index + 1) ≈ штраф")
            }
            XCTAssertGreaterThanOrEqual(deltaEDeutan(live[2], camera), 20, "\(theme): пробка ≈ камера, дейт.")
            // Лестница: днём тяжелее — темнее; ночью «свободно» — самое тихое.
            if day {
                for i in 0..<3 {
                    XCTAssertGreaterThanOrEqual(lab(live[i]).0 - lab(live[i + 1]).0, 4,
                                                "\(theme): уровень \(i + 2) не темнее \(i + 1)")
                }
            } else {
                for i in 1..<4 {
                    XCTAssertLessThan(chroma(live[0]), chroma(live[i]), "\(theme): свободно насыщеннее \(i + 1)")
                }
                for ground: UInt32 in [0x16181C, 0x30343C, 0x33373F, TrafficPalette.casing.night] {
                    for (index, line) in live.enumerated() {
                        XCTAssertGreaterThanOrEqual(contrast(line, rgb(ground)), 3,
                                                    "\(theme): \(index + 1) на #\(String(ground, radix: 16))")
                    }
                }
            }
            // Без неона: насыщенность не выше тонов состояний Theme.
            for (index, line) in live.enumerated() {
                XCTAssertLessThanOrEqual(chroma(line), 60, "\(theme): \(index + 1) — неон")
            }
            // Зелёный — не парк; медленно — не магистраль и не главное действие.
            for park in day ? mapParks.day : mapParks.night {
                XCTAssertGreaterThanOrEqual(deltaE(live[0], rgb(park)), 20, "\(theme): свободно ≈ парк")
                XCTAssertGreaterThanOrEqual(deltaE(usual[0], rgb(park)), 12, "\(theme): «обычно» свободно ≈ парк")
            }
            for trunk in (day ? mapTrunk.day : mapTrunk.night) + [0xFFD43B] {
                XCTAssertGreaterThanOrEqual(deltaE(live[1], rgb(trunk)), 20,
                                            "\(theme): медленно ≈ #\(String(trunk, radix: 16))")
            }
            // Ничто не синий маршрута / интерфейса / другого варианта.
            let route = rgb(day ? RouteColors.body.day : RouteColors.body.night)
            let alternative = rgb(day ? RouteColors.alternative.day : RouteColors.alternative.night)
            let casing = rgb(day ? RouteColors.casing.day : RouteColors.casing.night)
            for index in 0..<4 {
                for (ref, refName) in [(route, "маршрут"), (Theme.accent, "accent"), (alternative, "вариант")] {
                    XCTAssertGreaterThanOrEqual(deltaE(live[index], ref), 25, "\(theme): \(index + 1) ≈ \(refName)")
                    XCTAssertGreaterThanOrEqual(deltaE(usual[index], ref), 20, "\(theme): «обычно» \(index + 1) ≈ \(refName)")
                }
                XCTAssertGreaterThanOrEqual(deltaEDeutan(live[index], route), 15, "\(theme): \(index + 1) ≈ маршрут, дейт.")
                // «Обычно» отличимо от живого — и своего уровня, и чужого.
                XCTAssertGreaterThanOrEqual(deltaE(live[index], usual[index]), 10, "\(theme): «обычно» \(index + 1)")
                for other in 0..<4 where other != index {
                    XCTAssertGreaterThanOrEqual(deltaE(usual[index], live[other]), 12,
                                                "\(theme): «обычно» \(index + 1) ≈ живое \(other + 1)")
                }
                let line = day ? levels[index].day : levels[index].night
                XCTAssertGreaterThanOrEqual(deltaE(rgb(TrafficPalette.arrow(on: line, daylight: day).fill), live[index]),
                                            15, "\(theme): наконечник \(index + 1)")
            }
            // На линии маршрута: медленно и пробка — свой цвет внутри синей каймы.
            for index in 1...2 {
                XCTAssertGreaterThanOrEqual(deltaE(live[index], route), 40, "\(theme): \(index + 1) на маршруте")
                XCTAssertGreaterThanOrEqual(deltaE(live[index], casing), 40, "\(theme): \(index + 1) на кайме")
                XCTAssertGreaterThanOrEqual(deltaE(live[index], alternative), 40, "\(theme): \(index + 1) ≈ вариант")
            }
        }
    }

    /// «Сигнал» (выбор владельца 28.10) держит каждое правило 33H3.
    func testTrafficPaletteHoldsEveryRule() {
        checkPalette("«Сигнал»", TrafficPalette.active)
    }

    /// Асфальт поездки (make_style.py PALETTES drive_trunk / drive_primary /
    /// drive_tertiary — тёмный и днём). Слой пробок там красится ночным
    /// набором, как линия маршрута (DriveAsphalt.routeDaylight): каждый
    /// уровень — и «стоят» прежде всего — держит ≥ 3:1 к асфальту или к своей
    /// кайме (кайма — с её прозрачностью, поверх того же асфальта). Дневной
    /// баклажан здесь давал 1,3–1,5:1 — линия «стоят» пропадала.
    func testTrafficStandsOutOnTheDriveAsphalt() {
        XCTAssertFalse(DriveAsphalt.routeDaylight(daylight: true, active: true),
                       "в поездке слой пробок и маршрут — ночным набором")
        let c = TrafficPalette.active
        style = .dark
        for asphalt: UInt32 in [0x4B4F5A, 0x3F4859, 0x434C5E] {
            let casing = TrafficPalette.mix(TrafficPalette.casing.night, asphalt,
                                            1 - TrafficPalette.casingOpacity.night)
            for (name, line) in [("свободно", c.free.night), ("медленно", c.slow.night),
                                 ("пробка", c.jam.night), ("стоят", c.stand.night)] {
                let best = max(contrast(rgb(line), rgb(asphalt)), contrast(rgb(line), rgb(casing)))
                XCTAssertGreaterThanOrEqual(best, 3, "\(name) на асфальте #\(String(asphalt, radix: 16))")
            }
        }
    }
}
