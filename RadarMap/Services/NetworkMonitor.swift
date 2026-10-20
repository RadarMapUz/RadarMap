//
//  NetworkMonitor.swift
//  RadarMap
//
//  Есть ли связь. Нужно ровно для одной честной фразы на экране.
//
//  Тайлы карты MapKit требуют сети — своих карт у нас нет и быть не может.
//  На трассе Ташкент–Бухара карта станет серой, и человек решит, что
//  приложение сломалось. При этом оповещения о камерах будут работать как
//  обычно: база в 3467 точек лежит на телефоне, и связь ей не нужна.
//
//  Это и надо сказать вслух. Разница между «приложение сломалось» и «карта не
//  грузится, но предупреждать я продолжаю» — это разница между удалением и
//  доверием, и стоит она одной плашки.
//

import Foundation
import Network
import Observation
import os

@MainActor
@Observable
final class NetworkMonitor {
    private(set) var isOnline = true   // до первого ответа считаем, что связь есть
    /// Связь есть, а сервер карты не отвечает (S22): карта — со скачанной
    /// области, плашка — «сервер карты недоступен». Ставит AppEnvironment по
    /// сторожу тайлов.
    private(set) var isTileServerDown = false
    /// Карта может грузиться из сети: и связь, и сервер карты на месте.
    var isMapOnline: Bool { isOnline && !isTileServerDown }

    func setTileServerDown(_ down: Bool) {
        guard isTileServerDown != down else { return }
        isTileServerDown = down
        Log.network.notice("сервер карты: \(down ? "недоступен" : "отвечает", privacy: .public)")
    }
    /// Связь платная или урезанная (сотовая, режим экономии трафика). До
    /// первого ответа — да: предложить скачать сотни мегабайт по мобильной
    /// сети хуже, чем не предложить вовсе.
    private(set) var isExpensive = true

    @ObservationIgnored private let monitor = NWPathMonitor()
    /// Связь вернулась (переход «нет → есть») — маршрут без сети заменить
    /// серверным (12б.10). Ставит AppEnvironment.
    @ObservationIgnored var onOnline: (() -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onOnline,
                                               "NetworkMonitor.onOnline") }
    }

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive || path.isConstrained
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isExpensive != expensive { self.isExpensive = expensive }
                guard self.isOnline != online else { return }
                self.isOnline = online
                Log.network.notice("связь: \(online ? "есть" : "нет", privacy: .public)")
                if online { self.onOnline?() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "uz.radarmap.network"))
    }

    /// Снос без прыжка на актор: SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor
    /// синтезирует isolated deinit КАЖДОМУ классу, а он в рантайме iOS 26
    /// ведёт в free() по указателю, который никто не выделял (подробный
    /// разбор — в MotionService). Этот класс был одним из двух, кому
    /// пометку забыли поставить, — и единственным, кто в deinit ещё и
    /// делает работу, то есть попадает в баг охотнее пустого.
    nonisolated deinit { monitor.cancel() }
}
