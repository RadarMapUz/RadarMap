//
//  MapScale.swift
//  RadarMap
//
//  Масштаб размеров слоя стиля для экрана машины (29.F): экран CarPlay
//  смотрят с 70–80 см, а подписи улиц в 12 pt и линия маршрута в 7 pt
//  рассчитаны на телефон в руке. Размер в стиле — выражение по зуму;
//  обернуть его в ["*", …] нельзя (зум разрешён только на верхнем уровне
//  interpolate/step — движок отверг бы стиль целиком), поэтому множитель
//  входит в КАЖДУЮ ступень.
//
//  Чисто, покрыто MapScaleTests.
//

import Foundation

nonisolated enum MapScale {

    /// Выражение размера (JSON стиля), умноженное на `factor` ступень за
    /// ступенью. Число — умножается; interpolate/step — выходы ступеней;
    /// прочее без зума — в ["*", …, factor]; с зумом глубже — как было.
    static func scaled(_ value: Any, by factor: Double) -> Any {
        if let number = value as? NSNumber { return number.doubleValue * factor }
        guard let list = value as? [Any], let head = list.first as? String else { return value }
        switch head {
        case "interpolate" where list.count >= 5:
            var out = Array(list.prefix(3))
            for i in stride(from: 3, to: list.count - 1, by: 2) {
                out.append(list[i])
                out.append(scaled(list[i + 1], by: factor))
            }
            return out
        case "step" where list.count >= 3:
            var out = Array(list.prefix(2))
            out.append(scaled(list[2], by: factor))
            for i in stride(from: 3, to: list.count - 1, by: 2) {
                out.append(list[i])
                out.append(scaled(list[i + 1], by: factor))
            }
            return out
        default:
            if containsZoom(list) { return value }
            return ["*", value, factor] as [Any]
        }
    }

    private static func containsZoom(_ value: Any) -> Bool {
        if let list = value as? [Any] {
            if list.first as? String == "zoom" { return true }
            return list.contains { containsZoom($0) }
        }
        return false
    }
}
