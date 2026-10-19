//
//  WhatsNew.swift
//  RadarMap
//
//  «Что нового» (7.6) — один экран после обновления, три пункта, и только
//  если есть что сказать водителю. Не по номеру версии: сборки уходят под
//  номерами, которые назначает выгрузка (см. CLAUDE.md), — а по «выпуску»
//  текста: поменялся текст — поднять `edition`.
//
//  Новый пользователь экрана не видит: онбординг рассказал больше, и
//  «нового» для него нет. Видит тот, кто уже ездил с прошлой версией.
//

import Foundation

nonisolated enum WhatsNew {
    struct Item: Identifiable, Equatable, Sendable {
        let symbol: String
        let title: String
        let text: String
        var id: String { title }
    }

    /// Номер текущего выпуска текста. Поднимать вместе с `items`.
    static let edition = 1

    static var items: [Item] {
        [
            Item(symbol: "rectangle.3.group.fill",
                 title: String(localized: "Итоги недели на домашнем экране"),
                 text: String(localized: "Виджет в цветах приложения: километры, балл, дни и где теряете баллы.")),
            Item(symbol: "car.fill",
                 title: String(localized: "«Начать поездку» одним нажатием"),
                 text: String(localized: "В Пункте управления и на кнопке действия — не открывая приложение.")),
            Item(symbol: "speedometer",
                 title: String(localized: "Спокойнее за рулём"),
                 text: String(localized: "Одно расстояние до камеры, объявления ждут остановки, «Радар!» подписан в первых поездках.")),
        ]
    }

    /// Показать ли экран: человек уже пользовался приложением (онбординг
    /// пройден раньше), этот выпуск ещё не видел — и сейчас НЕ за рулём.
    /// Первое открытие после обновления чаще всего в машине с автостартом,
    /// и лист на весь экран закрыл бы предупреждение о камере (ревью 19.10);
    /// тогда — в следующий раз, стоя.
    static func shouldShow(seenEdition: Int, onboarded: Bool, isDriving: Bool = false,
                           carPlay: Bool = false, items: [Item] = items) -> Bool {
        onboarded && !isDriving && !carPlay && seenEdition < edition && !items.isEmpty
    }
}
