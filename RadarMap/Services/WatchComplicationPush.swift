//
//  WatchComplicationPush.swift
//  RadarMap
//
//  Толчок циферблату (14.5): когда приложение на часах не запущено,
//  applicationContext ждёт «удобного момента» — компликация «следующая
//  камера» могла бы час показывать прошлую поездку. Будит часы только
//  `transferCurrentComplicationUserInfo`, а он стоит денег: 50 в сутки, и
//  только пока компликация на активном циферблате.
//
//  Поэтому тратим его ровно на то, от чего циферблат становится ЛОЖЬЮ:
//  начало и конец поездки и другая камера впереди. Ступень дистанции — нет:
//  к камере впереди «< 1 км» остаётся правдой до самого проезда. Не чаще,
//  чем часы готовы перерисовать (`WatchComplication.minReloadInterval`), не
//  больше их суточного предела, и последние `watchComplicationEdgeReserve`
//  толчков — только на начало и конец поездки: часовая поездка по городу не
//  должна выбрать бюджет до своего конца, иначе циферблат весь вечер «в пути».
//
//  Контекст уходит всегда, толчок — сверху: кончился бюджет — часы узнают из
//  контекста, просто позже. Решения — здесь, чистые (WatchComplicationPushTests);
//  WatchConnectivity трогает только WatchBridgeService.
//
//  Честно о платформе: в SDK iOS 27 метод не помечен устаревшим, но инженеры
//  Apple на форуме (2024) писали, что с компликациями WidgetKit он «пока не
//  работает» — ведёт себя как transferUserInfo и доходит, когда приложение
//  часов проснётся само. Поэтому толчок несёт тот же снимок со временем
//  отправки, а часы берут его, только если он новее применённого и не
//  старше `WatchComplication.pushMaxAge` (WatchComplication.acceptsPush).
//

import Foundation

nonisolated enum WatchComplicationPush {
    /// Что важно циферблату: идёт ли поездка и какая камера впереди.
    nonisolated struct Key: Equatable, Sendable {
        var active: Bool
        /// id камеры впереди; nil — камеры нет (или нет поездки).
        var cameraID: Int?
    }

    nonisolated enum Event: Equatable, Sendable {
        /// Началась или кончилась поездка (и первый снимок после запуска).
        case tripEdge
        /// Другая камера впереди — или камера появилась / пропала.
        case cameraChanged
    }

    /// Учёт толчков — в памяти сервиса: после перезапуска первый снимок и так
    /// идёт как начало поездки.
    nonisolated struct Ledger: Equatable, Sendable {
        /// Что часы уже знают — толчком или контекстом, который точно дошёл.
        var delivered: Key?
        /// Последняя попытка толчка — и отказ бюджета тоже: свойство сессии не
        /// опрашиваем чаще интервала.
        var lastAttemptAt: Date?
        /// Сутки, за которые считаются толчки о камере.
        var day: Date?
        var cameraPushes = 0
    }

    /// Состояние связи — по событиям сессии, не опросом на каждом тике.
    nonisolated struct Link: Equatable, Sendable {
        /// Компликация на активном циферблате (`isComplicationEnabled`).
        var complicationEnabled: Bool
        /// Приложение часов на экране (`isReachable`): контекст дойдёт сразу.
        var watchAppRunning: Bool
    }

    nonisolated enum Route: Equatable, Sendable {
        /// Хватит контекста: циферблата нет, приложение часов и так на экране
        /// или суточный предел выбран.
        case context
        /// Подождать интервала — контекст ушёл, толчок повторим позже.
        case later
        /// Толкнуть, если хватит бюджета (`hasBudget`).
        case push(Event)
    }

    nonisolated enum Outcome: Equatable, Sendable {
        /// Часы узнают из контекста.
        case viaContext
        case pushed(Event)
        /// Бюджета нет — узнают из контекста; попытка считается для интервала.
        case noBudget
    }

    // MARK: - Решение

    static func key(isTripActive: Bool, cameraID: Int?) -> Key {
        Key(active: isTripActive, cameraID: isTripActive ? cameraID : nil)
    }

    /// Что часы ещё не знают. nil — циферблату нечего менять.
    static func event(for key: Key, delivered: Key?) -> Event? {
        guard let delivered, delivered.active == key.active else { return .tripEdge }
        return delivered.cameraID == key.cameraID ? nil : .cameraChanged
    }

    /// Каким путём донести событие.
    static func route(_ event: Event, link: Link, ledger: Ledger, now: Date,
                      calendar: Calendar = .current) -> Route {
        guard link.complicationEnabled, !link.watchAppRunning else { return .context }
        guard event == .cameraChanged else { return .push(.tripEdge) }
        if let last = ledger.lastAttemptAt {
            let elapsed = now.timeIntervalSince(last)
            // Часы назад (смена пояса) — не повод молчать: как у WatchComplication.
            if elapsed >= 0, elapsed < WatchComplication.minReloadInterval { return .later }
        }
        let today = ledger.day == calendar.startOfDay(for: now) ? ledger.cameraPushes : 0
        // Часы всё равно не перерисуют больше своего суточного предела.
        guard today < WatchComplication.maxRoutineReloadsPerDay else { return .context }
        return .push(.cameraChanged)
    }

    /// Хватит ли бюджета системы. 0 — компликации нет на циферблате или
    /// сутки выбраны: такой вызов ушёл бы обычным transferUserInfo — в
    /// очередь, без пробуждения.
    static func hasBudget(for event: Event, remaining: Int) -> Bool {
        switch event {
        case .tripEdge: return remaining > 0
        case .cameraChanged: return remaining > AppConfig.watchComplicationEdgeReserve
        }
    }

    /// Учёт после решения (`.later` не записывается: событие ждёт).
    static func recording(_ outcome: Outcome, key: Key, ledger: Ledger, now: Date,
                          calendar: Calendar = .current) -> Ledger {
        var next = ledger
        next.delivered = key
        switch outcome {
        case .viaContext:
            break
        case .noBudget:
            next.lastAttemptAt = now
        case .pushed(let event):
            next.lastAttemptAt = now
            guard event == .cameraChanged else { break }
            let day = calendar.startOfDay(for: now)
            if next.day != day {
                next.day = day
                next.cameraPushes = 0
            }
            next.cameraPushes += 1
        }
        return next
    }
}
