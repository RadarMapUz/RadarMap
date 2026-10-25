//
//  EngineCarScale.swift
//  RadarMap
//
//  Экран машины крупнее (29.F): подписи улиц и линия маршрута — множителем
//  к размерам стиля, раз на загрузку стиля (MapScale). Телефон не трогается.
//

#if canImport(MapLibre)
import MapLibre

@MainActor
enum EngineCarScale {

    /// Подписи улиц основы — их кегль 12 на z16 рассчитан на телефон в руке.
    static let labelLayers = ["highway-name-major", "highway-name-minor"]
    /// Слои линии маршрута — все вместе, пары окна и остатка одной ширины
    /// (иначе на стыке ступенька).
    static let routeLayers = ["route-traveled", "route-glow", "route-near-glow", "route-case", "route-near-case",
                              "route", "route-near", "route-traffic", "route-maneuver", "route-near-maneuver",
                              "route-core", "route-near-core"]

    static func apply(in style: MLNStyle) {
        for id in labelLayers {
            guard let layer = style.layer(withIdentifier: id) as? MLNSymbolStyleLayer else { continue }
            layer.textFontSize = scaled(layer.textFontSize, by: AppConfig.carPlayLabelScale)
        }
        for id in routeLayers {
            guard let layer = style.layer(withIdentifier: id) as? MLNLineStyleLayer else { continue }
            layer.lineWidth = scaled(layer.lineWidth, by: AppConfig.carPlayRouteWidthScale)
        }
    }

    private static func scaled(_ expression: NSExpression, by factor: Double) -> NSExpression {
        NSExpression(mglJSONObject: MapScale.scaled(expression.mgl_jsonExpressionObject, by: factor))
    }
}
#endif
