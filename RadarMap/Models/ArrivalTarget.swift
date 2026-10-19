//
//  ArrivalTarget.swift
//  RadarMap
//
//  «Быть на работе к 9:00» (план 19.10, 8.6). Без срока призрак говорит
//  только «как обычно / дольше обычного»; со сроком — запас: «с запасом
//  6 мин», «впритык», «на 4 мин позже 9:00». Срок задаёт сам человек — или
//  отвечает «да» на один вопрос, когда распорядок уже виден по поездкам:
//  догадка о том, когда человеку надо быть на работе, вслух без спроса —
//  это уже слежка, а не помощь.
//
//  Чистая модель: только на телефоне, на сервер не уходит.
//

import Foundation

nonisolated struct ArrivalTarget: Codable, Equatable, Sendable {
    /// Минута суток: 540 — 9:00.
    var minute: Int
    /// И по субботам — шестидневка в Узбекистане обычна.
    var saturday = false

    /// Срок действует сегодня: будни, суббота — если отмечена.
    func applies(on date: Date, calendar: Calendar = .current) -> Bool {
        let weekday = calendar.component(.weekday, from: date)   // 1 — воскресенье
        return (2...6).contains(weekday) || (saturday && weekday == 7)
    }

    /// Срок для поездки, начатой в `departure`: тот же день, если срок там
    /// действует, выезд раньше срока и не раньше чем за `arrivalTargetLeadHours`.
    /// Выехали уже после срока — запаса нет и говорить о нём нечего; выехали
    /// за пять часов — это не та поездка (ночная смена, аэропорт).
    func deadline(forDeparture departure: Date, calendar: Calendar = .current) -> Date? {
        guard applies(on: departure, calendar: calendar),
              let deadline = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0,
                                           of: departure),
              deadline > departure,
              deadline.timeIntervalSince(departure) <= AppConfig.arrivalTargetLeadHours * 3600
        else { return nil }
        return deadline
    }

    /// Запас: срок минус прибытие, мин (меньше нуля — позже срока).
    static func slackMinutes(deadline: Date, arrival: Date) -> Double {
        deadline.timeIntervalSince(arrival) / 60
    }

    // MARK: - Вопрос «вам нужно быть к 9:00?»

    /// Срок, о котором можно спросить, — или nil. Берётся первое прибытие на
    /// работу за будний день; нужно не меньше `arrivalTargetMinDays` таких
    /// дней за 30. p90 прибытия округляется вверх до :00 или :30 — это H, и
    /// спрашиваем, только если H − p90 ≤ 15 мин (человек и правда приезжает
    /// «к девяти», а не «где-то утром») и прибытия не разбросаны шире 40 мин
    /// между p25 и p90: у свободного графика срока нет, и вопрос о нём
    /// звучал бы странно.
    static func suggestion(arrivals: [Date], now: Date, calendar: Calendar = .current) -> Int? {
        let since = now.addingTimeInterval(-Double(AppConfig.commuteWindowDays) * 86_400)
        var firstOfDay: [Date: Int] = [:]
        for arrival in arrivals where arrival >= since && arrival <= now {
            let weekday = calendar.component(.weekday, from: arrival)
            guard (2...6).contains(weekday) else { continue }
            let day = calendar.startOfDay(for: arrival)
            let minute = Commute.minuteOfDay(arrival, calendar: calendar)
            firstOfDay[day] = min(firstOfDay[day] ?? .max, minute)
        }
        guard firstOfDay.count >= AppConfig.arrivalTargetMinDays else { return nil }
        let sorted = firstOfDay.values.sorted().map(Double.init)
        let p90 = CommuteGhost.quantile(sorted, 0.9)
        let p25 = CommuteGhost.quantile(sorted, 0.25)
        guard p90 - p25 <= AppConfig.arrivalTargetMaxSpreadMinutes else { return nil }
        let h = Int((p90 / 30).rounded(.up)) * 30
        guard Double(h) - p90 <= AppConfig.arrivalTargetMaxGapMinutes, h < 24 * 60 else { return nil }
        return h
    }
}
