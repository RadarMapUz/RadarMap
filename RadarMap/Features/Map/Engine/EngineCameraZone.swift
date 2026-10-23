//
//  EngineCameraZone.swift
//  RadarMap
//
//  Зона камеры на асфальте (28.B): одна лента в своём источнике и своём слое
//  движка. Что и когда рисовать решает CameraZone (чистая логика); здесь —
//  только слой и запись источника.
//
//  Слой — под всей линией маршрута (и под городскими пробками), над основой:
//  на асфальте и разметке, под маркерами. Маршрут остаётся главным
//  предметом карты — лента шире его линии и видна краями по обе стороны;
//  без маршрута она лежит на дороге целиком. Ширина — в МЕТРАХ проезжей
//  части (растёт с масштабом, как сама дорога) и не уже каймы линии
//  маршрута, чтобы на z15–16 её не съела линия.
//
//  Источник пишется только при смене камеры/стороны/заметном сдвиге
//  (CameraZone.needsRewrite), цвет — на смене темы: на тике ничего.
//
//  Только картинка — ни оповещения, ни гейты, ни проезды отсюда не читают.
//

#if canImport(MapLibre)
import MapLibre
import UIKit

final class EngineCameraZone {

    static let sourceID = "radar-camera-zone"
    static let layerID = "radar-camera-zone"

    private var installed = false
    private var written: CameraZone.Band?
    private var paintedDaylight: Bool?

    /// Новый стиль: источника и слоя нет — поставить заново на ближайшем применении.
    func styleLoaded() {
        installed = false
        written = nil
        paintedDaylight = nil
    }

    func update(_ band: CameraZone.Band?, daylight: Bool, in view: MLNMapView) {
        guard let style = view.style else { return }
        if !installed { install(in: style) }
        guard let layer = style.layer(withIdentifier: Self.layerID) as? MLNLineStyleLayer,
              let source = style.source(withIdentifier: Self.sourceID) as? MLNShapeSource else { return }
        if paintedDaylight != daylight {
            paintedDaylight = daylight
            let colour = CameraZone.Colors.pick(daylight: daylight)
            layer.lineColor = NSExpression(forConstantValue: Theme.rgb(colour.hex))
            layer.lineOpacity = NSExpression(forConstantValue: colour.alpha)
        }
        guard CameraZone.needsRewrite(written, band) else { return }
        written = band
        source.shape = band.map(Self.feature)
    }

    private static func feature(_ band: CameraZone.Band) -> MLNPolylineFeature {
        var coordinates = band.points.map(\.coordinate)
        let feature = MLNPolylineFeature(coordinates: &coordinates, count: UInt(coordinates.count))
        // Метры → точки экрана на масштабе 0 у этой широты; слой домножает на 2^z.
        let perPoint = CameraZone.metersPerPointAtZoomZero(latitude: band.latitude)
        feature.attributes = ["w": band.widthMeters / perPoint, "o": band.offsetMeters / perPoint]
        return feature
    }

    private func install(in style: MLNStyle) {
        installed = true
        let source = style.source(withIdentifier: Self.sourceID) as? MLNShapeSource
            ?? MLNShapeSource(identifier: Self.sourceID, shape: nil)
        if style.source(withIdentifier: Self.sourceID) == nil { style.addSource(source) }
        guard style.layer(withIdentifier: Self.layerID) == nil else { return }
        let layer = MLNLineStyleLayer(identifier: Self.layerID, source: source)
        layer.minimumZoomLevel = Float(AppConfig.cameraZoneMinZoom)
        // Плоский торец: лента кончается под значком, а не на полширины дальше.
        layer.lineCap = NSExpression(forConstantValue: "butt")
        layer.lineJoin = NSExpression(forConstantValue: "round")
        layer.lineWidth = NSExpression(mglJSONObject: Self.widthExpression())
        layer.lineOffset = NSExpression(mglJSONObject: Self.offsetExpression())
        // Под всей линией маршрута и пробками города: первый из них, что есть в стиле.
        if let anchor = ["traffic", "route-traveled", "route-case"].lazy
            .compactMap({ style.layer(withIdentifier: $0) }).first {
            style.insertLayer(layer, below: anchor)
        } else {
            style.addLayer(layer)
        }
    }

    /// Масштабы ступеней ширины: между ними — экспонента по основанию 2
    /// (метры на экране удваиваются с каждым уровнем).
    private static let zooms: [Double] = [15, 16, 17, 18, 19, 20, 22]

    /// Не уже каймы линии маршрута плюс по 3 точки с каждой стороны
    /// (EngineMapStyle.routeWidth(extra: 3): 10 на z15, 14 на z17, 19 на z19).
    private static func floor(zoom: Double) -> Double {
        let stops: [(Double, Double)] = [(15, 10), (17, 14), (19, 19), (20, 22)]
        guard zoom > stops[0].0 else { return stops[0].1 + 6 }
        for (a, b) in zip(stops, stops.dropFirst()) where zoom <= b.0 {
            return a.1 + (b.1 - a.1) * (zoom - a.0) / (b.0 - a.0) + 6
        }
        return stops[stops.count - 1].1 + 6
    }

    private static func widthExpression() -> [Any] {
        var out: [Any] = ["interpolate", ["exponential", 2], ["zoom"]]
        for zoom in zooms {
            out += [zoom, ["max", ["*", ["get", "w"], pow(2, zoom)], floor(zoom: zoom)]]
        }
        return out
    }

    private static func offsetExpression() -> [Any] {
        var out: [Any] = ["interpolate", ["exponential", 2], ["zoom"]]
        for zoom in zooms { out += [zoom, ["*", ["get", "o"], pow(2, zoom)]] }
        return out
    }
}
#endif
