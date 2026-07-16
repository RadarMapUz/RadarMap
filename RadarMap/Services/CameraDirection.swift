//
//  CameraDirection.swift
//  RadarMap
//
//  Где камера относительно курса — «умно», а не по сырой геометрии к точке.
//  Чистый классификатор: широкая мёртвая зона впереди (камера почти по ходу
//  не называется «сбоку»), приоритет маршрута (камера на твоём пути = «прямо»),
//  и сглаживание, чтобы стрелка не дёргалась от смещённых координат в базе.
//

import CoreLocation

nonisolated enum CameraDirection: Equatable {
    case ahead          // прямо по ходу
    case left, right    // сбоку
    case behindLeft, behindRight

    /// Классификация по относительному азимуту (0 = прямо по ходу, растёт по часовой).
    /// `deadZone` — половина сектора «прямо»: камера в ±deadZone от курса — впереди.
    /// Точка камеры в базе часто смещена вбок от полосы, поэтому зона широкая.
    static func classify(relativeBearing rel: Double,
                         deadZone: Double = AppConfig.directionAheadDeadZone) -> CameraDirection {
        let a = normalized(rel)
        if a < deadZone || a >= 360 - deadZone { return .ahead }
        switch a {
        case deadZone..<135:   return .right
        case 135..<180:        return .behindRight
        case 180..<225:        return .behindLeft
        default:               return .left   // 225 … 360-deadZone
        }
    }

    /// Куда повернуть стрелку (вверх = 0). Для «прямо» — строго вверх, без дрожи
    /// от мелкого бокового смещения; для «сбоку» — реальный сглаженный азимут.
    static func arrowAngle(relativeBearing rel: Double,
                           deadZone: Double = AppConfig.directionAheadDeadZone) -> Double {
        classify(relativeBearing: rel, deadZone: deadZone) == .ahead ? 0 : normalized(rel)
    }

    private static func normalized(_ angle: Double) -> Double {
        (angle.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }
}

/// Сглаживание угла по кратчайшей дуге (экспоненциальное). Курс GPS и азимут
/// к смещённой точке шумят — без сглаживания стрелка и «лево/право» прыгают.
nonisolated struct AngleSmoother {
    private var value: Double?
    let factor: Double   // 0…1, доля новой пробы

    init(factor: Double = 0.35) { self.factor = factor }

    mutating func update(_ new: Double) -> Double {
        guard let current = value else { value = new; return new }
        // Идём к новому по кратчайшей дуге, а не через 359→0.
        var delta = (new - current).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        let next = (current + delta * factor + 360).truncatingRemainder(dividingBy: 360)
        value = next
        return next
    }

    mutating func reset() { value = nil }
}
