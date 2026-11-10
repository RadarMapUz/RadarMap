//
//  EngineTripodZone.swift
//  RadarMap
//
//  Участок треноги на асфальте (83, вариант C): красная штриховка своей
//  проезжей части у треноги, янтарная — у зоны «часто ставят». Что и когда
//  рисовать решает TripodZone (чистая логика); здесь — слои и запись
//  источника.
//
//  Штриховка лежит ПОД каймой и телом линии маршрута: маршрут остаётся
//  синим и читаемым, штрих виден по бокам от него (пол ширины — кайма
//  маршрута + 12 точек), а кайма линии на участке краснеет. Красное поверх
//  синего давало грязный фиолет (снимки этапа 1). Без маршрута штриховка
//  лежит на проезжей части целиком.
//
//  Картинки штриховки — под своими именами (`radar-tripod-hatch…`): в
//  спрайте выпуска есть «hatch», и он перезаписал бы одноимённую.
//
//  Горячий телефон: штриховка и «часто ставят» гаснут (hotHiddenLayers),
//  вместо штриховки — ровная полупрозрачная лента (hotShownLayers).
//
//  Источник пишется только при смене участка или ступени; цвет — на смене
//  темы: на тике ничего. Только картинка.
//

#if canImport(MapLibre)
import MapLibre
import UIKit

final class EngineTripodZone {

    static let sourceID = "radar-tripod-zone"
    static let limitSourceID = "radar-tripod-limit"
    static let hatchLayerID = "radar-tripod-zone"
    static let calmLayerID = "radar-tripod-zone-calm"
    static let flatLayerID = "radar-tripod-zone-flat"
    static let caseLayerID = "radar-tripod-zone-case"
    static let limitLayerID = "radar-tripod-limit"

    static let hatchImage = "radar-tripod-hatch"
    static let sparseImage = "radar-tripod-hatch-sparse"
    static let calmImage = "radar-tripod-hatch-calm"
    static let limitImage = "radar-tripod-limit"

    /// Гаснут на горячем телефоне (EngineMapView.hotHiddenLayers).
    static let hotHidden = [hatchLayerID, calmLayerID]
    /// Видна только на горячем телефоне (EngineMapView.hotShownLayers).
    static let hotShown = [flatLayerID]

    /// Красный камеры (CameraGlyph) и янтарь «часто ставят» (ночной warning).
    static let red: UInt32 = CameraGlyph.camera.fillRGB
    static let amber: UInt32 = WidgetPalette.warning.dark

    private var installed = false
    private var wrote = false
    private var written: TripodZone.Band?
    private var paintedDaylight: Bool?

    func styleLoaded() {
        installed = false
        wrote = false
        written = nil
        paintedDaylight = nil
    }

    func update(_ band: TripodZone.Band?, daylight: Bool, hot: Bool, in view: MLNMapView) {
        guard let style = view.style else { return }
        if !installed { install(in: style, hot: hot) }
        guard let source = style.source(withIdentifier: Self.sourceID) as? MLNShapeSource,
              let limits = style.source(withIdentifier: Self.limitSourceID) as? MLNShapeSource else { return }
        if paintedDaylight != daylight {
            paintedDaylight = daylight
            paint(style, daylight: daylight)
        }
        guard !wrote || written != band else { return }
        wrote = true
        written = band
        source.shape = band.map(Self.zoneShape)
        limits.shape = band.map(Self.limitShape)
    }

    // MARK: - Источники

    private static func zoneShape(_ band: TripodZone.Band) -> MLNShape {
        let perPoint = CameraZone.metersPerPointAtZoomZero(latitude: band.latitude)
        var features: [MLNPolylineFeature] = []
        for piece in band.pieces {
            for ramp in TripodZone.ramps(piece) {
                var coordinates = ramp.points.map(\.coordinate)
                let feature = MLNPolylineFeature(coordinates: &coordinates, count: UInt(coordinates.count))
                feature.attributes = ["g": band.grade.rawValue, "a": ramp.alpha,
                                      "w": piece.widthMeters / perPoint, "o": piece.offsetMeters / perPoint,
                                      "r": piece.onRoute]
                features.append(feature)
            }
        }
        return MLNShapeCollectionFeature(shapes: features)
    }

    private static func limitShape(_ band: TripodZone.Band) -> MLNShape {
        MLNShapeCollectionFeature(shapes: band.limits.map { limit -> MLNPointFeature in
            let feature = MLNPointFeature()
            feature.coordinate = limit.point.coordinate
            feature.attributes = ["kmh": String(limit.kmh), "g": band.grade.rawValue]
            return feature
        })
    }

    // MARK: - Слои

    private func install(in style: MLNStyle, hot: Bool) {
        installed = true
        style.setImage(Self.hatch(colour: Self.red, period: 12, stripe: 5), forName: Self.hatchImage)
        style.setImage(Self.hatch(colour: Self.red, period: 24, stripe: 5), forName: Self.sparseImage)
        style.setImage(Self.hatch(colour: Self.amber, period: 24, stripe: 4), forName: Self.calmImage)
        style.setImage(Self.limitSign(), forName: Self.limitImage)
        let source = style.source(withIdentifier: Self.sourceID) as? MLNShapeSource
            ?? MLNShapeSource(identifier: Self.sourceID, shape: nil)
        if style.source(withIdentifier: Self.sourceID) == nil { style.addSource(source) }
        let limits = style.source(withIdentifier: Self.limitSourceID) as? MLNShapeSource
            ?? MLNShapeSource(identifier: Self.limitSourceID, shape: nil)
        if style.source(withIdentifier: Self.limitSourceID) == nil { style.addSource(limits) }
        guard style.layer(withIdentifier: Self.hatchLayerID) == nil else { return }

        let tripod = NSPredicate(format: "g != %@", TripodZone.Grade.hotspot.rawValue)
        func band(_ id: String, filter: NSPredicate) -> MLNLineStyleLayer {
            let layer = MLNLineStyleLayer(identifier: id, source: source)
            layer.predicate = filter
            layer.minimumZoomLevel = Float(AppConfig.tripodZoneMinZoom)
            layer.lineCap = NSExpression(forConstantValue: "butt")
            layer.lineJoin = NSExpression(forConstantValue: "round")
            layer.lineWidth = NSExpression(mglJSONObject: Self.widthExpression())
            layer.lineOffset = NSExpression(mglJSONObject: Self.offsetExpression())
            return layer
        }
        let hatch = band(Self.hatchLayerID, filter: tripod)
        hatch.linePattern = NSExpression(mglJSONObject: ["match", ["get", "g"],
                                                         TripodZone.Grade.unconfirmed.rawValue, Self.sparseImage,
                                                         Self.hatchImage])
        hatch.isVisible = !hot
        let calm = band(Self.calmLayerID, filter: NSPredicate(format: "g == %@", TripodZone.Grade.hotspot.rawValue))
        calm.linePattern = NSExpression(forConstantValue: Self.calmImage)
        calm.isVisible = !hot
        let flat = band(Self.flatLayerID, filter: tripod)
        flat.lineColor = NSExpression(forConstantValue: Theme.rgb(Self.red))
        flat.isVisible = hot
        // Кайма линии маршрута краснеет на участке — только где участок и есть линия маршрута.
        let edge = MLNLineStyleLayer(identifier: Self.caseLayerID, source: source)
        edge.predicate = NSPredicate(format: "r == YES AND g != %@", TripodZone.Grade.hotspot.rawValue)
        edge.minimumZoomLevel = Float(AppConfig.tripodZoneMinZoom)
        edge.lineCap = NSExpression(forConstantValue: "butt")
        edge.lineJoin = NSExpression(forConstantValue: "round")
        edge.lineColor = NSExpression(forConstantValue: Theme.rgb(Self.red))
        edge.lineWidth = NSExpression(mglJSONObject: EngineMapStyle.routeWidth(extra: 3))

        let sign = MLNSymbolStyleLayer(identifier: Self.limitLayerID, source: limits)
        sign.minimumZoomLevel = Float(AppConfig.tripodZoneMinZoom)
        sign.iconImageName = NSExpression(forConstantValue: Self.limitImage)
        sign.iconAllowsOverlap = NSExpression(forConstantValue: true)
        sign.iconIgnoresPlacement = NSExpression(forConstantValue: false)
        sign.iconPitchAlignment = NSExpression(forConstantValue: "viewport")
        sign.text = NSExpression(forKeyPath: "kmh")
        sign.textFontNames = NSExpression(forConstantValue: ["Noto Sans Bold"])
        sign.textFontSize = NSExpression(forConstantValue: 11)
        sign.textColor = NSExpression(forConstantValue: Theme.rgb(MapIconColors.ink))
        sign.textAllowsOverlap = NSExpression(forConstantValue: true)
        sign.textIgnoresPlacement = NSExpression(forConstantValue: true)
        sign.textPitchAlignment = NSExpression(forConstantValue: "viewport")
        // Неподтверждённая отметка — знак слабее, как и её метка.
        let weak: [Any] = ["case", ["==", ["get", "g"], TripodZone.Grade.unconfirmed.rawValue], 0.6, 1]
        sign.iconOpacity = NSExpression(mglJSONObject: weak)
        sign.textOpacity = NSExpression(mglJSONObject: weak)

        // Под каймой маршрута (над его свечением), кайма участка — под телом линии.
        for layer in [calm, hatch, flat] {
            if let anchor = style.layer(withIdentifier: "route-case") {
                style.insertLayer(layer, below: anchor)
            } else {
                style.addLayer(layer)
            }
        }
        if let body = style.layer(withIdentifier: "route") {
            style.insertLayer(edge, below: body)
        } else {
            style.addLayer(edge)
        }
        if let markers = style.layer(withIdentifier: "camera-halo") {
            style.insertLayer(sign, below: markers)
        } else {
            style.addLayer(sign)
        }
    }

    /// Сила по ступени и теме, умноженная на ступень мягкого конца.
    private func paint(_ style: MLNStyle, daylight: Bool) {
        func opacity(confirmed: Double, unconfirmed: Double) -> NSExpression {
            NSExpression(mglJSONObject: ["*", ["get", "a"],
                                         ["match", ["get", "g"],
                                          TripodZone.Grade.unconfirmed.rawValue, unconfirmed, confirmed]])
        }
        (style.layer(withIdentifier: Self.hatchLayerID) as? MLNLineStyleLayer)?.lineOpacity =
            opacity(confirmed: daylight ? 0.75 : 0.85, unconfirmed: daylight ? 0.55 : 0.6)
        (style.layer(withIdentifier: Self.calmLayerID) as? MLNLineStyleLayer)?.lineOpacity =
            NSExpression(mglJSONObject: ["*", ["get", "a"], daylight ? 0.5 : 0.55])
        (style.layer(withIdentifier: Self.flatLayerID) as? MLNLineStyleLayer)?.lineOpacity =
            opacity(confirmed: daylight ? 0.32 : 0.4, unconfirmed: daylight ? 0.18 : 0.22)
        (style.layer(withIdentifier: Self.caseLayerID) as? MLNLineStyleLayer)?.lineOpacity =
            opacity(confirmed: 1, unconfirmed: 0.55)
    }

    /// Масштабы ступеней ширины: между ними — экспонента по основанию 2.
    private static let zooms: [Double] = [14, 15, 16, 17, 18, 19, 20, 22]

    /// Не уже каймы линии маршрута плюс по 6 точек с каждой стороны: штрих
    /// виден по бокам линии и в машине на z16, где проезжая часть уже линии.
    private static func floor(zoom: Double) -> Double {
        let stops: [(Double, Double)] = [(11, 9), (15, 10), (17, 14), (19, 19), (20, 22)]
        guard zoom > stops[0].0 else { return stops[0].1 + 12 }
        for (a, b) in zip(stops, stops.dropFirst()) where zoom <= b.0 {
            return a.1 + (b.1 - a.1) * (zoom - a.0) / (b.0 - a.0) + 12
        }
        return stops[stops.count - 1].1 + 12
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

    // MARK: - Картинки

    /// Диагональные полосы; сторона картинки ложится на ширину линии.
    private static func hatch(colour: UInt32, period: CGFloat, stripe: CGFloat) -> UIImage {
        let side: CGFloat = 24
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            let cg = context.cgContext
            cg.setFillColor(Theme.rgb(colour).cgColor)
            var k = -side
            while k <= side {
                cg.move(to: CGPoint(x: k, y: side))
                cg.addLine(to: CGPoint(x: k + stripe, y: side))
                cg.addLine(to: CGPoint(x: k + stripe + side, y: 0))
                cg.addLine(to: CGPoint(x: k + side, y: 0))
                cg.closePath()
                k += period
            }
            cg.fillPath()
        }
    }

    /// Знак лимита: белый круг с красным ободом; число — текстом слоя.
    private static func limitSign() -> UIImage {
        let side: CGFloat = 24, pad: CGFloat = 2
        return UIGraphicsImageRenderer(size: CGSize(width: side + 2 * pad, height: side + 2 * pad)).image { context in
            let cg = context.cgContext
            let disc = CGRect(x: pad, y: pad, width: side, height: side)
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: 1), blur: 2.5, color: UIColor.black.withAlphaComponent(0.3).cgColor)
            cg.setFillColor(UIColor.white.cgColor)
            cg.fillEllipse(in: disc)
            cg.restoreGState()
            cg.setFillColor(Theme.rgb(red).cgColor)
            cg.fillEllipse(in: disc)
            cg.setFillColor(UIColor.white.cgColor)
            cg.fillEllipse(in: disc.insetBy(dx: side * 0.12, dy: side * 0.12))
        }
    }
}
#endif
