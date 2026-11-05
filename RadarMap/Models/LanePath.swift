//
//  LanePath.swift
//  RadarMap
//
//  Лента маршрута «Вождения 3D» (43): синяя заливка во всю НАШУ сторону
//  проезжей части, а у манёвра — плавное сужение к нужным полосам.
//
//  Вход — линия маршрута, ленты наших дорог из тайла (слой roads: ширина,
//  `oneway`, мост) и стрелки ряда у манёвра (слой arrows). Выход — один
//  непрерывный объект на участок: левый и правый край, середина и признак
//  моста на станциях через drive3DStationMeters. Карта кладёт его площадью
//  (без стыков и нахлёстов — ширина меняется вдоль одной фигуры) и режет
//  только по мосту: часть над настилом лежит на нём, часть под ним прячется.
//
//  Правило полосы. GPS полосу не знает, поэтому лента — совет, а не «вы
//  здесь»: на прямой — вся наша сторона (у односторонней — вся лента, у
//  двусторонней — правая половина), у манёвра в окне подъезда — сужение:
//  • есть ряд стрелок тайла — ровно до «наших» стрелок (их место берётся
//    из самих стрелок: тайл ставит их на нарисованное полотно);
//  • нет ряда — по ПДД: налево и разворот — к левому краю, направо — к
//    правому, шириной в одну полосу; прямо и без стороны — не сужаем.
//  Перестроение — S-кривая (smootherstep) длиной max(45 м, 3,5 с пути) на
//  полосу, оба края движутся синхронно, конец — за 15 м до ряда стрелок
//  (за 30 м до манёвра без ряда). После манёвра — снова во всю сторону.
//
//  Ось маршрута в изломах скругляется дугой (drive3DTurnRadius): узел OSRM
//  — угол, и край ленты на нём ломался бы. Смещения краёв считаются от оси
//  СОВПАВШЕЙ ленты тайла, а не от линии маршрута, — скругление и расхождение
//  осей не уводят ленту с асфальта. Внутри узла (лент нет или они `inner`)
//  края плавно переходят от входа к выходу.
//
//  Только картинка: ни голос, ни оповещения, ни прогресс маршрута отсюда не
//  читают. Считается при смене маршрута, манёвра и раз в несколько сотен
//  метров пути — не на тике (EngineDriveRibbon). Покрыто LanePathTests.
//

import CoreLocation

nonisolated enum LanePath {

    // MARK: - Вход

    /// Лента дороги из тайла (слой `roads`).
    struct Road: Equatable, Sendable {
        var points: [CLLocationCoordinate2D]
        /// Ширина всей непрерывной ленты, м (`width`).
        var width: Double
        var oneway: Bool
        var bridge: Bool
        /// Кусок внутри узла: для ширины не годится, мост — да.
        var inner: Bool = false
        /// Сужение у устья узла (`stub`): для ширины не годится.
        var stub: Bool = false

        static func == (l: Road, r: Road) -> Bool {
            l.width == r.width && l.oneway == r.oneway && l.bridge == r.bridge && l.inner == r.inner
                && l.stub == r.stub && l.points.count == r.points.count
                && zip(l.points, r.points).allSatisfy { $0.latitude == $1.latitude && $0.longitude == $1.longitude }
        }
    }

    /// Стрелка полосы из тайла (слой `arrows`). Чья она — решает вызывающий
    /// (LaneFocus: полосы OSRM или набор поворотов стрелки), здесь — где ряд.
    struct Arrow: Equatable, Sendable {
        var coordinate: CLLocationCoordinate2D
        /// Куда смотрит стрелка, градусы (по ходу движения).
        var bearing: Double
        /// Ширина полосы, м (`lw`); nil — старый тайл.
        var width: Double?
        var ours: Bool

        static func == (l: Arrow, r: Arrow) -> Bool {
            l.coordinate.latitude == r.coordinate.latitude && l.coordinate.longitude == r.coordinate.longitude
                && l.bearing == r.bearing && l.width == r.width && l.ours == r.ours
        }
    }

    enum Edge: Equatable, Sendable { case left, right }

    /// Ближайший манёвр.
    struct Maneuver: Equatable, Sendable {
        /// Метры от старта маршрута.
        var along: Double
        /// Край по ПДД без ряда стрелок; nil — без ряда не сужаем (прямо, плавно).
        var edge: Edge?
        /// Сужать ли по ряду стрелок (нет у кольца и финиша).
        var row: Bool
    }

    struct Input: Sendable {
        var route: [CLLocationCoordinate2D]
        /// Участок маршрута: откуда и сколько метров.
        var from: Double
        var length: Double
        /// Где машина (срез ленты), м: перестроение не начинается под ней.
        var car: Double
        var speedMps: Double
        /// Окно подъезда к манёвру, м (LaneFocus.window — как у DriveCamera).
        var window: Double
        var roads: [Road]
        var arrows: [Arrow]
        var maneuver: Maneuver?
        /// Сужение у манёвра разрешено (на горячем телефоне и плитке — нет).
        var narrowing: Bool
        /// Метры маршрута у каждой точки — в той же мере, что прогресс и
        /// манёвры (RouteService.cumulative); nil — своя оценка.
        var cumulative: [Double]? = nil
    }

    // MARK: - Выход

    /// Точка в метрах местной плоскости (восток, север).
    struct Point: Equatable, Sendable {
        var x: Double
        var y: Double

        static func + (a: Point, b: Point) -> Point { Point(x: a.x + b.x, y: a.y + b.y) }
        static func - (a: Point, b: Point) -> Point { Point(x: a.x - b.x, y: a.y - b.y) }
        static func * (a: Point, k: Double) -> Point { Point(x: a.x * k, y: a.y * k) }
        func dot(_ b: Point) -> Double { x * b.x + y * b.y }
        func cross(_ b: Point) -> Double { x * b.y - y * b.x }
        var length: Double { (x * x + y * y).squareRoot() }
        var unit: Point { let l = length; return l > 1e-9 ? Point(x: x / l, y: y / l) : Point(x: 0, y: 1) }
        /// Нормаль вправо от направления (x — восток, y — север).
        var right: Point { Point(x: y, y: -x) }
    }

    /// Местная плоскость: метры от опорной точки (до нескольких км — точно).
    struct Frame: Sendable {
        let origin: CLLocationCoordinate2D
        let kx: Double
        let ky = 110_540.0

        init(origin: CLLocationCoordinate2D) {
            self.origin = origin
            kx = 111_320 * cos(origin.latitude * .pi / 180)
        }

        func point(_ c: CLLocationCoordinate2D) -> Point {
            Point(x: (c.longitude - origin.longitude) * kx, y: (c.latitude - origin.latitude) * ky)
        }

        func coordinate(_ p: Point) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: origin.latitude + p.y / ky, longitude: origin.longitude + p.x / kx)
        }
    }

    /// Откуда ширина у манёвра.
    enum Narrowing: Equatable, Sendable { case none, arrows, rules }

    struct Ribbon: Sendable {
        let frame: Frame
        /// Метры от старта маршрута у каждой станции (мера линии маршрута).
        let along: [Double]
        let left: [Point]
        let right: [Point]
        let centre: [Point]
        let bridge: [Bool]
        /// Смещения краёв от оси маршрута, м (+ вправо) — для тестов и журнала.
        let leftOffset: [Double]
        let rightOffset: [Double]
        let narrowing: Narrowing
        /// Где лента уже всей стороны (сужение, удержание, возврат).
        let narrowed: ClosedRange<Double>?
        /// Где ряд стрелок (м от старта), если найден.
        let row: Double?
        /// Доля станций, у которых нашлась лента тайла.
        let matchedShare: Double

        var isEmpty: Bool { along.count < 2 }

        static func empty(_ frame: Frame) -> Ribbon {
            Ribbon(frame: frame, along: [], left: [], right: [], centre: [], bridge: [], leftOffset: [],
                   rightOffset: [], narrowing: .none, narrowed: nil, row: nil, matchedShare: 0)
        }
    }

    /// Кусок ленты для источника карты: площадь, края и середина.
    struct Piece: Sendable {
        let bridge: Bool
        /// Замкнутое кольцо: левый край вперёд, правый назад.
        let ring: [CLLocationCoordinate2D]
        let left: [CLLocationCoordinate2D]
        let right: [CLLocationCoordinate2D]
        let centre: [CLLocationCoordinate2D]
    }

    /// Шеврон направления внутри ленты.
    struct Chevron: Sendable {
        let coordinate: CLLocationCoordinate2D
        let bearing: Double
        let along: Double
        let bridge: Bool
    }

    // MARK: - Расчёт

    static func build(_ input: Input) -> Ribbon {
        guard input.route.count >= 2, input.length > 0 else {
            return .empty(Frame(origin: input.route.first ?? CLLocationCoordinate2D()))
        }
        let rawAlong = measure(input)
        // Плоскость — у начала участка: на маршруте в десятки километров
        // масштаб долготы у его старта уже другой.
        let originIndex = rawAlong.firstIndex { $0 >= input.from } ?? (input.route.count - 1)
        let frame = Frame(origin: input.route[originIndex])
        let raw = input.route.map(frame.point)
        let pad = 30.0
        let lo = max(0, input.from - pad)
        let hi = min(rawAlong.last ?? 0, input.from + input.length + pad)
        guard hi - lo > 1 else { return .empty(frame) }
        let section = cut(raw, rawAlong, from: lo, to: hi)
        let smooth = fillet(section, radius: AppConfig.drive3DTurnRadius)
        let (dense, along) = densify(smooth, step: AppConfig.drive3DStationMeters)
        // Пологие изломы (вершины OSM через 10–20 м по 3–6°) дуга не берёт —
        // край ленты шёл бы гранями. Скользящее среднее по ±10 м делает из
        // них кривую; смещения краёв всё равно считаются от оси ленты тайла.
        let points = averaged(dense, AppConfig.drive3DAxisSmoothStations)
        let n = points.count
        guard n >= 2 else { return .empty(frame) }

        // Касательная и нормаль: центральная разность через две станции.
        var tangent = [Point](repeating: Point(x: 0, y: 1), count: n)
        for i in 0..<n {
            tangent[i] = (points[min(n - 1, i + 2)] - points[max(0, i - 2)]).unit
        }

        // Совпавшая лента тайла на каждой станции.
        let index = SegmentIndex(roads: input.roads, frame: frame)
        var fullL = [Double?](repeating: nil, count: n)
        var fullR = [Double?](repeating: nil, count: n)
        var bridgeRaw = [Bool?](repeating: nil, count: n)
        var matched = 0
        var lastBridge: Bool?
        for i in 0..<n {
            guard let hit = index.match(points[i], tangent: tangent[i], previousBridge: lastBridge) else { continue }
            bridgeRaw[i] = hit.road.bridge
            lastBridge = hit.road.bridge
            guard !hit.road.inner, !hit.road.stub else { continue }
            let w = hit.road.width
            fullL[i] = (hit.road.oneway ? -w / 2 : 0) - hit.lateral
            fullR[i] = w / 2 - hit.lateral
            matched += 1
        }
        let half = AppConfig.drive3DFallbackWidth / 2
        var lf = fill(median(fullL, AppConfig.drive3DMedianStations), along: along, fallback: -half)
        var rf = fill(median(fullR, AppConfig.drive3DMedianStations), along: along, fallback: half)
        lf = average(lf, 3)
        rf = average(rf, 3)

        // Сужение у манёвра.
        var plan = NarrowPlan.none
        if input.narrowing, let maneuver = input.maneuver,
           maneuver.along > along[0], maneuver.along - input.window - AppConfig.drive3DRowSearchMeters < along[n - 1] {
            plan = narrowPlan(maneuver: maneuver, input: input, frame: frame, points: points, tangent: tangent,
                              along: along, lf: lf, rf: rf)
        }
        var leftOff = lf
        var rightOff = rf
        var narrowedLo = Double.infinity
        var narrowedHi = -Double.infinity
        for i in 0..<n {
            let k = plan.weight(along[i])
            guard k > 0 else { continue }
            narrowedLo = min(narrowedLo, along[i])
            narrowedHi = max(narrowedHi, along[i])
            let (a, b) = plan.target(lf: lf[i], rf: rf[i])
            leftOff[i] = lf[i] + (a - lf[i]) * k
            rightOff[i] = rf[i] + (b - rf[i]) * k
            if rightOff[i] - leftOff[i] < 1 {
                let mid = (leftOff[i] + rightOff[i]) / 2
                leftOff[i] = mid - 0.5
                rightOff[i] = mid + 0.5
            }
        }

        var left = [Point]()
        var right = [Point]()
        var centre = [Point]()
        left.reserveCapacity(n)
        right.reserveCapacity(n)
        centre.reserveCapacity(n)
        for i in 0..<n {
            let normal = tangent[i].right
            left.append(points[i] + normal * leftOff[i])
            right.append(points[i] + normal * rightOff[i])
            centre.append(points[i] + normal * ((leftOff[i] + rightOff[i]) / 2))
        }
        untangle(&left)
        untangle(&right)
        untangle(&centre)

        return Ribbon(frame: frame, along: along, left: left, right: right, centre: centre,
                      bridge: bridges(bridgeRaw), leftOffset: leftOff, rightOffset: rightOff,
                      narrowing: plan.kind,
                      narrowed: narrowedLo <= narrowedHi ? narrowedLo...narrowedHi : nil,
                      row: plan.row, matchedShare: Double(matched) / Double(n))
    }

    // MARK: - Куски для карты

    /// Лента от среза до `end`: куски по мосту, стык — общая станция.
    static func pieces(_ ribbon: Ribbon, from cut: Double, to end: Double = .infinity) -> [Piece] {
        guard !ribbon.isEmpty, let start = ribbon.along.firstIndex(where: { $0 >= cut }) else { return [] }
        let last = ribbon.along.lastIndex(where: { $0 <= end }) ?? -1
        guard last > start else { return [] }
        var out: [Piece] = []
        var i0 = start
        let tolerance = AppConfig.drive3DSimplifyMeters
        func emit(_ a: Int, _ b: Int) {
            guard b > a else { return }
            let left = simplified(Array(ribbon.left[a...b]), tolerance)
            let right = simplified(Array(ribbon.right[a...b]), tolerance)
            let centre = simplified(Array(ribbon.centre[a...b]), tolerance)
            var ring = left + right.reversed()
            if let first = ring.first { ring.append(first) }
            let f = ribbon.frame
            out.append(Piece(bridge: ribbon.bridge[a + 1], ring: ring.map(f.coordinate),
                             left: left.map(f.coordinate), right: right.map(f.coordinate),
                             centre: centre.map(f.coordinate)))
        }
        for i in (start + 1)...last where ribbon.bridge[i] != ribbon.bridge[i - 1] {
            emit(i0, i)
            i0 = i
        }
        emit(i0, last)
        return out
    }

    /// Шевроны по середине ленты на постоянных метрах маршрута (кратных
    /// `spacing`): пересчёт ленты их не сдвигает.
    static func chevrons(_ ribbon: Ribbon, spacing: Double) -> [Chevron] {
        guard !ribbon.isEmpty, spacing > 0 else { return [] }
        var out: [Chevron] = []
        var mark = (ribbon.along[0] / spacing).rounded(.up) * spacing
        var i = 1
        let n = ribbon.along.count
        while mark <= ribbon.along[n - 1], i < n {
            while i < n - 1, ribbon.along[i] < mark { i += 1 }
            let a = ribbon.centre[max(0, i - 2)]
            let b = ribbon.centre[min(n - 1, i + 1)]
            let d = b - a
            guard d.length > 0.1 else { mark += spacing; continue }
            let bearing = (atan2(d.x, d.y) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
            out.append(Chevron(coordinate: ribbon.frame.coordinate(ribbon.centre[i]), bearing: bearing,
                               along: mark, bridge: ribbon.bridge[i]))
            mark += spacing
        }
        return out
    }

    // MARK: - Ось

    /// Метры маршрута у точек: переданные (мера RouteService) или по
    /// отрезкам с масштабом долготы на их середине.
    static func measure(_ input: Input) -> [Double] {
        if let cumulative = input.cumulative, cumulative.count == input.route.count { return cumulative }
        var out = [0.0]
        out.reserveCapacity(input.route.count)
        for i in 1..<input.route.count {
            let a = input.route[i - 1], b = input.route[i]
            let kx = 111_320 * cos((a.latitude + b.latitude) / 2 * .pi / 180)
            let dx = (b.longitude - a.longitude) * kx, dy = (b.latitude - a.latitude) * 110_540
            out.append(out[i - 1] + (dx * dx + dy * dy).squareRoot())
        }
        return out
    }

    /// Отрезок полилинии между двумя метрами (с концами по интерполяции).
    static func cut(_ points: [Point], _ along: [Double], from lo: Double, to hi: Double)
        -> [(point: Point, along: Double)] {
        var out: [(point: Point, along: Double)] = []
        func at(_ s: Double) -> Point {
            guard let k = along.firstIndex(where: { $0 >= s }), k > 0 else {
                return s <= 0 ? points[0] : points[points.count - 1]
            }
            let t = (s - along[k - 1]) / max(1e-9, along[k] - along[k - 1])
            return points[k - 1] + (points[k] - points[k - 1]) * t
        }
        out.append((at(lo), lo))
        for i in 0..<points.count where along[i] > lo + 0.5 && along[i] < hi - 0.5 {
            if let prev = out.last, (points[i] - prev.point).length < 0.5 { continue }
            out.append((points[i], along[i]))
        }
        out.append((at(hi), hi))
        return out
    }

    /// Скругление изломов дугой радиуса не больше `radius` (меньше, если
    /// соседние отрезки коротки). Метры маршрута на дуге — линейно между
    /// метрами её концов на исходной линии: мера та же, что у маршрута.
    static func fillet(_ line: [(point: Point, along: Double)], radius: Double) -> [(point: Point, along: Double)] {
        guard line.count >= 3 else { return line }
        var out: [(point: Point, along: Double)] = [line[0]]
        for i in 1..<(line.count - 1) {
            let p = line[i].point
            let inc = p - line[i - 1].point
            let outg = line[i + 1].point - p
            let l1 = inc.length, l2 = outg.length
            guard l1 > 0.01, l2 > 0.01 else { continue }
            let u1 = inc.unit, u2 = outg.unit
            let theta = acos(max(-1, min(1, u1.dot(u2))))
            guard theta > 0.035 else { out.append(line[i]); continue }
            let tanHalf = tan(min(theta, .pi - 1e-3) / 2)
            let d = min(radius * tanHalf, 0.45 * l1, 0.45 * l2)
            guard d > 0.3 else { out.append(line[i]); continue }
            let r = d / tanHalf
            let a = p - u1 * d
            let side: Double = u1.cross(u2) > 0 ? 1 : -1
            let leftNormal = Point(x: -u1.y, y: u1.x)
            let centre = a + leftNormal * (side * r)
            let steps = max(2, Int((theta / (6 * .pi / 180)).rounded(.up)), Int((r * theta / 1.5).rounded(.up)))
            let start = a - centre
            let s0 = line[i].along - d
            for k in 0...steps {
                let phi = side * theta * Double(k) / Double(steps)
                let c = cos(phi), s = sin(phi)
                let v = Point(x: start.x * c - start.y * s, y: start.x * s + start.y * c)
                out.append((centre + v, s0 + 2 * d * Double(k) / Double(steps)))
            }
        }
        out.append(line[line.count - 1])
        return out
    }

    /// Станции не реже `step` метров.
    static func densify(_ line: [(point: Point, along: Double)], step: Double) -> ([Point], [Double]) {
        guard let first = line.first else { return ([], []) }
        var points = [first.point]
        var along = [first.along]
        for k in 1..<line.count {
            let a = line[k - 1], b = line[k]
            let d = (b.point - a.point).length
            guard d > 0.05 else { continue }
            let parts = max(1, Int((d / step).rounded(.up)))
            for j in 1...parts {
                let t = Double(j) / Double(parts)
                points.append(a.point + (b.point - a.point) * t)
                along.append(a.along + (b.along - a.along) * t)
            }
        }
        return (points, along)
    }

    // MARK: - Сопоставление с лентами тайла

    struct Hit {
        let road: Road
        /// Станция правее оси ленты на столько метров.
        let lateral: Double
    }

    /// Отрезки лент в сетке 20 м: станция смотрит в свою и соседние ячейки.
    struct SegmentIndex {
        private struct Segment { let a: Point; let b: Point; let road: Int }
        private let segments: [Segment]
        private let roads: [Road]
        private var cells: [Int64: [Int]] = [:]
        private let cell = 20.0

        init(roads: [Road], frame: Frame) {
            self.roads = roads
            var segments: [Segment] = []
            for (k, road) in roads.enumerated() where road.points.count >= 2 && road.width > 0 {
                let pts = road.points.map(frame.point)
                for j in 1..<pts.count where (pts[j] - pts[j - 1]).length > 0.2 {
                    segments.append(Segment(a: pts[j - 1], b: pts[j], road: k))
                }
            }
            self.segments = segments
            for (s, seg) in segments.enumerated() {
                let margin = AppConfig.drive3DMatchMeters
                let x0 = Int(((min(seg.a.x, seg.b.x) - margin) / cell).rounded(.down))
                let x1 = Int(((max(seg.a.x, seg.b.x) + margin) / cell).rounded(.down))
                let y0 = Int(((min(seg.a.y, seg.b.y) - margin) / cell).rounded(.down))
                let y1 = Int(((max(seg.a.y, seg.b.y) + margin) / cell).rounded(.down))
                guard (x1 - x0 + 1) * (y1 - y0 + 1) <= 400 else { continue }
                for x in x0...x1 { for y in y0...y1 { cells[Self.key(x, y), default: []].append(s) } }
            }
        }

        private static func key(_ x: Int, _ y: Int) -> Int64 { (Int64(x) << 32) ^ Int64(UInt32(bitPattern: Int32(y))) }

        func match(_ p: Point, tangent: Point, previousBridge: Bool?) -> Hit? {
            guard let list = cells[Self.key(Int((p.x / cell).rounded(.down)), Int((p.y / cell).rounded(.down)))] else {
                return nil
            }
            let maxDistance = AppConfig.drive3DMatchMeters
            let minCos = cos(AppConfig.drive3DMatchDegrees * .pi / 180)
            var best: (score: Double, hit: Hit)?
            for s in list {
                let seg = segments[s]
                let road = roads[seg.road]
                let d = seg.b - seg.a
                let l2 = d.dot(d)
                let t = max(0, min(1, (p - seg.a).dot(d) / l2))
                let foot = seg.a + d * t
                let distance = (p - foot).length
                guard distance <= maxDistance else { continue }
                let along = d.unit.dot(tangent)
                let alignment = road.oneway ? along : abs(along)
                guard alignment >= minCos else { continue }
                var score = distance + (1 - alignment) * 6
                if road.inner { score += 8 }
                if road.stub { score += 3 }
                if let previousBridge, previousBridge != road.bridge { score += 4 }
                if best == nil || score < best!.score {
                    best = (score, Hit(road: road, lateral: (p - foot).dot(tangent.right)))
                }
            }
            return best?.hit
        }
    }

    // MARK: - Сглаживание ширины

    /// Медиана по окну ±`half` станций — только по известным.
    static func median(_ values: [Double?], _ half: Int) -> [Double?] {
        var out = values
        var window: [Double] = []
        window.reserveCapacity(2 * half + 1)
        for i in values.indices where values[i] != nil {
            window.removeAll(keepingCapacity: true)
            for j in max(0, i - half)...min(values.count - 1, i + half) {
                if let v = values[j] { window.append(v) }
            }
            window.sort()
            out[i] = window[window.count / 2]
        }
        return out
    }

    /// Пробелы — плавным переходом между соседями (smootherstep по метрам),
    /// края — ближайшим известным, ничего не известно — `fallback`.
    static func fill(_ values: [Double?], along: [Double], fallback: Double) -> [Double] {
        let known = values.indices.filter { values[$0] != nil }
        guard let firstKnown = known.first, let lastKnown = known.last else {
            return [Double](repeating: fallback, count: values.count)
        }
        var out = values.map { $0 ?? 0 }
        for i in 0..<firstKnown { out[i] = out[firstKnown] }
        for i in (lastKnown + 1)..<max(lastKnown + 1, values.count) { out[i] = out[lastKnown] }
        for (a, b) in zip(known, known.dropFirst()) where b > a + 1 {
            let span = max(0.1, along[b] - along[a])
            for i in (a + 1)..<b {
                out[i] = out[a] + (out[b] - out[a]) * smootherstep((along[i] - along[a]) / span)
            }
        }
        return out
    }

    /// Скользящее среднее точек; концы остаются на месте (окно сужается).
    static func averaged(_ points: [Point], _ half: Int) -> [Point] {
        guard points.count > 2, half > 0 else { return points }
        var out = points
        for i in 1..<(points.count - 1) {
            let k = min(half, i, points.count - 1 - i)
            var sum = Point(x: 0, y: 0)
            for j in (i - k)...(i + k) { sum = sum + points[j] }
            out[i] = sum * (1 / Double(2 * k + 1))
        }
        return out
    }

    static func average(_ values: [Double], _ half: Int) -> [Double] {
        guard values.count > 2 * half else { return values }
        var out = values
        var sum = 0.0
        var lo = 0, hi = -1
        for i in values.indices {
            let a = max(0, i - half), b = min(values.count - 1, i + half)
            while hi < b { hi += 1; sum += values[hi] }
            while lo < a { sum -= values[lo]; lo += 1 }
            out[i] = sum / Double(hi - lo + 1)
        }
        return out
    }

    /// Мост по станциям: пробелы — значением соседей (разные — ближайшим),
    /// островки короче трёх станций сливаются с окружением.
    static func bridges(_ raw: [Bool?]) -> [Bool] {
        let n = raw.count
        var out = [Bool](repeating: false, count: n)
        var lastKnown: (index: Int, value: Bool)?
        var pending: [Int] = []
        for i in 0..<n {
            guard let v = raw[i] else { pending.append(i); continue }
            for j in pending {
                if let lastKnown, lastKnown.value == v { out[j] = v }
                else if let lastKnown { out[j] = (j - lastKnown.index) <= (i - j) ? lastKnown.value : v }
                else { out[j] = v }
            }
            pending = []
            out[i] = v
            lastKnown = (i, v)
        }
        for j in pending { out[j] = lastKnown?.value ?? false }
        var i = 0
        while i < n {
            var j = i
            while j + 1 < n, out[j + 1] == out[i] { j += 1 }
            if j - i + 1 < 3, i > 0, j < n - 1, out[i - 1] == out[j + 1] {
                for k in i...j { out[k] = out[i - 1] }
            }
            i = j + 1
        }
        return out
    }

    // MARK: - Сужение у манёвра

    struct NarrowPlan {
        var kind: Narrowing
        var start = 0.0
        var end = 0.0
        var maneuver = 0.0
        var release = 0.0
        /// Цель по ряду стрелок — смещения краёв от оси маршрута.
        var fixed: (Double, Double)?
        /// Цель по ПДД: край и ширина полосы.
        var edge: Edge?
        var lane = 0.0
        var row: Double?

        static let none = NarrowPlan(kind: .none)

        func weight(_ s: Double) -> Double {
            guard kind != .none else { return 0 }
            if s < start { return 0 }
            if s < end { return LanePath.smootherstep((s - start) / max(0.1, end - start)) }
            if s <= maneuver { return 1 }
            if s < maneuver + release { return 1 - LanePath.smootherstep((s - maneuver) / release) }
            return 0
        }

        func target(lf: Double, rf: Double) -> (Double, Double) {
            if let fixed { return fixed }
            let lane = min(self.lane, rf - lf)
            return edge == .left ? (lf, lf + lane) : (rf - lane, rf)
        }
    }

    static func narrowPlan(maneuver: Maneuver, input: Input, frame: Frame, points: [Point], tangent: [Point],
                           along: [Double], lf: [Double], rf: [Double]) -> NarrowPlan {
        let n = along.count
        func station(_ s: Double) -> Int {
            var lo = 0, hi = n - 1
            while lo < hi { let mid = (lo + hi) / 2; if along[mid] < s { lo = mid + 1 } else { hi = mid } }
            return lo
        }
        // Ряд стрелок перед манёвром на нашей стороне.
        var rowArrows: [(along: Double, lateral: Double, arrow: Arrow)] = []
        if maneuver.row {
            let a0 = station(maneuver.along - AppConfig.drive3DRowSearchMeters)
            let a1 = station(maneuver.along)
            if a1 > a0 {
                let minCos = cos(AppConfig.drive3DRowDegrees * .pi / 180)
                for arrow in input.arrows {
                    let q = frame.point(arrow.coordinate)
                    var best: (d: Double, i: Int)?
                    for i in a0...a1 {
                        let d = (q - points[i]).length
                        if d < 18, best == nil || d < best!.d { best = (d, i) }
                    }
                    guard let best else { continue }
                    let t = tangent[best.i]
                    let rad = arrow.bearing * .pi / 180
                    guard Point(x: sin(rad), y: cos(rad)).dot(t) >= minCos else { continue }
                    let lateral = (q - points[best.i]).dot(t.right)
                    guard lateral >= lf[best.i] - 1.5, lateral <= rf[best.i] + 1.5 else { continue }
                    let longitudinal = (q - points[best.i]).dot(t)
                    rowArrows.append((along[best.i] + longitudinal, lateral, arrow))
                }
            }
        }
        var plan = NarrowPlan(kind: .none)
        plan.maneuver = maneuver.along
        plan.release = AppConfig.drive3DReleaseMeters
        var laneWidth = AppConfig.drive3DLaneMeters
        if let far = rowArrows.map(\.along).max() {
            let row = rowArrows.filter { $0.along >= far - 8 }
            let ours = row.filter(\.arrow.ours)
            let rowAt = row.map(\.along).reduce(0, +) / Double(row.count)
            if !ours.isEmpty {
                let at = station(rowAt)
                let lo = ours.map { $0.lateral - ($0.arrow.width ?? AppConfig.drive3DLaneMeters) / 2 }.min() ?? 0
                let hi = ours.map { $0.lateral + ($0.arrow.width ?? AppConfig.drive3DLaneMeters) / 2 }.max() ?? 0
                let a = max(lf[at], lo), b = min(rf[at], hi)
                if b - a >= 2 {
                    plan.kind = .arrows
                    plan.fixed = (a, b)
                    plan.row = rowAt
                    plan.end = rowAt - AppConfig.drive3DRowGapMeters
                    let widths = ours.compactMap(\.arrow.width)
                    if !widths.isEmpty { laneWidth = widths.reduce(0, +) / Double(widths.count) }
                }
            }
        }
        if plan.kind == .none {
            guard let edge = maneuver.edge else { return .none }
            plan.kind = .rules
            plan.edge = edge
            plan.end = maneuver.along - AppConfig.drive3DNoRowGapMeters
            let at = station(plan.end)
            let side = rf[at] - lf[at]
            plan.lane = min(side, AppConfig.drive3DLaneMeters)
            laneWidth = plan.lane
        }
        // Длина перестроения: по полосам, на которые сдвигается край.
        let at = station(plan.end)
        let (a, b) = plan.target(lf: lf[at], rf: rf[at])
        let move = max(abs(a - lf[at]), abs(rf[at] - b))
        guard move > 0.3 else { return .none }
        let lanes = max(1, Int((move / max(1, laneWidth)).rounded()))
        let perLane = max(AppConfig.drive3DShiftMeters, input.speedMps * AppConfig.drive3DShiftSeconds)
        var start = plan.end - perLane * Double(lanes)
        start = max(start, maneuver.along - input.window, input.car + AppConfig.drive3DShiftLeadMeters)
        if plan.end - start < AppConfig.drive3DShiftMinMeters {
            plan.end = min(maneuver.along, start + AppConfig.drive3DShiftMinMeters)
        }
        plan.start = start
        return plan
    }

    // MARK: - Помощники

    /// S-кривая без излома скорости и ускорения на концах.
    static func smootherstep(_ t: Double) -> Double {
        let x = max(0, min(1, t))
        return x * x * x * (x * (x * 6 - 15) + 10)
    }

    /// Петли края на тугом изгибе (внутренний край длиннее радиуса) — в точку
    /// пересечения: площадь без самопересечений, нумерация станций та же.
    static func untangle(_ points: inout [Point], window: Int = 40) {
        let n = points.count
        guard n >= 4 else { return }
        var i = 0
        while i < n - 3 {
            var cut: (j: Int, x: Point)?
            let a = points[i], b = points[i + 1]
            for j in (i + 2)..<min(n - 1, i + window) {
                if let x = intersection(a, b, points[j], points[j + 1]) { cut = (j, x); break }
            }
            if let cut {
                for k in (i + 1)...cut.j { points[k] = cut.x }
                i = cut.j
            } else {
                i += 1
            }
        }
    }

    static func intersection(_ p: Point, _ p2: Point, _ q: Point, _ q2: Point) -> Point? {
        let r = p2 - p, s = q2 - q
        let denom = r.cross(s)
        guard abs(denom) > 1e-12 else { return nil }
        let t = (q - p).cross(s) / denom
        let u = (q - p).cross(r) / denom
        guard t > 1e-6, t < 1 - 1e-6, u > 1e-6, u < 1 - 1e-6 else { return nil }
        return p + r * t
    }

    /// Дуглас — Пекер: прямые участки — двумя точками.
    static func simplified(_ points: [Point], _ tolerance: Double) -> [Point] {
        var deduped: [Point] = []
        deduped.reserveCapacity(points.count)
        for p in points where deduped.last.map({ ($0 - p).length > 0.01 }) ?? true { deduped.append(p) }
        guard deduped.count > 2 else { return deduped }
        var keep = [Bool](repeating: false, count: deduped.count)
        keep[0] = true
        keep[deduped.count - 1] = true
        var stack = [(0, deduped.count - 1)]
        while let (a, b) = stack.popLast() {
            guard b > a + 1 else { continue }
            let base = deduped[b] - deduped[a]
            let len = base.length
            var worst = (d: -1.0, i: a)
            for i in (a + 1)..<b {
                let v = deduped[i] - deduped[a]
                let d = len > 1e-9 ? abs(base.cross(v)) / len : v.length
                if d > worst.d { worst = (d, i) }
            }
            if worst.d > tolerance {
                keep[worst.i] = true
                stack.append((a, worst.i))
                stack.append((worst.i, b))
            }
        }
        return deduped.indices.filter { keep[$0] }.map { deduped[$0] }
    }
}
