//
//  SpeedSmoother.swift
//  RadarMap
//
//  Скорость на спидометре: сглаживать шум, не пряча динамику.
//
//  Прежнее сглаживание было парой констант (0.6 старого + 0.4 нового) и
//  предполагало тик раз в секунду. Но тики НЕ раз в секунду: адаптивный GPS
//  на крейсере отдаёт фикс раз в 15–25 метров, в городе это 2–3 секунды, — и
//  константный вес на редких тиках растягивал хвост на пять с лишним секунд.
//  Водитель тормозит, а цифра ещё едет. Спидометр, который врёт при
//  торможении, хуже дёрганого: по нему принимают решение у камеры.
//
//  Два правила вместо весов:
//  * **Сглаживание зависит от времени**, а не от номера тика: вес нового
//    значения — 1 − exp(−dt/τ). Редкие тики почти не сглаживаются (за три
//    секунды сглаживать уже нечего), частые — как раньше.
//  * **Большой скачок — не шум.** GPS-шум на крейсере — ±2–3 км/ч; перепад
//    больше `snapDeltaKmh` бывает только от настоящего разгона или
//    торможения, и его показываем сразу, без хвоста.
//
//  Чистая структура без обращения к часам — время передаётся параметром,
//  поэтому поведение воспроизводимо в тестах (SpeedSmootherTests).
//

import Foundation

nonisolated struct SpeedSmoother {

    /// Постоянная времени сглаживания: за τ секунд цифра проходит ~63%
    /// разницы. 0.7 с гасит покадровый шум, но не отстаёт заметно глазу.
    static let tau: TimeInterval = 0.7
    /// Перепад, который считаем настоящим изменением скорости, а не шумом.
    static let snapDeltaKmh: Double = 6
    /// Пауза, после которой прошлое значение устарело (туннель, остановка
    /// GPS): начинаем с сырого, сглаживать старую скорость с новой нельзя.
    static let staleAfterSeconds: TimeInterval = 5

    private var value: Double?
    private var lastAt: Date?

    /// Ниже 1 км/ч показываем 0: дрожь стоящего GPS не должна читаться как
    /// «ползу». Тот же порог, что был в LocationService.
    private static func floored(_ kmh: Double) -> Double { kmh < 1 ? 0 : kmh }

    mutating func update(rawKmh: Double, at now: Date) -> Double {
        defer { lastAt = now }
        guard let previous = value, let lastAt,
              now.timeIntervalSince(lastAt) < Self.staleAfterSeconds else {
            let fresh = Self.floored(rawKmh)
            value = fresh
            return fresh
        }
        if abs(rawKmh - previous) > Self.snapDeltaKmh {
            let fresh = Self.floored(rawKmh)
            value = fresh
            return fresh
        }
        let dt = max(0, now.timeIntervalSince(lastAt))
        let alpha = 1 - exp(-dt / Self.tau)
        let smoothed = Self.floored(previous + (rawKmh - previous) * alpha)
        value = smoothed
        return smoothed
    }

    /// Сброс при смене режима геолокации: непрерывность значений разорвана,
    /// и первое значение нового режима должно быть сырым.
    mutating func reset() {
        value = nil
        lastAt = nil
    }
}
