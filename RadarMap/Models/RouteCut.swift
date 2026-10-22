//
//  RouteCut.swift
//  RadarMap
//
//  Где кончается пройденная линия маршрута — под значком «я», каждый кадр
//  (27.A, 22.10).
//
//  После 25.B значок стоит там, где машина СЕЙЧАС (MarkerPredictor), а линия
//  переписывалась в источники движка по фиксам и раз в 30 м: значок уезжал
//  вперёд, граница пройденного оставалась — из-под машины назад торчал синий
//  хвост (снимок CarPlay 22.10). Переписывать GeoJSON каждый кадр нельзя —
//  ровно от этого ушли 11.10 (перетайливание и расстановка символов на
//  главном потоке). Режем краской:
//
//  - пройденная (бледная) линия — ВЕСЬ маршрут, один раз на маршрут, снизу;
//  - у машины — короткое окно линии (источник с lineMetrics), его кайма,
//    тело (с пробками), подсветка манёвра и светлая середина красятся
//    `line-gradient` по `line-progress`: до среза прозрачно, после — цвет.
//    Краска — 256 точек на длину источника, поэтому окно короткое
//    (routeCutWindowMeters → метр на точку);
//  - дальше окна — обычный остаток линии и пробки на нём;
//  - стрелки — точками с местом на линии; прячутся фильтром, когда срез
//    проходит стрелку, — в этот момент она под машиной.
//
//  Доля пути — проекция предсказанной точки значка на линию
//  (RouteService.project) около прогресса последнего фикса: не дальше
//  «фикс + скорость × горизонт значка», не за излом круче
//  markerPathTurnDegrees (значок сам ждёт фикса у угла), не назад (уход с
//  маршрута и разворот назад линию не «отрезают» обратно), не вдали от
//  линии. Новый маршрут (перестроение) — срез заново.
//
//  Только картинка: оповещения, ETA и прогресс маршрута отсюда не читают.
//  Чистая логика — RouteCutTests.
//

import CoreLocation
import MapKit

nonisolated enum RouteCut {

    // MARK: - Линия

    /// Геометрия линии для среза: точки, пройденное до каждой и изломы.
    /// Строится один раз на маршрут (не на кадре).
    struct Line: Sendable {
        let coordinates: [CLLocationCoordinate2D]
        let points: [MKMapPoint]
        /// Пройденное от начала до каждой точки, м.
        let cumulative: [Double]
        /// Пройденное до каждого излома круче markerPathTurnDegrees, по возрастанию.
        let bends: [Double]

        init(_ coordinates: [CLLocationCoordinate2D],
             bendDegrees: Double = AppConfig.markerPathTurnDegrees) {
            self.coordinates = coordinates
            let points = coordinates.map(MKMapPoint.init)
            self.points = points
            var cumulative = [Double]()
            cumulative.reserveCapacity(points.count)
            var sum = 0.0
            for i in points.indices {
                if i > 0 { sum += points[i - 1].distance(to: points[i]) }
                cumulative.append(sum)
            }
            self.cumulative = cumulative
            // Излом — как у MarkerPredictor.walk: между соседними отрезками
            // не короче метра (дубли точек — шум, их направлению не верим).
            var bends: [Double] = []
            var previous: Double?
            if coordinates.count > 1 {
                for i in 1..<coordinates.count {
                    let a = coordinates[i - 1], b = coordinates[i]
                    guard MarkerPredictor.distance(a, b) >= 1 else { continue }
                    let bearing = GeoMath.bearing(from: a, to: b)
                    if let previous, GeoMath.angleDifference(previous, bearing) > bendDegrees {
                        bends.append(cumulative[i - 1])
                    }
                    previous = bearing
                }
            }
            self.bends = bends
        }

        var length: Double { cumulative.last ?? 0 }

        /// Первый излом строго дальше `along` (с запасом в сантиметр); nil — нет.
        func nextBend(after along: Double) -> Double? {
            var lo = 0, hi = bends.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if bends[mid] <= along + 0.01 { lo = mid + 1 } else { hi = mid }
            }
            return lo < bends.count ? bends[lo] : nil
        }

        /// Индекс отрезка, на котором лежит `along`.
        func segment(at along: Double) -> Int {
            guard cumulative.count > 1 else { return 0 }
            var lo = 1, hi = cumulative.count - 1
            while lo < hi {
                let mid = (lo + hi) / 2
                if cumulative[mid] < along { lo = mid + 1 } else { hi = mid }
            }
            return lo - 1
        }

        /// Точка и направление линии на `along`.
        func pose(at along: Double) -> (coordinate: CLLocationCoordinate2D, bearing: Double) {
            guard coordinates.count > 1 else { return (coordinates.first ?? .init(), 0) }
            let clamped = min(max(0, along), length)
            let i = segment(at: clamped)
            let a = points[i], b = points[i + 1]
            let span = cumulative[i + 1] - cumulative[i]
            let t = span > 0 ? (clamped - cumulative[i]) / span : 0
            let point = MKMapPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            return (point.coordinate, GeoMath.bearing(from: coordinates[i], to: coordinates[i + 1]))
        }
    }

    // MARK: - Доля пути

    /// Срез под значком. Монотонный в пределах одного маршрута.
    struct Tracker {
        /// Пройденное по линии до среза, м.
        private(set) var cut: Double = 0
        private var hint = 0
        private var anchor = -Double.infinity

        /// Новый маршрут (перестроение, выбор варианта): срез — заново.
        mutating func reset() {
            cut = 0
            hint = 0
            anchor = -.infinity
        }

        /// Сдвинуть срез к предсказанной точке значка.
        /// `fixAlong` — прогресс маршрута на последнем фиксе (RouteService);
        /// `course` — курс значка (< 0 — неизвестен); `speedMps` — скорость фикса.
        @discardableResult
        mutating func advance(pose: CLLocationCoordinate2D, course: Double, fixAlong: Double,
                              speedMps: Double, line: Line) -> Double {
            guard line.points.count >= 2 else { return cut }
            // Окно поиска — от прогресса фикса: он знает маршрут целиком
            // (полный перебор, курс), и съезд с возвратом дальше по линии
            // догоняется сразу, а не теряется за окном прошлого кадра.
            if fixAlong != anchor {
                anchor = fixAlong
                hint = line.segment(at: fixAlong)
            }
            let (along, deviation) = RouteService.project(MKMapPoint(pose), onto: line.points,
                                                          cum: line.cumulative, hint: &hint,
                                                          allowFullScan: false, course: course)
            // Значок не на линии (съехали, дублёр, грубая точка) — срез стоит.
            guard deviation <= AppConfig.routeCutMaxDeviationMeters else { return cut }
            let base = max(0, fixAlong)
            var limit = base + max(0, speedMps) * AppConfig.markerMaxLeadSeconds
                + AppConfig.routeCutLeadSlackMeters
            // За излом — только когда туда дошёл фикс: проекция точки у угла
            // на соседнюю ветку не утаскивает границу за поворот.
            if let bend = line.nextBend(after: base) { limit = min(limit, bend) }
            let target = min(along, limit, line.length)
            if target > cut { cut = target }
            return cut
        }
    }

    // MARK: - Окно у машины

    /// Участок линии в источнике окна, м от начала маршрута.
    struct Window: Equatable, Sendable {
        var start: Double
        var end: Double
        var length: Double { end - start }

        /// Доля окна (line-progress) для места на линии.
        func progress(_ along: Double) -> Double {
            length > 0 ? min(1, max(0, (along - start) / length)) : 0
        }
    }

    /// Окно для среза: прежнее, пока срез в нём с запасом до конца (или окно
    /// доходит до финиша); иначе новое — от чуть позади среза.
    static func window(_ current: Window?, cut: Double, routeLength: Double,
                       meters: Double = AppConfig.routeCutWindowMeters,
                       reserve: Double = AppConfig.routeCutWindowReserveMeters,
                       behind: Double = AppConfig.routeCutWindowBehindMeters) -> Window? {
        guard routeLength > 0 else { return nil }
        if let current, cut >= current.start,
           cut <= current.end - reserve || current.end >= routeLength - 0.01 {
            return current
        }
        let start = max(0, min(cut - behind, routeLength - min(meters, routeLength)))
        return Window(start: start, end: min(routeLength, start + meters))
    }

    // MARK: - Краска окна

    /// Цвет RGBA (0…255 и альфа 0…1) — выражение ["rgba", …] стиля.
    struct Colour: Equatable, Sendable {
        var r: Double, g: Double, b: Double, a: Double

        static let clear = Colour(r: 0, g: 0, b: 0, a: 0)

        init(r: Double, g: Double, b: Double, a: Double) {
            self.r = r; self.g = g; self.b = b; self.a = a
        }

        init(hex: UInt32, alpha: Double = 1) {
            r = Double((hex >> 16) & 0xFF); g = Double((hex >> 8) & 0xFF); b = Double(hex & 0xFF)
            a = alpha
        }

        var json: [Any] { ["rgba", r, g, b, a] }
    }

    /// Цвета линии темы — те же числа RouteColors, что у остатка линии.
    struct Colours: Equatable, Sendable {
        var casing, body, slow, jam, maneuver, core: Colour

        init(daylight: Bool) {
            func pick(_ pair: RouteColors.Pair) -> Colour { Colour(hex: daylight ? pair.day : pair.night) }
            casing = pick(RouteColors.casing)
            body = pick(RouteColors.body)
            slow = pick(RouteColors.slow)
            jam = pick(RouteColors.jam)
            maneuver = Colour(hex: daylight ? RouteColors.maneuver.day : RouteColors.maneuver.night)
            core = Colour(r: 255, g: 255, b: 255,
                          a: daylight ? RouteColors.coreAlpha.day : RouteColors.coreAlpha.night)
        }
    }

    /// Смена цвета на доле окна: с `at` и дальше — `colour`.
    struct Stop: Equatable, Sendable {
        var at: Double
        var colour: Colour
    }

    /// Ступени краски слоёв окна. Первая ступень всегда на 0.
    struct Paint: Equatable, Sendable {
        var casing: [Stop]
        var body: [Stop]
        var maneuver: [Stop]
        var core: [Stop]

        /// Всё прозрачно — окно ещё не показано.
        static let clear = Paint(casing: [Stop(at: 0, colour: .clear)], body: [Stop(at: 0, colour: .clear)],
                                 maneuver: [Stop(at: 0, colour: .clear)], core: [Stop(at: 0, colour: .clear)])
    }

    /// Краска окна: до среза прозрачно; от среза до `drawEnd` (конец окна или
    /// начало остатка линии, пока тот ещё старый) — кайма, тело с пробками,
    /// манёвр и середина; дальше снова прозрачно.
    static func paint(window: Window, cut: Double, drawEnd: Double, traffic: [RouteTraffic.Piece],
                      maneuver: ClosedRange<Double>?, colours: Colours) -> Paint {
        let from = max(cut, window.start), to = min(drawEnd, window.end)
        guard to > from, window.length > 0 else { return .clear }
        func ramp(_ spans: [(Double, Double, Colour)]) -> [Stop] {
            var stops = [Stop(at: 0, colour: .clear)]
            func set(_ at: Double, _ colour: Colour) {
                if let last = stops.last, last.at >= at { stops[stops.count - 1].colour = colour; return }
                if stops.last?.colour == colour { return }
                stops.append(Stop(at: at, colour: colour))
            }
            for (a, b, colour) in spans {
                let lo = max(a, from), hi = min(b, to)
                guard hi > lo else { continue }
                set(window.progress(lo), colour)
                set(window.progress(hi), .clear)
            }
            // Хвост «прозрачно» в самом конце окна не нужен, если окно
            // окрашено до края: ступень на 1 ничего не меняет.
            if stops.count > 1, stops.last?.at ?? 0 >= 1, stops.last?.colour == .clear { stops.removeLast() }
            return stops
        }
        var body: [(Double, Double, Colour)] = []
        var cursor = from
        for piece in traffic.sorted(by: { $0.from < $1.from }) where piece.to > from && piece.from < to {
            let lo = max(piece.from, cursor)
            if lo > cursor { body.append((cursor, lo, colours.body)) }
            let hi = min(piece.to, to)
            if hi > lo { body.append((lo, hi, piece.level >= 3 ? colours.jam : colours.slow)) }
            cursor = max(cursor, hi)
        }
        if cursor < to { body.append((cursor, to, colours.body)) }
        return Paint(casing: ramp([(from, to, colours.casing)]),
                     body: ramp(body),
                     maneuver: ramp(maneuver.map { [($0.lowerBound, $0.upperBound, colours.maneuver)] } ?? []),
                     core: ramp([(from, to, colours.core)]))
    }

    /// Выражение line-gradient: ступени по line-progress. Резкая граница —
    /// две точки на расстоянии `epsilon` (interpolate требует возрастания).
    static func gradient(_ stops: [Stop], epsilon: Double = 1e-5) -> [Any] {
        var out: [Any] = ["interpolate", ["linear"], ["line-progress"]]
        var lastAt = -1.0
        var lastColour = stops.first?.colour ?? .clear
        func add(_ at: Double, _ colour: Colour) {
            out.append(at)
            out.append(colour.json)
            lastAt = at
        }
        add(0, lastColour)
        for stop in stops.dropFirst() {
            let at = min(1, max(stop.at, lastAt + epsilon))
            let before = max(lastAt + epsilon, at - epsilon)
            if before < at { add(before, lastColour) }
            if at > lastAt { add(at, stop.colour) }
            lastColour = stop.colour
        }
        if lastAt < 1 { add(1, lastColour) }
        return out
    }

    // MARK: - Стрелки направления

    /// Стрелка на линии: точка, направление, место и ранг (чем выше, тем
    /// дальше видна: ранг r — каждая 2^r-я стрелка).
    struct Arrow: Equatable, Sendable {
        var coordinate: CLLocationCoordinate2D
        var bearing: Double
        var along: Double
        var rank: Int

        static func == (l: Self, r: Self) -> Bool {
            l.coordinate.latitude == r.coordinate.latitude && l.coordinate.longitude == r.coordinate.longitude
                && l.bearing == r.bearing && l.along == r.along && l.rank == r.rank
        }
    }

    static let arrowMaxRank = 5

    /// Стрелки по всей линии через `spacing` метров. Место — в метрах линии,
    /// поэтому стрелки не «прыгают», когда переписывается остаток.
    static func arrows(_ line: Line, spacing: Double = AppConfig.routeArrowSpacingMeters) -> [Arrow] {
        guard line.points.count >= 2, spacing > 0 else { return [] }
        var out: [Arrow] = []
        var i = 1
        while Double(i) * spacing < line.length {
            let along = Double(i) * spacing
            let pose = line.pose(at: along)
            out.append(Arrow(coordinate: pose.coordinate, bearing: pose.bearing, along: along,
                             rank: min(arrowMaxRank, i.trailingZeroBitCount)))
            i += 1
        }
        return out
    }

    /// Масштабы смены ранга: на обзоре — каждая 32-я (≈ 480 м), вблизи —
    /// каждая (15 м); шаг как у прежних стрелок symbol-spacing (70 точек на
    /// z13 … 160 на z19).
    static let arrowRankZooms: [Double] = [13.5, 14.6, 16.3, 17.5, 18.6]

    /// Наименьший видимый ранг на масштабе.
    static func arrowMinRank(zoom: Double) -> Int {
        arrowMaxRank - arrowRankZooms.filter { zoom >= $0 }.count
    }

    /// Порог фильтра стрелок: место первой ВИДИМОЙ на этом масштабе стрелки
    /// впереди среза. Всё, что раньше, скрыто; меняется, только когда срез
    /// проходит видимую стрелку, — она в этот момент под значком.
    static func arrowThreshold(_ arrows: [Arrow], cut: Double, minRank: Int) -> Double {
        var lo = 0, hi = arrows.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if arrows[mid].along <= cut { lo = mid + 1 } else { hi = mid }
        }
        for arrow in arrows[lo...] where arrow.rank >= minRank { return arrow.along }
        return (arrows.last?.along ?? 0) + 1
    }
}
