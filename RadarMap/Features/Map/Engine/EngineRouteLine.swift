//
//  EngineRouteLine.swift
//  RadarMap
//
//  Линия маршрута на карте движка: что лежит в её источниках и как режется
//  пройденное (27.A, 22.10; правила — RouteCut).
//
//  Источники пишутся редко: «traveled» (весь маршрут, бледно) и стрелки — раз
//  на маршрут; окно у машины, остаток линии, его пробки и манёвр — когда
//  окно переставляется вперёд (раз в ~150 м) или меняются пробки/манёвр.
//  Каждый кадр меняется только краска окна (line-gradient трёх-четырёх
//  слоёв) — её движок применяет в тот же кадр, без перетайливания.
//
//  Перестановка окна — без мигания. Новые данные источника доходят до
//  кадра не сразу (тайлы строятся на воркерах), а краска — сразу; поэтому:
//  сперва пишется новое окно, и краска режет по СТАРОМУ, пока движок не
//  покажет новое (запрос признаков источника видит поколение `g`); затем —
//  остаток линии за новым окном, и до его прихода окно красится только до
//  начала старого остатка. Ни разрыва линии, ни двойной полупрозрачной
//  середины на стыке.
//
//  Только картинка — ни оповещения, ни прогресс маршрута отсюда не читают.
//

#if canImport(MapLibre)
import MapKit
import MapLibre
import os

final class EngineRouteLine {

    private let performanceLog = OSLog(subsystem: "uz.radarmap", category: "MapPerformance")

    // MARK: Маршрут

    private var initialized = false
    private var routeObject: MKPolyline?
    private var index: EngineMapPresentation.RouteIndex?
    private var line: RouteCut.Line?
    private var arrows: [RouteCut.Arrow] = []
    /// Пробки на линии с местом в метрах (RouteTraffic.Piece.from/to).
    private var traffic: [RouteTraffic.Piece] = []
    private var trafficRevision = -1
    /// Поколение пробок — входит в ключ краски.
    private var trafficGeneration = 0
    private var maneuver: ClosedRange<Double>?
    private var task: Task<Void, Never>?
    private var generation = 0

    // MARK: Срез и окно

    private var tracker = RouteCut.Tracker()
    /// Прогресс маршрута на последнем фиксе (RouteService.progressAlong).
    private var fixAlong = 0.0
    /// Последняя точка значка: срез считается и без нового кадра (новые
    /// пробки, манёвр).
    private var lastPose: (coordinate: CLLocationCoordinate2D, course: Double, speed: Double)?
    private var colours = RouteCut.Colours(daylight: true)
    private var daylight: Bool?
    /// Окно, по которому режет краска (его данные уже показаны движком).
    private var window: RouteCut.Window?
    /// Откуда рисуется показанный остаток линии.
    private var farStart = 0.0
    /// Откуда записан остаток (может ещё не дойти до кадра).
    private var farWritten = 0.0
    private var handoff: Handoff?
    private var sourceGeneration = 0

    private struct Handoff {
        enum Phase { case near, far }
        var window: RouteCut.Window
        var generation: Int
        var phase: Phase
        var since: CFTimeInterval
    }

    // MARK: Краска

    private struct PaintKey: Equatable {
        var window: RouteCut.Window
        var drawEnd: Double
        var maneuver: ClosedRange<Double>?
        var traffic: Int
        var colours: RouteCut.Colours
    }

    private var paintKey: PaintKey?
    private var paintedCut = -Double.infinity
    private var painted = RouteCut.Paint.clear
    private var layers: (casing: MLNLineStyleLayer, body: MLNLineStyleLayer,
                         maneuver: MLNLineStyleLayer, core: MLNLineStyleLayer)?
    private var arrowLayer: MLNSymbolStyleLayer?
    private var arrowThreshold: Double?

    /// Что последним ушло в источник линии — пустое поверх пустого не пишется.
    private var lineKeys: [String: [Double]] = [:]

    /// Где сейчас нарисована граница пройденного (для замера 27.A).
    var paintedCutCoordinate: CLLocationCoordinate2D? {
        guard let line, paintedCut.isFinite else { return nil }
        return line.pose(at: paintedCut).coordinate
    }

    // MARK: - Жизненный цикл

    /// Новый стиль: источники пусты, слои новые — всё заново на ближайшем применении.
    func styleLoaded() {
        cancel()
        initialized = false
        lineKeys = [:]
        layers = nil
        arrowLayer = nil
        resetCut()
    }

    func cancel() {
        task?.cancel()
        generation += 1
    }

    func releaseMemory() {
        // Индекс и линия — несколько массивов на маршрут; нужны каждый кадр,
        // поэтому остаются. Освобождать нечего.
    }

    private func resetCut() {
        tracker.reset()
        window = nil
        handoff = nil
        farStart = 0
        farWritten = 0
        paintKey = nil
        paintedCut = -.infinity
        painted = .clear
        arrowThreshold = nil
    }

    // MARK: - Применение модели

    /// - Parameter routeDaylight: тема линии — в поездке ночная и днём (29.B,
    ///   DriveAsphalt.routeDaylight): светлое тело на тёмном асфальте поездки.
    func update(_ model: EngineMapView, routeDaylight: Bool, in view: MLNMapView) {
        if daylight != routeDaylight {
            daylight = routeDaylight
            colours = RouteCut.Colours(daylight: routeDaylight)
        }
        let fixMoved = fixAlong != model.routeProgress
        fixAlong = model.routeProgress
        if !initialized || routeObject !== model.routeObject {
            initialized = true
            routeObject = model.routeObject
            cancel()
            index = nil
            line = nil
            arrows = []
            traffic = []
            maneuver = nil
            trafficRevision = model.trafficRevision
            resetCut()
            // Прежний маршрут уходит целиком: источники с поколением
            // (окно, остаток) ключей не ведут, поэтому — без сравнения.
            lineKeys = [:]
            for name in ["traveled", "route", "maneuver", "route-traffic", EngineMapStyle.routeNearSource,
                         EngineMapStyle.routeArrowsSource] {
                setShape(nil, source: name, in: view)
                lineKeys[name] = [0]
            }
            applyPaint(.clear, in: view)
            guard model.route.count >= 2 else { return }
            prepare(model.route, snapshot: model.trafficSnapshot, reuse: nil, in: view)
            return
        }
        if model.trafficRevision != trafficRevision, let index, let line {
            trafficRevision = model.trafficRevision
            prepare(model.route, snapshot: model.trafficSnapshot, reuse: (index, line, arrows), in: view)
        }
        let range = EngineMapPresentation.maneuverRange(at: model.maneuverAlong, progress: model.routeProgress)
        if range != maneuver {
            maneuver = range
            if line != nil { writeFarManeuver(in: view) }
        }
        // Новый фикс: значок посчитан раньше (в начале применения), а предел
        // среза держится за прогресс фикса — пересчитать с новым.
        if line != nil, fixMoved || range != paintKey?.maneuver { frame(in: view) }
    }

    /// Индекс, линия среза, стрелки и пробки — вне главного потока.
    private func prepare(_ route: [CLLocationCoordinate2D], snapshot: TrafficSnapshot?,
                         reuse: (EngineMapPresentation.RouteIndex, RouteCut.Line, [RouteCut.Arrow])?,
                         in view: MLNMapView) {
        cancel()
        let token = generation
        task = Task { [weak self, weak view] in
            let frame = await EngineMapPresentation.prepareCut(route, reuse: reuse, traffic: snapshot)
            guard !Task.isCancelled, let self, let view, self.generation == token else { return }
            let fresh = self.line == nil
            self.index = frame.index
            self.line = frame.line
            self.arrows = frame.arrows
            self.traffic = frame.traffic
            self.trafficGeneration += 1
            if fresh {
                self.setLine(frame.index.coordinates, source: "traveled", in: view)
                self.writeArrows(in: view)
            } else {
                self.writeFarTraffic(in: view)
            }
            self.frame(in: view)
        }
    }

    // MARK: - Кадр

    /// Срез под значком. `pose` — предсказанная точка значка (MarkerPredictor),
    /// nil — прежняя (пересчёт без нового кадра).
    func frame(pose: CLLocationCoordinate2D? = nil, course: Double = -1, speedMps: Double = 0,
               in view: MLNMapView) {
        if let pose { lastPose = (pose, course, speedMps) }
        guard let line, let index, let pose = lastPose else { return }
        tracker.advance(pose: pose.coordinate, course: pose.course, fixAlong: fixAlong,
                        speedMps: pose.speed, line: line)
        let cut = tracker.cut
        if window == nil {
            // Первое окно маршрута — сразу: показывать прежнее нечего.
            guard let first = RouteCut.window(nil, cut: cut, routeLength: line.length) else { return }
            sourceGeneration += 1
            writeNear(first, index: index, in: view)
            writeFar(from: first.end, in: view)
            window = first
            farStart = first.end
        } else if handoff == nil, let want = RouteCut.window(window, cut: cut, routeLength: line.length),
                  want != window {
            sourceGeneration += 1
            writeNear(want, index: index, in: view)
            handoff = Handoff(window: want, generation: sourceGeneration, phase: .near,
                              since: CACurrentMediaTime())
        }
        advanceHandoff(in: view)
        paint(cut: cut, in: view)
        updateArrows(cut: cut, in: view)
    }

    /// Вид устоялся (жест, вписывание, новый масштаб ведения): стоя
    /// кадров среза нет, а ранг видимых стрелок мог смениться.
    func regionChanged(in view: MLNMapView) {
        guard line != nil else { return }
        updateArrows(cut: tracker.cut, in: view)
    }

    private func advanceHandoff(in view: MLNMapView) {
        guard var step = handoff else { return }
        let waited = CACurrentMediaTime() - step.since >= AppConfig.routeCutConfirmSeconds
        switch step.phase {
        case .near:
            guard waited || shown(EngineMapStyle.routeNearSource, generation: step.generation, in: view)
            else { return }
            window = step.window
            writeFar(from: step.window.end, in: view)
            step.phase = .far
            step.since = CACurrentMediaTime()
            handoff = step
        case .far:
            guard waited || shown("route", generation: step.generation, in: view) else { return }
            farStart = step.window.end
            handoff = nil
        }
    }

    /// Движок уже показывает данные этого поколения: все признаки источника
    /// в загруженных тайлах — нового поколения (тайлы, ещё не перестроенные,
    /// отдают старое).
    private func shown(_ source: String, generation: Int, in view: MLNMapView) -> Bool {
        guard let shape = view.style?.source(withIdentifier: source) as? MLNShapeSource else { return true }
        let features = shape.features(matching: nil)
        return !features.isEmpty && features.allSatisfy {
            ($0.attribute(forKey: "g") as? NSNumber)?.intValue == generation
        }
    }

    private func paint(cut: Double, in view: MLNMapView) {
        guard let window else { return }
        let key = PaintKey(window: window, drawEnd: farStart, maneuver: maneuver,
                           traffic: trafficGeneration, colours: colours)
        // Шаг перекраски — несколько точек экрана в метрах этого масштаба:
        // срез под значком (корпус — десятки точек), и смена краски чаще,
        // чем видно глазу, — только работа движку (три слоя пересобирают
        // свои отрисовки на каждой смене).
        let step = min(AppConfig.routeCutRepaintMaxMeters,
                       max(AppConfig.routeCutRepaintMeters,
                           view.metersPerPoint(atLatitude: view.centerCoordinate.latitude)
                               * AppConfig.routeCutRepaintPoints))
        guard key != paintKey || abs(cut - paintedCut) >= step else { return }
        paintKey = key
        paintedCut = cut
        applyPaint(RouteCut.paint(window: window, cut: cut, drawEnd: farStart, traffic: traffic,
                                  maneuver: maneuver, colours: colours), in: view)
    }

    private func applyPaint(_ paint: RouteCut.Paint, in view: MLNMapView) {
        guard let layers = nearLayers(in: view) else { return }
        os_signpost(.begin, log: performanceLog, name: "Route cut paint")
        defer { os_signpost(.end, log: performanceLog, name: "Route cut paint") }
        func set(_ layer: MLNLineStyleLayer, _ new: [RouteCut.Stop], _ old: [RouteCut.Stop]) {
            guard new != old else { return }
            layer.lineGradient = NSExpression(mglJSONObject: RouteCut.gradient(new))
        }
        let old = painted
        painted = paint
        set(layers.casing, paint.casing, old.casing)
        set(layers.body, paint.body, old.body)
        set(layers.maneuver, paint.maneuver, old.maneuver)
        set(layers.core, paint.core, old.core)
    }

    private func nearLayers(in view: MLNMapView)
        -> (casing: MLNLineStyleLayer, body: MLNLineStyleLayer, maneuver: MLNLineStyleLayer, core: MLNLineStyleLayer)? {
        if let layers { return layers }
        guard let style = view.style else { return nil }
        let ids = EngineMapStyle.routeNearLayers
        guard let casing = style.layer(withIdentifier: ids.casing) as? MLNLineStyleLayer,
              let body = style.layer(withIdentifier: ids.body) as? MLNLineStyleLayer,
              let maneuver = style.layer(withIdentifier: ids.maneuver) as? MLNLineStyleLayer,
              let core = style.layer(withIdentifier: ids.core) as? MLNLineStyleLayer else { return nil }
        // В стиле слои окна пусты (прозрачны): то, что считаем
        // нарисованным, должно совпадать с ними.
        painted = .clear
        layers = (casing, body, maneuver, core)
        return layers
    }

    /// Стрелки позади среза скрыты фильтром; порог меняется, когда срез
    /// проходит видимую на этом масштабе стрелку (она под значком).
    private func updateArrows(cut: Double, in view: MLNMapView) {
        guard !arrows.isEmpty else { return }
        let threshold = RouteCut.arrowThreshold(arrows, cut: cut,
                                                minRank: RouteCut.arrowMinRank(zoom: view.zoomLevel))
        guard threshold != arrowThreshold else { return }
        if arrowLayer == nil {
            arrowLayer = view.style?.layer(withIdentifier: "route-arrows") as? MLNSymbolStyleLayer
        }
        guard let arrowLayer else { return }
        arrowThreshold = threshold
        arrowLayer.predicate = NSPredicate(mglJSONObject: [">=", ["get", "a"], threshold])
    }

    // MARK: - Источники

    private func writeNear(_ window: RouteCut.Window, index: EngineMapPresentation.RouteIndex,
                           in view: MLNMapView) {
        var coordinates = index.slice(from: window.start, to: window.end)
        guard coordinates.count >= 2 else { return setShape(nil, source: EngineMapStyle.routeNearSource, in: view) }
        let feature = MLNPolylineFeature(coordinates: &coordinates, count: UInt(coordinates.count))
        feature.attributes = ["g": sourceGeneration]
        setShape(feature, source: EngineMapStyle.routeNearSource, in: view)
    }

    /// Остаток линии за окном, его пробки и манёвр.
    private func writeFar(from start: Double, in view: MLNMapView) {
        guard let index else { return }
        farWritten = start
        var coordinates = index.slice(from: start, to: index.length)
        if coordinates.count >= 2 {
            let feature = MLNPolylineFeature(coordinates: &coordinates, count: UInt(coordinates.count))
            feature.attributes = ["g": sourceGeneration]
            setShape(feature, source: "route", in: view)
        } else {
            setShape(nil, source: "route", in: view)
        }
        lineKeys["route"] = nil
        writeFarTraffic(in: view)
        writeFarManeuver(in: view)
    }

    private func writeFarTraffic(in view: MLNMapView) {
        guard let index else { return }
        let start = farWritten
        let lines = traffic.compactMap { piece -> MLNPolylineFeature? in
            guard piece.to > start else { return nil }
            var coordinates = index.slice(from: max(piece.from, start), to: piece.to)
            guard coordinates.count >= 2 else { return nil }
            let line = MLNPolylineFeature(coordinates: &coordinates, count: UInt(coordinates.count))
            line.attributes = ["level": piece.level]
            return line
        }
        setShape(lines.isEmpty ? nil : MLNShapeCollectionFeature(shapes: lines), source: "route-traffic", in: view)
    }

    private func writeFarManeuver(in view: MLNMapView) {
        guard let index else { return }
        if let maneuver, maneuver.upperBound > farWritten {
            setLine(index.slice(from: max(maneuver.lowerBound, farWritten), to: maneuver.upperBound),
                    source: "maneuver", in: view)
        } else {
            setLine([], source: "maneuver", in: view)
        }
    }

    /// Стрелки — точки с местом на линии (a), рангом (r) и поворотом картинки (b).
    private func writeArrows(in view: MLNMapView) {
        let points = arrows.map { arrow -> MLNPointFeature in
            let point = MLNPointFeature()
            point.coordinate = arrow.coordinate
            point.attributes = ["a": arrow.along, "r": arrow.rank, "b": arrow.bearing - 90]
            return point
        }
        arrowThreshold = nil
        setShape(points.isEmpty ? nil : MLNShapeCollectionFeature(shapes: points),
                 source: EngineMapStyle.routeArrowsSource, in: view)
    }

    private func setShape(_ shape: MLNShape?, source name: String, in view: MLNMapView) {
        guard let source = view.style?.source(withIdentifier: name) as? MLNShapeSource else { return }
        os_signpost(.begin, log: performanceLog, name: "Route source")
        defer { os_signpost(.end, log: performanceLog, name: "Route source") }
        source.shape = shape
    }

    /// Линия без поколения (бледная, манёвр, очистка): пустое поверх пустого
    /// и та же линия заново не пишутся — запись будит перетайливание.
    private func setLine(_ coordinates: [CLLocationCoordinate2D], source name: String, in view: MLNMapView) {
        guard view.style?.source(withIdentifier: name) is MLNShapeSource else { return }
        let key: [Double] = coordinates.count < 2 ? [0] : [
            Double(coordinates.count),
            coordinates[0].latitude, coordinates[0].longitude,
            coordinates[coordinates.count - 1].latitude, coordinates[coordinates.count - 1].longitude]
        guard lineKeys[name] != key else { return }
        lineKeys[name] = key
        if coordinates.count < 2 { return setShape(nil, source: name, in: view) }
        setShape(coordinates.withUnsafeBufferPointer {
            MLNPolylineFeature(coordinates: $0.baseAddress!, count: UInt($0.count))
        }, source: name, in: view)
    }
}
#endif
