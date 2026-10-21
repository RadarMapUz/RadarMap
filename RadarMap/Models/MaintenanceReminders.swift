//
//  MaintenanceReminders.swift
//  RadarMap
//
//  Напоминания об обслуживании (план 20.10, этап 18.3) — когда и какие.
//
//  Правила:
//  - одно уведомление на пункт и порог («скоро», «пора») за цикл: сделали
//    заново или поменяли дату — новый цикл, новые пороги. «Просрочено» —
//    тот же порог «пора»: напоминать каждый день о том, что человек уже
//    слышал, — способ заставить выключить напоминания совсем;
//  - никогда в поездке: на старте поездки поставленное снимается (и
//    забывается — после поездки поставится заново), а пересчёт в поездке
//    не ставит ничего;
//  - после поездки, когда машина встала, — через пару минут, если день; иначе
//    и при открытии приложения — в 9:00 (сегодня, если ещё не 9, или завтра);
//  - выключатель (свой и системный) — ничего не ставить и снять поставленное;
//  - то, что человек сам только что увидел на экране, правя пункт, не
//    напоминается: порог отмечается «показанным» сразу;
//  - пересчёт идемпотентен: показанное и поставленное лежат в журнале
//    (id → момент показа), второй пересчёт с теми же данными не делает ничего.
//
//  Чистая логика — MaintenanceRemindersTests.
//

import Foundation

nonisolated enum MaintenanceReminders {

    enum Threshold: String, Sendable {
        case soon, due
    }

    /// Откуда пересчёт: от этого зависит, когда показать.
    enum Moment: Sendable {
        /// Поездка закончилась — машина стоит.
        case parked
        /// Приложение открыли, правили пункт — человек не за рулём, но и
        /// пинать его прямо сейчас не за что: утром.
        case opened
    }

    struct Reminder: Equatable, Sendable {
        let id: String
        let kind: MaintenanceKind
        let threshold: Threshold
        let fire: Date
    }

    struct Plan: Equatable, Sendable {
        /// Поставить (тот же id заменяет поставленное).
        var schedule: [Reminder] = []
        /// Снять поставленные и ещё не показанные.
        var cancel: [String] = []
        /// Журнал после плана: id → момент показа (прошедший — показано).
        var ledger: [String: Date] = [:]
    }

    static let idPrefix = "maintenance."

    static func id(_ kind: MaintenanceKind, _ threshold: Threshold, cycle: String) -> String {
        "\(idPrefix)\(kind.rawValue).\(threshold.rawValue).\(cycle)"
    }

    /// Порог состояния: «скоро» или «пора» («просрочено» — тоже «пора»).
    static func threshold(_ status: Maintenance.Status) -> Threshold? {
        switch status {
        case .soon: return .soon
        case .due, .overdue: return .due
        case .unknown, .ok: return nil
        }
    }

    /// `states` — включённые пункты этой машины. `enabled` — свой выключатель
    /// и разрешение системы вместе. `acknowledged` — пункты, которые человек
    /// только что правил на экране: их нынешний порог он уже видел.
    static func plan(states: [Maintenance.State], ledger: [String: Date], enabled: Bool,
                     tripActive: Bool, moment: Moment, now: Date,
                     acknowledged: Set<MaintenanceKind> = [],
                     calendar: Calendar = .current) -> Plan {
        var result = Plan()
        var journal = ledger

        // Чего хотим сейчас: по порогу на пункт, которому есть что сказать.
        var wanted: [String: Maintenance.State] = [:]
        for state in states {
            guard let threshold = threshold(state.status) else { continue }
            wanted[id(state.kind, threshold, cycle: state.cycle)] = state
        }

        // Поставленное, но ещё не показанное, — снять, если его больше не
        // хотим (сделали, выключили, «скоро» сменилось на «пора») или если
        // показывать сейчас нельзя вовсе (поездка, выключатель). Из журнала —
        // тоже: после поездки поставится заново.
        let mayShow = enabled && !tripActive
        for (key, fire) in journal where fire > now {
            if !mayShow || wanted[key] == nil {
                result.cancel.append(key)
                journal[key] = nil
            } else if let state = wanted[key], acknowledged.contains(state.kind) {
                // Ждало утра, а человек уже смотрит на этот пункт.
                result.cancel.append(key)
                journal[key] = now
            }
        }

        if mayShow {
            let fire = fireTime(moment: moment, now: now, calendar: calendar)
            for key in wanted.keys.sorted() {
                guard journal[key] == nil, let state = wanted[key],
                      let threshold = threshold(state.status) else { continue }
                if acknowledged.contains(state.kind) {
                    // Видел на экране — показанным считаем сейчас.
                    journal[key] = now
                    continue
                }
                result.schedule.append(Reminder(id: key, kind: state.kind, threshold: threshold, fire: fire))
                journal[key] = fire
            }
        }

        // Журнал не копится: показанное о прошлых циклах и выключенных пунктах
        // больше не нужно. Нынешние циклы держим при любом выключателе —
        // иначе после поездки «показанное» забылось бы и пришло второй раз.
        let current = Set(states.flatMap { state in
            [id(state.kind, .soon, cycle: state.cycle), id(state.kind, .due, cycle: state.cycle)]
        })
        journal = journal.filter { current.contains($0.key) }
        result.cancel.sort()
        result.ledger = journal
        return result
    }

    /// Когда показать: после стоянки днём — через пару минут; иначе — в
    /// ближайшие 9:00.
    static func fireTime(moment: Moment, now: Date, calendar: Calendar = .current) -> Date {
        let hour = calendar.component(.hour, from: now)
        if case .parked = moment,
           hour >= AppConfig.maintenanceNotifyFromHour, hour < AppConfig.maintenanceNotifyUntilHour {
            return now.addingTimeInterval(AppConfig.maintenanceParkedDelaySeconds)
        }
        let today = calendar.startOfDay(for: now)
        let morning = calendar.date(bySettingHour: AppConfig.maintenanceNotifyFromHour, minute: 0,
                                    second: 0, of: today) ?? today
        if morning > now { return morning }
        return calendar.date(byAdding: .day, value: 1, to: morning) ?? morning.addingTimeInterval(86_400)
    }
}
