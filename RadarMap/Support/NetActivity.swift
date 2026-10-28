//
//  NetActivity.swift
//  RadarMap
//
//  Счёт выходов в сеть (36B, 28.10). Батарею ест не байт, а пробуждение
//  сотового радио: после каждого обмена LTE ещё 5–10 с держит высокое
//  потребление («хвост»). Поэтому считаем два числа — запросы и «окна»: окно
//  открывает запрос, начатый после того, как хвост прошлого обмена остыл;
//  запросы внутри одного окна радио почти бесплатны.
//
//  `RadioWindows` — чистая модель (тест на фальшивых часах, NetSchedulerTests),
//  `NetActivity` — живой счётчик в APIClient, пишет строку в журнал на каждое
//  новое окно: по ней замеряли до/после на симуляторе.
//

import Foundation
import os

/// Окна радио по запросам: новый запрос, начатый позже `tail` после конца
/// всех прежних, — новое пробуждение.
nonisolated struct RadioWindows: Equatable, Sendable {
    let tail: TimeInterval
    private(set) var windows = 0
    private(set) var requests = 0
    private var lastEnd: Date?
    private var inFlight = 0

    init(tail: TimeInterval = AppConfig.radioTailSeconds) {
        self.tail = tail
    }

    /// true — этот запрос разбудил радио (открыл новое окно).
    @discardableResult
    mutating func began(at moment: Date) -> Bool {
        requests += 1
        defer { inFlight += 1 }
        guard inFlight == 0 else { return false }
        if let lastEnd, moment.timeIntervalSince(lastEnd) <= tail { return false }
        windows += 1
        return true
    }

    mutating func ended(at moment: Date) {
        inFlight = max(0, inFlight - 1)
        lastEnd = max(lastEnd ?? moment, moment)
    }
}

/// Живой счётчик всего, что прошло через APIClient. Только счёт и журнал:
/// ни путей, ни времени наружу не отдаёт.
nonisolated enum NetActivity {
    private static let state = OSAllocatedUnfairLock(initialState: RadioWindows())

    static func began(_ path: String, at moment: Date) {
        let (opened, totals) = state.withLock { windows -> (Bool, (Int, Int)) in
            let opened = windows.began(at: moment)
            return (opened, (windows.windows, windows.requests))
        }
        if opened {
            Log.network.notice("радио: окно \(totals.0, privacy: .public), запрос \(totals.1, privacy: .public) — \(path, privacy: .public)")
        } else {
            Log.network.info("радио: в том же окне, запрос \(totals.1, privacy: .public) — \(path, privacy: .public)")
        }
    }

    static func ended(at moment: Date) {
        state.withLock { $0.ended(at: moment) }
    }

    /// Окна и запросы с запуска процесса (DEBUG-экраны, замер).
    static var totals: (windows: Int, requests: Int) {
        state.withLock { ($0.windows, $0.requests) }
    }
}
