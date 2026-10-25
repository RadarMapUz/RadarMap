//
//  EngineManeuverArrow.swift
//  RadarMap
//
//  Стрелка манёвра на линии маршрута (29.G): белое древко с каймой и
//  наконечник по курсу выезда, лежащий на асфальте (под наклоном — в
//  плоскости карты, как разметка). Геометрию решает ManeuverArrow (чистая
//  логика); здесь — свой источник, три слоя и запись источника.
//
//  Источник пишется только на смене манёвра и на входе в порог показа
//  (`maneuverArrowShowMeters`), цвет каймы — на смене темы маршрута: на тике
//  ничего (правило аудита 11.10). Слои — над всей линией маршрута и её
//  шевронами, под стрелками полос на асфальте (их выбирают у стоп-линии,
//  до древка) и под значками камер.
//
//  Оформление (толщины, цвет, вид наконечника) — предмет 29.F «премиум-
//  линии»: идентификаторы слоёв — `maneuver-arrow-*`, данные — здесь.
//

#if canImport(MapLibre)
import MapLibre
import UIKit

final class EngineManeuverArrow {

    static let sourceID = "maneuver-arrow"
    static let casingID = "maneuver-arrow-casing"
    static let bodyID = "maneuver-arrow-body"
    static let headID = "maneuver-arrow-head"
    static let headImage = "radar-maneuver-head"
    static let headCasingImage = "radar-maneuver-head-casing"

    private var installed = false
    private var written: ManeuverArrow.Shape?
    private var wroteEmpty = false
    private var paintedDaylight: Bool?
    /// Длины по линии маршрута — раз на маршрут (объект полилайна).
    private var routeKey: ObjectIdentifier?
    private var cumulative: [Double] = []

    func styleLoaded() {
        installed = false
        written = nil
        wroteEmpty = false
        paintedDaylight = nil
        lastWanted = nil
    }

    /// `along` — манёвр (метры от старта), nil — манёвра нет.
    func update(route: [CLLocationCoordinate2D], routeObject: AnyObject?, progress: Double,
                along: Double?, kind: ManeuverKind?, routeDaylight: Bool, in view: MLNMapView) {
        guard let style = view.style else { return }
        if !installed { install(in: style) }
        guard let source = style.source(withIdentifier: Self.sourceID) as? MLNShapeSource else { return }
        if paintedDaylight != routeDaylight {
            paintedDaylight = routeDaylight
            let casing = Theme.rgb(routeDaylight ? RouteColors.casing.day : RouteColors.casing.night)
            (style.layer(withIdentifier: Self.casingID) as? MLNLineStyleLayer)?.lineColor =
                NSExpression(forConstantValue: casing)
            if let image = Self.headImage(fill: .white, size: 40) { style.setImage(image, forName: Self.headImage) }
            if let image = Self.headImage(fill: casing, size: 52) { style.setImage(image, forName: Self.headCasingImage) }
        }
        let key = routeObject.map(ObjectIdentifier.init)
        if key != routeKey || cumulative.count != route.count {
            routeKey = key
            cumulative = ManeuverArrow.cumulative(route)
            written = nil
            wroteEmpty = false
            lastWanted = nil
        }
        // Геометрия — только на смене манёвра, маршрута или входа в порог
        // показа: на фиксе, ничего не поменявшем, — ни счёта, ни записи.
        let visible = along.map {
            $0 - progress <= AppConfig.maneuverArrowShowMeters && $0 - progress >= -AppConfig.maneuverCalloutGoneMeters
        } ?? false
        let wanted = Wanted(along: visible ? along : nil, kind: kind, route: key)
        guard wanted != lastWanted else { return }
        lastWanted = wanted
        let shape = wanted.along.flatMap {
            ManeuverArrow.shape(along: $0, kind: kind, route: route, cumulative: cumulative)
        }
        guard shape != written || (shape == nil && !wroteEmpty) else { return }
        written = shape
        wroteEmpty = shape == nil
        source.shape = shape.map(Self.features)
    }

    private struct Wanted: Equatable {
        var along: Double?
        var kind: ManeuverKind?
        var route: ObjectIdentifier?
    }
    private var lastWanted: Wanted?

    /// Точка линии маршрута в `along` метрах — по длинам, посчитанным в
    /// `update` (тот же маршрут; другой — nil, а не чужая точка).
    func point(along: Double, route: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D? {
        guard cumulative.count == route.count else { return nil }
        return ManeuverCallout.point(along: along, route: route, cumulative: cumulative)
    }

    private static func features(_ shape: ManeuverArrow.Shape) -> MLNShapeCollectionFeature {
        var shaft = shape.shaft
        let line = MLNPolylineFeature(coordinates: &shaft, count: UInt(shaft.count))
        let head = MLNPointFeature()
        head.coordinate = shape.head
        head.attributes = ["b": shape.bearing]
        return MLNShapeCollectionFeature(shapes: [line, head])
    }

    private func install(in style: MLNStyle) {
        installed = true
        let source = style.source(withIdentifier: Self.sourceID) as? MLNShapeSource
            ?? MLNShapeSource(identifier: Self.sourceID, shape: nil)
        if style.source(withIdentifier: Self.sourceID) == nil { style.addSource(source) }
        guard style.layer(withIdentifier: Self.bodyID) == nil else { return }
        let lines = NSPredicate(mglJSONObject: ["==", ["geometry-type"], "LineString"])
        let points = NSPredicate(mglJSONObject: ["==", ["geometry-type"], "Point"])

        let casing = MLNLineStyleLayer(identifier: Self.casingID, source: source)
        casing.predicate = lines
        casing.lineCap = NSExpression(forConstantValue: "round")
        casing.lineJoin = NSExpression(forConstantValue: "round")
        casing.lineWidth = NSExpression(mglJSONObject: Self.width(extra: 3))
        let body = MLNLineStyleLayer(identifier: Self.bodyID, source: source)
        body.predicate = lines
        body.lineCap = NSExpression(forConstantValue: "round")
        body.lineJoin = NSExpression(forConstantValue: "round")
        body.lineColor = NSExpression(forConstantValue: UIColor.white)
        body.lineWidth = NSExpression(mglJSONObject: Self.width(extra: 0))

        let headCasing = MLNSymbolStyleLayer(identifier: Self.headID + "-casing", source: source)
        let head = MLNSymbolStyleLayer(identifier: Self.headID, source: source)
        for (layer, image) in [(headCasing, Self.headCasingImage), (head, Self.headImage)] {
            layer.predicate = points
            layer.iconImageName = NSExpression(forConstantValue: image)
            layer.iconRotation = NSExpression(mglJSONObject: ["get", "b"])
            layer.iconRotationAlignment = NSExpression(forConstantValue: "map")
            layer.iconPitchAlignment = NSExpression(forConstantValue: "map")
            layer.iconAllowsOverlap = NSExpression(forConstantValue: true)
            layer.iconIgnoresPlacement = NSExpression(forConstantValue: true)
            layer.iconScale = NSExpression(mglJSONObject: Self.headScale())
        }
        // Над линией маршрута и её шевронами, под стрелками полос на асфальте.
        let stack: [MLNStyleLayer] = [casing, body, headCasing, head]
        if let lanes = style.layers.first(where: { $0.identifier.hasPrefix(EngineLaneArrowsOrder.prefix) }) {
            for layer in stack { style.insertLayer(layer, below: lanes) }
        } else if var above = style.layer(withIdentifier: EngineLaneArrowsOrder.anchor) {
            for layer in stack {
                style.insertLayer(layer, above: above)
                above = layer
            }
        } else {
            for layer in stack { style.addLayer(layer) }
        }
    }

    /// Толщина древка по масштабу, pt: тоньше тела линии маршрута, чтобы
    /// синий край линии оставался виден по бокам.
    private static func width(extra: Double) -> [Any] {
        ["interpolate", ["exponential", 1.6], ["zoom"],
         14, 3 + extra, 16, 5 + extra, 18, 9 + extra, 20, 16 + extra]
    }

    /// Масштаб наконечника (картинка 40 pt при 1.0).
    private static func headScale() -> [Any] {
        ["interpolate", ["exponential", 1.6], ["zoom"], 14, 0.3, 16, 0.5, 18, 0.9, 20, 1.6]
    }

    /// Наконечник: треугольник носом на север, белый (или цвета каймы —
    /// подложка на 30 % крупнее).
    private static func headImage(fill: UIColor, size: CGFloat) -> UIImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)
        return renderer.image { ctx in
            let path = UIBezierPath()
            path.move(to: CGPoint(x: size / 2, y: size * 0.08))
            path.addLine(to: CGPoint(x: size * 0.92, y: size * 0.86))
            path.addLine(to: CGPoint(x: size / 2, y: size * 0.70))
            path.addLine(to: CGPoint(x: size * 0.08, y: size * 0.86))
            path.close()
            path.lineJoinStyle = .round
            fill.setFill()
            path.fill()
            ctx.cgContext.setLineJoin(.round)
        }
    }
}
#endif
