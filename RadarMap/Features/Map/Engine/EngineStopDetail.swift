//
//  EngineStopDetail.swift
//  RadarMap
//
//  Значки заведений, которые стоя возвращаются на карту поездки (StopView,
//  29.D). Решение «что показать» — MapDetailPolicy (29.H, `places`); здесь — только
//  порядок слоёв и место у машины.
//

#if canImport(MapLibre)
import CoreLocation
import MapLibre

/// Значки — под линией маршрута и не у самой машины.
///
/// Порядок: в шаблоне выпуска `poi-level-*` лежат над маршрутом (маршрут
/// вставлен под первым слоем подписей основы), и вернувшийся значок ложился
/// бы поверх линии. Под маршрутом они ниже и по порядку размещения: подписи
/// улиц, стрелки полос и камеры (слои приложения в конце стиля) занимают
/// место первыми, значок уступает. Раз на загрузку стиля.
///
/// Место у машины: «я» и кольцо компаса — виды поверх карты, движок о них не
/// знает, и подпись заведения ложилась прямо под стрелку (снимок
/// after_turn_day_stand, «Санаторий Семашко» под кольцом). Значки в круге
/// `stopViewCarClearMeters` вокруг машины отсекаются фильтром `within` — не
/// столкновением: невидимый значок-заглушка у машины вытеснил бы и светофор у
/// стоп-линии. Фильтр меняется на входе в остановку и на сдвиге машины больше
/// `stopViewCarClearRewriteMeters` — не на тике.
final class EngineStopDetail {
    static let prefix = "poi-level"
    static let anchor = "route-traveled"

    /// Фильтры слоёв до нас (nil внутри — у слоя фильтра не было).
    private var base: [String: NSPredicate?] = [:]
    /// Где стоит круг сейчас; nil — фильтры исходные.
    private var clearedAt: CLLocationCoordinate2D?
    private var clearedLayers: [String] = []

    /// Новый стиль: слои и фильтры — заново.
    func styleLoaded(_ style: MLNStyle) {
        base = [:]
        clearedAt = nil
        clearedLayers = []
        guard let route = style.layer(withIdentifier: Self.anchor) else { return }
        // poi-level-3, -2, -1 — в прежнем порядке, сразу под маршрутом.
        for layer in style.layers.filter({ $0.identifier.hasPrefix(Self.prefix) }) {
            style.removeLayer(layer)
            style.insertLayer(layer, below: route)
        }
    }

    /// `layers` — показанные в поездке ряды (MapDetailLayers.tripPlaceRows), `car` — машина.
    func update(layers: [String], car: CLLocationCoordinate2D, in style: MLNStyle) {
        guard !layers.isEmpty else {
            if clearedAt != nil { restore(in: style) }
            return
        }
        guard layers != clearedLayers || StopView.carClearNeedsRewrite(clearedAt, car) else { return }
        if layers != clearedLayers { restore(in: style) }
        var ring = StopView.carClearRing(center: car, radius: AppConfig.stopViewCarClearMeters)
        let outside = NSCompoundPredicate(notPredicateWithSubpredicate:
            NSPredicate(format: "SELF IN %@", MLNPolygon(coordinates: &ring, count: UInt(ring.count))))
        for id in layers {
            guard let layer = style.layer(withIdentifier: id) as? MLNVectorStyleLayer else { continue }
            if base[id] == nil { base[id] = .some(layer.predicate) }
            let original = base[id] ?? nil
            layer.predicate = original.map { NSCompoundPredicate(andPredicateWithSubpredicates: [$0, outside]) }
                ?? outside
        }
        clearedAt = car
        clearedLayers = layers
    }

    private func restore(in style: MLNStyle) {
        for (id, predicate) in base {
            (style.layer(withIdentifier: id) as? MLNVectorStyleLayer)?.predicate = predicate
        }
        clearedAt = nil
        clearedLayers = []
    }
}
#endif
