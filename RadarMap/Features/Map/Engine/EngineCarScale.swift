//
//  EngineCarScale.swift
//  RadarMap
//
//  Экран машины крупнее (29.F): подписи улиц и линия маршрута — множителем
//  к размерам стиля, раз на загрузку стиля (MapScale). С 40J — и щиты трасс,
//  подписи мест и заправок (CarMapStyle.Scale: машина и плитка). Телефон не
//  трогается.
//

#if canImport(MapLibre)
import MapLibre

@MainActor
enum EngineCarScale {

    /// Подписи улиц основы — их кегль 12 на z16 рассчитан на телефон в руке.
    static let labelLayers = ["highway-name-major", "highway-name-minor"]
    /// Мелкие подписи основы: номера трасс, места, имя заправки (10–11,5 pt).
    static let smallLabelLayers = ["highway-shield", "place-other", "place-village", "place-town",
                                   "place-city", "place-city-capital", "radar-poi-fuel"]
    /// Номер трассы стоит внутри щита: щит растёт вместе с цифрами.
    static let shieldLayers = ["highway-shield"]
    /// Слои линии маршрута — все вместе, пары окна и остатка одной ширины
    /// (иначе на стыке ступенька).
    static let routeLayers = ["route-traveled", "route-glow", "route-near-glow", "route-case", "route-near-case",
                              "route", "route-near", "route-traffic", "route-maneuver", "route-near-maneuver",
                              "route-core", "route-near-core"]

    static func apply(_ scale: CarMapStyle.Scale, in style: MLNStyle) {
        for (ids, factor) in [(labelLayers, scale.streets), (smallLabelLayers, scale.small)] where factor != 1 {
            for id in ids {
                guard let layer = style.layer(withIdentifier: id) as? MLNSymbolStyleLayer else { continue }
                layer.textFontSize = scaled(layer.textFontSize, by: factor)
            }
        }
        if scale.small != 1 {
            for id in shieldLayers {
                guard let layer = style.layer(withIdentifier: id) as? MLNSymbolStyleLayer else { continue }
                layer.iconScale = scaled(layer.iconScale, by: scale.small)
            }
        }
        guard scale.route != 1 else { return }
        for id in routeLayers {
            guard let layer = style.layer(withIdentifier: id) as? MLNLineStyleLayer else { continue }
            layer.lineWidth = scaled(layer.lineWidth, by: scale.route)
        }
    }

    private static func scaled(_ expression: NSExpression, by factor: Double) -> NSExpression {
        NSExpression(mglJSONObject: MapScale.scaled(expression.mgl_jsonExpressionObject, by: factor))
    }
}
#endif
