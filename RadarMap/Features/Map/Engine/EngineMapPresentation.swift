import MapKit
import os

/// Геометрия отображения: не участвует в оповещениях и определении полосы машины.
nonisolated enum EngineMapPresentation {
    /// Индекс строится один раз на поколение маршрута, не на каждом GPS-тике.
    struct RouteIndex: Sendable {
        let coordinates: [CLLocationCoordinate2D]
        let cumulative: [Double]

        init(_ coordinates: [CLLocationCoordinate2D]) {
            self.coordinates = coordinates
            var distances = [Double]()
            distances.reserveCapacity(coordinates.count)
            var sum = 0.0
            for i in coordinates.indices {
                if i > 0 { sum += MKMapPoint(coordinates[i - 1]).distance(to: MKMapPoint(coordinates[i])) }
                distances.append(sum)
            }
            cumulative = distances
        }

        var length: Double { cumulative.last ?? 0 }

        func slice(from start: Double, to end: Double) -> [CLLocationCoordinate2D] {
            guard coordinates.count > 1, start.isFinite, end.isFinite else { return [] }
            let low = max(0, start), high = min(length, end)
            guard high > low else { return [] }
            func locate(_ distance: Double) -> (Int, CLLocationCoordinate2D) {
                var a = 1, b = cumulative.count - 1
                while a < b {
                    let mid = (a + b) / 2
                    if cumulative[mid] < distance { a = mid + 1 } else { b = mid }
                }
                let before = MKMapPoint(coordinates[a - 1]), after = MKMapPoint(coordinates[a])
                let span = cumulative[a] - cumulative[a - 1]
                let t = span > 0 ? (distance - cumulative[a - 1]) / span : 0
                return (a, MKMapPoint(x: before.x + (after.x - before.x) * t,
                                     y: before.y + (after.y - before.y) * t).coordinate)
            }
            let (first, a) = locate(low), (last, b) = locate(high)
            return [a] + Array(coordinates[first..<last]) + [b]
        }
    }

    /// Всё, что строится один раз на маршрут (или на новый набор пробок) —
    /// вне главного потока: индекс для нарезки, линия среза (RouteCut),
    /// стрелки и пробки на линии с местом в метрах.
    struct CutFrame: Sendable {
        let index: RouteIndex
        let line: RouteCut.Line
        let arrows: [RouteCut.Arrow]
        /// Пробки на линии (RouteTraffic): пусто — данных нет или свободно.
        let traffic: [RouteTraffic.Piece]
    }

    /// `index`/`line` прошлого раза — тот же маршрут, новый набор пробок:
    /// пересчитываются только пробки.
    @concurrent static func prepareCut(_ coordinates: [CLLocationCoordinate2D],
                                       reuse: (RouteIndex, RouteCut.Line, [RouteCut.Arrow])? = nil,
                                       traffic: TrafficSnapshot? = nil) async -> CutFrame {
        let log = OSLog(subsystem: "uz.radarmap", category: "MapPerformance")
        os_signpost(.begin, log: log, name: "Route preparation")
        defer { os_signpost(.end, log: log, name: "Route preparation") }
        let index = reuse?.0 ?? RouteIndex(coordinates)
        let line = reuse?.1 ?? RouteCut.Line(coordinates)
        let arrows = reuse?.2 ?? RouteCut.arrows(line)
        let pieces = traffic.map {
            RouteTraffic.pieces(along: coordinates, snapshot: $0, cumulative: line.cumulative)
        } ?? []
        return CutFrame(index: index, line: line, arrows: arrows, traffic: pieces)
    }

    /// Подсветка ближнего манёвра на линии, м от начала: ±engineManeuverHighlightMeters
    /// у точки манёвра, пока он впереди фикса не дальше engineManeuverApproachMeters.
    static func maneuverRange(at distance: Double?, progress: Double) -> ClosedRange<Double>? {
        guard let distance, distance >= progress,
              distance - progress <= AppConfig.engineManeuverApproachMeters else { return nil }
        return max(0, distance - AppConfig.engineManeuverHighlightMeters)...(distance + AppConfig.engineManeuverHighlightMeters)
    }

    /// Запас области уменьшает частоту перестановки символов при скролле.
    static func contains(_ outer: MKCoordinateRegion, _ inner: MKCoordinateRegion) -> Bool {
        abs(outer.center.latitude - inner.center.latitude) + inner.span.latitudeDelta / 2 <= outer.span.latitudeDelta / 2
        && abs(outer.center.longitude - inner.center.longitude) + inner.span.longitudeDelta / 2 <= outer.span.longitudeDelta / 2
    }

    static func padded(_ region: MKCoordinateRegion) -> MKCoordinateRegion {
        MKCoordinateRegion(center: region.center, span: MKCoordinateSpan(
            latitudeDelta: min(170, region.span.latitudeDelta * AppConfig.engineCameraViewportPadding),
            longitudeDelta: min(350, region.span.longitudeDelta * AppConfig.engineCameraViewportPadding)))
    }

    /// Что лежит в источнике камер: по какому виду сделана выборка, область
    /// с запасом и полна ли она.
    ///
    /// Выборка ограничена бюджетом (`engineCameraViewportLimit`) и при
    /// переполнении оставляет камеры, ближайшие к ЦЕНТРУ области. Урезанная
    /// выборка не покрывает область, по которой сделана, и «вид внутри
    /// прежней области» для неё ничего не значит. Поездка 21.10 (P0 20.1):
    /// обзор маршрута в 12 км набирал 160 камер вокруг середины пути, кадр
    /// ведения (z17 у машины) лежал внутри той области — и выборка не
    /// повторялась: у машины в источнике не было ни одной камеры всю поездку,
    /// на телефоне и в машине. Так же — первый кадр новой карты (вид всего
    /// мира до установки камеры): CarPlay, подключённый на ходу, оставался без
    /// камер до конца поездки.
    struct CameraWindow {
        /// Вид, по которому сделана выборка.
        let view: MKCoordinateRegion
        /// Область выборки — вид с запасом.
        let padded: MKCoordinateRegion
        /// Бюджет выборку не урезал: в ней все камеры области.
        let complete: Bool

        /// `found` — сколько камер вернула выборка с бюджетом `limit`: ровно
        /// бюджет — значит, могла быть урезана.
        init(view: MKCoordinateRegion, found: Int, limit: Int) {
            self.view = view
            padded = EngineMapPresentation.padded(view)
            complete = found < limit
        }
    }

    /// Нужна ли новая выборка для вида. Полная — повторяется, только когда
    /// вид вышел из области с запасом (меньше перестановок символов при
    /// осмотре). Урезанная верна лишь для своего вида: любой сдвиг или
    /// масштаб — выборка заново, иначе приближение к машине оставляло бы
    /// камеры вокруг чужого центра.
    static func needsCameraQuery(_ window: CameraWindow?, view: MKCoordinateRegion) -> Bool {
        guard let window else { return true }
        if window.complete { return !contains(window.padded, view) }
        return !sameView(window.view, view)
    }

    /// Тот же вид с точностью до шума пересчёта границ.
    static func sameView(_ a: MKCoordinateRegion, _ b: MKCoordinateRegion) -> Bool {
        let tolerance = AppConfig.engineCameraViewTolerance
        let lat = max(a.span.latitudeDelta, b.span.latitudeDelta) * tolerance
        let lon = max(a.span.longitudeDelta, b.span.longitudeDelta) * tolerance
        return abs(a.center.latitude - b.center.latitude) <= lat
            && abs(a.center.longitude - b.center.longitude) <= lon
            && abs(a.span.latitudeDelta - b.span.latitudeDelta) <= lat
            && abs(a.span.longitudeDelta - b.span.longitudeDelta) <= lon
    }

    static func maneuver(_ coordinates: [CLLocationCoordinate2D], at distance: Double?, progress: Double)
        -> [CLLocationCoordinate2D] {
        guard let distance, distance >= progress,
              distance - progress <= AppConfig.engineManeuverApproachMeters else { return [] }
        let throughTurn = split(coordinates, at: distance + AppConfig.engineManeuverHighlightMeters).traveled
        return split(throughTurn, at: max(progress, distance - AppConfig.engineManeuverHighlightMeters)).remaining
    }
    /// Поворот КАМЕРЫ движка: курс, а без курса — текущий поворот карты, всегда
    /// в [0, 360).
    ///
    /// MapLibre молча выбрасывает отрицательный курс камеры (MLNMapView,
    /// `cameraOptionsObjectForAnimatingToCamera`: `if (camera.heading >= 0)
    /// options.bearing = …`), а кратчайший путь через север выбирает сам. До
    /// 21.10 камере шёл развёрнутый `heading(_:near:)`: поворот налево через
    /// север давал, например, −92° (карта на 2°, курс 270°), движок его не
    /// применял, и карта застывала в прежнем повороте — пока курс не вернётся
    /// в правую половину. Стрелку «я» крутим мы сами, она показывала настоящий
    /// курс: машина вставала боком к дорогам, а центр кадра, вынесенный
    /// вперёд по курсу, уезжал вбок (снимок CarPlay 21.10, 08:28).
    static func cameraHeading(_ course: Double, current: Double) -> Double {
        let value = course.isFinite && course >= 0 ? course : current
        guard value.isFinite else { return 0 }
        let wrapped = value.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }

    /// Поворот СТРЕЛКИ «я» — её крутим сами, поэтому развёрнутый угол здесь
    /// годится. Короткий путь через север: 359° → 1° не должен делать полный
    /// оборот. Камере движка — только `cameraHeading`.
    static func heading(_ target: Double, near previous: Double) -> Double {
        guard target.isFinite, target >= 0 else { return previous }
        let delta = (target - previous).truncatingRemainder(dividingBy: 360)
        return previous + (delta > 180 ? delta - 360 : delta < -180 ? delta + 360 : delta)
    }

    /// Обе части делят одну точку среза; петля не проецируется на соседнюю ветку.
    static func split(_ coordinates: [CLLocationCoordinate2D], at distance: Double)
        -> (traveled: [CLLocationCoordinate2D], remaining: [CLLocationCoordinate2D]) {
        guard coordinates.count > 1, distance.isFinite, distance > 0 else { return ([], coordinates) }
        var accumulated = 0.0
        for index in 1..<coordinates.count {
            let a = MKMapPoint(coordinates[index - 1]), b = MKMapPoint(coordinates[index])
            let length = a.distance(to: b)
            if accumulated + length >= distance, length > 0 {
                let t = (distance - accumulated) / length
                let cut = MKMapPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t).coordinate
                return (Array(coordinates[..<index]) + [cut], [cut] + Array(coordinates[index...]))
            }
            accumulated += length
        }
        return (coordinates, [])
    }
}
