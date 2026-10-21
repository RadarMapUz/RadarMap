//
//  MaintenanceText.swift
//  RadarMap
//
//  Слова обслуживания: подпись состояния, строка срока, фраза для VoiceOver
//  и текст напоминания. Одно место на экран, «Итоги» и уведомление — чтобы
//  «скоро» в карточке и в пуше говорило одно и то же.
//

import SwiftUI

enum MaintenanceText {

    /// Цвет и глиф состояния — общее правило приложения (Theme.Level).
    static func level(_ status: Maintenance.Status) -> Theme.Level {
        switch status {
        case .unknown: return .neutral
        case .ok: return .normal
        case .soon: return .attention
        case .due, .overdue: return .alarm
        }
    }

    static func color(_ status: Maintenance.Status) -> Color {
        status == .unknown ? Theme.textSecondary : Theme.role(level(status))
    }

    /// Подпись состояния. У документа — «действует» / «истёк», у работы —
    /// «в порядке» / «пора».
    static func status(_ state: Maintenance.State) -> String {
        let document = state.kind.isDocument
        switch state.status {
        case .unknown: return String(localized: "Не задано")
        case .ok: return document ? String(localized: "Действует") : String(localized: "В порядке")
        case .soon: return String(localized: "Скоро")
        case .due: return document ? String(localized: "Последний день") : String(localized: "Пора")
        case .overdue: return document ? String(localized: "Истёк") : String(localized: "Просрочено")
        }
    }

    /// Строка срока: «Ещё 1 200 км · до 12 марта», «Действует до 30 октября».
    /// `spoken` — для VoiceOver: единицы словами (SpokenUnits).
    static func detail(_ state: Maintenance.State, spoken: Bool = false) -> String {
        if state.status == .unknown {
            return state.kind.isDocument
                ? String(localized: "Укажите, до какого числа действует")
                : String(localized: "Укажите, когда делали в последний раз")
        }
        func distance(_ km: Double) -> String {
            spoken ? SpokenUnits.distance(km * 1000) : Formatting.distance(km * 1000)
        }
        var parts: [String] = []
        if let remaining = state.remainingKm {
            parts.append(remaining > 0
                ? String(format: String(localized: "ещё %@"), distance(remaining))
                : remaining <= -1
                    ? String(format: String(localized: "пробег сверх срока: %@"), distance(-remaining))
                    : String(localized: "пробег подошёл"))
        }
        if let due = state.dueDate, let days = state.daysLeft {
            if state.kind.isDocument {
                // В последний день — та же дата: «последний день» уже говорит
                // подпись состояния, дата в строке не повторяет её словами.
                parts.append(days >= 0 ? String(format: String(localized: "действует до %@"), date(due))
                             : String(format: String(localized: "истёк %@"), date(due)))
            } else {
                parts.append(days > 0 ? String(format: String(localized: "до %@"), date(due))
                             : days == 0 ? String(localized: "срок сегодня")
                             : String(format: String(localized: "срок был %@"), date(due)))
            }
        }
        return capitalized(parts.joined(separator: " · "))
    }

    /// Вся строка пункта для VoiceOver: «Масло двигателя. Скоро. Ещё 450
    /// километров, до 12 марта».
    static func spoken(_ state: Maintenance.State) -> String {
        [state.kind.title, status(state),
         detail(state, spoken: true).replacingOccurrences(of: " · ", with: ", ")]
            .joined(separator: ". ")
    }

    /// Текст напоминания: срок словами и что сделать.
    static func notificationBody(_ state: Maintenance.State) -> String {
        let when = detail(state)
        switch state.status {
        case .soon:
            return state.kind.isDocument
                ? String(format: String(localized: "%@ — продлите заранее."), when)
                : String(format: String(localized: "%@ — пора записаться."), when)
        case .due, .overdue:
            return state.kind.isDocument
                ? String(format: String(localized: "%@. Продлили — отметьте в приложении."), when)
                : String(format: String(localized: "%@. Сделали — отметьте «Сделано сегодня»."), when)
        case .unknown, .ok:
            return when
        }
    }

    /// Справа у строки «Обслуживание» в настройках.
    static func summary(_ states: [Maintenance.State], hasOdometer: Bool) -> String {
        let urgent = states.filter { $0.status >= .due }.count
        let soon = states.filter { $0.status == .soon }.count
        if urgent > 0 { return String(format: String(localized: "пора: %lld"), urgent) }
        if soon > 0 { return String(format: String(localized: "скоро: %lld"), soon) }
        if !hasOdometer, states.allSatisfy({ $0.status == .unknown }) { return String(localized: "не задано") }
        return String(localized: "в порядке")
    }

    /// «12 марта»; другой год — «12 марта 2027».
    static func date(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let style = Date.FormatStyle(timeZone: calendar.timeZone).day().month(.wide)
            .locale(Formatting.numberLocale)
        return calendar.isDate(date, equalTo: now, toGranularity: .year)
            ? date.formatted(style)
            : date.formatted(style.year())
    }

    private static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased(with: Formatting.numberLocale) + text.dropFirst()
    }
}
