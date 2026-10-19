//
//  DeepLink.swift
//  RadarMap
//
//  Куда ведёт radarmap://… — одно чистое решение вместо проверок host()
//  по месту. Пуш «Итоги поездки» шлёт radarmap://trip/last, а обработчик
//  смотрел только на host и открывал обзор Итогов: человек, нажавший
//  уведомление про ЭТУ поездку, искал её в списке сам (аудит 19.10).
//

import Foundation

nonisolated enum DeepLink: Equatable, Sendable {
    /// Обзор «Итогов» (виджеты: radarmap://stats, radarmap://trip).
    case stats
    /// Деталка последней сохранённой поездки (пуш: radarmap://trip/last).
    case lastTrip

    static let scheme = "radarmap"

    /// Ссылки, которые обрабатывает карта. Остальные (start-trip, map) —
    /// не наши: их разбирают RootView и система, здесь nil.
    static func parse(_ url: URL) -> DeepLink? {
        guard url.scheme == scheme else { return nil }
        switch url.host() {
        case "stats":
            return .stats
        case "trip":
            let path = url.pathComponents.filter { $0 != "/" }
            return path == ["last"] ? .lastTrip : .stats
        default:
            return nil
        }
    }
}
