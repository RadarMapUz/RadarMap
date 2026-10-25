//
//  EngineStopDetail.swift
//  RadarMap
//

#if canImport(MapLibre)
import MapLibre

/// Значки заведений — под линией маршрута (29.D). В шаблоне выпуска
/// `poi-level-*` лежат над маршрутом (маршрут вставлен под первым слоем
/// подписей основы), и значок, который стоя вернулся на карту поездки
/// (StopView), ложился бы поверх линии. Под маршрутом они ниже и по порядку
/// размещения: подписи улиц, стрелки полос и камеры (слои приложения в конце
/// стиля) занимают место первыми, значок уступает. Раз на загрузку стиля;
/// видимость — отдельно (applyHiddenLayers).
enum EngineStopDetail {
    static let prefix = "poi-level"
    static let anchor = "route-traveled"

    static func lower(in style: MLNStyle) {
        guard let route = style.layer(withIdentifier: anchor) else { return }
        // poi-level-3, -2, -1 — в прежнем порядке, сразу под маршрутом.
        for layer in style.layers.filter({ $0.identifier.hasPrefix(prefix) }) {
            style.removeLayer(layer)
            style.insertLayer(layer, below: route)
        }
    }
}
#endif
