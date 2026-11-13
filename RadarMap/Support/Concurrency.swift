//
//  Concurrency.swift
//  RadarMap
//
//  Мелкие удобства конкурентности.
//

import Foundation

extension Task where Success == Never, Failure == Never {
    /// Пауза для UI-таймингов (автоскрытие, дебаунс, задержки анимаций).
    /// Отмену Task переживает молча — это штатный путь, а не ошибка.
    static func pause(seconds: Double) async {
        try? await sleep(for: .seconds(seconds))
    }
}

/// Тяжёлая работа вне главного потока — правило 11 ARCHITECTURE.md
/// (`@concurrent`), когда она отвечает на действие человека: приоритет
/// вызывающего наследуется (поиск «по пути», применение базы, варианты
/// маршрута). Синхронное тело отменой не прерывается — его обрывает только
/// проверка `Task.isCancelled` внутри. Фоновая работа, которой нужен НИЗКИЙ
/// приоритет (разбор лимитов при запуске, оценка объезда), — по-прежнему
/// `Task.detached(priority: .utility)`: offMain поднял бы её до приоритета
/// главного потока.
@concurrent
nonisolated func offMain<T: Sendable>(_ work: @Sendable () throws -> T) async rethrows -> T {
    try work()
}

/// Дело к сроку: отменяется только ожидание, а не само дело. Дело идёт в своей
/// задаче — оно может снять этот же срок (или завести новый), не обрывая себя.
/// Раньше отсчёт «Отметить» отправлял треногу в задаче таймера, отправка первым
/// делом снимала таймер — и отменяла собственный запрос: тренога по молчанию
/// уходила в очередь с «нет связи» при полной антенне (92).
@MainActor
final class Deadline {
    /// Снос без прыжка на актор — обход бага рантайма (см. MobileCameraService).
    nonisolated deinit {}

    private var waiting: Task<Void, Never>?

    func arm(_ at: Date, _ action: @escaping @MainActor () async -> Void) {
        waiting?.cancel()
        waiting = Task { [weak self] in
            // Ошибка sleep — только отмена: срок сняли раньше.
            try? await Task.sleep(for: .seconds(max(0, at.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.waiting = nil
            Task { await action() }
        }
    }

    func cancel() {
        waiting?.cancel()
        waiting = nil
    }

    var isArmed: Bool { waiting != nil }
}
