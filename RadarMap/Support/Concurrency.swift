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
