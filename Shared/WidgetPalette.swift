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
//  жёлтого, чем в «Итогах». Теперь это палитра А «Синий навигатор»: те же
//  значения, что у Theme, день и ночь.
//

import Foundation

nonisolated enum WidgetPalette {
    /// Пара «день / ночь» в 0xRRGGBB.
    struct Pair: Equatable, Sendable {
        let light: UInt32
        let dark: UInt32
    }

    /// Theme.accent — текст и обводки (синий читается на белом, жёлтый нет).
    static let accent = Pair(light: 0x2563D9, dark: 0x6BA3FF)
    /// Theme.danger / success / warning — цвета состояний и балла.
    static let danger = Pair(light: 0xC62828, dark: 0xFF7A70)
    static let success = Pair(light: 0x177A41, dark: 0x4CC27A)
    static let warning = Pair(light: 0x9A5800, dark: 0xFFB020)

    /// Заливки под белым значком (Theme.accentFill / dangerFill / successFill):
    /// ночные accent/danger светлые — белый на них 2,5:1 (ревью 19.10).
    static let accentFill = Pair(light: 0x2563D9, dark: 0x2A62D6)
    static let dangerFill = Pair(light: 0xC62828, dark: 0xD0362C)
    static let successFill = Pair(light: 0x177A41, dark: 0x1A7F45)
    /// Theme.action / onAction — жёлтое главное действие («Радар!») и текст
    /// на нём; одно значение в обеих темах, как в приложении.
    static let action: UInt32 = 0xFFD43B
    static let onAction: UInt32 = 0x1C1C1E
    /// Подложка плашки поездки — графит экрана тревоги (Theme.alertSurface):
    /// Live Activity и Dynamic Island всегда тёмные.
    static let alertSurface: UInt32 = 0x14181D

    /// Подложка: верх и низ карточки (Theme.surfaceTop → surface ночью;
    /// днём — белая с едва заметным холодным низом, как панели приложения).
    static let top = Pair(light: 0xFFFFFF, dark: 0x252B33)
    static let bottom = Pair(light: 0xF1F4F9, dark: 0x1A1F26)

    /// Theme.textPrimary / textSecondary / textTertiary.
    static let primary = Pair(light: 0x111827, dark: 0xF1F4F8)
    static let secondary = Pair(light: 0x556070, dark: 0xA0A9B6)
    static let tertiary = Pair(light: 0x657080, dark: 0x8F99A6)

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
        switch symbol {
        case "camera.fill": return 0xD93025
        case "speedometer", "light.beacon.max.fill": return 0xF2B200
        case "sensor.tag.radiowaves.forward.fill": return 0x6A3FD6
        case "dot.radiowaves.left.and.right": return 0xC2409E
        case "exclamationmark.triangle.fill": return dangerFill.dark
        default: return 0x46525E
        }
    }

    /// Значок на заливке типа: на светлом янтаре радара и треноги — тёмный.
    static func cameraGlyph(symbol: String?) -> UInt32 {
        cameraFill(symbol: symbol) == 0xF2B200 ? onAction : 0xFFFFFF
    }
}
