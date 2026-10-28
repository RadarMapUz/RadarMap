//
//  ArrivalClock.swift
//  RadarMap
//
//  Одни часы прибытия (37, 28.10): телефон, CarPlay, плашка Live Activity,
//  «Поделиться прибытием» и Telegram близких показывают ОДНУ минуту.
//
//  До этого у каждого выхода было своё время. Панель считала
//  `Date() + remainingTime` в body и обновлялась только при перерисовке —
//  стоя в пробке (фиксов нет, distanceFilter) прибытие застывало, пока часы
//  шли; CarPlay слал оценки по смене РАССТОЯНИЯ и стоя молчал; плашка
//  округляла до минуты, панель отбрасывала секунды, ссылка слала шагом в две
//  минуты, близкие — свой «призрак». Владелец: «на телефоне другое, на
//  CarPlay другое, в Телеграме другое».
//
//  Правило одно: остаток пути (`RouteService.remainingTime` — призрак,
//  хвост, пробки, темп, как было) + сейчас → до БЛИЖАЙШЕЙ минуты, с
//  удержанием: показанная минута держится, пока сырое прибытие не ушло от неё
//  на `arrivalClockHoldSeconds`. Без удержания сырое время у границы полминуты
//  (15:56:29 ↔ 15:56:31) мигало бы 15:56/15:57 на каждом фиксе — и каждое
//  мигание было бы отправкой в машину, плашку и на сервер.
//

import Foundation

nonisolated enum ArrivalClock {

    /// Ближайшая минута. Ровно на минуте и отбрасывание секунд (формат
    /// «HH:mm», сервер `%H:%M`), и округление дают одно и то же — поэтому
    /// показываемое время всегда ровно на минуте.
    static func rounded(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded() * 60)
    }

    /// Сырое прибытие: сейчас плюс остаток.
    static func raw(now: Date, remaining: TimeInterval) -> Date {
        now.addingTimeInterval(max(0, remaining))
    }

    /// Что показывать дальше. `shown` — показанная минута; `sameRoute` —
    /// тот же маршрут (на новом маршруте удерживать нечего: прежняя минута
    /// была про другую линию). nil `raw` — маршрута нет.
    static func next(shown: Date?, raw: Date?, sameRoute: Bool,
                     hold: TimeInterval = AppConfig.arrivalClockHoldSeconds) -> Date? {
        guard let raw else { return nil }
        if sameRoute, let shown, abs(raw.timeIntervalSince(shown)) < hold { return shown }
        return rounded(raw)
    }

    /// Остаток для того, кто сам прибавляет его к своим часам (CarPlay
    /// `CPTravelEstimates`: машина показывает прибытие = её «сейчас» +
    /// остаток). До показанной минуты — плюс запас `arrivalClockCarMarginSeconds`:
    /// ровно минута, посчитанная машиной на долю секунды позже, при
    /// отбрасывании секунд дала бы предыдущую минуту; с запасом меньше
    /// полуминуты и округление, и отбрасывание дают ту же.
    static func secondsUntil(_ arrival: Date, now: Date,
                             margin: TimeInterval = AppConfig.arrivalClockCarMarginSeconds) -> TimeInterval {
        max(0, arrival.timeIntervalSince(now)) + margin
    }

    /// Остаток для машины по времени варианта, которого на телефоне ещё нет
    /// как маршрута (выбор вариантов в CarPlay): то же правило минуты.
    static func secondsUntil(remaining: TimeInterval, now: Date) -> TimeInterval {
        secondsUntil(rounded(raw(now: now, remaining: remaining)), now: now)
    }
}
