//
//  EngineDriveRibbon.swift
//  RadarMap
//
//  Лента маршрута «Вождения 3D» на карте движка (43). Геометрию считает
//  LanePath (чистый, тесты), здесь — только слои, источник и когда писать.
//
//  Слои — двумя стопками из одного источника: у земли — под разметкой
//  (`radar-markings-solid`), у моста — над настилом под его разметкой
//  (`radar-markings-solid-bridge`). Часть ленты под эстакадой лежит под
//  настилом и не просвечивает, часть на рампе — на ней. В стопке снизу вверх:
//  жила середины (нижний предел толщины в точках — у горизонта лента не
//  пропадает), площадь ленты, пробки на ней (цветом линии маршрута), кант,
//  шевроны направления.
//
//  Когда пишется (правило аудита 11.10 — на тике источники не переписываются):
//  • расчёт — на смене маршрута, манёвра, разрешения сужения, на входе в
//    окно подъезда и раз в drive3DRecomputeMeters пути (Drive3D.needsRecompute),
//    вне главного потока; ленты дорог берутся пробами вдоль маршрута на
//    экране, стрелки ряда — из загруженных тайлов;
//  • срез под машиной — шагом drive3DCutStepMeters (лента начинается у
//    машины, пройденного нет);
//  • фильтр шевронов — когда срез проходит шеврон.
//
//  Линия маршрута при этом гаснет с 15-го зума (лента её сменяет), до него —
//  как была: обзор и дальняя трасса остаются тонкой линией.
//
//  Только картинка: ни голос, ни оповещения, ни прогресс маршрута отсюда не
//  читают.
//

#if canImport(MapLibre)
import MapKit
import MapLibre
import os
import UIKit

@MainActor
final class EngineDriveRibbon {

    static let sourceID = "drive-ribbon"
    static let chevronSourceID = "drive-ribbon-chevrons"
    static let chevronImage = "radar-ribbon-chevron"
    /// Слои стопки, снизу вверх.
    private static let roles = ["spine", "body", "traffic", "edge", "chevrons"]
    static func layerID(_ role: String, bridge: Bool) -> String { "drive-ribbon-\(role)" + (bridge ? "-bridge" : "") }
    static var layerIDs: [String] { roles.flatMap { [layerID($0, bridge: false), layerID($0, bridge: true)] } }

    /// Слои линии маршрута, которые лента сменяет с 15-го зума.
    private static let routeLines = ["route-traveled", "route-case", "route", "route-traffic", "route-maneuver",
                                     "route-core", EngineMapStyle.routeNearLayers.casing,
                                     EngineMapStyle.routeNearLayers.body, EngineMapStyle.routeNearLayers.maneuver,
                                     EngineMapStyle.routeNearLayers.core]
    /// Ленты наших дорог для проб (make_style: radar-roads…).
    private static let roadLayers: Set<String> = ["radar-roads", "radar-roads-stub", "radar-bridge"]

    private var installed = false
    private var active = false
    private var paintedDaylight: Bool?
    private var originals: [String: NSExpression?] = [:]
    private var arrowsWereVisible: Bool?

    private var ribbon: LanePath.Ribbon?
    private var plan: Drive3D.Plan?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var writtenCut: Double?
    private var writtenTraffic = -1
    private var chevrons: [LanePath.Chevron] = []
    private var chevronThreshold: Double?
    private var chevronGate = Drive3D.ChevronGate()
    private var chevronsShown: Bool?

    private var routeKey: Int?
    private var cumulative: [Double] = []

    func styleLoaded() {
        cancel()
        installed = false
        active = false
        paintedDaylight = nil
        originals = [:]
        arrowsWereVisible = nil
        ribbon = nil
        plan = nil
        writtenCut = nil
        writtenTraffic = -1
        chevrons = []
        chevronThreshold = nil
        chevronsShown = nil
    }

    func cancel() {
        task?.cancel()
        generation += 1
    }

    /// - Parameters:
    ///   - cut: где нарисована граница пройденного (EngineRouteLine), м.
    ///   - traffic: пробки на линии с местом в метрах.
    func update(_ model: EngineMapView, on: Bool, cut: Double?, traffic: [RouteTraffic.Piece],
                in view: MLNMapView) {
        guard let style = view.style else { return }
        let surface = model.drive3D
        guard on, let surface, model.route.count >= 2 else {
            if active { deactivate(in: style) }
            return
        }
        if !installed { install(in: style) }
        if !active { activate(in: style) }
        if paintedDaylight != model.daylight { paint(daylight: model.daylight, in: style) }

        let key = model.routeObject.map { ObjectIdentifier($0).hashValue } ?? model.route.count
        if key != routeKey {
            routeKey = key
            cumulative = Self.cumulative(model.route)
            ribbon = nil
            plan = nil
            writtenCut = nil
            write(nil, in: style)
        }
        let car = max(0, cut ?? model.routeProgress)
        let speedKmh = max(0, (model.markerMotion?.speedMps ?? 0) * 3.6)
        let window = LaneFocus.window(speedKmh: speedKmh)
        let narrowing = Drive3D.narrows(surface: surface, hot: model.performance != .full)
        if Drive3D.needsRecompute(last: plan, route: key, car: car, maneuver: model.maneuverAlong, window: window,
                                  narrowing: narrowing) {
            compute(model, key: key, car: car, speedKmh: speedKmh, window: window, narrowing: narrowing, in: view)
        }
        last = (car, traffic)
        guard let ribbon else { return }
        let quantized = Drive3D.quantizedCut(car)
        if Drive3D.cutDue(last: writtenCut, now: quantized) || writtenTraffic != model.trafficRevision {
            writtenCut = quantized
            writtenTraffic = model.trafficRevision
            write(Self.collection(ribbon, cut: quantized, traffic: traffic), in: style)
        }
        updateChevrons(surface: surface, cut: car, speedKmh: speedKmh, in: style)
    }

    // MARK: - Расчёт

    private func compute(_ model: EngineMapView, key: Int, car: Double, speedKmh: Double, window: Double,
                         narrowing: Bool, in view: MLNMapView) {
        let from = max(0, car - 20)
        plan = Drive3D.Plan(route: key, from: car, maneuver: model.maneuverAlong, narrowing: narrowing,
                            inWindow: Drive3D.inWindow(car: car, maneuver: model.maneuverAlong, window: window))
        let maneuver = Self.maneuver(model)
        let probeStart = CACurrentMediaTime()
        let roads = probeRoads(route: model.route, from: from, length: AppConfig.drive3DAheadMeters, in: view)
        let arrows = maneuver.map { probeArrows(near: $0.along, model: model, in: view) } ?? []
        let probeMs = Int((CACurrentMediaTime() - probeStart) * 1000)
        let input = LanePath.Input(route: model.route, from: from, length: AppConfig.drive3DAheadMeters, car: car,
                                   speedMps: speedKmh / 3.6, window: window, roads: roads, arrows: arrows,
                                   maneuver: maneuver, narrowing: narrowing, cumulative: cumulative)
        cancel()
        let generation = generation
        let started = CACurrentMediaTime()
        task = Task { [weak self, weak view] in
            let ribbon = await Self.build(input)
            guard let self, let view, generation == self.generation, let style = view.style else { return }
            self.ribbon = ribbon
            self.chevrons = LanePath.chevrons(ribbon, spacing: AppConfig.drive3DChevronSpacing)
            self.chevronThreshold = nil
            self.writeChevrons(in: style)
            // Готовый расчёт ложится сразу — по последнему срезу, не дожидаясь фикса.
            let cut = Drive3D.quantizedCut(self.last.cut)
            self.writtenCut = cut
            self.write(Self.collection(ribbon, cut: cut, traffic: self.last.traffic), in: style)
            Log.route.info("Лента 3D: \(roads.count, privacy: .public) лент, \(arrows.count, privacy: .public) стрелок, совпало \(Int(ribbon.matchedShare * 100), privacy: .public) %, сужение \(String(describing: ribbon.narrowing), privacy: .public), пробы \(probeMs, privacy: .public) мс на главном, расчёт \(Int((CACurrentMediaTime() - started) * 1000), privacy: .public) мс")
        }
    }

    /// Последний срез и пробки — чтобы готовый расчёт сразу лёг на карту.
    private var last: (cut: Double, traffic: [RouteTraffic.Piece]) = (0, [])

    @concurrent
    private nonisolated static func build(_ input: LanePath.Input) async -> LanePath.Ribbon {
        LanePath.build(input)
    }

    private static func maneuver(_ model: EngineMapView) -> LanePath.Maneuver? {
        guard let along = model.maneuverAlong, let kind = model.maneuverKind else { return nil }
        let edge: LanePath.Edge? = switch kind {
        case .left, .sharpLeft, .uturn: .left
        case .right, .sharpRight: .right
        default: nil
        }
        let row = ![ManeuverKind.straight, .roundabout, .arrive].contains(kind)
        guard edge != nil || row else { return nil }
        return LanePath.Maneuver(along: along, edge: edge, row: row)
    }

    private static func cumulative(_ route: [CLLocationCoordinate2D]) -> [Double] {
        RouteService.cumulative(of: route.map(MKMapPoint.init))
    }

    /// Координата на линии маршрута в метрах от старта.
    private func point(at along: Double, route: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D? {
        guard cumulative.count == route.count, let k = cumulative.firstIndex(where: { $0 >= along }) else { return nil }
        guard k > 0 else { return route[0] }
        let t = (along - cumulative[k - 1]) / max(0.01, cumulative[k] - cumulative[k - 1])
        let a = route[k - 1], b = route[k]
        return CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                      longitude: a.longitude + (b.longitude - a.longitude) * t)
    }

    /// Ленты дорог вдоль маршрута на экране: квадрат пробы через каждые
    /// drive3DProbeStepMeters. За краем экрана данных нет — LanePath
    /// продолжит последней известной шириной до следующего пересчёта.
    private func probeRoads(route: [CLLocationCoordinate2D], from: Double, length: Double,
                            in view: MLNMapView) -> [LanePath.Road] {
        var seen = Set<String>()
        var out: [LanePath.Road] = []
        let bounds = view.bounds
        let half = AppConfig.drive3DProbePoints / 2
        var along = from
        var probes = 0
        while along <= from + length, probes < AppConfig.drive3DProbeLimit,
              let coordinate = point(at: along, route: route) {
            along += AppConfig.drive3DProbeStepMeters
            let p = view.convert(coordinate, toPointTo: view)
            guard bounds.contains(p) else { continue }
            probes += 1
            let rect = CGRect(x: p.x - half, y: p.y - half, width: 2 * half, height: 2 * half)
            for feature in view.visibleFeatures(in: rect, styleLayerIdentifiers: Self.roadLayers) {
                for line in Self.lines(of: feature) where line.count >= 2 {
                    let first = line[0], last = line[line.count - 1]
                    let key = String(format: "%.6f,%.6f,%.6f,%.6f,%d", first.latitude, first.longitude,
                                     last.latitude, last.longitude, line.count)
                    guard seen.insert(key).inserted else { continue }
                    let width = (feature.attribute(forKey: "width") as? NSNumber)?.doubleValue ?? 0
                    guard width > 0 else { continue }
                    out.append(LanePath.Road(points: line, width: width,
                                             oneway: Self.flag(feature, "oneway"), bridge: Self.flag(feature, "bridge"),
                                             inner: Self.flag(feature, "inner"), stub: Self.flag(feature, "stub")))
                }
            }
        }
        return out
    }

    /// Стрелки полос у манёвра из загруженных тайлов (видны они с 17-го, а
    /// ряд нужен и раньше). Чья стрелка — по полосам манёвра (LaneFocus), а
    /// без них — по набору поворотов стрелки.
    private func probeArrows(near along: Double, model: EngineMapView, in view: MLNMapView) -> [LanePath.Arrow] {
        guard let centre = point(at: along, route: model.route),
              let source = view.style?.source(withIdentifier: "radar") as? MLNVectorTileSource else { return [] }
        let movement = model.maneuverKind.flatMap(LaneFocus.movement)
        let focus = model.laneFocus.flatMap { abs($0.along - along) < 5 ? $0 : nil }
        var out: [LanePath.Arrow] = []
        for feature in source.features(sourceLayerIdentifiers: ["arrows"], predicate: nil) {
            guard let point = feature as? MLNPointFeature else { continue }
            let c = point.coordinate
            guard GeoMath.fastDistance(c.latitude, c.longitude, centre.latitude, centre.longitude)
                    <= AppConfig.drive3DRowSearchMeters + 30 else { continue }
            let number = { (key: String) in (feature.attribute(forKey: key) as? NSNumber) }
            guard let turn = number("turn")?.intValue, let bearing = number("bearing")?.doubleValue else { continue }
            let lane = LaneFocus.Lane(index: number("li")?.intValue, count: number("ln")?.intValue,
                                      width: number("lw")?.doubleValue, turn: turn)
            let ours = focus.map { $0.isOurs(lane) } ?? movement.map { lane.turns.contains($0) } ?? false
            out.append(LanePath.Arrow(coordinate: c, bearing: bearing, width: lane.width, ours: ours))
        }
        return out
    }

    private static func flag(_ feature: MLNFeature, _ key: String) -> Bool {
        guard let value = feature.attribute(forKey: key) else { return false }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String { return text != "0" && text != "false" && !text.isEmpty }
        return true
    }

    private static func lines(of feature: MLNFeature) -> [[CLLocationCoordinate2D]] {
        if let line = feature as? MLNPolylineFeature { return [coordinates(line)] }
        if let multi = feature as? MLNMultiPolylineFeature { return multi.polylines.map(coordinates) }
        return []
    }

    private static func coordinates(_ line: MLNPolyline) -> [CLLocationCoordinate2D] {
        let count = Int(line.pointCount)
        guard count > 0 else { return [] }
        var out = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: count)
        line.getCoordinates(&out, range: NSRange(location: 0, length: count))
        return out
    }

    // MARK: - Источник

    private static func collection(_ ribbon: LanePath.Ribbon, cut: Double,
                                   traffic: [RouteTraffic.Piece]) -> MLNShapeCollectionFeature {
        var shapes: [MLNShape] = []
        for piece in LanePath.pieces(ribbon, from: cut) {
            shapes.append(polygon(piece.ring, kind: "body", bridge: piece.bridge))
            shapes.append(line(piece.centre, kind: "spine", bridge: piece.bridge))
            shapes.append(line(piece.left, kind: "edge", bridge: piece.bridge))
            shapes.append(line(piece.right, kind: "edge", bridge: piece.bridge))
        }
        for jam in traffic where jam.to > cut {
            for piece in LanePath.pieces(ribbon, from: max(cut, jam.from), to: jam.to) {
                let shape = polygon(piece.ring, kind: "traffic", bridge: piece.bridge)
                shape.attributes["level"] = jam.level
                shapes.append(shape)
            }
        }
        return MLNShapeCollectionFeature(shapes: shapes)
    }

    private static func polygon(_ ring: [CLLocationCoordinate2D], kind: String, bridge: Bool) -> MLNPolygonFeature {
        var points = ring
        let shape = MLNPolygonFeature(coordinates: &points, count: UInt(points.count))
        shape.attributes = ["k": kind, "bridge": bridge]
        return shape
    }

    private static func line(_ coordinates: [CLLocationCoordinate2D], kind: String, bridge: Bool) -> MLNPolylineFeature {
        var points = coordinates
        let shape = MLNPolylineFeature(coordinates: &points, count: UInt(points.count))
        shape.attributes = ["k": kind, "bridge": bridge]
        return shape
    }

    private func write(_ shape: MLNShape?, in style: MLNStyle) {
        (style.source(withIdentifier: Self.sourceID) as? MLNShapeSource)?.shape = shape
    }

    private func writeChevrons(in style: MLNStyle) {
        let shapes = chevrons.map { chevron -> MLNPointFeature in
            let point = MLNPointFeature()
            point.coordinate = chevron.coordinate
            point.attributes = ["a": chevron.along, "b": chevron.bearing, "bridge": chevron.bridge]
            return point
        }
        (style.source(withIdentifier: Self.chevronSourceID) as? MLNShapeSource)?.shape =
            MLNShapeCollectionFeature(shapes: shapes)
    }

    /// Шевроны: видимость по скорости (гистерезис), фильтр «впереди среза» —
    /// когда срез проходит очередной шеврон, а не на каждом применении.
    private func updateChevrons(surface: Drive3D.Surface, cut: Double, speedKmh: Double, in style: MLNStyle) {
        let shown = Drive3D.chevrons(surface: surface) && chevronGate.update(speedKmh: speedKmh)
        if shown != chevronsShown {
            chevronsShown = shown
            for bridge in [false, true] {
                style.layer(withIdentifier: Self.layerID("chevrons", bridge: bridge))?.isVisible = shown
            }
        }
        guard shown else { return }
        let threshold = chevrons.first { $0.along > cut + 10 }?.along ?? .infinity
        guard threshold != chevronThreshold else { return }
        chevronThreshold = threshold
        for bridge in [false, true] {
            (style.layer(withIdentifier: Self.layerID("chevrons", bridge: bridge)) as? MLNSymbolStyleLayer)?.predicate =
                NSPredicate(mglJSONObject: ["all", ["==", ["get", "bridge"], bridge],
                                            [">=", ["get", "a"], threshold.isFinite ? threshold : 1e9]])
        }
    }

    // MARK: - Слои

    private func install(in style: MLNStyle) {
        installed = true
        for id in [Self.sourceID, Self.chevronSourceID] where style.source(withIdentifier: id) == nil {
            style.addSource(MLNShapeSource(identifier: id, shape: nil))
        }
        guard let source = style.source(withIdentifier: Self.sourceID),
              let chevronSource = style.source(withIdentifier: Self.chevronSourceID) else { return }
        style.setImage(Self.chevronIcon(), forName: Self.chevronImage)
        for bridge in [false, true] {
            let anchor = style.layer(withIdentifier: bridge ? "radar-markings-solid-bridge" : "radar-markings-solid")
                ?? ["traffic", "route-traveled", "route-case"].lazy.compactMap { style.layer(withIdentifier: $0) }.first
            for role in Self.roles {
                let id = Self.layerID(role, bridge: bridge)
                guard style.layer(withIdentifier: id) == nil else { continue }
                let layer = Self.makeLayer(role, bridge: bridge, source: role == "chevrons" ? chevronSource : source)
                layer.isVisible = false
                if let anchor { style.insertLayer(layer, below: anchor) } else { style.addLayer(layer) }
            }
        }
    }

    private static func makeLayer(_ role: String, bridge: Bool, source: MLNSource) -> MLNStyleLayer {
        let id = layerID(role, bridge: bridge)
        let filter = { (kind: String) in
            NSPredicate(mglJSONObject: ["all", ["==", ["get", "k"], kind], ["==", ["get", "bridge"], bridge]])
        }
        // Лента сменяет линию маршрута на 14,5–15,5 (Drive3D: линия гаснет там же).
        let fadeIn = NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"], 14.5, 0, 15.5, 1])
        switch role {
        case "spine":
            let layer = MLNLineStyleLayer(identifier: id, source: source)
            layer.predicate = filter("spine")
            layer.lineJoin = NSExpression(forConstantValue: "round")
            layer.lineCap = NSExpression(forConstantValue: "round")
            layer.lineWidth = NSExpression(forConstantValue: AppConfig.drive3DSpinePoints)
            layer.lineOpacity = fadeIn
            return layer
        case "body", "traffic":
            let layer = MLNFillStyleLayer(identifier: id, source: source)
            layer.predicate = filter(role)
            layer.fillAntialiased = NSExpression(forConstantValue: true)
            layer.fillOpacity = fadeIn
            return layer
        case "edge":
            let layer = MLNLineStyleLayer(identifier: id, source: source)
            layer.predicate = filter("edge")
            layer.lineJoin = NSExpression(forConstantValue: "round")
            layer.lineCap = NSExpression(forConstantValue: "butt")
            return layer
        default:
            let layer = MLNSymbolStyleLayer(identifier: id, source: source)
            layer.predicate = NSPredicate(mglJSONObject: ["==", ["get", "bridge"], bridge])
            layer.iconImageName = NSExpression(forConstantValue: chevronImage)
            layer.iconRotation = NSExpression(mglJSONObject: ["get", "b"])
            layer.iconRotationAlignment = NSExpression(forConstantValue: "map")
            layer.iconPitchAlignment = NSExpression(forConstantValue: "map")
            layer.iconAllowsOverlap = NSExpression(forConstantValue: true)
            layer.iconIgnoresPlacement = NSExpression(forConstantValue: true)
            layer.iconScale = NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"],
                                                           15, 0.45, 17, 0.75, 19, 1.2, 20, 1.5])
            layer.minimumZoomLevel = 15
            return layer
        }
    }

    private func paint(daylight: Bool, in style: MLNStyle) {
        paintedDaylight = daylight
        let ribbon = Drive3D.ribbon(daylight: daylight)
        let fill = NSExpression(forConstantValue: Theme.rgb(ribbon.fill))
        let traffic = NSExpression(mglJSONObject: [
            "match", ["get", "level"], 3, RouteColors.pick(RouteColors.jam, daylight: daylight),
            RouteColors.pick(RouteColors.slow, daylight: daylight)])
        // Кант — 0,5–1 точки, проступает с 15,5-го (у горизонта два канта в
        // жилу не сливаются); ночью — еле заметный.
        let edgeOpacity = NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"],
                                                       15.5, 0, 16.5, ribbon.edgeOpacity])
        let edgeWidth = NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"],
                                                     16, 0.5, 18, daylight ? 0.9 : 0.7, 20, daylight ? 1.2 : 0.9])
        for bridge in [false, true] {
            (style.layer(withIdentifier: Self.layerID("spine", bridge: bridge)) as? MLNLineStyleLayer)?.lineColor = fill
            (style.layer(withIdentifier: Self.layerID("body", bridge: bridge)) as? MLNFillStyleLayer)?.fillColor = fill
            (style.layer(withIdentifier: Self.layerID("traffic", bridge: bridge)) as? MLNFillStyleLayer)?.fillColor = traffic
            if let edge = style.layer(withIdentifier: Self.layerID("edge", bridge: bridge)) as? MLNLineStyleLayer {
                edge.lineColor = NSExpression(forConstantValue: Theme.rgb(ribbon.edge))
                edge.lineOpacity = edgeOpacity
                edge.lineWidth = edgeWidth
            }
            (style.layer(withIdentifier: Self.layerID("chevrons", bridge: bridge)) as? MLNSymbolStyleLayer)?.iconOpacity =
                NSExpression(forConstantValue: daylight ? 0.8 : 0.45)
        }
    }

    /// Включить: слои ленты видны, линия маршрута гаснет с 15-го зума,
    /// стрелки направления на линии уходят (у ленты свои шевроны).
    private func activate(in style: MLNStyle) {
        active = true
        for role in Self.roles where role != "chevrons" {
            for bridge in [false, true] { style.layer(withIdentifier: Self.layerID(role, bridge: bridge))?.isVisible = true }
        }
        chevronsShown = nil
        for id in Self.routeLines {
            guard let layer = style.layer(withIdentifier: id) as? MLNLineStyleLayer else { continue }
            let was: NSExpression? = layer.lineOpacity
            originals[id] = was
            let constant = was?.expressionType == .constantValue ? was?.constantValue as? NSNumber : nil
            let start = constant?.doubleValue ?? 1
            layer.lineOpacity = NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"],
                                                             14.5, start, 15.5, 0])
        }
        if let arrows = style.layer(withIdentifier: "route-arrows") {
            arrowsWereVisible = arrows.isVisible
            arrows.isVisible = false
        }
    }

    private func deactivate(in style: MLNStyle) {
        active = false
        cancel()
        for id in Self.layerIDs { style.layer(withIdentifier: id)?.isVisible = false }
        for (id, value) in originals {
            (style.layer(withIdentifier: id) as? MLNLineStyleLayer)?.lineOpacity =
                value ?? NSExpression(forConstantValue: 1)
        }
        originals = [:]
        if let was = arrowsWereVisible { style.layer(withIdentifier: "route-arrows")?.isVisible = was }
        arrowsWereVisible = nil
        write(nil, in: style)
        (style.source(withIdentifier: Self.chevronSourceID) as? MLNShapeSource)?.shape = nil
        ribbon = nil
        plan = nil
        routeKey = nil
        writtenCut = nil
        chevrons = []
        chevronThreshold = nil
        chevronsShown = nil
        last = (0, [])
    }

    /// Шеврон носом вверх (по ходу при icon-rotate = курс): тонкий светлый,
    /// без каймы — направление, а не знак.
    private static func chevronIcon() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 18, height: 12)).image { _ in
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 3, y: 10))
            path.addLine(to: CGPoint(x: 9, y: 3))
            path.addLine(to: CGPoint(x: 15, y: 10))
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.lineWidth = 2.2
            UIColor.white.setStroke()
            path.stroke()
        }
    }
}
#endif
