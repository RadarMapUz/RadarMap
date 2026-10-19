//
//  NumberFormat.swift
//  RadarMap
//
//  Числа по ЯЗЫКУ приложения — одно правило для приложения, виджетов,
//  Live Activity и часов. До 19.10 у виджета, плашки и часов были свои копии
//  локали и округления: «1,25 км» на часах выходило «1,2», в приложении «1,3»
//  (банковское округление против «от нуля»).
//

import Foundation

nonisolated enum NumberFormat {
    /// И русский, и узбекский пишут дробь через запятую — при регионе
    /// телефона «США» `String(format:)` ставил точку посреди русского текста.
    static let locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "ru")

    /// «1,3» — дробное с `digits` знаками, округление от нуля, без разрядов.
    static func decimal(_ value: Double, digits: Int = 1, locale: Locale = locale) -> String {
        value.formatted(.number.precision(.fractionLength(digits))
            .rounded(rule: .toNearestOrAwayFromZero)
            .grouping(.never)
            .locale(locale))
    }
}
