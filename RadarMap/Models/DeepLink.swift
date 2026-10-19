//
//  DeepLink.swift
//  RadarMap
//
//  Куда ведёт radarmap://… — одно чистое решение вместо проверок host()
//  по месту. Пуш «Итоги поездки» слал radarmap://trip/last, а обработчик
//  смотрел только на host и открывал обзор Итогов: человек, нажавший
//  уведомление про ЭТУ поездку, искал её в списке сам (аудит 19.10).
//  Теперь пуш несёт id записи: «последняя» к моменту тапа может быть уже
//  другой поездкой.
//

import Foundation

nonisolated enum DeepLink: Equatable, Sendable {
    /// Обзор «Итогов» (виджеты: radarmap://stats, radarmap://trip).
    case stats
    /// Деталка поездки по id записи (пуш: radarmap://trip/<id>).
    case trip(id: Double)
    /// Последняя сохранённая поездка (пуши до 19.10: radarmap://trip/last).
    case lastTrip

    static let scheme = "radarmap"

    /// Ссылки, которые обрабатывает карта. Остальные (start-trip, map) —
    /// не наши: их разбирают RootView и система, здесь nil.
    static func trip(_ id: Double) -> URL {
        URL(string: "\(scheme)://trip/\(id)")!
    }

    static func parse(_ url: URL) -> DeepLink? {
        guard url.scheme == scheme else { return nil }
        switch url.host() {
        case "stats":
            return .stats
        case "trip":
            let path = url.pathComponents.filter { $0 != "/" }
            guard path.count == 1 else { return .stats }
            if path[0] == "last" { return .lastTrip }
            if let id = Double(path[0]), id.isFinite { return .trip(id: id) }
            return .stats
        default:
            return nil
        }
    }
}
