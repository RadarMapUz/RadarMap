//
//  CameraActivityAttributes.swift
//  RadarMap
//
//  Контракт Live Activity — компилируется и в приложение, и в widget-extension.
//

import Foundation
#if canImport(ActivityKit)
import ActivityKit

// nonisolated: приложение собрано с MainActor по умолчанию, а ActivityKit
// кодирует состояние вне главного потока (`@concurrent` в LiveActivityService) —
// изолированное соответствие в Swift 6 стало бы ошибкой.
nonisolated struct CameraActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable {
        /// Адрес/название ближайшей камеры (nil — рядом камер нет).
        var nearestTitle: String?
        /// SF Symbol типа камеры ("camera.fill" / "speedometer").
        var nearestSymbol: String
        /// Расстояние до ближайшей камеры, метры.
        var distanceMeters: Double?
        /// Когда машина будет у камеры на текущей скорости; nil — стоим или
        /// камеры нет. Полосу приближения между обновлениями двигает сама
        /// система (ProgressView(timerInterval:)) — плашку не нужно будить на
        /// каждые 25 м, чтобы картинка жила (аудит энергии 19.10).
        var arrivesAt: Date?
        /// Начало полосы — момент отправки состояния.
        var since: Date?
        // «Камер вокруг» убрано 19.10: строка «следит за N камерами» была шумом,
        // а неквантованный счётчик слал обновления плашки и в пробке на месте.
    }
}
#endif
