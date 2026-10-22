//
//  EngineRouteVariants.swift
//  RadarMap
//
//  Другие варианты маршрута на карте выбора (27.D) — как у Яндекса: все
//  варианты видны сразу, выбранный — полной лентой с пробками (его рисуют
//  обычные слои маршрута, 25.D), остальные — бледнее своим тоном и ПОД ним,
//  на каждом — подпись времени «24 мин». Касание линии или подписи выбирает
//  вариант (RoutePreview.variant — чистая функция с тестом).
//
//  Слои ставятся в живой стиль при загрузке, а не в JSON стиля: это
//  временная картинка экрана выбора, и шаблон выпуска о ней знать не должен.
//  Стоит ниже «route-traveled»/«route-case» — выбранную ленту ничто не
//  перекрывает; подписи — над стрелками маршрута, под камерами.
//
//  В ведении (поездка) вариантов нет: источник пуст, слои маршрута в ведении
//  этот файл не трогает.
//

#if canImport(MapLibre)
import CoreLocation
import MapKit
import MapLibre
import UIKit

/// Вариант маршрута для карты выбора: линия и подпись времени.
struct RouteVariantLine: Equatable {
    let id: Int
    let polyline: MKPolyline
    /// «24 мин» — то же время с пробками, что на карточке варианта.
    let eta: String

    static func == (a: RouteVariantLine, b: RouteVariantLine) -> Bool {
        a.id == b.id && a.polyline === b.polyline && a.eta == b.eta
    }
}

@MainActor
final class EngineRouteVariants {
    /// Снос без прыжка на актор — тот же обход бага рантайма, что у карт.
    nonisolated deinit {}

    static let lineSource = "radar-route-variants"
    static let labelSource = "radar-route-variant-labels"
    static let casingLayer = "radar-route-variants-case"
    static let bodyLayer = "radar-route-variants"
    static let labelLayer = "radar-route-variant-labels"

    private struct Key: Equatable {
        var variants: [RouteVariantLine]
        var selected: Int?
        var daylight: Bool
    }

    private var installed = false
    private var lastKey: Key?
    /// Линии всех вариантов (прорежённые) — для касания.
    private var lines: [(id: Int, coordinates: [CLLocationCoordinate2D])] = []
    private var selected: Int?
    private var imageNames: Set<String> = []
    /// Где стоит подпись каждого варианта (для касания без пальца в DEBUG).
    private var labelPoints: [Int: CLLocationCoordinate2D] = [:]

    func labelCoordinate(of id: Int) -> CLLocationCoordinate2D? { labelPoints[id] }

    /// Новый стиль: источники и слои пусты, ставятся заново.
    func styleLoaded() {
        installed = false
        lastKey = nil
        imageNames = []
    }

    /// Показаны ли сейчас варианты (больше одного).
    var isShowing: Bool { lines.count > 1 }

    func update(_ variants: [RouteVariantLine], selected: Int?, daylight: Bool, in view: MLNMapView) {
        guard let style = view.style else { return }
        if !installed { install(in: style, daylight: daylight) }
        let key = Key(variants: variants.count > 1 ? variants : [], selected: selected, daylight: daylight)
        guard key != lastKey else { return }
        let themeChanged = lastKey?.daylight != daylight
        lastKey = key
        self.selected = selected
        if themeChanged { paint(style, daylight: daylight) }
        let shown = key.variants
        lines = shown.map { variant in
            var all = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid,
                                               count: variant.polyline.pointCount)
            variant.polyline.getCoordinates(&all, range: NSRange(location: 0, length: all.count))
            let thin = RoutePreview.thinned(all.map { MKMapPoint($0) },
                                            limit: AppConfig.routeVariantLabelOtherPoints * 2)
            return (variant.id, thin.map(\.coordinate))
        }
        // Линии — только не выбранные: выбранную рисуют слои маршрута.
        let others = zip(shown, lines).filter { $0.0.id != selected }.map { pair -> MLNPolylineFeature in
            var coordinates = pair.1.coordinates
            let line = MLNPolylineFeature(coordinates: &coordinates, count: UInt(coordinates.count))
            line.attributes = ["id": pair.0.id]
            return line
        }
        (style.source(withIdentifier: Self.lineSource) as? MLNShapeSource)?.shape =
            others.isEmpty ? nil : MLNShapeCollectionFeature(shapes: others)
        // Подписи — у каждого варианта, в месте, где он отдельно от других.
        let mapLines = lines.map { $0.coordinates.map { MKMapPoint($0) } }
        var labels: [MLNPointFeature] = []
        labelPoints = [:]
        var names: Set<String> = []
        for (index, variant) in shown.enumerated() {
            guard let point = RoutePreview.labelPoint(of: index, lines: mapLines) else { continue }
            let isSelected = variant.id == selected
            let name = "radar-variant-\(variant.id)-\(isSelected ? 1 : 0)-\(daylight ? "d" : "n")-\(variant.eta)"
            if !imageNames.contains(name) {
                style.setImage(Self.pill(variant.eta, selected: isSelected, daylight: daylight), forName: name)
            }
            names.insert(name)
            let feature = MLNPointFeature()
            feature.coordinate = point.coordinate
            labelPoints[variant.id] = point.coordinate
            feature.attributes = ["id": variant.id, "img": name, "rank": isSelected ? 1 : 0]
            labels.append(feature)
        }
        (style.source(withIdentifier: Self.labelSource) as? MLNShapeSource)?.shape =
            labels.isEmpty ? nil : MLNShapeCollectionFeature(shapes: labels)
        for stale in imageNames.subtracting(names) { style.removeImage(forName: stale) }
        imageNames = names
    }

    /// Вариант под пальцем: сначала подпись (она крупнее линии), потом линия.
    /// nil — мимо или вариантов нет.
    func variant(at point: CGPoint, in view: MLNMapView) -> Int? {
        guard isShowing else { return nil }
        let half = AppConfig.routeVariantTapPoints
        let rect = CGRect(x: point.x - half, y: point.y - half, width: half * 2, height: half * 2)
        let hits = view.visibleFeatures(in: rect, styleLayerIdentifiers: [Self.labelLayer])
            .compactMap { ($0.attribute(forKey: "id") as? NSNumber)?.intValue }
        if let id = hits.first { return id }
        let screen = lines.map { line in
            RoutePreview.Line(id: line.id, points: line.coordinates.map { view.convert($0, toPointTo: view) })
        }
        return RoutePreview.variant(at: point, lines: screen, selected: selected)
    }

    // MARK: - Слои

    private func install(in style: MLNStyle, daylight: Bool) {
        installed = true
        let lineSource = style.source(withIdentifier: Self.lineSource) as? MLNShapeSource
            ?? MLNShapeSource(identifier: Self.lineSource, shape: nil)
        let labelSource = style.source(withIdentifier: Self.labelSource) as? MLNShapeSource
            ?? MLNShapeSource(identifier: Self.labelSource, shape: nil)
        if style.source(withIdentifier: Self.lineSource) == nil { style.addSource(lineSource) }
        if style.source(withIdentifier: Self.labelSource) == nil { style.addSource(labelSource) }
        if style.layer(withIdentifier: Self.casingLayer) == nil {
            let casing = MLNLineStyleLayer(identifier: Self.casingLayer, source: lineSource)
            let body = MLNLineStyleLayer(identifier: Self.bodyLayer, source: lineSource)
            for layer in [casing, body] {
                layer.lineCap = NSExpression(forConstantValue: "round")
                layer.lineJoin = NSExpression(forConstantValue: "round")
            }
            casing.lineWidth = Self.width(extra: 2.5)
            body.lineWidth = Self.width(extra: 0)
            // Под выбранной лентой: ниже пройденного и каймы маршрута.
            if let anchor = style.layer(withIdentifier: "route-traveled") ?? style.layer(withIdentifier: "route-case") {
                style.insertLayer(casing, below: anchor)
                style.insertLayer(body, below: anchor)
            } else {
                style.addLayer(casing)
                style.addLayer(body)
            }
        }
        if style.layer(withIdentifier: Self.labelLayer) == nil {
            let labels = MLNSymbolStyleLayer(identifier: Self.labelLayer, source: labelSource)
            labels.iconImageName = NSExpression(forKeyPath: "img")
            // Подпись не вытесняет ни камеру, ни название улицы — и её ничто
            // не прячет: время варианта — то, ради чего человек смотрит.
            labels.iconAllowsOverlap = NSExpression(forConstantValue: true)
            labels.iconIgnoresPlacement = NSExpression(forConstantValue: true)
            labels.symbolSortKey = NSExpression(forKeyPath: "rank")
            if let arrows = style.layer(withIdentifier: "route-arrows") {
                style.insertLayer(labels, above: arrows)
            } else if let camera = style.layer(withIdentifier: "camera-dot") {
                style.insertLayer(labels, below: camera)
            } else {
                style.addLayer(labels)
            }
        }
        paint(style, daylight: daylight)
    }

    private func paint(_ style: MLNStyle, daylight: Bool) {
        let body = daylight ? RouteColors.alternative.day : RouteColors.alternative.night
        let casing = daylight ? RouteColors.alternativeCasing.day : RouteColors.alternativeCasing.night
        (style.layer(withIdentifier: Self.casingLayer) as? MLNLineStyleLayer)?.lineColor =
            NSExpression(forConstantValue: Theme.rgb(casing))
        (style.layer(withIdentifier: Self.bodyLayer) as? MLNLineStyleLayer)?.lineColor =
            NSExpression(forConstantValue: Theme.rgb(body))
    }

    /// Ширина другого варианта — ~0,6 выбранной (EngineMapStyle.routeWidth):
    /// главный предмет — выбранный (ночью светлый серо-синий вариант при
    /// равной ширине спорил с ним — снимок CarPlay 27.D); попасть пальцем
    /// помогает не ширина, а порог касания 22 pt и подпись.
    private static func width(extra: Double) -> NSExpression {
        let stops: [NSNumber: NSNumber] = [11: NSNumber(value: 3.5 + extra), 15: NSNumber(value: 4.5 + extra),
                                           17: NSNumber(value: 7 + extra), 19: NSNumber(value: 10 + extra)]
        return NSExpression(format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'linear', nil, %@)",
                            stops)
    }

    /// Подпись времени: выбранный — синей заливкой с белым, как его карточка;
    /// другие — панелью с каймой своего тона.
    static func pill(_ text: String, selected: Bool, daylight: Bool) -> UIImage {
        let font = UIFont.systemFont(ofSize: 14, weight: .bold).withRounded
        let ink: UIColor = selected ? .white : Theme.rgb(daylight ? 0x111827 : 0xF1F4F8)
        let fill: UIColor = selected ? Theme.rgb(daylight ? 0x2563D9 : 0x2A62D6)
                                     : Theme.rgb(daylight ? 0xFFFFFF : 0x1E232A)
        let rim: UIColor = selected ? .white
            : Theme.rgb(daylight ? RouteColors.alternativeCasing.day : RouteColors.alternative.night)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let size = (text as NSString).size(withAttributes: attributes)
        let box = CGSize(width: ceil(size.width) + 20, height: ceil(size.height) + 10)
        return UIGraphicsImageRenderer(size: box).image { _ in
            let shape = UIBezierPath(roundedRect: CGRect(origin: .zero, size: box).insetBy(dx: 1, dy: 1),
                                     cornerRadius: box.height / 2)
            fill.setFill()
            shape.fill()
            rim.setStroke()
            shape.lineWidth = 1.5
            shape.stroke()
            (text as NSString).draw(at: CGPoint(x: (box.width - size.width) / 2, y: (box.height - size.height) / 2),
                                    withAttributes: attributes)
        }
    }
}

private extension UIFont {
    var withRounded: UIFont {
        guard let descriptor = fontDescriptor.withDesign(.rounded) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
#endif
