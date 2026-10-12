//
//  DrivingDeclutter.swift
//  RadarMap
//
//  «На ходу — только дорога» (владелец, 12.10: «убери тоннели и другие
//  отвлекающие моменты при езде, при остановке можно показать»).
//
//  На ходу карта прячет то, что водителю за рулём не нужно и отвлекает:
//  подземные пешеходные переходы и тротуары (широкие фиолетовые полосы
//  поперёк проспекта), наложение тоннелей, деревья, тени, парковочную
//  разметку, значки заведений. Остаются дорога, полосы, «зебры», светофоры,
//  заправки, маршрут и камеры. Встали — всё возвращается: на стоянке
//  рассмотреть окрестность можно.
//
//  Решение с гистерезисом, чтобы на светофоре карта не мигала слоями:
//  прячем с `hideKmh`, показываем, только простояв `showAfter` секунд
//  медленнее `showKmh`. Видимость слоёв меняется без перезагрузки стиля.
//
//  Чистая логика, время — параметром; DrivingDeclutterTests.
//

import Foundation

nonisolated struct DrivingDeclutter: Equatable, Sendable {

    static let hideKmh = 12.0
    static let showKmh = 4.0
    static let showAfter: TimeInterval = 4

    private(set) var isDecluttered = false
    private var slowSince: Date?

    /// Новое состояние по скорости в момент `now`.
    @discardableResult
    mutating func update(speedKmh: Double, at now: Date) -> Bool {
        let speed = speedKmh.isFinite ? max(0, speedKmh) : 0
        if speed >= Self.hideKmh {
            isDecluttered = true
            slowSince = nil
        } else if speed <= Self.showKmh {
            let since = slowSince ?? now
            slowSince = since
            if isDecluttered, now.timeIntervalSince(since) >= Self.showAfter { isDecluttered = false }
        } else {
            // Между порогами — как было: и не прячем, и не показываем.
            slowSince = nil
        }
        return isDecluttered
    }
}
