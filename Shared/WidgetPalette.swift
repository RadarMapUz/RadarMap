//
//  WidgetPalette.swift
//  RadarMap
//
//  Цвета виджетов — числами, без SwiftUI: файл общий и для часов, а
//  проверяет их тест приложения (WidgetPaletteTests) против Theme.
//
//  До 19.10 у виджета была своя неоновая палитра «радар-детектора» — циан
//  и малиновый, от которых само приложение отказалось 7 октября. Виджет на
//  домашнем экране выглядел другим приложением, а балл 67 на нём был другого
//  жёлтого, чем в «Итогах». Теперь те же значения, что у Theme, день и ночь:
//  с 27.10 — «Строгий навигатор» (31D): тёплые нейтральные, свой синий,
//  ровная подложка без градиента.
//

import Foundation

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
}
