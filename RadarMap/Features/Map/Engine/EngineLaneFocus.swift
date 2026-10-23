//
//  EngineLaneFocus.swift
//  RadarMap
//
//  «Нужная полоса» на карте движка (28.C): стрелки полос ряда у ближайшего
//  манёвра — «наши» цветом маршрута, остальные бледнее. Что подсвечивать,
//  решает LaneFocus (чистый, LaneFocusTests); здесь — только слои.
//
//  Как, не трогая тайлы: слой стрелок стиля (`radar-arrows`) получает фильтр
//  «не в ряду», а две копии его оформления над ним рисуют ряд — «наши»
//  значками цвета маршрута (перекрашенные значки того же спрайта, форма та же),
//  «чужие» прежними значками с пониженной непрозрачностью. Ряд — фильтр
//  `within` по коридору вдоль маршрута + курс стрелки + её код.
//
//  Фильтры меняются только при смене манёвра, входе в окно подъезда и выходе
//  за манёвр (LaneFocus.Gate) — не на тике: смена фильтра перекладывает
//  символы слоя (правило аудита 11.10).
//
//  Нет слоя стрелок в стиле, нет полос у манёвра, нет значков в спрайте —
//  карта как была, без выдумки.
//

#if canImport(MapLibre)
import MapLibre
import os
import UIKit

final class EngineLaneFocus {

    static let baseLayer = "radar-arrows"
    static let oursLayer = "radar-lane-focus-ours"
    static let otherLayer = "radar-lane-focus-other"
    static let iconPrefix = "radar-lane-focus-"

    private var gate = LaneFocus.Gate()

    private struct Key: Equatable {
        var step: LaneFocus.Step
        var route: ObjectIdentifier?
        var daylight: Bool
    }

    /// Что показано сейчас; nil — ряд не выделен.
    private var applied: Key?
    /// Слои фокуса добавлены в текущий стиль.
    private var layers: (ours: MLNSymbolStyleLayer, other: MLNSymbolStyleLayer)?
    /// Фильтр слоя стрелок до нас (в стиле его нет — nil).
    private var basePredicate: NSPredicate?
    private var baseTouched = false
    /// Перекрашенные значки — в какой теме и каких кодов.
    private var tintedFor: Bool?
    private var tinted: Set<Int> = []
    /// Значков спрайта не было — когда пробовать снова.
    private var retryAt: CFTimeInterval?

    /// Новый стиль: слои и значки ушли вместе со старым.
    func styleLoaded() {
        applied = nil
        layers = nil
        basePredicate = nil
        baseTouched = false
        tintedFor = nil
        tinted = []
        retryAt = nil
    }

    func update(_ model: EngineMapView, in view: MLNMapView) {
        let speedKmh = (model.markerMotion?.speedMps ?? 0) * 3.6
        let shown = gate.update(model.laneFocus, progress: model.routeProgress, speedKmh: speedKmh)
        let key = shown.map {
            Key(step: $0, route: model.routeObject.map(ObjectIdentifier.init), daylight: model.daylight)
        }
        let retryDue = retryAt.map { CACurrentMediaTime() >= $0 } ?? false
        guard key != applied || retryDue, let style = view.style else { return }
        retryAt = nil
        guard let key, let zone = LaneFocus.zone(route: model.route, step: key.step) else {
            clear(in: style)
            applied = key
            return
        }
        guard let base = style.layer(withIdentifier: Self.baseLayer) as? MLNSymbolStyleLayer else {
            applied = key
            return
        }
        guard installIcons(codes: key.step.codes, daylight: key.daylight, in: style) else {
            // Спрайт ещё не пришёл (стиль только что загрузился): ряд пока как
            // был, повтор позже.
            clear(in: style)
            retryAt = CACurrentMediaTime() + AppConfig.laneFocusRetrySeconds
            return
        }
        guard let layers = ensureLayers(base: base, in: style) else {
            applied = key
            return
        }
        let row = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "SELF IN %@", Self.polygon(zone.ring)),
            NSPredicate(mglJSONObject: LaneFocus.bearingFilter(zone.bearing)),
        ])
        let ours = NSPredicate(mglJSONObject: LaneFocus.oursFilter(key.step))
        layers.ours.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [row, ours])
        layers.other.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            row, NSCompoundPredicate(notPredicateWithSubpredicate: ours)])
        let outside = NSCompoundPredicate(notPredicateWithSubpredicate: row)
        if !baseTouched {
            basePredicate = base.predicate
            baseTouched = true
        }
        base.predicate = basePredicate.map { NSCompoundPredicate(andPredicateWithSubpredicates: [$0, outside]) }
            ?? outside
        layers.ours.isVisible = true
        layers.other.isVisible = true
        applied = key
        Log.route.info("Полоса: ряд у манёвра \(Int(key.step.along), privacy: .public) м, коды \(key.step.codes.map(String.init).joined(separator: ","), privacy: .public)")
    }

    // MARK: - Слои

    private func clear(in style: MLNStyle) {
        if baseTouched, let base = style.layer(withIdentifier: Self.baseLayer) as? MLNSymbolStyleLayer {
            base.predicate = basePredicate
        }
        layers?.ours.isVisible = false
        layers?.other.isVisible = false
    }

    /// Две копии оформления слоя стрелок прямо над ним.
    private func ensureLayers(base: MLNSymbolStyleLayer,
                              in style: MLNStyle) -> (ours: MLNSymbolStyleLayer, other: MLNSymbolStyleLayer)? {
        if let layers { return layers }
        guard let sourceID = base.sourceIdentifier, let source = style.source(withIdentifier: sourceID) else {
            return nil
        }
        func copy(_ id: String) -> MLNSymbolStyleLayer {
            let layer = MLNSymbolStyleLayer(identifier: id, source: source)
            layer.sourceLayerIdentifier = base.sourceLayerIdentifier
            layer.minimumZoomLevel = base.minimumZoomLevel
            layer.maximumZoomLevel = base.maximumZoomLevel
            layer.iconImageName = base.iconImageName
            layer.iconRotation = base.iconRotation
            layer.iconRotationAlignment = base.iconRotationAlignment
            layer.iconPitchAlignment = base.iconPitchAlignment
            layer.iconAllowsOverlap = base.iconAllowsOverlap
            layer.iconIgnoresPlacement = base.iconIgnoresPlacement
            layer.iconScale = base.iconScale
            layer.isVisible = false
            return layer
        }
        let other = copy(Self.otherLayer)
        other.iconOpacity = NSExpression(forConstantValue: AppConfig.laneFocusOtherOpacity)
        let ours = copy(Self.oursLayer)
        var names: [Any] = ["match", ["get", "turn"]]
        for code in LaneFocus.tileIcons.keys.sorted() {
            names += [code, Self.iconPrefix + (LaneFocus.tileIcons[code] ?? "")]
        }
        names.append("")
        ours.iconImageName = NSExpression(mglJSONObject: names)
        style.insertLayer(other, above: base)
        style.insertLayer(ours, above: other)
        layers = (ours, other)
        return layers
    }

    // MARK: - Значки

    /// Значки «наших» кодов цветом маршрута — из того же спрайта: форма,
    /// размер и кайма прежние, белое становится синим. false — нужного
    /// значка в спрайте ещё нет (стиль только что загрузился).
    private func installIcons(codes: [Int], daylight: Bool, in style: MLNStyle) -> Bool {
        if tintedFor != daylight {
            tintedFor = daylight
            tinted = []
        }
        let colour = Self.colour(daylight ? RouteColors.body.day : RouteColors.body.night)
        for code in codes {
            guard let name = LaneFocus.tileIcons[code] else { continue }
            if tinted.contains(code) { continue }
            guard let image = style.image(forName: name) else { return false }
            style.setImage(Self.recoloured(image, colour), forName: Self.iconPrefix + name)
            tinted.insert(code)
        }
        return true
    }

    /// Белое → цвет, тёмная кайма остаётся тёмной (умножение), прозрачность —
    /// исходного значка.
    static func recoloured(_ image: UIImage, _ colour: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let rect = CGRect(origin: .zero, size: image.size)
        return UIGraphicsImageRenderer(size: image.size, format: format).image { context in
            image.draw(in: rect)
            colour.setFill()
            context.fill(rect, blendMode: .multiply)
            image.draw(in: rect, blendMode: .destinationIn, alpha: 1)
        }
    }

    private static func colour(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private static func polygon(_ ring: [CLLocationCoordinate2D]) -> MLNPolygon {
        var points = ring
        return MLNPolygon(coordinates: &points, count: UInt(points.count))
    }
}
#endif
