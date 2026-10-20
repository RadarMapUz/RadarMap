//
//  WatchComplication.swift
//  RadarMap
//
//  Компликация часов «следующая камера» (план 19.10, 9.3б): значок типа
//  камеры и дистанция прямо на циферблате, «нет поездки» вне её.
//
//  Данные — из того же applicationContext, что и HUD часов: приложение часов
//  кладёт снимок в App Group, расширение компликации его только рисует.
//  Решения — что показать, когда снимок устарел и когда тратить перезагрузку
//  WidgetKit — здесь, чистые и без часов/диска: файл компилируется и в
//  приложение телефона, и его проверяет WatchComplicationTests.
//
//  Два правила, на которых всё стоит:
//
//  * Дистанция — ВЕРХНЯЯ граница («< 1 км»), а не число. Перезагрузок у
//    WidgetKit — десятки в сутки, а не одна в секунду: между ними машина
//    проезжает километры, и «800 м» на циферблате через две минуты было бы
//    ложью. К камере впереди расстояние только сокращается, поэтому «ближе
//    1 км» остаётся правдой до самого проезда — а проезд меняет камеру и
//    сам по себе повод обновиться.
//  * Бюджет. Перезагрузка — на начало и конец поездки всегда, на смену
//    камеры или ступени — не чаще `minReloadInterval` и не больше
//    `maxRoutineReloadsPerDay` в сутки. Не на каждый GPS-тик: бюджет,
//    выбранный впустую, кончился бы ровно к концу поездки.
//

import Foundation

/// То, что рисует компликация, — и ничего сверх этого.
nonisolated struct WatchComplicationState: Codable, Equatable, Sendable {
    nonisolated struct Camera: Codable, Equatable, Sendable {
        /// SF Symbol типа (CameraType.symbolName на телефоне).
        var symbol: String
        /// Адрес камеры; nil — подпись «до камеры».
        var title: String?
        /// Верхняя граница дистанции, м (ступень `WatchComplication.bounds`);
        /// nil — дальше самой крупной ступени.
        var within: Int?
    }

    var isTripActive: Bool
    /// Камера впереди; nil в поездке — «камер рядом нет».
    var camera: Camera?

    static let noTrip = WatchComplicationState(isTripActive: false, camera: nil)
}

/// Снимок в App Group: состояние и когда оно получено.
nonisolated struct WatchComplicationSnapshot: Codable, Equatable, Sendable {
    var state: WatchComplicationState
    var updatedAt: Date
}

/// Учёт перезагрузок — живёт у приложения часов, расширению не нужен.
nonisolated struct WatchComplicationLedger: Codable, Equatable, Sendable {
    /// Что было на циферблате после последней перезагрузки.
    var lastState: WatchComplicationState?
    var lastReloadAt: Date?
    /// Сутки, за которые считаются плановые перезагрузки.
    var day: Date?
    var routineReloads = 0
}

nonisolated enum WatchComplication {
    /// Вид виджета — один на расширение и приложение часов.
    static let kind = "RadarWatchNextCamera"
    /// Ключи в App Group.
    static let snapshotKey = "watch.complication.snapshot"
    static let ledgerKey = "watch.complication.ledger"

    /// Ступени дистанции, м. Мельче не нужно: между перезагрузками машина
    /// проезжает больше, чем шаг ступени.
    static let bounds = [300, 500, 1000, 2000, 5000]
    /// Плановые перезагрузки (смена камеры или ступени) — не чаще.
    static let minReloadInterval: TimeInterval = 120
    /// И не больше за сутки; начало и конец поездки — вне счёта.
    static let maxRoutineReloadsPerDay = 40
    /// Снимок поездки старше — показываем «на 12:04» приглушённо: часы не
    /// отличат стоянку на светофоре (телефон молчит — цифры те же) от
    /// разряженного телефона, поэтому не судим, а называем время.
    static let staleAfter: TimeInterval = 10 * 60
    /// В поездке тот же снимок освежаем раньше, чем он потускнеет: на трассе
    /// ступень «> 5 км» держится полчаса, и без этого живые данные выглядели бы
    /// старыми.
    static let refreshAfter: TimeInterval = 8 * 60

    // MARK: - Состояние

    /// Ступень: наименьшая граница, не меньше дистанции; nil — дальше всех.
    static func bound(forMeters meters: Int) -> Int? {
        bounds.first { meters <= $0 }
    }

    /// Состояние из того, что прислал телефон (ключи applicationContext).
    static func state(isTripActive: Bool, symbol: String?, title: String?,
                      distanceMeters: Int?) -> WatchComplicationState {
        guard isTripActive else { return .noTrip }
        guard let distanceMeters, distanceMeters >= 0 else {
            return WatchComplicationState(isTripActive: true, camera: nil)
        }
        let camera = WatchComplicationState.Camera(symbol: symbol ?? "camera.fill",
                                                   title: title,
                                                   within: bound(forMeters: distanceMeters))
        return WatchComplicationState(isTripActive: true, camera: camera)
    }

    // MARK: - Перезагрузка

    enum Reason: Equatable, Sendable {
        /// Началась или кончилась поездка, первый снимок — всегда.
        case tripChanged
        /// Другая камера или ступень.
        case contentChanged
        /// Тот же снимок, но скоро потускнеет.
        case refresh
    }

    /// Тратить ли перезагрузку сейчас. nil — нет.
    static func reloadReason(for state: WatchComplicationState,
                             ledger: WatchComplicationLedger, now: Date,
                             calendar: Calendar = .current) -> Reason? {
        guard let last = ledger.lastState, let lastAt = ledger.lastReloadAt else {
            return .tripChanged
        }
        if state.isTripActive != last.isTripActive { return .tripChanged }
        let elapsed = now.timeIntervalSince(lastAt)
        // Часы назад (смена пояса, ручная установка) — не повод молчать сутки.
        let reason: Reason
        if state != last {
            reason = .contentChanged
        } else if state.isTripActive, elapsed >= refreshAfter || elapsed < 0 {
            reason = .refresh
        } else {
            return nil
        }
        guard elapsed >= minReloadInterval || elapsed < 0 else { return nil }
        guard routineReloads(ledger, now: now, calendar: calendar) < maxRoutineReloadsPerDay else {
            return nil
        }
        return reason
    }

    /// Учёт после перезагрузки.
    static func recording(_ reason: Reason, state: WatchComplicationState,
                          ledger: WatchComplicationLedger, now: Date,
                          calendar: Calendar = .current) -> WatchComplicationLedger {
        let day = calendar.startOfDay(for: now)
        var next = ledger
        if next.day != day {
            next.day = day
            next.routineReloads = 0
        }
        if reason != .tripChanged { next.routineReloads += 1 }
        next.lastState = state
        next.lastReloadAt = now
        return next
    }

    private static func routineReloads(_ ledger: WatchComplicationLedger, now: Date,
                                       calendar: Calendar) -> Int {
        ledger.day == calendar.startOfDay(for: now) ? ledger.routineReloads : 0
    }

    // MARK: - Показ

    /// Снимок поездки устарел — рисуем приглушённо и со временем.
    static func isStale(_ snapshot: WatchComplicationSnapshot, now: Date) -> Bool {
        snapshot.state.isTripActive && now.timeIntervalSince(snapshot.updatedAt) > staleAfter
    }

    /// Моменты записей таймлайна: сейчас и, для свежей поездки, — когда
    /// снимок потускнеет. Без лишней перезагрузки: WidgetKit сам перейдёт.
    static func entryDates(for snapshot: WatchComplicationSnapshot, now: Date) -> [Date] {
        var dates = [now]
        if snapshot.state.isTripActive {
            let staleAt = snapshot.updatedAt.addingTimeInterval(staleAfter + 1)
            if staleAt > now { dates.append(staleAt) }
        }
        return dates
    }

    /// «< 300 м», «< 1 км», «> 5 км».
    static func distanceText(within: Int?) -> String {
        guard let within else {
            let far = (bounds.last ?? 5000) / 1000
            return String(format: String(localized: "> %@ км"), String(far))
        }
        if within < 1000 {
            return String(format: String(localized: "< %@ м"), String(within))
        }
        return String(format: String(localized: "< %@ км"), String(within / 1000))
    }
}
