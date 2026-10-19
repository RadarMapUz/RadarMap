//
//  DepartureReminder.swift
//  RadarMap
//
//  «Выезжайте раньше» (план 19.10, 8.8.7): локальное напоминание по будням
//  за 10 минут до выезда, который выгоднее обычного. Текст — из своей
//  истории поездок (Commute), без сервера: что бы ни узнал сервер о времени
//  выезда человека, это уже его распорядок дня.
//
//  Когда есть что сказать:
//  - задан срок «быть к 9:00» — «Выезжайте к 8:10 — к 9:00 с запасом»:
//    срок минус обычное время в пути минус запас, вниз до 5 минут;
//  - срока нет, но выезд в другое время стабильно быстрее (Commute.BestWindow:
//    ≥ 2 поездок, экономия ≥ 5 мин) — «В 7:45 до работы обычно 37 мин — на
//    11 мин быстрее, чем в 8:20».
//  Ни того, ни другого — напоминаний нет: «пора ехать» в обычное время человек
//  знает и без нас, и ежедневный пинг без пользы быстро выключают целиком.
//
//  Не напоминаем: в выходные (суббота — только у шестидневки со сроком), если
//  сегодня уже ехали на работу, и в отпуске — больше 10 дней без поездки.
//

import Foundation

/// На главном акторе: тексты собирает Formatting (часы и длительности в языке
/// приложения), а зовётся план из AppEnvironment — тоже с main.
enum DepartureReminder {

    struct Reminder: Equatable, Sendable {
        /// `departure-2026-10-21` — по дате, чтобы заменять, а не копить.
        let id: String
        let fire: Date
        let body: String
    }

    static let idPrefix = "departure-"

    /// Напоминания на `days` дней вперёд, начиная с сегодняшнего.
    static func plan(summary: Commute.Summary?, target: ArrivalTarget?, now: Date,
                     calendar: Calendar = .current,
                     days: Int = AppConfig.departureReminderDays) -> [Reminder] {
        guard let summary, summary.direction == .toWork, let usual = summary.usual else { return [] }
        // Отпуск или работа из дома: давно не ездили — молчим, пока не поедем.
        guard now.timeIntervalSince(summary.last.departure)
                <= Double(AppConfig.departureReminderVacationDays) * 86_400 else { return [] }

        let leave: (minute: Int, body: String)
        if let target, let minute = leaveBy(target: target, usual: usual) {
            leave = (minute, String(format: String(localized: "Выезжайте к %1$@ — к %2$@ с запасом (обычно %3$@ в пути)"),
                                    Formatting.clock(minuteOfDay: minute, calendar: calendar),
                                    Formatting.clock(minuteOfDay: target.minute, calendar: calendar),
                                    Formatting.unbreakable(Formatting.duration(usual))))
        } else if let best = summary.best, let usualDeparture = summary.usualDepartureMinute {
            leave = (best.startMinute,
                     String(format: String(localized: "В %1$@ до работы обычно %2$@ — на %3$@ быстрее, чем в %4$@"),
                            Formatting.clock(minuteOfDay: best.startMinute, calendar: calendar),
                            Formatting.unbreakable(Formatting.duration(best.medianDuration)),
                            Formatting.unbreakable(Formatting.duration(best.saving)),
                            Formatting.clock(minuteOfDay: usualDeparture, calendar: calendar)))
        } else {
            return []
        }

        let today = calendar.startOfDay(for: now)
        let drovePastToday = calendar.isDate(summary.last.departure, inSameDayAs: now)
        var result: [Reminder] = []
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let weekday = calendar.component(.weekday, from: day)   // 1 — воскресенье
            let workday = (2...6).contains(weekday) || (weekday == 7 && target?.saturday == true)
            guard workday, !(offset == 0 && drovePastToday) else { continue }
            let fireMinute = leave.minute - AppConfig.departureReminderLeadMinutes
            guard fireMinute >= 0,
                  let fire = calendar.date(bySettingHour: fireMinute / 60, minute: fireMinute % 60,
                                           second: 0, of: day),
                  fire > now else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let id = String(format: "%@%04d-%02d-%02d", idPrefix, parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            result.append(Reminder(id: id, fire: fire, body: leave.body))
        }
        return result
    }

    /// Во сколько выезжать к сроку: срок − обычное время − запас, вниз до 5 мин.
    /// nil — срок раньше, чем вообще можно доехать от полуночи (ночная смена).
    static func leaveBy(target: ArrivalTarget, usual: TimeInterval) -> Int? {
        let raw = target.minute - Int((usual / 60).rounded(.up)) - AppConfig.departureReminderMarginMinutes
        guard raw >= 0 else { return nil }
        return raw / 5 * 5
    }
}
