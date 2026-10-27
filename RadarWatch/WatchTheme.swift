//
//  WatchTheme.swift
//  RadarWatch
//
//  Палитра приложения на запястье (9.3; с 27.10 — «Строгий навигатор», 31D) — ночные значения, как у
//  плашки поездки и окна тревоги: циферблат чёрный, а до 20.10 здесь жили
//  циан и жёлто-оранжевая лестница «радар-детектора», от которых приложение
//  отказалось 7 октября. Числа — из общего WidgetPalette (их сверяет тест
//  приложения с Theme).
//

import SwiftUI

enum WatchTheme {
    static let accent = color(WidgetPalette.accent.dark)
    static let danger = color(WidgetPalette.danger.dark)
    static let warning = color(WidgetPalette.warning.dark)
    static let success = color(WidgetPalette.success.dark)
    static let dangerFill = color(WidgetPalette.dangerFill.dark)
    static let successFill = color(WidgetPalette.successFill.dark)
    static let primary = color(WidgetPalette.primary.dark)
    static let secondary = color(WidgetPalette.secondary.dark)
    static let action = color(WidgetPalette.action)
    static let onAction = color(WidgetPalette.onAction)
    static let signRed = color(WidgetPalette.signRed)

    /// Дистанция по уровню тревоги — та же лестница, что у плашки: ближе —
    /// горячее. Цвет не единственный носитель: уровень 3 — это и тук по
    /// запястью, и скорость на экране.
    static func level(_ level: Int) -> Color {
        switch level {
        case 3...: return danger
        case 2: return warning
        default: return accent
        }
    }

    private static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }
}
