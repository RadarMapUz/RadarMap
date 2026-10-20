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
    /// `tripActive` — уже едем: сегодняшнего «пора выезжать» нет (вход плана,
    /// а не разовая отмена — иначе следующий пересчёт возвращал его в дороге).
    static func plan(summary: Commute.Summary?, target: ArrivalTarget?, now: Date,
                     tripActive: Bool = false, calendar: Calendar = .current,
                     days: Int = AppConfig.departureReminderDays) -> [Reminder] {
        guard let summary, summary.direction == .toWork, let usual = summary.usual else { return [] }
        let vacation = Double(AppConfig.departureReminderVacationDays) * 86_400

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
            // Будни без праздников: «Выезжайте раньше» в первый день хайита —
            // будильник на выходной (UzHolidays).
            let workday = target?.applies(on: day, calendar: calendar)
                ?? UzHolidays.isWorkday(day, calendar: calendar)
            guard workday, !(offset == 0 && (drovePastToday || tripActive)) else { continue }
            let fireMinute = leave.minute - AppConfig.departureReminderLeadMinutes
            guard fireMinute >= 0,
                  let fire = calendar.date(bySettingHour: fireMinute / 60, minute: fireMinute % 60,
                                           second: 0, of: day),
                  fire > now,
                  // Отпуск или работа из дома — по КАЖДОМУ дню: неделя, уже
                  // поставленная, не должна звонить в первый день отпуска.
                  fire.timeIntervalSince(summary.last.departure) <= vacation else { continue }
            result.append(Reminder(id: id(for: day, calendar: calendar), fire: fire, body: leave.body))
        }
        return result
    }

    /// Что сделать с уже поставленными напоминаниями.
    enum Step: Equatable {
        /// Ничего: план тот же — или считать его ещё не из чего.
        case keep
        /// Снять поставленное и поставить план; `deliveredToday` — снять и
        /// показанное сегодня (поехали).
        case replace(deliveredToday: Bool)
        /// Поехали, а план считать не из чего: снять только сегодняшнее.
        case dropToday
    }

    /// `dataLoaded` — история и профиль дороги прочитаны с диска. До этого
    /// пустой план значит «ещё не знаем», а не «напоминать не о чем»: после
    /// перезагрузки телефона процесс поднимается до первой разблокировки,
    /// история не читается, выученных Дом/Работы нет — и пересчёт снимал всю
    /// поставленную неделю (ревью 14.1, хвост 14.8; то же правило, что у
    /// виджета дороги). Прочитается второе из двух — его колбэк и переставит.
    /// Поехали до чтения — сегодняшнее «пора выезжать» снимается и так: для
    /// этого план не нужен.
    static func step(plan: [Reminder], scheduled: [Reminder]?, dataLoaded: Bool,
                     tripEdge: Bool, tripActive: Bool) -> Step {
        guard dataLoaded else { return tripEdge && tripActive ? .dropToday : .keep }
        guard plan != scheduled || tripEdge else { return .keep }
        return .replace(deliveredToday: tripEdge && tripActive)
    }

    /// `departure-2026-10-21` — один id на день: замена, а не копия.
    static func id(for day: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%@%04d-%02d-%02d", idPrefix, parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// id всех дней, где напоминание могло стоять, — чтобы снять их без
    /// опроса центра уведомлений (неделя назад и две вперёд).
    static func allIDs(around now: Date, calendar: Calendar = .current) -> [String] {
        let today = calendar.startOfDay(for: now)
        return (-7...14).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
            .map { id(for: $0, calendar: calendar) }
    }

    /// Во сколько выезжать к сроку: срок − обычное время − запас, вниз до 5 мин.
    /// nil — срок раньше, чем вообще можно доехать от полуночи (ночная смена).
    static func leaveBy(target: ArrivalTarget, usual: TimeInterval) -> Int? {
        let raw = target.minute - Int((usual / 60).rounded(.up)) - AppConfig.departureReminderMarginMinutes
        guard raw >= 0 else { return nil }
        return raw / 5 * 5
    }
}
