//
//  ReportImpact.swift
//  RadarMap
//
//  «Польза водителям» (31E, п. 2): сколько своих отметок за окно и сколько
//  раз их подтвердили другие водители.
//
//  Откуда числа. Сервер знает отметки по UUID устройства (ротация 30 дней) и
//  голоса за них. `POST /api/mine` с текущим UUID отдаёт по своим отметкам
//  только пары {id, confirmers} — ни координат, ни времени, ни типа, ни чужих
//  отметок (server/api.py, test_api.py). Спрашивать по id было бы хуже: id
//  идут подряд, и кто угодно перебрал бы счётчики всех отметок страны. По
//  UUID — только то, что этот телефон сам и поставил.
//
//  Сервер стирает отметку через сутки после протухания, а UUID меняется раз
//  в месяц, — значит, сервер помнит недолго. Телефон держит у себя
//  наибольшее увиденное число по каждой своей отметке (`merged`): число
//  подтверждений со временем не убывает, а пропажа строки на сервере — не
//  «подтверждения отозвали».
//
//  «Подтверждений», а не «водителей»: один и тот же водитель мог подтвердить
//  две ваши отметки, а сложить различных людей по разным отметкам и разным
//  UUID нельзя, не храня чужих идентификаторов. Подтверждение — независимое:
//  другое устройство И другой адрес, как в жизненном цикле отметки.
//
//  Чистая логика — ReportImpactTests.
//

import Foundation

nonisolated enum ReportImpact {

    /// Своя отметка для счёта: когда поставлена, что известно о подтверждениях.
    struct Report: Equatable, Sendable {
        let at: Date
        /// Число независимых подтверждений с сервера (nil — не спрашивали).
        let confirmers: Int?
        /// Живой список хоть раз показал «подтверждена».
        let confirmed: Bool
    }

    struct Summary: Equatable, Sendable {
        var reports = 0
        /// Отметок, у которых есть хоть одно подтверждение.
        var confirmedReports = 0
        /// Подтверждений всего.
        var confirmations = 0
    }

    /// Итог за последние `days` дней. Отметка, о которой сервер ещё не
    /// ответил, но живой список видел подтверждённой, — одно подтверждение:
    /// меньше быть не может.
    static func summary(_ reports: [Report], now: Date,
                        days: Int = AppConfig.reportImpactDays) -> Summary {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        var result = Summary()
        for report in reports where report.at >= since && report.at <= now {
            result.reports += 1
            let count = max(report.confirmers ?? 0, report.confirmed ? 1 : 0)
            if count > 0 { result.confirmedReports += 1 }
            result.confirmations += count
        }
        return result
    }

    /// Что хранить по отметке после ответа сервера: наибольшее увиденное.
    /// Отметки нет в ответе (стёрта, другой UUID) — прежнее значение.
    static func merged(known: Int?, fetched: Int?) -> Int? {
        switch (known, fetched) {
        case let (k?, f?): return max(k, max(0, f))
        case let (nil, f?): return max(0, f)
        case let (k, nil): return k
        }
    }

    /// Пора ли спрашивать: есть свои отметки моложе окна и с прошлого
    /// вопроса прошло `interval`.
    static func isDue(lastFetch: Date?, now: Date, newest: Date?,
                      interval: TimeInterval = AppConfig.reportImpactRefreshSeconds,
                      days: Int = AppConfig.reportImpactDays) -> Bool {
        guard let newest, now.timeIntervalSince(newest) <= Double(days) * 86_400 else { return false }
        guard let lastFetch else { return true }
        // Часы перевели назад — спрашиваем, а не ждём «будущего» срока.
        return now.timeIntervalSince(lastFetch) >= interval || lastFetch > now
    }
}
