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
/// (`@concurrent`). Вместо `await Task.detached { … }.value`: та же работа на
/// пуле, но отмена и приоритет вызывающего наследуются — отменённый поиск
/// «по пути» больше не досчитывает миллионы проекций впустую (аудит 19.10).
@concurrent
nonisolated func offMain<T: Sendable>(_ work: @Sendable () throws -> T) async rethrows -> T {
    try work()
}
