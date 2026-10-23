//
//  LaneFocus.swift
//  RadarMap
//
//  «Нужная полоса» на асфальте (28.C, 23.10): у ближайшего манёвра стрелки
//  полос, ведущие туда, куда нам, — цветом маршрута, остальные стрелки того
//  же ряда бледнее (как у Яндекс Навигатора).
//
//  Два источника и ни одной догадки:
//  • стрелки на асфальте — наши тайлы (слой `arrows`, build_mvt.lane_arrows):
//    точка на полосу, `turn` (куда ведёт полоса, коды build_roads.TURN_*) и
//    `bearing` (куда смотрит стрелка — по ходу движения);
//  • куда нам — полосы манёвра (OSRM `intersections[0].lanes` или слой полос):
//    какие полосы `valid`. Оба описывают один и тот же `turn:lanes` из OSM,
//    поэтому стрелка «нашей» полосы узнаётся по её же набору направлений.
//  Нет полос у манёвра (а это 90 % поворотов Ташкента) — ничего не меняется:
//  подсветить «левую» по одному модификатору нельзя, на развилке «плавно
//  левее» стрелка могла бы оказаться «налево», и ряд погас бы целиком.
//
//  Где ряд: коридор вдоль линии маршрута перед точкой манёвра (стрелки стоят
//  в 15–70 м до перекрёстка, на нашей половине дороги) и курс стрелки ≈ курс
//  подъезда — встречные стрелки и стрелки поперечной улицы в коридор не
//  попадают. Коридор не заходит за предыдущий перекрёсток маршрута: его ряд —
//  не наш.
//
//  Карта применяет это фильтром слоя (`within` + курс + код), и фильтр меняется
//  только при смене манёвра или входе в окно подъезда — не на тике.
//
//  Только картинка: ни голос, ни оповещения отсюда не читают.
//

import CoreLocation

nonisolated enum LaneFocus {

    /// Одно направление движения с полосы.
    enum Movement: String, Equatable, Hashable, Sendable {
        case straight, left, right, slightLeft, slightRight, uturn
    }

    // MARK: - Контракт со стрелками тайла

    /// Коды `turn` стрелок тайла (build_roads.TURN_*) → куда ведёт полоса.
    /// 0 — полоса без стрелки, её на асфальте нет.
    static let tileTurns: [Int: Set<Movement>] = [
        1: [.straight], 2: [.left], 3: [.right],
        4: [.slightLeft], 5: [.slightRight], 6: [.uturn],
        7: [.straight, .left], 8: [.straight, .right], 9: [.left, .right],
    ]

    /// Имена значков тех же кодов в спрайте (make_arrows.NAMES).
    static let tileIcons: [Int: String] = [
        1: "lane-through", 2: "lane-left", 3: "lane-right",
        4: "lane-slight_left", 5: "lane-slight_right", 6: "lane-uturn",
        7: "lane-through_left", 8: "lane-through_right", 9: "lane-left_right",
    ]

    /// Стрелка OSRM в языке тайла: острый поворот нарисован той же стрелкой,
    /// что обычный, «перестройтесь левее» — той же, что «плавно левее»
    /// (build_roads.TURN_SETS: merge_to_left → slight_left).
    static func movement(_ arrow: LaneArrow) -> Movement {
        switch arrow {
        case .straight:                  return .straight
        case .left, .sharpLeft:          return .left
        case .right, .sharpRight:        return .right
        case .slightLeft, .mergeToLeft:  return .slightLeft
        case .slightRight, .mergeToRight: return .slightRight
        case .uturn:                     return .uturn
        }
    }

    /// Манёвр в языке тайла. Кольцо и финиш — nil: ряд на кольце зависит от
    /// съезда, а на финише поворота нет.
    static func movement(_ kind: ManeuverKind) -> Movement? {
        switch kind {
        case .straight:              return .straight
        case .left, .sharpLeft:      return .left
        case .right, .sharpRight:    return .right
        case .slightLeft:            return .slightLeft
        case .slightRight:           return .slightRight
        case .uturn:                 return .uturn
        case .roundabout, .arrive:   return nil
        }
    }

    /// Коды стрелок тайла, которые ведут нас: набор направлений стрелки
    /// совпадает с набором подходящей полосы манёвра. Если ни один код не
    /// совпал целиком (у полосы редкое сочетание, «left;slight_left»), —
    /// стрелки, в которых есть общее направление всех подходящих полос.
    /// Пусто — подсвечивать нечего, ряд остаётся как был.
    static func ourCodes(kind: ManeuverKind?, lanes: [LaneHint]) -> [Int] {
        guard let kind, movement(kind) != nil else { return [] }
        let valid = lanes.filter(\.isValid).map { Set($0.arrows.map(movement)) }
        guard !valid.isEmpty else { return [] }
        let exact = tileTurns.filter { valid.contains($0.value) }.map(\.key)
        if !exact.isEmpty { return exact.sorted() }
        guard let target = target(kind: kind, valid: valid) else { return [] }
        return tileTurns.filter { $0.value.contains(target) }.map(\.key).sorted()
    }

    /// Общее направление всех подходящих полос: модификатор манёвра, если он
    /// среди общих; иначе единственное общее. Неоднозначно — nil.
    private static func target(kind: ManeuverKind, valid: [Set<Movement>]) -> Movement? {
        guard var common = valid.first else { return nil }
        for lane in valid.dropFirst() { common.formIntersection(lane) }
        if let wanted = movement(kind), common.contains(wanted) { return wanted }
        return common.count == 1 ? common.first : nil
    }

    // MARK: - Манёвр

    // MARK: - Полоса

    /// Одна полоса ряда стрелок тайла — как её видит карта. Та же модель ляжет
    /// под ленту маршрута в полосе (этап 29): место полосы на ленте — `index`
    /// и `width` от левой кромки, переход между полосами — по `turns`.
    struct Lane: Equatable, Sendable {
        /// Номер слева направо по ходу, с нуля (`li` тайла); nil — старый тайл.
        let index: Int?
        /// Полос в ряду (`ln`); nil — старый тайл.
        let count: Int?
        /// Ширина полосы, м (`lw`); nil — старый тайл.
        let width: Double?
        /// Код стрелки (`turn`, build_roads.TURN_*).
        let turn: Int

        /// Куда ведёт полоса; пусто — код неизвестен.
        var turns: Set<Movement> { tileTurns[turn] ?? [] }
    }

    /// «Наша» полоса манёвра по её месту: номер и коды стрелок, совпадающие с
    /// набором направлений этой полосы.
    struct OurLane: Equatable, Sendable {
        let index: Int
        let codes: [Int]
    }

    /// Подходящие полосы манёвра по номерам: у каждой — коды стрелок тайла с
    /// тем же набором направлений (стрелка на этом месте должна говорить то
    /// же, что полоса OSRM; иная — данные разных лет, не подсвечиваем).
    static func ourLanes(kind: ManeuverKind?, lanes: [LaneHint]) -> [OurLane] {
        guard let kind, movement(kind) != nil else { return [] }
        return lanes.enumerated().compactMap { index, lane in
            guard lane.isValid else { return nil }
            let set = Set(lane.arrows.map(movement))
            let codes = tileTurns.filter { $0.value == set }.map(\.key).sorted()
            return codes.isEmpty ? nil : OurLane(index: index, codes: codes)
        }
    }

    // MARK: - Манёвр

    /// Что подсвечивать у манёвра — от ряда полос маршрута, без координат.
    struct Step: Equatable, Sendable {
        /// Где манёвр, метры от старта маршрута.
        let along: Double
        /// Ближе к манёвру коридор не начинается: здесь предыдущий перекрёсток
        /// маршрута (его ряд стрелок — не наш). −∞ — его нет.
        let floor: Double
        /// Коды «наших» стрелок тайла по набору поворотов, по возрастанию, не
        /// пусто — для тайлов без номера полосы.
        let codes: [Int]
        /// Полос у манёвра (OSRM или слой полос).
        let laneCount: Int
        /// «Наши» полосы по номеру — для тайлов с `li`/`ln`.
        let lanes: [OurLane]

        /// Наша ли стрелка ряда. Номер полосы главнее набора поворотов: на
        /// «налево | налево» OSRM может годиться только одна из двух. Номер
        /// верен, пока в ряду тайла полос не больше, чем у манёвра (хвост
        /// полос «без стрелки» тайл не считает, OSRM — считает).
        func isOurs(_ lane: Lane) -> Bool {
            if let index = lane.index, let count = lane.count, count <= laneCount {
                return lanes.contains { $0.index == index && $0.codes.contains(lane.turn) }
            }
            return codes.contains(lane.turn)
        }
    }

    /// Ближайший манёвр с известными полосами; nil — подсвечивать нечего.
    /// `steps` и `notices` — манёвры и ряды на проездах прямо того же маршрута.
    static func step(next: RouteStep?, steps: [RouteStep], notices: [LaneNotice]) -> Step? {
        guard let next, next.kind?.isDrawable == true else { return nil }
        let codes = ourCodes(kind: next.kind, lanes: next.lanes)
        guard !codes.isEmpty else { return nil }
        let along = next.distanceAlong
        let before = steps.map(\.distanceAlong) + notices.map(\.distanceAlong)
        let previous = before.filter { $0 < along - 1 }.max()
        let floor = previous.map { $0 + AppConfig.laneFocusFloorMarginMeters } ?? -.infinity
        return Step(along: along, floor: floor, codes: codes, laneCount: next.lanes.count,
                    lanes: ourLanes(kind: next.kind, lanes: next.lanes))
    }

    // MARK: - Окно подъезда

    /// Окно подъезда — то же, что у камеры ведения (DriveCamera): 15 секунд
    /// хода, не меньше 150 и не больше 450 м. С этого места карта уже
    /// приближается к развилке и стрелки видны.
    static func window(speedKmh: Double) -> Double {
        let mps = max(0, speedKmh.isFinite ? speedKmh : 0) / 3.6
        return min(DriveCamera.maneuverWindowMax,
                   max(DriveCamera.maneuverWindowMin, mps * DriveCamera.maneuverLeadSeconds))
    }

    /// Вход в окно и выход за манёвр — с памятью: окно сжимается при
    /// торможении (450 → 150 м), и без памяти подсветка гасла бы посреди
    /// подъезда, а на светофоре мигала бы от шума скорости.
    struct Gate: Equatable, Sendable {
        private(set) var shown: Step?

        init() {}

        mutating func update(_ step: Step?, progress: Double, speedKmh: Double) -> Step? {
            guard let step else {
                shown = nil
                return nil
            }
            let distance = step.along - progress
            if shown == step {
                if distance < -AppConfig.laneFocusPassedMeters { shown = nil }
                return shown
            }
            shown = distance >= -AppConfig.laneFocusPassedMeters && distance <= window(speedKmh: speedKmh)
                ? step : nil
            return shown
        }
    }

    // MARK: - Коридор ряда

    /// Где искать ряд стрелок: многоугольник вокруг линии маршрута перед
    /// манёвром и курс подъезда.
    struct Zone: Equatable, Sendable {
        /// Замкнутое кольцо (первая точка повторена в конце).
        let ring: [CLLocationCoordinate2D]
        /// Курс подъезда, 0–360°.
        let bearing: Double

        static func == (l: Zone, r: Zone) -> Bool {
            l.bearing == r.bearing && l.ring.count == r.ring.count
                && zip(l.ring, r.ring).allSatisfy { $0.latitude == $1.latitude && $0.longitude == $1.longitude }
        }
    }

    /// Коридор по линии маршрута от `along − laneFocusBackMeters` (не ближе
    /// `floor`) до самого манёвра, шириной ±`laneFocusHalfWidthMeters`.
    /// nil — линии нет или коридор короче `laneFocusMinRowMeters`.
    /// Один проход по линии — раз на манёвр, не на тике.
    static func zone(route: [CLLocationCoordinate2D], step: Step) -> Zone? {
        guard route.count >= 2 else { return nil }
        var cumulative = [0.0]
        cumulative.reserveCapacity(route.count)
        for i in route.indices.dropFirst() {
            cumulative.append(cumulative[i - 1] + GeoMath.fastDistance(
                route[i - 1].latitude, route[i - 1].longitude, route[i].latitude, route[i].longitude))
        }
        let length = cumulative[cumulative.count - 1]
        let end = min(step.along, length)
        let start = max(0, step.along - AppConfig.laneFocusBackMeters, step.floor)
        guard end - start >= AppConfig.laneFocusMinRowMeters else { return nil }

        func point(at along: Double) -> CLLocationCoordinate2D {
            var lo = 0, hi = cumulative.count - 1
            while lo + 1 < hi {
                let mid = (lo + hi) / 2
                if cumulative[mid] <= along { lo = mid } else { hi = mid }
            }
            let span = cumulative[lo + 1] - cumulative[lo]
            let t = span > 0 ? min(1, max(0, (along - cumulative[lo]) / span)) : 0
            let a = route[lo], b = route[lo + 1]
            return CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                          longitude: a.longitude + (b.longitude - a.longitude) * t)
        }

        // Ось коридора: концы и все вершины линии между ними.
        var axis = [point(at: start)]
        for (i, d) in cumulative.enumerated() where d > start && d < end { axis.append(route[i]) }
        axis.append(point(at: end))
        axis = axis.enumerated().filter { index, p in
            index == 0 || GeoMath.fastDistance(axis[index - 1].latitude, axis[index - 1].longitude,
                                               p.latitude, p.longitude) >= 0.5
        }.map(\.element)
        guard axis.count >= 2 else { return nil }

        // Курс подъезда — по последним метрам перед манёвром: полоса разгона
        // и карман в начале коридора направление не сбивают.
        let from = point(at: max(start, end - AppConfig.laneFocusBearingMeters))
        let to = point(at: max(start, end - AppConfig.laneFocusBearingTailMeters))
        let bearing = GeoMath.bearing(from: from, to: to)

        // Сдвиг вершин вбок — по нормали к среднему направлению соседних отрезков.
        let half = AppConfig.laneFocusHalfWidthMeters
        let lat0 = axis[0].latitude
        let kx = 111_320 * cos(lat0 * .pi / 180), ky = 111_320.0
        let xy = axis.map { ((($0.longitude - axis[0].longitude) * kx), ($0.latitude - lat0) * ky) }
        var left: [CLLocationCoordinate2D] = [], right: [CLLocationCoordinate2D] = []
        for i in xy.indices {
            let a = xy[max(0, i - 1)], b = xy[min(xy.count - 1, i + 1)]
            let dx = b.0 - a.0, dy = b.1 - a.1
            let norm = max(1e-9, (dx * dx + dy * dy).squareRoot())
            let nx = -dy / norm, ny = dx / norm          // влево от хода
            func coordinate(_ x: Double, _ y: Double) -> CLLocationCoordinate2D {
                CLLocationCoordinate2D(latitude: lat0 + y / ky, longitude: axis[0].longitude + x / kx)
            }
            left.append(coordinate(xy[i].0 + nx * half, xy[i].1 + ny * half))
            right.append(coordinate(xy[i].0 - nx * half, xy[i].1 - ny * half))
        }
        var ring = right + left.reversed()
        ring.append(ring[0])
        return Zone(ring: ring, bearing: bearing)
    }

    // MARK: - Ряд и роль стрелки

    /// Роль стрелки у манёвра в фокусе.
    enum Role: Equatable, Sendable { case ours, other }

    /// Та же проверка, что фильтр слоя на карте, — для тестов и журнала:
    /// стрелка в коридоре, смотрит по ходу подъезда — «наша» или «чужая»;
    /// вне ряда — nil (рисуется как всегда).
    static func role(_ lane: Lane, bearing: Double, at point: CLLocationCoordinate2D,
                     zone: Zone, step: Step) -> Role? {
        guard faces(bearing, zone.bearing), contains(zone.ring, point) else { return nil }
        return step.isOurs(lane) ? .ours : .other
    }

    /// Стрелка смотрит по ходу подъезда (в пределах допуска).
    static func faces(_ bearing: Double, _ approach: Double) -> Bool {
        abs((bearing - approach + 540).truncatingRemainder(dividingBy: 360) - 180)
            <= AppConfig.laneFocusBearingDegrees
    }

    /// Точка внутри кольца (луч по долготе; кольцо — короткое, плоскость).
    static func contains(_ ring: [CLLocationCoordinate2D], _ p: CLLocationCoordinate2D) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[i], b = ring[j]
            if (a.latitude > p.latitude) != (b.latitude > p.latitude) {
                let x = (b.longitude - a.longitude) * (p.latitude - a.latitude) / (b.latitude - a.latitude)
                    + a.longitude
                if p.longitude < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    // MARK: - Выражения стиля

    /// Курс стрелки (`bearing` тайла, целые градусы) в пределах допуска от
    /// курса подъезда: |((b − B + 540) mod 360) − 180| ≤ допуск — то же, что `faces`.
    static func bearingFilter(_ approach: Double) -> [Any] {
        ["<=", ["abs", ["-", ["%", ["+", ["-", ["get", "bearing"], approach], 540], 360], 180]],
         AppConfig.laneFocusBearingDegrees]
    }

    /// Код стрелки среди `codes`. Цепочка «==», а не `match` со списком:
    /// список меток NSExpression заворачивает в `literal`, и стиль бы его
    /// не принял.
    static func turnFilter(_ codes: [Int]) -> [Any] {
        ["any"] + codes.map { ["==", ["get", "turn"], $0] as [Any] }
    }

    /// «Наша» стрелка — то же, что `Step.isOurs`, языком стиля.
    static func oursFilter(_ step: Step) -> [Any] {
        let indexed: [Any] = ["all", ["has", "li"], ["has", "ln"], ["<=", ["get", "ln"], step.laneCount]]
        let byIndex: [Any] = step.lanes.isEmpty
            ? ["==", ["get", "li"], -1]
            : ["any"] + step.lanes.map { lane -> Any in
                ["all", ["==", ["get", "li"], lane.index], turnFilter(lane.codes)] as [Any]
            }
        return ["any", ["all", indexed, byIndex], ["all", ["!", indexed], turnFilter(step.codes)]]
    }
}

extension RouteService {
    /// Ряд стрелок у ближайшего манёвра выбранного маршрута — для карты
    /// (телефон и машина). Дешёвый: ≤ 8 полос и списки шагов одного маршрута;
    /// результат меняется только со сменой манёвра.
    var laneFocusStep: LaneFocus.Step? {
        LaneFocus.step(next: nextStep, steps: selected?.steps ?? [], notices: selected?.laneNotices ?? [])
    }
}
