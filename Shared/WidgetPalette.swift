//
//  WidgetPalette.swift
//  RadarMap
//
//  Общая палитра числами — источник Theme (приложение), виджетов и часов:
//  токены состояний, текста и подложек живут здесь один раз, а проверяет их
//  тест приложения (WidgetPaletteTests, PaletteTests).
//
//  До 19.10 у виджета была своя неоновая палитра «радар-детектора» — циан
//  и малиновый, от которых само приложение отказалось 7 октября. Виджет на
//  домашнем экране выглядел другим приложением, а балл 67 на нём был другого
//  жёлтого, чем в «Итогах». Теперь те же значения, что у Theme, день и ночь:
//  с 27.10 — «Строгий навигатор» (31D): тёплые нейтральные, свой синий,
//  ровная подложка без градиента.
//

import SwiftUI

nonisolated enum WidgetPalette {
    /// Пара «день / ночь» в 0xRRGGBB.
    struct Pair: Equatable, Sendable {
        let light: UInt32
        let dark: UInt32
    }

    /// Theme.accent — текст и обводки (синий читается на белом, жёлтый нет).
    static let accent = Pair(light: 0x0B62D0, dark: 0x5FA2FF)
    /// Theme.danger / success / warning — цвета состояний и балла.
    static let danger = Pair(light: 0xC62828, dark: 0xFF7A70)
    static let success = Pair(light: 0x177A41, dark: 0x4CC27A)
    static let warning = Pair(light: 0x9A5800, dark: 0xFFB020)

    /// Заливки под белым значком (Theme.accentFill / dangerFill / successFill):
    /// ночные accent/danger светлые — белый на них 2,5:1 (ревью 19.10).
    static let accentFill = Pair(light: 0x0B62D0, dark: 0x1E5DC4)
    static let dangerFill = Pair(light: 0xC62828, dark: 0xD0362C)
    static let successFill = Pair(light: 0x177A41, dark: 0x1A7F45)
    /// Theme.action / onAction — жёлтое главное действие («Радар!») и текст
    /// на нём; одно значение в обеих темах, как в приложении.
    static let action: UInt32 = 0xFFD43B
    static let onAction: UInt32 = 0x1C1C1E
    /// Подложка плашки поездки — графит экрана тревоги (Theme.alertSurface):
    /// Live Activity и Dynamic Island всегда тёмные.
    static let alertSurface: UInt32 = 0x14181D

    /// Подложка виджета — Theme.surface, ровная: градиент «свет сверху»
    /// ушёл из приложения вместе с остальными (31D).
    static let surface = Pair(light: 0xFFFFFF, dark: 0x1F1F1F)
    /// Спокойная зона виджета «Дорога» — вторая карточка рядом с синей.
    static let quiet = Pair(light: 0xF2F1EE, dark: 0x2A2A29)
    /// Кольца дня и недели (Theme.Stats и виджет). Дневные — те же оттенки
    /// темнее, потому что ночные на белом не видны (тест проверяет контраст
    /// обоих со своей подложкой).
    struct Gradient: Equatable, Sendable {
        let light: [UInt32]
        let dark: [UInt32]
    }

    static let ringCalm = Gradient(light: [0x0B9F78, 0x0A8AA8], dark: [0x2BF0B5, 0x19C8E8])
    static let ringWatch = Gradient(light: [0xC77E00, 0xB85C00], dark: [0xFFD15C, 0xFF9A2E])
    /// Ночные концы «риска» и «пробега» до 10.11 были неоном (OKLCH C 0,20–0,25
    /// против ≤ 0,165 у состояний) — насыщенность снижена при той же светлоте и тоне.
    static let ringRisk = Gradient(light: [0xE0325A, 0xC2187A], dark: [0xF16B80, 0xC94F88])
    static let ringRoad = Gradient(light: [0x7A5CF0, 0x5B3DF5], dark: [0xB49CFF, 0x6B63D2])
    /// Theme.Stats.commute / other — деление недели.
    static let statsCommute = Pair(light: 0x5B3DF5, dark: 0x9A85FF)
    static let statsOther = Pair(light: 0x0B9F78, dark: 0x3BE3B0)

    /// Кант знака ограничения скорости (Theme.signRed).
    static let signRed: UInt32 = 0xD90D1A

    /// Theme.textPrimary / textSecondary / textTertiary.
    static let primary = Pair(light: 0x1D1D1B, dark: 0xF2F1EE)
    static let secondary = Pair(light: 0x5C5B57, dark: 0xAAA9A4)
    static let tertiary = Pair(light: 0x6A6964, dark: 0x9A9993)

    /// Ступень балла — те же пороги, что DrivingScore.tier (тест сверяет):
    /// виджет не имеет права красить 70 иначе, чем «Итоги».
    /// 2 — зелёный, 1 — жёлтый, 0 — красный.
    static func scoreTier(_ rating: Int) -> Int {
        rating >= 75 ? 2 : rating >= 60 ? 1 : 0
    }

    /// Цвет типа камеры (Theme.Types) по SF Symbol, который телефон шлёт
    /// часам (CameraType.symbolName): компликация часов красит диск камеры
    /// тем же цветом, что маркер на карте. Тест сверяет с Theme.Types.
    /// ДТП — заливка опасности (ночной danger светлый, белый на нём не
    /// читается); неизвестный тип — графит поста, не синий интерфейса.
    static func cameraFill(symbol: String?) -> UInt32 {
        (CameraGlyph(symbol: symbol) ?? .other).fillRGB
    }

    /// Значок на заливке типа: на светлом янтаре радара и треноги — тёмный.
    static func cameraGlyph(symbol: String?) -> UInt32 {
        (CameraGlyph(symbol: symbol) ?? .other).inkRGB
    }

    /// Цвет из числа — для виджетов и часов, где нет Theme.
    static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }
}
