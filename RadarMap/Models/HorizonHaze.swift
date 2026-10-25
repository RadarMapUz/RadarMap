//
//  HorizonHaze.swift
//  RadarMap
//
//  Дымка у дальнего края наклонной карты (29.F).
//
//  Неба у MapLibre Native 6.31 нет, и под наклоном 45–58° верх кадра — это
//  сжатые в полоску дальние тайлы: мелкая рябь домов и дорог, обрезанная
//  краем экрана, «пустой горизонт». У Amap, Яндекса и Apple дальний план
//  тонет в воздухе. Здесь то же самое дёшево: градиент поверх карты и под
//  интерфейсом, высота и сила — от наклона. Днём — светлая голубоватая
//  дымка, ночью — тёмно-синяя с лёгким свечением у горизонта.
//
//  Решение — чистое (HorizonHazeTests): у верхнего края не плотнее
//  `AppConfig.hazeTopAlpha`, к середине высоты дымки — вдвое прозрачнее,
//  чтобы камера у верхнего края не тонула (дымка — над картой, значит, и
//  над маркерами). Плоская карта (горячий телефон, обзор сверху) — без дымки.
//
//  Только картинка.
//

import Foundation

nonisolated enum HorizonHaze {

    /// Как рисовать дымку при данном наклоне.
    struct Look: Equatable, Sendable {
        /// Доля высоты вида сверху, которую занимает градиент.
        var heightShare: Double
        /// Общая непрозрачность слоя (0 — дымки нет).
        var opacity: Double
    }

    static func look(pitchDegrees: Double) -> Look {
        let start = AppConfig.hazeStartPitch, full = AppConfig.hazeFullPitch
        let low = AppConfig.hazeMinHeightShare, high = AppConfig.hazeMaxHeightShare
        guard pitchDegrees > start else { return Look(heightShare: low, opacity: 0) }
        let t = min(1, (pitchDegrees - start) / (full - start))
        let eased = t * t * (3 - 2 * t)
        return Look(heightShare: low + (high - low) * eased, opacity: eased)
    }

    /// Ступень градиента: доля высоты дымки (0 — верхний край) и цвет RGBA.
    struct Stop: Equatable, Sendable {
        var at: Double
        var rgb: UInt32
        var alpha: Double
    }

    /// Ступени дымки темы: днём — воздух светлее земли, ночью — тёмно-синий
    /// с тонкой светлой полосой у горизонта (город светится в небо).
    static func stops(daylight: Bool) -> [Stop] {
        if daylight {
            return [Stop(at: 0, rgb: 0xDCE6F2, alpha: AppConfig.hazeTopAlpha),
                    Stop(at: 0.35, rgb: 0xE4EBF4, alpha: 0.5),
                    Stop(at: 0.7, rgb: 0xEEF2F7, alpha: 0.14),
                    Stop(at: 1, rgb: 0xF2F4F7, alpha: 0)]
        }
        return [Stop(at: 0, rgb: 0x0A0F18, alpha: AppConfig.hazeTopAlpha),
                Stop(at: 0.3, rgb: 0x1A2436, alpha: 0.55),
                Stop(at: 0.62, rgb: 0x182030, alpha: 0.16),
                Stop(at: 1, rgb: 0x16181C, alpha: 0)]
    }
}
