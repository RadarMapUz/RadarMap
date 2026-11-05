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
//  • срез — не чаще полсекунды пути на телефоне и секунды в машине и на
//    плитке (Drive3D.Budget): смена фильтра — перераскладка тайлов источника.
//  Расчёт, кеш дорог и готовые признаки — общие для всех карт процесса
//  (EngineRibbonShare, 48): плитка берёт ленту телефона или экрана машины, а
//  не щупает тайлы второй раз. Расчёты, взятые готовыми ленты, записи
//  источника и перестановки среза считаются и раз в минуту уходят в журнал с
//  меткой карты; вокруг них — signpost «Лента 3D».
//
//  Только картинка: ни голос, ни оповещения, ни прогресс маршрута отсюда не
//  читают.
//

#if canImport(MapLibre)
import MapKit
import MapLibre
import os
import UIKit

/// Общая лента маршрута для всех карт процесса (48): расчёт, прощупанные
/// ленты тайла и готовые признаки источника живут здесь, а не в карте.
/// Телефон, экран машины и плитка ведут один маршрут из одной позиции — две
/// карты считали бы одно и то же дважды и щупали бы тайлы на главном потоке
/// дважды. Считает одна карта (Drive3D.computes: плитка уступает телефону и
/// экрану машины), остальные берут её версию. Карта, сменившая другую
/// (плитка ↔ экран машины, возврат из музыки), получает ленту и кеш дорог
/// сразу, без нового прощупывания.
@MainActor
final class EngineRibbonShare {
    static let shared = EngineRibbonShare()

    /// Готовые признаки источника: одна сборка на версию ленты, пробки и начало.
    struct Built {
        let version: Int
        let traffic: [RouteTraffic.Piece]
        let start: Double
        let body: MLNShapeCollectionFeature
        let chevrons: MLNShapeCollectionFeature
        let tail: MLNPolylineFeature?
    }

    final class Entry {
        nonisolated deinit {}
        /// Номер маршрута для Drive3D.Plan (растёт на каждый новый).
        let id: Int
        let route: MKPolyline?
        let count: Int
        let first: CLLocationCoordinate2D?
        let last: CLLocationCoordinate2D?
        let cumulative: [Double]
        var knownRoads: [String: LanePath.Road] = [:]
        var probedUntil = -Double.infinity
        var arrowsCache: (along: Double, arrows: [LanePath.Arrow])?
        var plan: Drive3D.Plan?
        var ribbon: LanePath.Ribbon?
        /// Манёвр и сужение ленты, что лежит в `ribbon`.
        var drawnKey: (maneuver: Double?, narrowing: Bool)?
        var chevrons: [LanePath.Chevron] = []
        /// Растёт на каждой новой готовой ленте: карта пишет источник по смене.
        var version = 0
        /// Какая карта посчитала эту версию (взято готовым — счётчик журнала).
        var versionOwner: ObjectIdentifier?
        var attemptAt: CFTimeInterval = -.infinity
        /// Чей расчёт в полёте и с какого момента: вторая карта ждёт его.
        var computing: (owner: ObjectIdentifier, since: CFTimeInterval)?
        /// Когда карта телефона или экрана машины последний раз применялась.
        var primarySeenAt: CFTimeInterval = -.infinity
        var users: Set<ObjectIdentifier> = []
        /// Когда ушла последняя карта (nil — карты есть): запись живёт ещё
        /// drive3DShareKeepSeconds — смена плитки и экрана машины сносит
        /// прежнюю карту раньше, чем новая загрузит стиль и возьмёт ленту.
        var orphanedAt: CFTimeInterval?
        var built: Built?

        init(id: Int, route: MKPolyline?, points: [CLLocationCoordinate2D]) {
            self.id = id
            self.route = route
            count = points.count
            first = points.first
            last = points.last
            cumulative = RouteService.cumulative(of: points.map(MKMapPoint.init))
        }

        func matches(route: MKPolyline?, points: [CLLocationCoordinate2D]) -> Bool {
            if let route { return self.route === route }
            guard self.route == nil, count == points.count, let a = first, let b = points.first,
                  let c = last, let d = points.last else { return false }
            return a.latitude == b.latitude && a.longitude == b.longitude
                && c.latitude == d.latitude && c.longitude == d.longitude
        }

        func isComputing(now: CFTimeInterval, except owner: ObjectIdentifier) -> Bool {
            guard let computing, computing.owner != owner else { return false }
            return now - computing.since < AppConfig.drive3DShareStaleSeconds
        }
    }

    private var entries: [Entry] = []
    private var nextID = 0

    /// Запись маршрута для карты `user`: найденная или новая. Держим не больше
    /// двух маршрутов (смена линии доходит до двух карт не в один кадр).
    func entry(route: MKPolyline?, points: [CLLocationCoordinate2D], user: ObjectIdentifier,
               now: CFTimeInterval = CACurrentMediaTime()) -> Entry {
        entries.removeAll { entry in
            entry.orphanedAt.map { now - $0 >= AppConfig.drive3DShareKeepSeconds } ?? false
        }
        let found = entries.first { $0.matches(route: route, points: points) }
        let entry = found ?? {
            // Новый маршрут: брошенные записи прежнего больше не нужны.
            entries.removeAll { $0.users.isEmpty }
            nextID &+= 1
            let made = Entry(id: nextID, route: route, points: points)
            entries.append(made)
            if entries.count > 2 { entries.removeFirst(entries.count - 2) }
            return made
        }()
        entry.users.insert(user)
        entry.orphanedAt = nil
        return entry
    }

    /// Карта ушла с маршрута. Запись без карт не удаляется сразу, а живёт
    /// drive3DShareKeepSeconds (или до нового маршрута): карта, которая придёт
    /// на смену, возьмёт ленту и кеш дорог готовыми.
    func leave(_ entry: Entry, user: ObjectIdentifier, now: CFTimeInterval = CACurrentMediaTime()) {
        entry.users.remove(user)
        if entry.computing?.owner == user { entry.computing = nil }
        if entry.users.isEmpty { entry.orphanedAt = now }
    }
}

@MainActor
final class EngineDriveRibbon {
    nonisolated deinit {}

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
    private let share = EngineRibbonShare.shared
    private var me: ObjectIdentifier { ObjectIdentifier(self) }

    private var installed = false
    private var active = false
    /// Лента показана, линия маршрута с 15-го погашена.
    private var shown = false
    private var paintedDaylight: Bool?
    private var paintedRouteDaylight: Bool?
    private var originals: [String: NSExpression?] = [:]
    private var arrowsMaxZoom: Float?

    /// Общая запись маршрута (EngineRibbonShare) — расчёт, кеш дорог, лента.
    private var entry: EngineRibbonShare.Entry?
    private var task: Task<Void, Never>?
    private var generation = 0

    /// Срез, по которому стоят фильтры слоёв (nil — ещё не ставили).
    private var cutValue: Double?
    /// Какая версия общей ленты и какие пробки лежат в источнике этой карты.
    private var writtenVersion = -1
    private var writtenTraffic = -1
    private var lastTrafficVersion = 0
    private var chevronThreshold: Double?
    private var chevronGate = Drive3D.ChevronGate()
    private var chevronsShown: Bool?

    /// Последний срез и пробки — готовый расчёт ложится сразу.
    private var last: (cut: Double, traffic: [RouteTraffic.Piece]) = (0, [])
    /// За минуту: свои расчёты, чужие ленты, взятые готовыми, записи источника
    /// (и сколько из них — готовыми признаками), перестановки среза.
    private var counters = (computes: 0, adopted: 0, writes: 0, reused: 0, cuts: 0, since: CACurrentMediaTime())
    private var tag = "телефон"

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
        // Расчёт годен и для нового стиля — источники пустые, пишем заново.
        writtenVersion = -1
        writtenTraffic = -1
        chevronThreshold = nil
        chevronsShown = nil
    }

    func cancel() {
        task?.cancel()
        generation += 1
        if let entry, entry.computing?.owner == me { entry.computing = nil }
    }

    /// Карту сносят: расчёт отменён, общая запись маршрута — без неё (кеш
    /// дорог отпускается, когда карт на маршруте не осталось).
    func release() {
        cancel()
        if let entry { share.leave(entry, user: me) }
        entry = nil
        current = nil
    }

    /// - Parameters:
    ///   - probeAllowed: можно щупать тайлы (Drive3D.canCompute).
    ///   - cut: где нарисована граница пройденного (EngineRouteLine), м.
    ///   - traffic: пробки на линии с местом в метрах и их поколение.
    func update(_ model: EngineMapView, on: Bool, probeAllowed: Bool, cut: Double?,
                traffic: [RouteTraffic.Piece], trafficVersion: Int, routeDaylight: Bool, in view: MLNMapView) {
        guard let style = view.style else { return }
        guard on, let surface = model.drive3D, model.drive3DRibbon, model.route.count >= 2 else {
            if active { deactivate(in: style) }
            return
        }
        tag = model.healthTag ?? "телефон"
        if !installed { install(in: style) }
        active = true
        if paintedDaylight != model.daylight || paintedRouteDaylight != routeDaylight {
            paint(daylight: model.daylight, routeDaylight: routeDaylight, in: style)
        }
        if let entry, !entry.matches(route: model.routeObject, points: model.route) {
            routeChanged(in: style)
        }
        let entry = self.entry ?? share.entry(route: model.routeObject, points: model.route, user: me)
        self.entry = entry
        let now = CACurrentMediaTime()
        // Уступать плитке есть кому, только если эта карта вправе считать:
        // телефон в осмотре ленту не считает, и плитка без него осталась бы
        // за концом старой ленты без ленты и без линии маршрута.
        if surface != .dashboard, probeAllowed { entry.primarySeenAt = now }
        let hot = model.performance != .full
        let budget = Drive3D.budget(surface: surface)
        let car = max(0, cut ?? model.routeProgress)
        let speedMps = max(0, model.markerMotion?.speedMps ?? 0)
        let window = LaneFocus.window(speedKmh: speedMps * 3.6)
        let narrowing = Drive3D.narrows(surface: surface, hot: hot)
        last = (car, traffic)
        lastTrafficVersion = trafficVersion
        current = model
        if probeAllowed, Drive3D.computes(surface: surface, sincePrimary: now - entry.primarySeenAt),
           !entry.isComputing(now: now, except: me),
           Drive3D.needsRecompute(last: entry.plan, route: entry.id, car: car, maneuver: model.maneuverAlong,
                                  window: window, narrowing: narrowing, sinceAttempt: now - entry.attemptAt,
                                  budget: budget) {
            compute(model, entry: entry, car: car, speedMps: speedMps, window: window, narrowing: narrowing,
                    budget: budget, in: view)
        }
        let ready = entry.ribbon?.isReady == true
        if ready != shown { show(ready, in: style) }
        guard ready, let ribbon = entry.ribbon else { return }
        if writtenVersion != entry.version || writtenTraffic != trafficVersion {
            if writtenVersion != entry.version, entry.versionOwner != me { counters.adopted += 1 }
            writeSource(ribbon, entry: entry, model: model, trafficVersion: trafficVersion, in: style)
            chevronThreshold = nil
            setCut(car, in: style)
        }
        if Drive3D.cutDue(last: cutValue, now: car,
                          step: Drive3D.cutStep(speedMps: speedMps, hot: hot, seconds: budget.cutSeconds)) {
            setCut(car, in: style)
        }
        updateChevrons(surface: surface, hot: hot, cut: car, speedKmh: speedMps * 3.6, in: style)
        logCountersIfDue()
    }

    /// Карта ушла на другой маршрут: свои источники — пустые, общая запись
    /// прежнего маршрута — без этой карты.
    private func routeChanged(in style: MLNStyle) {
        cancel()
        if let entry { share.leave(entry, user: me) }
        entry = nil
        writtenVersion = -1
        writtenTraffic = -1
        cutValue = nil
        chevronThreshold = nil
        clearSources(in: style)
        if shown { show(false, in: style) }
    }

    // MARK: - Расчёт

    private func compute(_ model: EngineMapView, entry: EngineRibbonShare.Entry, car: Double, speedMps: Double,
                         window: Double, narrowing: Bool, budget: Drive3D.Budget, in view: MLNMapView) {
        let startedAt = CACurrentMediaTime()
        entry.attemptAt = startedAt
        counters.computes += 1
        let from = max(0, car - 20)
        let maneuver = Self.maneuver(model)
        let old = entry.plan
        var next = Drive3D.Plan(route: entry.id, from: car, maneuver: model.maneuverAlong, narrowing: narrowing,
                                inWindow: Drive3D.inWindow(car: car, maneuver: model.maneuverAlong, window: window),
                                complete: false, verifiedEnd: old?.verifiedEnd)
        if let old, old.route == next.route {
            if !old.complete || old.stalledEnd != nil { next.attempts = old.attempts + 1 }
            // Начало перестроения — из расчёта на входе в окно, до манёвра.
            if old.maneuver == next.maneuver { next.shiftStart = old.shiftStart }
        }
        entry.plan = next
        // Тот же манёвр и сужение, что у ленты на карте: не выросший конец —
        // застой (тоннель, пробел, финиш); иначе геометрия другая и кладётся.
        let previousEnd = entry.drawnKey.map { $0.maneuver == next.maneuver && $0.narrowing == narrowing } == true
            ? entry.ribbon?.verifiedEnd : nil
        os_signpost(.begin, log: performanceLog, name: "Лента 3D: пробы")
        let roads = probeRoads(entry: entry, route: model.route, car: car, from: from,
                               length: AppConfig.drive3DAheadMeters, limit: budget.probeLimit, in: view)
        let arrows = narrowing
            ? maneuver.map { probeArrows(entry: entry, near: $0.along, model: model, in: view) } ?? [] : []
        os_signpost(.end, log: performanceLog, name: "Лента 3D: пробы")
        let probeMs = Int((CACurrentMediaTime() - startedAt) * 1000)
        var input = LanePath.Input(route: model.route, from: from, length: AppConfig.drive3DAheadMeters, car: car,
                                   speedMps: speedMps, window: window, roads: roads, arrows: arrows,
                                   maneuver: maneuver, narrowing: narrowing, cumulative: entry.cumulative)
        if next.inWindow { input.shiftStart = next.shiftStart }
        cancel()
        entry.computing = (me, startedAt)
        let generation = generation
        let started = CACurrentMediaTime()
        let tailMargin = budget.tailMarginMeters
        let tag = tag
        task = Task { [weak self, weak view, entry] in
            let result = await Self.build(input)
            guard let self, generation == self.generation else { return }
            if entry.computing?.owner == self.me { entry.computing = nil }
            guard self.entry === entry, var plan = entry.plan, plan.route == next.route else { return }
            let settled = Drive3D.settle(&plan, ready: result.isReady, end: result.verifiedEnd,
                                         previousEnd: previousEnd, car: car, tailMargin: tailMargin)
            if plan.inWindow, plan.shiftStart == nil { plan.shiftStart = result.shiftStart }
            entry.plan = plan
            Log.route.info("Лента 3D (\(tag, privacy: .public)): \(roads.count, privacy: .public) лент, \(arrows.count, privacy: .public) стрелок, совпало \(Int(result.matchedShare * 100), privacy: .public) %, прощупано \(Int(result.verifiedEnd - car), privacy: .public) м, сужение \(String(describing: result.narrowing), privacy: .public), пробы \(probeMs, privacy: .public) мс на главном, расчёт \(Int((CACurrentMediaTime() - started) * 1000), privacy: .public) мс")
            // Неготовый (карта без лент тайла) или не выросший (тоннель, финиш)
            // расчёт не сменяет ленту на карте и источник не трогает.
            guard settled == .write else { return }
            entry.ribbon = result
            entry.drawnKey = (next.maneuver, narrowing)
            entry.chevrons = LanePath.chevrons(result, spacing: AppConfig.drive3DChevronSpacing)
                .filter { $0.along <= result.verifiedEnd }
            entry.version &+= 1
            entry.versionOwner = self.me
            entry.built = nil
            guard let view, let style = view.style else { return }
            self.chevronThreshold = nil
            if let current = self.current {
                self.writeSource(result, entry: entry, model: current, trafficVersion: self.lastTrafficVersion,
                                 in: style)
            }
            self.setCut(self.last.cut, in: style)
            if !self.shown { self.show(true, in: style) }
        }
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
    private static func point(at along: Double, route: [CLLocationCoordinate2D],
                              cumulative: [Double]) -> CLLocationCoordinate2D? {
        guard cumulative.count == route.count, let k = cumulative.firstIndex(where: { $0 >= along }) else { return nil }
        guard k > 0 else { return route[0] }
        let t = (along - cumulative[k - 1]) / max(0.01, cumulative[k] - cumulative[k - 1])
        let a = route[k - 1], b = route[k]
        return CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                      longitude: a.longitude + (b.longitude - a.longitude) * t)
    }

    private static func index(at along: Double, cumulative: [Double]) -> Int {
        cumulative.firstIndex { $0 >= along } ?? max(0, cumulative.count - 1)
    }

    /// Ленты дорог вдоль маршрута на экране: квадрат пробы через каждые
    /// drive3DProbeStepMeters, не дальше уже прощупанного минус 100 м; что
    /// нащупали раньше, остаётся (общий кеш маршрута — им пользуются все
    /// карты). За краем экрана данных нет — лента там кончается, дальше
    /// линия (verifiedEnd).
    private func probeRoads(entry: EngineRibbonShare.Entry, route: [CLLocationCoordinate2D], car: Double,
                            from: Double, length: Double, limit: Int, in view: MLNMapView) -> [LanePath.Road] {
        pruneRoads(entry: entry, route: route, car: car)
        let bounds = view.bounds
        let half = AppConfig.drive3DProbePoints / 2
        var along = max(from, entry.probedUntil - 100)
        var probes = 0
        while along <= from + length, probes < limit,
              let coordinate = Self.point(at: along, route: route, cumulative: entry.cumulative) {
            let here = along
            along += AppConfig.drive3DProbeStepMeters
            let p = view.convert(coordinate, toPointTo: view)
            guard bounds.contains(p) else { continue }
            probes += 1
            entry.probedUntil = max(entry.probedUntil, here)
            let rect = CGRect(x: p.x - half, y: p.y - half, width: 2 * half, height: 2 * half)
            for feature in view.visibleFeatures(in: rect, styleLayerIdentifiers: Self.roadLayers) {
                for line in Self.lines(of: feature) where line.count >= 2 {
                    let first = line[0], end = line[line.count - 1]
                    let key = String(format: "%.6f,%.6f,%.6f,%.6f,%ld", first.latitude, first.longitude,
                                     end.latitude, end.longitude, line.count)
                    guard entry.knownRoads[key] == nil else { continue }
                    let width = (feature.attribute(forKey: "width") as? NSNumber)?.doubleValue ?? 0
                    guard width > 0 else { continue }
                    entry.knownRoads[key] = LanePath.Road(points: line, width: width,
                                                          oneway: Self.flag(feature, "oneway"),
                                                          bridge: Self.flag(feature, "bridge"),
                                                          inner: Self.flag(feature, "inner"),
                                                          stub: Self.flag(feature, "stub"))
                }
            }
        }
        return Array(entry.knownRoads.values)
    }

    /// Ленты позади машины дальше drive3DRoadCacheBehindMeters и дальше
    /// радиуса кеша уходят: индекс LanePath строится по тому, что впереди.
    private func pruneRoads(entry: EngineRibbonShare.Entry, route: [CLLocationCoordinate2D], car: Double) {
        guard !entry.knownRoads.isEmpty,
              let here = Self.point(at: car, route: route, cumulative: entry.cumulative),
              let ahead = Self.point(at: car + 30, route: route, cumulative: entry.cumulative) else { return }
        let frame = LanePath.Frame(origin: here)
        let heading = frame.point(ahead).unit
        let behind = AppConfig.drive3DRoadCacheBehindMeters, radius = AppConfig.drive3DRoadCacheRadiusMeters
        entry.knownRoads = entry.knownRoads.filter { _, road in
            road.points.contains { c in
                let p = frame.point(c)
                return p.length <= radius && p.dot(heading) >= -behind
            }
        }
    }

    /// Стрелки полос у манёвра — один запрос на манёвр: с 17-го — нарисованные
    /// у точки манёвра, раньше — из загруженных тайлов в окрестности. Чья
    /// стрелка — по полосам манёвра (LaneFocus), без них — по набору поворотов.
    private func probeArrows(entry: EngineRibbonShare.Entry, near along: Double, model: EngineMapView,
                             in view: MLNMapView) -> [LanePath.Arrow] {
        if let cache = entry.arrowsCache, cache.along == along, !cache.arrows.isEmpty { return cache.arrows }
        guard let centre = Self.point(at: along, route: model.route, cumulative: entry.cumulative) else { return [] }
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
        entry.arrowsCache = (along, out)
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
    /// фильтром), пробки на ней, шевроны и хвост линии за ней. Признаки
    /// собираются один раз на версию ленты и пробки (EngineRibbonShare.Built):
    /// вторая карта кладёт в свой источник те же объекты.
    private func writeSource(_ ribbon: LanePath.Ribbon, entry: EngineRibbonShare.Entry, model: EngineMapView,
                             trafficVersion: Int, in style: MLNStyle) {
        os_signpost(.begin, log: performanceLog, name: "Лента 3D: запись")
        defer { os_signpost(.end, log: performanceLog, name: "Лента 3D: запись") }
        counters.writes += 1
        writtenVersion = entry.version
        writtenTraffic = trafficVersion
        let start = max(ribbon.along.first ?? 0, last.cut - 20)
        let built: EngineRibbonShare.Built
        if let cached = entry.built, cached.version == entry.version, cached.traffic == last.traffic,
           cached.start <= start, start - cached.start <= AppConfig.drive3DShareReuseBehindMeters {
            built = cached
            counters.reused += 1
        } else {
            built = Self.build(ribbon, entry: entry, start: start, traffic: last.traffic, route: model.route)
            entry.built = built
        }
        (style.source(withIdentifier: Self.sourceID) as? MLNShapeSource)?.shape = built.body
        (style.source(withIdentifier: Self.chevronSourceID) as? MLNShapeSource)?.shape = built.chevrons
        (style.source(withIdentifier: Self.tailSourceID) as? MLNShapeSource)?.shape = built.tail
    }

    private static func build(_ ribbon: LanePath.Ribbon, entry: EngineRibbonShare.Entry, start: Double,
                              traffic: [RouteTraffic.Piece], route: [CLLocationCoordinate2D]) -> EngineRibbonShare.Built {
        let end = ribbon.verifiedEnd
        let chunk = AppConfig.drive3DCutStepMeters
        let chunkUntil = (entry.plan?.from ?? start) + AppConfig.drive3DChunkMeters
        var shapes: [MLNShape] = []
        for piece in LanePath.pieces(ribbon, from: start, to: end, chunk: chunk, chunkUntil: chunkUntil) {
            shapes.append(polygon(piece.ring, kind: "body", piece: piece))
            shapes.append(line(piece.centre, kind: "spine", piece: piece))
            shapes.append(line(piece.left, kind: "edge", piece: piece))
            shapes.append(line(piece.right, kind: "edge", piece: piece))
        }
        for jam in traffic where jam.to > start && jam.from < end {
            for piece in LanePath.pieces(ribbon, from: max(start, jam.from), to: min(end, jam.to),
                                         chunk: chunk, chunkUntil: chunkUntil) {
                let shape = polygon(piece.ring, kind: "traffic", piece: piece)
                shape.attributes["level"] = jam.level
                shapes.append(shape)
            }
        }
        let points = entry.chevrons.map { chevron -> MLNPointFeature in
            let point = MLNPointFeature()
            point.coordinate = chevron.coordinate
            point.attributes = ["a": chevron.along, "b": chevron.bearing, "bridge": chevron.bridge]
            return point
        }
        // Хвост: маршрут от конца ленты (с заходом под неё) — линией.
        var tail: [CLLocationCoordinate2D] = []
        if let head = point(at: max(0, end - AppConfig.drive3DTailOverlapMeters), route: route,
                            cumulative: entry.cumulative) {
            tail = [head] + route[min(route.count - 1, index(at: end, cumulative: entry.cumulative))...]
        }
        let tailFeature: MLNPolylineFeature? = tail.count >= 2
            ? { var c = tail; return MLNPolylineFeature(coordinates: &c, count: UInt(c.count)) }() : nil
        return EngineRibbonShare.Built(version: entry.version, traffic: traffic, start: start,
                                       body: MLNShapeCollectionFeature(shapes: shapes),
                                       chevrons: MLNShapeCollectionFeature(shapes: points), tail: tailFeature)
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
        let threshold = entry?.chevrons.first { $0.along > cut + 10 }?.along ?? .infinity
        guard threshold != chevronThreshold else { return }
        chevronThreshold = threshold
        for bridge in [false, true] {
            (style.layer(withIdentifier: Self.layerID("chevrons", bridge: bridge)) as? MLNSymbolStyleLayer)?.predicate =
                NSPredicate(mglJSONObject: ["all", ["==", ["get", "bridge"], bridge],
                                            [">=", ["get", "a"], threshold.isFinite ? threshold : 1e9]])
        }
    }

    /// Раз в минуту: сколько эта карта считала сама, сколько лент взяла
    /// готовыми у другой карты, сколько раз писала источник (из них — готовыми
    /// признаками) и переставляла срез. Владелец сравнивает строки «машина» и
    /// «плитка» на устройстве.
    private func logCountersIfDue() {
        let now = CACurrentMediaTime()
        guard now - counters.since >= 60 else { return }
        Log.route.info("Лента 3D (\(self.tag, privacy: .public)) за минуту: расчётов \(self.counters.computes, privacy: .public), взято готовых \(self.counters.adopted, privacy: .public), записей источника \(self.counters.writes, privacy: .public) (готовыми признаками \(self.counters.reused, privacy: .public)), перестановок среза \(self.counters.cuts, privacy: .public)")
        counters = (0, 0, 0, 0, 0, now)
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
        if let entry { share.leave(entry, user: me) }
        entry = nil
        cutValue = nil
        writtenVersion = -1
        writtenTraffic = -1
        chevronThreshold = nil
        chevronsShown = nil
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
