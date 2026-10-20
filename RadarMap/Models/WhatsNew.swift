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
    static let edition = 2

    static var items: [Item] {
        [
            // Выпуск 2 (2.2.23): только то, что работает без выкладки сервера —
            // перекрытия, метан и семейная ссылка появятся после неё.
            Item(symbol: "car.fill",
                 title: String(localized: "Где оставили машину"),
                 text: String(localized: "После поездки на карте — значок машины и «Машина · 330 м» со стрелкой.")),
            Item(symbol: "fuelpump.fill",
                 title: String(localized: "Сколько стоит дорога"),
                 text: String(localized: "Укажите расход и цену — стоимость появится в поездках и «Итогах». Там же — проверка штрафов по госномеру.")),
            Item(symbol: "lock.rectangle.on.rectangle",
                 title: String(localized: "«На работу» на экране блокировки"),
                 text: String(localized: "Виджет: сколько ехать сейчас и не мешают ли пробки — ещё до выезда.")),
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
