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
    /// `CPTravelEstimates`). Машина берёт минуту на СВОИХ часах и прибавляет
    /// остаток в целых минутах: снимок владельца 05.11 — телефон 22:02, а
    /// машина «22:01 · 20 min» при остатке «до 22:02:05 от 21:41:ss», то есть
    /// не «сейчас + остаток» (это дало бы 22:02). Поэтому остаток — от
    /// минуты на часах до показанной минуты, ровно целые минуты, плюс запас
    /// `arrivalClockCarMarginSeconds` (полсекунды): и «минута часов + минуты
    /// остатка» (округлить или отбросить), и «сейчас + остаток» с отбрасыванием
    /// секунд дают ту же минуту, что на телефоне, — если отправка не попала в
    /// конец минуты (`carMaySend`), — а «N min» в машине — ту же разность, что
    /// у плитки (`minutesUntil`).
    static func secondsUntil(_ arrival: Date, now: Date,
                             margin: TimeInterval = AppConfig.arrivalClockCarMarginSeconds) -> TimeInterval {
        max(0, arrival.timeIntervalSince(clockMinute(now))) + margin
    }

    /// Можно ли слать остаток машине сейчас: не в последние
    /// `arrivalClockCarSendGuardSeconds` минуты. Остаток считается от минуты
    /// часов, и отправка в 21:41:59,6, доставленная в 21:42:00,1, при любом
    /// правиле машины дала бы минутой позже — до следующей отправки (стоя —
    /// до 30 с). Запас 4 с покрывает задержку доставки до 3 с и запас
    /// остатка; отложенная отправка уходит в начале следующей минуты.
    static func carMaySend(now: Date, guardSeconds: TimeInterval = AppConfig.arrivalClockCarSendGuardSeconds) -> Bool {
        now.timeIntervalSince(clockMinute(now)) < 60 - guardSeconds
    }

    /// Когда отправить отложенное: начало следующей минуты.
    static func nextCarSend(after now: Date) -> Date {
        clockMinute(now).addingTimeInterval(60)
    }

    /// Минута на часах: «сейчас» без секунд.
    static func clockMinute(_ now: Date) -> Date {
        Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 60) * 60)
    }

    /// Сколько минут показать рядом с прибытием, чтобы сходилось с часами:
    /// «21:41 → 22:02 — 21 мин» (плитка машины рядом с системной полосой
    /// «22:02 · 21 min»). Сырые минуты остатка давали «20 мин 22:02».
    static func minutesUntil(_ arrival: Date, now: Date) -> Int {
        max(0, Int((arrival.timeIntervalSince(clockMinute(now)) / 60).rounded()))
    }

    /// Остаток для машины по времени варианта, которого на телефоне ещё нет
    /// как маршрута (выбор вариантов в CarPlay): то же правило минуты.
    static func secondsUntil(remaining: TimeInterval, now: Date) -> TimeInterval {
        secondsUntil(rounded(raw(now: now, remaining: remaining)), now: now)
    }
}
