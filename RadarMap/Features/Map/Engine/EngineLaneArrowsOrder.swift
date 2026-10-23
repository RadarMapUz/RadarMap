//
//  EngineLaneArrowsOrder.swift
//  RadarMap
//

#if canImport(MapLibre)
import MapLibre

/// Стрелки полос на асфальте — над линией маршрута (28.B/28.D по просьбе
/// 28.C, 23.10). В шаблоне выпуска `radar-arrows` лежит в основе, под всеми
/// слоями приложения, и тело линии маршрута (11–16 точек на z17–19) закрывало
/// стрелки средних полос как раз у стоп-линии, где по ним выбирают ряд
/// (снимки shots_28c/after_*_2near). Белая стрелка на синей линии читается,
/// как у больших навигаторов; линия маршрута при этом не прячется.
///
/// Переставляются все слои с именем `radar-arrows…` (и подсветка нужных
/// полос 28.C, если она в стиле), в прежнем порядке, сразу над стрелками
/// направления маршрута — над шевроном линии, под подписями. Раз на загрузку
/// стиля; слой, вставленный позже «над radar-arrows», окажется там же.
/// Видимость (приглушение в поездке, горячий телефон) — отдельно и не меняется.
enum EngineLaneArrowsOrder {
    static let prefix = "radar-arrows"
    static let anchor = "route-arrows"

    static func raise(in style: MLNStyle) {
        guard let route = style.layer(withIdentifier: anchor) else { return }
        let lanes = style.layers.filter { $0.identifier.hasPrefix(prefix) }
        var above: MLNStyleLayer = route
        for layer in lanes {
            style.removeLayer(layer)
            style.insertLayer(layer, above: above)
            above = layer
        }
    }
}
#endif
