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
    ///
    /// Не `preferredLocalizations.first` как есть: в бандле есть `en.lproj`
    /// (его генерирует Xcode для фраз Siri и Быстрых команд), и на телефоне с
    /// английским языком системы первым шёл «en» — строки при этом русские
    /// (английских в каталоге нет), а числа — с точкой: «11.7 км» на карточке
    /// прибытия у владельца 21.10. Язык чисел — язык текста: первый из ru/uz.
    static let locale = Locale(identifier: contentLanguage(Bundle.main.preferredLocalizations))

    /// Язык, на котором приложение реально показывает текст: первый ru/uz из
    /// предпочтений, иначе исходный — русский.
    static func contentLanguage(_ preferred: [String]) -> String {
        preferred.lazy.map { String($0.prefix(2)).lowercased() }
            .first { $0 == "ru" || $0 == "uz" } ?? "ru"
    }

    /// Время на часах: «8:22» / «8:22 PM» — ЕДИНСТВЕННОЕ место, где дата
    /// форматируется без языка приложения, и это решение, а не недосмотр:
    /// 12/24 часа — настройка человека в iOS (регион), и навязать ему чужой
    /// формат часов хуже, чем английское «PM» рядом с русским текстом.
    /// Названия месяцев и дней недели — только через язык приложения
    /// (`Formatting.date`), иначе при английской системе выходят английскими.
    static func clock(_ date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timeZone))
    }

    /// «1,3» — дробное с `digits` знаками, округление от нуля, без разрядов.
    static func decimal(_ value: Double, digits: Int = 1, locale: Locale = locale) -> String {
        value.formatted(.number.precision(.fractionLength(digits))
            .rounded(rule: .toNearestOrAwayFromZero)
            .grouping(.never)
            .locale(locale))
    }
}
