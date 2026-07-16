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
