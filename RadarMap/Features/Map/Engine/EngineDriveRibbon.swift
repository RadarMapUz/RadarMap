//
//  EngineDriveRibbon.swift
//  RadarMap
//
//  Лента маршрута «Вождения 3D» на карте движка (43). Геометрию считает
//  LanePath (чистый, тесты), когда считать — Drive3D (тесты), здесь — слои,
//  источники и пробы тайла.
//
//  Слои — двумя стопками из одного источника: у земли — под разметкой
//  (`radar-markings-solid`), у моста — над настилом под его разметкой
//  (`radar-markings-solid-bridge`). Часть ленты под эстакадой лежит под
//  настилом и не просвечивает, часть на рампе — на ней. В стопке снизу вверх:
//  жила середины (нижний предел толщины в точках), площадь ленты, пробки на
//  ней (цветом линии маршрута), кант, шевроны.
//
//  Лента — только на прощупанном участке (LanePath.Ribbon.verifiedEnd).
//  Дальше маршрут — «хвостом»: линия цветом маршрута от конца ленты; обычная
//  линия маршрута гаснет с 15-го зума только пока лента готова (isReady), а
//  без лент тайла (обзор, непрогруженная карта) остаётся как была.
//
//  Когда пишется (правило аудита 11.10 — источники не на тике):
//  • расчёт — только при слежении, с 15-го зума и на дорисованном кадре
//    (Drive3D.canCompute), на смене маршрута, манёвра, перегрева, на входе в
//    окно подъезда, у конца прощупанного и раз в 250 м (Drive3D.needsRecompute);
//    вне главного потока; ленты дорог — пробами вдоль маршрута на экране
//    (с запасом прощупанного), стрелки ряда — только при сужении;
//  • источник — только с готовым расчётом и новыми пробками;
//  • срез под машиной — фильтром слоёв по концу куска (`t`), шагом
//    Drive3D.cutStep (крупнее на горячем телефоне);
//  • фильтр шевронов — когда срез проходит шеврон.
//  Записи источника и перестановки среза считаются и раз в минуту уходят в
//  журнал; вокруг них — signpost «Лента 3D».
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
    static let tailSourceID = "drive-ribbon-tail"
    static let chevronImage = "radar-ribbon-chevron"
    static let tailLayers = (casing: "drive-ribbon-tail-case", body: "drive-ribbon-tail")
    /// Слои стопки, снизу вверх.
    private static let roles = ["spine", "body", "traffic", "edge", "chevrons"]
    /// Слои, которые режет срез под машиной.
    private static let cutRoles = ["spine", "body", "traffic", "edge"]
    static func layerID(_ role: String, bridge: Bool) -> String { "drive-ribbon-\(role)" + (bridge ? "-bridge" : "") }
    static var layerIDs: [String] {
        roles.flatMap { [layerID($0, bridge: false), layerID($0, bridge: true)] } + [tailLayers.casing, tailLayers.body]
    }

    /// Слои линии маршрута, которые лента сменяет с 15-го зума.
    private static let routeLines = ["route-traveled", "route-case", "route", "route-traffic", "route-maneuver",
                                     "route-core", EngineMapStyle.routeNearLayers.casing,
                                     EngineMapStyle.routeNearLayers.body, EngineMapStyle.routeNearLayers.maneuver,
                                     EngineMapStyle.routeNearLayers.core]
    private static let routeArrows = "route-arrows"
    /// Ленты наших дорог для проб (make_style: radar-roads…).
    private static let roadLayers: Set<String> = ["radar-roads", "radar-roads-stub", "radar-bridge"]
    private static let arrowLayers: Set<String> = [EngineLaneFocus.baseLayer, EngineLaneFocus.oursLayer,
                                                    EngineLaneFocus.otherLayer]

    private let performanceLog = OSLog(subsystem: "uz.radarmap", category: "MapPerformance")

    private var installed = false
    private var active = false
    /// Лента показана, линия маршрута с 15-го погашена.
    private var shown = false
    private var paintedDaylight: Bool?
    private var paintedRouteDaylight: Bool?
    private var originals: [String: NSExpression?] = [:]
    private var arrowsMaxZoom: Float?

    private var ribbon: LanePath.Ribbon?
    private var plan: Drive3D.Plan?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var attemptAt: CFTimeInterval = -.infinity

    /// Срез, по которому стоят фильтры слоёв (nil — ещё не ставили).
    private var cutValue: Double?
    private var writtenTraffic = -1
    private var lastTrafficVersion = 0
    private var chevrons: [LanePath.Chevron] = []
    private var chevronThreshold: Double?
    private var chevronGate = Drive3D.ChevronGate()
    private var chevronsShown: Bool?

    /// Маршрут — по тождеству линии (как EngineRouteLine), без неё — по точкам.
    private var routeRef: MKPolyline?
    private var routeCount = -1
    private var routeGeneration = 0
    private var cumulative: [Double] = []
    /// Прощупанные ленты тайла этого маршрута и докуда щупали.
    private var knownRoads: [String: LanePath.Road] = [:]
    private var probedUntil = -Double.infinity
    /// Стрелки ряда у манёвра (м от старта) — один запрос на манёвр.
    private var arrowsCache: (along: Double, arrows: [LanePath.Arrow])?

    /// Последний срез и пробки — готовый расчёт ложится сразу.
    private var last: (cut: Double, traffic: [RouteTraffic.Piece]) = (0, [])
    private var counters = (writes: 0, cuts: 0, since: CACurrentMediaTime())

    func styleLoaded() {
        cancel()
        installed = false
        active = false
        shown = false
        paintedDaylight = nil
        paintedRouteDaylight = nil
        originals = [:]
        arrowsMaxZoom = nil
        cutValue = nil
        writtenTraffic = -1
        chevronThreshold = nil
        chevronsShown = nil
        // Расчёт годен и для нового стиля — источники пустые, пишем заново.
        if ribbon != nil { writtenTraffic = -2 }
    }

    func cancel() {
        task?.cancel()
        generation += 1
    }

    /// - Parameters:
    ///   - probeAllowed: можно щупать тайлы (Drive3D.canCompute).
    ///   - cut: где нарисована граница пройденного (EngineRouteLine), м.
    ///   - traffic: пробки на линии с местом в метрах и их поколение.
    func update(_ model: EngineMapView, on: Bool, probeAllowed: Bool, cut: Double?,
                traffic: [RouteTraffic.Piece], trafficVersion: Int, routeDaylight: Bool, in view: MLNMapView) {
        guard let style = view.style else { return }
        guard on, let surface = model.drive3D, Drive3D.ribbon(surface: surface), model.route.count >= 2 else {
            if active { deactivate(in: style) }
            return
        }
        if !installed { install(in: style) }
        active = true
        if paintedDaylight != model.daylight || paintedRouteDaylight != routeDaylight {
            paint(daylight: model.daylight, routeDaylight: routeDaylight, in: style)
        }
        if model.routeObject !== routeRef || (model.routeObject == nil && model.route.count != routeCount) {
            routeChanged(model, in: style)
        }
        let hot = model.performance != .full
        let car = max(0, cut ?? model.routeProgress)
        let speedMps = max(0, model.markerMotion?.speedMps ?? 0)
        let window = LaneFocus.window(speedKmh: speedMps * 3.6)
        let narrowing = Drive3D.narrows(surface: surface, hot: hot)
        last = (car, traffic)
        lastTrafficVersion = trafficVersion
        if probeAllowed, Drive3D.needsRecompute(last: plan, route: routeGeneration, car: car,
                                                maneuver: model.maneuverAlong, window: window, narrowing: narrowing,
                                                sinceAttempt: CACurrentMediaTime() - attemptAt) {
            compute(model, car: car, speedMps: speedMps, window: window, narrowing: narrowing, in: view)
        }
        let ready = ribbon?.isReady == true
        if ready != shown { show(ready, in: style) }
        guard ready, let ribbon else { return }
        if writtenTraffic != trafficVersion {
            writtenTraffic = trafficVersion
            writeSource(ribbon, model: model, in: style)
        }
        if Drive3D.cutDue(last: cutValue, now: car, step: Drive3D.cutStep(speedMps: speedMps, hot: hot)) {
            setCut(car, in: style)
        }
        updateChevrons(surface: surface, hot: hot, cut: car, speedKmh: speedMps * 3.6, in: style)
        logCountersIfDue()
    }

    private func routeChanged(_ model: EngineMapView, in style: MLNStyle) {
        routeRef = model.routeObject
        routeCount = model.route.count
        routeGeneration &+= 1
        cumulative = RouteService.cumulative(of: model.route.map(MKMapPoint.init))
        cancel()
        ribbon = nil
        plan = nil
        knownRoads = [:]
        probedUntil = -.infinity
        arrowsCache = nil
        chevrons = []
        chevronThreshold = nil
        clearSources(in: style)
        if shown { show(false, in: style) }
    }

    // MARK: - Расчёт

    private func compute(_ model: EngineMapView, car: Double, speedMps: Double, window: Double, narrowing: Bool,
                         in view: MLNMapView) {
        attemptAt = CACurrentMediaTime()
        let from = max(0, car - 20)
        let maneuver = Self.maneuver(model)
        let previousEnd = plan?.verifiedEnd
        plan = Drive3D.Plan(route: routeGeneration, from: car, maneuver: model.maneuverAlong, narrowing: narrowing,
                            inWindow: Drive3D.inWindow(car: car, maneuver: model.maneuverAlong, window: window),
                            complete: false, verifiedEnd: previousEnd)
        os_signpost(.begin, log: performanceLog, name: "Лента 3D: пробы")
        let roads = probeRoads(route: model.route, from: from, length: AppConfig.drive3DAheadMeters, in: view)
        let arrows = narrowing ? maneuver.map { probeArrows(near: $0.along, model: model, in: view) } ?? [] : []
        os_signpost(.end, log: performanceLog, name: "Лента 3D: пробы")
        let probeMs = Int((CACurrentMediaTime() - attemptAt) * 1000)
        let input = LanePath.Input(route: model.route, from: from, length: AppConfig.drive3DAheadMeters, car: car,
                                   speedMps: speedMps, window: window, roads: roads, arrows: arrows,
                                   maneuver: maneuver, narrowing: narrowing, cumulative: cumulative)
        cancel()
        let generation = generation
        let started = CACurrentMediaTime()
        task = Task { [weak self, weak view] in
            let result = await Self.build(input)
            guard let self, let view, generation == self.generation, let style = view.style else { return }
            self.plan?.complete = result.isReady
            Log.route.info("Лента 3D: \(roads.count, privacy: .public) лент, \(arrows.count, privacy: .public) стрелок, совпало \(Int(result.matchedShare * 100), privacy: .public) %, прощупано \(Int(result.verifiedEnd - car), privacy: .public) м, сужение \(String(describing: result.narrowing), privacy: .public), пробы \(probeMs, privacy: .public) мс на главном, расчёт \(Int((CACurrentMediaTime() - started) * 1000), privacy: .public) мс")
            // Неготовый расчёт (карта без лент тайла) не сменяет готовый: тот
            // верен до своего конца, а повтор — на ближайшем годном кадре.
            guard result.isReady else { return }
            self.plan?.verifiedEnd = result.verifiedEnd
            self.ribbon = result
            self.chevrons = LanePath.chevrons(result, spacing: AppConfig.drive3DChevronSpacing)
                .filter { $0.along <= result.verifiedEnd }
            self.chevronThreshold = nil
            if let current = self.current {
                self.writtenTraffic = self.lastTrafficVersion
                self.writeSource(result, model: current, in: style)
            }
            self.setCut(self.last.cut, in: style)
            if !self.shown { self.show(true, in: style) }
        }
        current = model
    }

    /// Модель последнего применения — маршрут и пробки для записи готового расчёта.
    private var current: EngineMapView?

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

    /// Координата на линии маршрута в метрах от старта.
    private func point(at along: Double, route: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D? {
        guard cumulative.count == route.count, let k = cumulative.firstIndex(where: { $0 >= along }) else { return nil }
        guard k > 0 else { return route[0] }
        let t = (along - cumulative[k - 1]) / max(0.01, cumulative[k] - cumulative[k - 1])
        let a = route[k - 1], b = route[k]
        return CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                      longitude: a.longitude + (b.longitude - a.longitude) * t)
    }

    private func index(at along: Double) -> Int {
        cumulative.firstIndex { $0 >= along } ?? max(0, cumulative.count - 1)
    }

    /// Ленты дорог вдоль маршрута на экране: квадрат пробы через каждые
    /// drive3DProbeStepMeters, не дальше уже прощупанного минус 100 м; что
    /// нащупали раньше, остаётся (кеш маршрута). За краем экрана данных нет —
    /// лента там кончается, дальше линия (verifiedEnd).
    private func probeRoads(route: [CLLocationCoordinate2D], from: Double, length: Double,
                            in view: MLNMapView) -> [LanePath.Road] {
        if knownRoads.count > 8000 { knownRoads = [:]; probedUntil = -.infinity }
        let bounds = view.bounds
        let half = AppConfig.drive3DProbePoints / 2
        var along = max(from, probedUntil - 100)
        var probes = 0
        while along <= from + length, probes < AppConfig.drive3DProbeLimit,
              let coordinate = point(at: along, route: route) {
            let here = along
            along += AppConfig.drive3DProbeStepMeters
            let p = view.convert(coordinate, toPointTo: view)
            guard bounds.contains(p) else { continue }
            probes += 1
            probedUntil = max(probedUntil, here)
            let rect = CGRect(x: p.x - half, y: p.y - half, width: 2 * half, height: 2 * half)
            for feature in view.visibleFeatures(in: rect, styleLayerIdentifiers: Self.roadLayers) {
                for line in Self.lines(of: feature) where line.count >= 2 {
                    let first = line[0], end = line[line.count - 1]
                    let key = String(format: "%.6f,%.6f,%.6f,%.6f,%ld", first.latitude, first.longitude,
                                     end.latitude, end.longitude, line.count)
                    guard knownRoads[key] == nil else { continue }
                    let width = (feature.attribute(forKey: "width") as? NSNumber)?.doubleValue ?? 0
                    guard width > 0 else { continue }
                    knownRoads[key] = LanePath.Road(points: line, width: width,
                                                    oneway: Self.flag(feature, "oneway"),
                                                    bridge: Self.flag(feature, "bridge"),
                                                    inner: Self.flag(feature, "inner"), stub: Self.flag(feature, "stub"))
                }
            }
        }
        return Array(knownRoads.values)
    }

    /// Стрелки полос у манёвра — один запрос на манёвр: с 17-го — нарисованные
    /// у точки манёвра, раньше — из загруженных тайлов в окрестности. Чья
    /// стрелка — по полосам манёвра (LaneFocus), без них — по набору поворотов.
    private func probeArrows(near along: Double, model: EngineMapView, in view: MLNMapView) -> [LanePath.Arrow] {
        if let cache = arrowsCache, cache.along == along, !cache.arrows.isEmpty { return cache.arrows }
        guard let centre = point(at: along, route: model.route) else { return [] }
        let movement = model.maneuverKind.flatMap(LaneFocus.movement)
        let focus = model.laneFocus.flatMap { abs($0.along - along) < 5 ? $0 : nil }
        var features: [MLNFeature] = []
        let p = view.convert(centre, toPointTo: view)
        if view.zoomLevel >= 17, view.bounds.contains(p) {
            features = view.visibleFeatures(in: CGRect(x: p.x - 160, y: p.y - 160, width: 320, height: 320),
                                            styleLayerIdentifiers: Self.arrowLayers)
        } else if let source = view.style?.source(withIdentifier: "radar") as? MLNVectorTileSource {
            features = source.features(sourceLayerIdentifiers: ["arrows"], predicate: nil)
        }
        var out: [LanePath.Arrow] = []
        for feature in features {
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
        arrowsCache = (along, out)
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

    // MARK: - Источники

    /// Лента от машины до конца прощупанного (кусками по 8 м — для среза
    /// фильтром), пробки на ней, шевроны и хвост линии за ней.
    private func writeSource(_ ribbon: LanePath.Ribbon, model: EngineMapView, in style: MLNStyle) {
        os_signpost(.begin, log: performanceLog, name: "Лента 3D: запись")
        defer { os_signpost(.end, log: performanceLog, name: "Лента 3D: запись") }
        counters.writes += 1
        let start = max(ribbon.along.first ?? 0, last.cut - 20)
        let end = ribbon.verifiedEnd
        let chunk = AppConfig.drive3DCutStepMeters
        let chunkUntil = (plan?.from ?? start) + AppConfig.drive3DChunkMeters
        var shapes: [MLNShape] = []
        for piece in LanePath.pieces(ribbon, from: start, to: end, chunk: chunk, chunkUntil: chunkUntil) {
            shapes.append(Self.polygon(piece.ring, kind: "body", piece: piece))
            shapes.append(Self.line(piece.centre, kind: "spine", piece: piece))
            shapes.append(Self.line(piece.left, kind: "edge", piece: piece))
            shapes.append(Self.line(piece.right, kind: "edge", piece: piece))
        }
        for jam in last.traffic where jam.to > start && jam.from < end {
            for piece in LanePath.pieces(ribbon, from: max(start, jam.from), to: min(end, jam.to),
                                         chunk: chunk, chunkUntil: chunkUntil) {
                let shape = Self.polygon(piece.ring, kind: "traffic", piece: piece)
                shape.attributes["level"] = jam.level
                shapes.append(shape)
            }
        }
        (style.source(withIdentifier: Self.sourceID) as? MLNShapeSource)?.shape = MLNShapeCollectionFeature(shapes: shapes)
        let points = chevrons.map { chevron -> MLNPointFeature in
            let point = MLNPointFeature()
            point.coordinate = chevron.coordinate
            point.attributes = ["a": chevron.along, "b": chevron.bearing, "bridge": chevron.bridge]
            return point
        }
        (style.source(withIdentifier: Self.chevronSourceID) as? MLNShapeSource)?.shape =
            MLNShapeCollectionFeature(shapes: points)
        // Хвост: маршрут от конца ленты (с заходом под неё) — линией.
        var tail: [CLLocationCoordinate2D] = []
        if let head = point(at: max(0, end - AppConfig.drive3DTailOverlapMeters), route: model.route) {
            tail = [head] + model.route[min(model.route.count - 1, index(at: end))...]
        }
        (style.source(withIdentifier: Self.tailSourceID) as? MLNShapeSource)?.shape = tail.count >= 2
            ? { var c = tail; return MLNPolylineFeature(coordinates: &c, count: UInt(c.count)) }() : nil
    }

    private func clearSources(in style: MLNStyle) {
        for id in [Self.sourceID, Self.chevronSourceID, Self.tailSourceID] {
            (style.source(withIdentifier: id) as? MLNShapeSource)?.shape = nil
        }
    }

    private static func polygon(_ ring: [CLLocationCoordinate2D], kind: String, piece: LanePath.Piece) -> MLNPolygonFeature {
        var points = ring
        let shape = MLNPolygonFeature(coordinates: &points, count: UInt(points.count))
        shape.attributes = ["k": kind, "bridge": piece.bridge, "t": piece.to]
        return shape
    }

    private static func line(_ coordinates: [CLLocationCoordinate2D], kind: String,
                             piece: LanePath.Piece) -> MLNPolylineFeature {
        var points = coordinates
        let shape = MLNPolylineFeature(coordinates: &points, count: UInt(points.count))
        shape.attributes = ["k": kind, "bridge": piece.bridge, "t": piece.to]
        return shape
    }

    /// Срез под машиной: куски, кончившиеся позади, гаснут фильтром.
    private func setCut(_ cut: Double, in style: MLNStyle) {
        os_signpost(.begin, log: performanceLog, name: "Лента 3D: срез")
        defer { os_signpost(.end, log: performanceLog, name: "Лента 3D: срез") }
        cutValue = cut
        counters.cuts += 1
        for role in Self.cutRoles {
            for bridge in [false, true] {
                (style.layer(withIdentifier: Self.layerID(role, bridge: bridge)) as? MLNVectorStyleLayer)?.predicate =
                    Self.filter(role, bridge: bridge, cut: cut)
            }
        }
    }

    private static func filter(_ kind: String, bridge: Bool, cut: Double) -> NSPredicate {
        NSPredicate(mglJSONObject: ["all", ["==", ["get", "k"], kind], ["==", ["get", "bridge"], bridge],
                                    [">", ["get", "t"], cut]])
    }

    /// Шевроны: видимость по скорости (гистерезис) и перегреву, фильтр
    /// «впереди среза» — когда срез проходит очередной шеврон.
    private func updateChevrons(surface: Drive3D.Surface, hot: Bool, cut: Double, speedKmh: Double, in style: MLNStyle) {
        let shown = Drive3D.chevrons(surface: surface, hot: hot) && chevronGate.update(speedKmh: speedKmh)
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

    private func logCountersIfDue() {
        let now = CACurrentMediaTime()
        guard now - counters.since >= 60 else { return }
        Log.route.info("Лента 3D за минуту: записей источника \(self.counters.writes, privacy: .public), перестановок среза \(self.counters.cuts, privacy: .public)")
        counters = (0, 0, now)
    }

    // MARK: - Слои

    private func install(in style: MLNStyle) {
        installed = true
        for id in [Self.sourceID, Self.chevronSourceID, Self.tailSourceID] where style.source(withIdentifier: id) == nil {
            style.addSource(MLNShapeSource(identifier: id, shape: nil))
        }
        guard let source = style.source(withIdentifier: Self.sourceID),
              let chevronSource = style.source(withIdentifier: Self.chevronSourceID),
              let tailSource = style.source(withIdentifier: Self.tailSourceID) else { return }
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
        // Хвост — там же, где линия маршрута: над её серединой, под стрелками.
        let fadeIn = NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"], 14.5, 0, 15.5, 1])
        var above: MLNStyleLayer? = style.layer(withIdentifier: "route-core")
        for (id, extra) in [(Self.tailLayers.casing, 3.0), (Self.tailLayers.body, 0.0)]
        where style.layer(withIdentifier: id) == nil {
            let layer = MLNLineStyleLayer(identifier: id, source: tailSource)
            layer.lineJoin = NSExpression(forConstantValue: "round")
            layer.lineCap = NSExpression(forConstantValue: "round")
            layer.lineWidth = NSExpression(mglJSONObject: EngineMapStyle.routeWidth(extra: extra))
            layer.lineOpacity = fadeIn
            layer.isVisible = false
            if let above { style.insertLayer(layer, above: above) } else { style.addLayer(layer) }
            above = layer
        }
    }

    private static func makeLayer(_ role: String, bridge: Bool, source: MLNSource) -> MLNStyleLayer {
        let id = layerID(role, bridge: bridge)
        // Лента сменяет линию маршрута на 14,5–15,5 (линия гаснет там же).
        let fadeIn = NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"], 14.5, 0, 15.5, 1])
        switch role {
        case "spine":
            let layer = MLNLineStyleLayer(identifier: id, source: source)
            layer.predicate = filter("spine", bridge: bridge, cut: -1)
            layer.lineJoin = NSExpression(forConstantValue: "round")
            layer.lineCap = NSExpression(forConstantValue: "round")
            // До z16,5 жила не тоньше линии маршрута на трассе (25.D), к z17,5
            // уходит под ленту в метрах.
            layer.lineWidth = NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"],
                                                           16.5, AppConfig.drive3DSpineFarPoints,
                                                           17.5, AppConfig.drive3DSpinePoints])
            layer.lineOpacity = fadeIn
            return layer
        case "body", "traffic":
            let layer = MLNFillStyleLayer(identifier: id, source: source)
            layer.predicate = filter(role, bridge: bridge, cut: -1)
            layer.fillAntialiased = NSExpression(forConstantValue: true)
            layer.fillOpacity = fadeIn
            return layer
        case "edge":
            let layer = MLNLineStyleLayer(identifier: id, source: source)
            layer.predicate = filter("edge", bridge: bridge, cut: -1)
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

    private func paint(daylight: Bool, routeDaylight: Bool, in style: MLNStyle) {
        paintedDaylight = daylight
        paintedRouteDaylight = routeDaylight
        let ribbon = Drive3D.ribbon(daylight: daylight)
        let fill = NSExpression(forConstantValue: Theme.rgb(ribbon.fill))
        let traffic = NSExpression(mglJSONObject: [
            "match", ["get", "level"], 3, RouteColors.pick(RouteColors.jam, daylight: daylight),
            RouteColors.pick(RouteColors.slow, daylight: daylight)])
        // Кант — 0,5–1,2 точки, проступает с 15,5-го (у горизонта два канта в
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
        (style.layer(withIdentifier: Self.tailLayers.casing) as? MLNLineStyleLayer)?.lineColor =
            NSExpression(forConstantValue: Theme.rgb(routeDaylight ? RouteColors.casing.day : RouteColors.casing.night))
        (style.layer(withIdentifier: Self.tailLayers.body) as? MLNLineStyleLayer)?.lineColor =
            NSExpression(forConstantValue: Theme.rgb(routeDaylight ? RouteColors.body.day : RouteColors.body.night))
    }

    /// Показать ленту (готова): её слои и хвост видны, линия маршрута гаснет
    /// с 15-го, стрелки на линии — тоже с 15,5-го (у ленты свои шевроны).
    /// Спрятать: всё как было.
    private func show(_ on: Bool, in style: MLNStyle) {
        shown = on
        for role in Self.roles where role != "chevrons" {
            for bridge in [false, true] { style.layer(withIdentifier: Self.layerID(role, bridge: bridge))?.isVisible = on }
        }
        style.layer(withIdentifier: Self.tailLayers.casing)?.isVisible = on
        style.layer(withIdentifier: Self.tailLayers.body)?.isVisible = on
        if !on {
            for bridge in [false, true] { style.layer(withIdentifier: Self.layerID("chevrons", bridge: bridge))?.isVisible = false }
        }
        chevronsShown = on ? chevronsShown : false
        if on {
            for id in Self.routeLines where originals[id] == nil {
                guard let layer = style.layer(withIdentifier: id) as? MLNLineStyleLayer else { continue }
                let was: NSExpression? = layer.lineOpacity
                originals[id] = .some(was)
                let constant = was?.expressionType == .constantValue ? was?.constantValue as? NSNumber : nil
                layer.lineOpacity = NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"],
                                                                 14.5, constant?.doubleValue ?? 1, 15.5, 0])
            }
            if arrowsMaxZoom == nil, let arrows = style.layer(withIdentifier: Self.routeArrows) {
                arrowsMaxZoom = arrows.maximumZoomLevel
                arrows.maximumZoomLevel = 15.5
            }
        } else {
            for (id, value) in originals {
                (style.layer(withIdentifier: id) as? MLNLineStyleLayer)?.lineOpacity =
                    value ?? NSExpression(forConstantValue: 1)
            }
            originals = [:]
            if let zoom = arrowsMaxZoom { style.layer(withIdentifier: Self.routeArrows)?.maximumZoomLevel = zoom }
            arrowsMaxZoom = nil
        }
    }

    private func deactivate(in style: MLNStyle) {
        active = false
        cancel()
        if shown { show(false, in: style) }
        for id in Self.layerIDs { style.layer(withIdentifier: id)?.isVisible = false }
        clearSources(in: style)
        ribbon = nil
        plan = nil
        routeRef = nil
        routeCount = -1
        cutValue = nil
        writtenTraffic = -1
        chevrons = []
        chevronThreshold = nil
        chevronsShown = nil
        knownRoads = [:]
        probedUntil = -.infinity
        arrowsCache = nil
        current = nil
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
