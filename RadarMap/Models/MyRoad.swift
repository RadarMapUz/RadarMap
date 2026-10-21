//
//  MyRoad.swift
//  RadarMap
//
//  «Моя дорога» (план 19.10, 24.4): вариант маршрута домой и на работу тем
//  путём, которым водитель ездит сам. Владелец 21.10: «каждый день по своей
//  дороге возвращаюсь домой, а он предлагает другой вариант».
//
//  Почему так вышло: движок отдаёт два-три своих варианта, и привычного
//  среди них может не быть вовсе; «Знакомый» искался по трекам, а треки
//  живут неделю. Путь же водителя уже лежит на телефоне — линия варианта
//  CommuteProfile (45 дней, ≤ 600 вершин). Здесь из неё выбираются немногие
//  опорные точки (via) для обычного запроса к своему OSRM, и проверяется,
//  что вышедший маршрут — та же дорога, а не петля через опорную точку.
//
//  Правила:
//    * опорных точек немного (до 8): после поворотов линии, на отрезке, где
//      точка не ляжет на перекрёсток, и на длинных прямых — чтобы движок не
//      ушёл на параллельную улицу; не на коротких хвостах;
//    * ни одной опорной точки ближе `myRoadPrivacyMeters` к дому и к работе:
//      запрос к своему серверу маршрутов — тот же, что и всегда, но лишней
//      точки рядом с подъездом в нём быть не должно;
//    * маршрут длиннее линии на `myRoadMaxExtraShare` — отказ: так выглядит
//      разворот у опорной точки, легшей на встречную проезжую часть;
//    * вариант движка, уже идущий своей дорогой, помечается сам — второй
//      такой же не строится и не показывается;
//    * время — по своим поездкам этим путём в этот час (как у «призрака»),
//      плюс пробки толпы сверх своего обычного.
//
//  Чистая логика — MyRoadTests.
//

import CoreLocation
import Foundation
import simd

nonisolated enum MyRoad {

    /// Опорная точка запроса: где и в какую сторону по ней ехать.
    struct Via: Equatable, Sendable {
        let latitude: Double
        let longitude: Double
        /// Курс по линии, 0–359°: OSRM берёт дорогу этого направления, а не
        /// встречную проезжую часть того же проспекта.
        let bearing: Int
        /// Метров по остатку линии от точки старта.
        let along: Double

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    /// Что нужно для «Моей дороги» к этой цели.
    struct Plan: Sendable {
        let direction: Commute.Direction
        let variant: CommuteProfile.Variant
        /// Где на линии варианта начинается сегодняшний путь (проекция старта), м.
        let fromAlong: Double
        /// Насколько старт в стороне от линии, м (подъезд к ней).
        let startOffset: Double
        /// Остаток линии от проекции старта до конца.
        let line: [CLLocationCoordinate2D]
        let lineLength: Double
        let via: [Via]
        /// Сдвиг журнала точности направления (CommuteAccuracy.biasFactor,
        /// 24.2) — тот же, что у призрака в пути: «Моя дорога 26 мин» на
        /// плашке и прибытие по дороге не должны расходиться.
        var bias: Double = 1

        /// Поездок этим путём в профиле (45 дней).
        var trips: Int { variant.rows.count }
    }

    /// Время своей дорогой «сейчас»: обычное в этот час плюс пробки сверх него.
    struct Estimate: Equatable, Sendable {
        let seconds: TimeInterval
        let jamSeconds: TimeInterval
    }

    // MARK: - Цель

    /// Цель — дом или работа: ближе `myRoadPlaceMeters` к одному из них.
    /// Оба рядом — тот, что ближе.
    static func direction(destination: CLLocationCoordinate2D,
                          home: CLLocationCoordinate2D, work: CLLocationCoordinate2D) -> Commute.Direction? {
        let toHome = GeoMath.fastDistance(destination.latitude, destination.longitude, home.latitude, home.longitude)
        let toWork = GeoMath.fastDistance(destination.latitude, destination.longitude, work.latitude, work.longitude)
        let limit = AppConfig.myRoadPlaceMeters
        if toHome <= limit, toHome <= toWork { return .toHome }
        if toWork <= limit { return .toWork }
        return nil
    }

    // MARK: - План

    /// План для маршрута `source → destination` по вариантам направления:
    /// вариант с `myRoadMinRows` поездками, кончающийся у цели, со стартом
    /// не дальше `myRoadStartMeters` от линии. Из нескольких — где поездок
    /// больше (обычнее), при равенстве — недавний. nil — своей дороги нет.
    static func plan(variants: [CommuteProfile.Variant], direction: Commute.Direction,
                     source: CLLocationCoordinate2D, destination: CLLocationCoordinate2D,
                     home: CLLocationCoordinate2D, work: CLLocationCoordinate2D) -> Plan? {
        let usable = variants.filter { variant in
            guard variant.rows.count >= AppConfig.myRoadMinRows, variant.line.count >= 4,
                  let end = variant.coordinates.last else { return false }
            return GeoMath.fastDistance(end.latitude, end.longitude, destination.latitude, destination.longitude)
                <= AppConfig.commuteRouteFinishMeters
        }.sorted { a, b in
            a.rows.count != b.rows.count ? a.rows.count > b.rows.count : a.lastUsed > b.lastUsed
        }
        for variant in usable {
            let coordinates = variant.coordinates
            let frame = CommuteProfile.Frame(latitude: coordinates[0].latitude)
            let xy = coordinates.map { frame.xy($0.latitude, $0.longitude) }
            let start = project(frame.xy(source.latitude, source.longitude), onto: xy)
            guard start.offset <= AppConfig.myRoadStartMeters else { continue }
            let rest = tail(of: xy, from: start)
            let length = CommuteProfile.Geometry.length(rest)
            guard length >= AppConfig.myRoadMinLineMeters else { continue }
            let avoid = [home, work].map { frame.xy($0.latitude, $0.longitude) }
            let via = viaPoints(rest, avoid: avoid).map { point in
                let c = frame.coordinate(point.point)
                return Via(latitude: c.latitude, longitude: c.longitude,
                           bearing: point.bearing, along: point.along)
            }
            return Plan(direction: direction, variant: variant, fromAlong: start.along,
                        startOffset: start.offset, line: rest.map(frame.coordinate),
                        lineLength: length, via: via)
        }
        return nil
    }

    /// Ближайшая точка линии: пройденное по ней, отклонение и сегмент.
    static func project(_ p: SIMD2<Double>, onto line: [SIMD2<Double>])
        -> (along: Double, offset: Double, segment: Int, point: SIMD2<Double>) {
        var best = (along: 0.0, offset: Double.infinity, segment: 0, point: line.first ?? p)
        var walked = 0.0
        for i in 0..<max(0, line.count - 1) {
            let (q, f) = CommuteProfile.Geometry.nearest(p, line[i], line[i + 1])
            let step = simd_distance(line[i], line[i + 1])
            let offset = simd_distance(p, q)
            if offset < best.offset { best = (walked + f * step, offset, i, q) }
            walked += step
        }
        return best
    }

    /// Линия от проекции старта до конца.
    static func tail(of line: [SIMD2<Double>],
                     from start: (along: Double, offset: Double, segment: Int, point: SIMD2<Double>))
        -> [SIMD2<Double>] {
        guard line.count >= 2 else { return line }
        var rest = [start.point]
        for p in line[(start.segment + 1)...] where simd_distance(p, rest[rest.count - 1]) > 0.5 {
            rest.append(p)
        }
        return rest
    }

    // MARK: - Перестроение

    /// Своя дорога для перестроения (ревью 24.4): ушли с маршрута, выбранного
    /// как «Моя дорога», — новый маршрут ведёт через ОСТАВШИЕСЯ впереди
    /// опорные точки той же линии, а не движком, который и вёл бы по дороге,
    /// на которую жаловались. Пройденные по проекции точки отброшены;
    /// ближайшая впереди — тоже, если до неё меньше `myRoadRerouteSkipMeters`
    /// (на неё уже не успеть вырулить без петли) или она позади по курсу.
    /// nil — точек не осталось или машина ушла от линии дальше
    /// `myRoadStartMeters`: тогда перестраивает движок.
    static func remaining(_ plan: Plan, from position: CLLocationCoordinate2D,
                          course: CLLocationDirection = -1) -> Plan? {
        guard plan.line.count >= 2 else { return nil }
        let frame = CommuteProfile.Frame(latitude: plan.line[0].latitude)
        let xy = plan.line.map { frame.xy($0.latitude, $0.longitude) }
        let car = frame.xy(position.latitude, position.longitude)
        let here = project(car, onto: xy)
        guard here.offset <= AppConfig.myRoadStartMeters else { return nil }
        var ahead = plan.via.filter { $0.along > here.along }
        if let first = ahead.first {
            let toVia = frame.xy(first.latitude, first.longitude) - car
            let close = simd_length(toVia) < AppConfig.myRoadRerouteSkipMeters
            var behind = false
            if course >= 0, course.isFinite, simd_length(toVia) > 0 {
                let diff = abs((Double(bearing(toVia)) - course + 540).truncatingRemainder(dividingBy: 360) - 180)
                behind = diff > AppConfig.myRoadRerouteBehindDegrees
            }
            if close || behind { ahead.removeFirst() }
        }
        guard !ahead.isEmpty else { return nil }
        let rest = tail(of: xy, from: here)
        return Plan(direction: plan.direction, variant: plan.variant, fromAlong: plan.fromAlong + here.along,
                    startOffset: here.offset, line: rest.map(frame.coordinate),
                    lineLength: CommuteProfile.Geometry.length(rest),
                    via: ahead.map { Via(latitude: $0.latitude, longitude: $0.longitude,
                                         bearing: $0.bearing, along: $0.along - here.along) })
    }

    // MARK: - Опорные точки

    /// Опорные точки на линии (в метрах плоской проекции), по ходу движения.
    ///
    /// Кандидаты двух родов. После поворота линии (`myRoadViaTurnDegrees`) —
    /// на `myRoadViaAfterTurnMeters` дальше вершины, на отрезке не короче
    /// `myRoadViaMinLegMeters`: сама вершина — перекрёсток, и точка на нём
    /// легла бы на поперечную улицу. На длинной прямой — посередине: иначе
    /// между поворотами движок волен уйти на параллельную улицу. Отбор —
    /// сначала самые крутые повороты, затем самые длинные прямые, с
    /// интервалом `myRoadViaSpacingMeters` и не больше `myRoadViaMax`.
    static func viaPoints(_ raw: [SIMD2<Double>], avoid: [SIMD2<Double>])
        -> [(point: SIMD2<Double>, bearing: Int, along: Double)] {
        let line = CommuteProfile.Geometry.simplify(raw, tolerance: AppConfig.myRoadViaSimplifyMeters,
                                                    maxPoints: AppConfig.commuteProfileMaxVertices)
        guard line.count >= 2 else { return [] }
        var cumulative: [Double] = [0]
        for (a, b) in zip(line, line.dropFirst()) { cumulative.append(cumulative[cumulative.count - 1] + simd_distance(a, b)) }
        let total = cumulative[cumulative.count - 1]
        let edge = AppConfig.myRoadViaEdgeMeters

        struct Candidate { let point: SIMD2<Double>; let bearing: Int; let along: Double; let rank: Double }
        func allowed(_ p: SIMD2<Double>, _ along: Double) -> Bool {
            along >= edge && along <= total - edge
                && avoid.allSatisfy { simd_distance($0, p) >= AppConfig.myRoadPrivacyMeters }
        }

        // Повороты: ранг — угол (до 180), выше любой прямой.
        var turns: [Candidate] = []
        for i in 1..<max(1, line.count - 1) {
            let incoming = line[i] - line[i - 1], outgoing = line[i + 1] - line[i]
            let outLength = simd_length(outgoing)
            guard simd_length(incoming) > 0, outLength >= AppConfig.myRoadViaMinLegMeters else { continue }
            let turn = abs(angle(incoming, outgoing))
            guard turn >= AppConfig.myRoadViaTurnDegrees else { continue }
            let shift = min(AppConfig.myRoadViaAfterTurnMeters, outLength / 2)
            let point = line[i] + outgoing / outLength * shift
            let along = cumulative[i] + shift
            guard allowed(point, along) else { continue }
            turns.append(Candidate(point: point, bearing: bearing(outgoing), along: along, rank: 1000 + turn))
        }
        // Длинные прямые: середина отрезка, ранг — длина.
        var straights: [Candidate] = []
        for i in 0..<(line.count - 1) {
            let segment = line[i + 1] - line[i]
            let length = simd_length(segment)
            guard length >= AppConfig.myRoadViaStraightMeters else { continue }
            let point = line[i] + segment * 0.5
            let along = cumulative[i] + length / 2
            guard allowed(point, along) else { continue }
            straights.append(Candidate(point: point, bearing: bearing(segment), along: along, rank: length))
        }

        var picked: [Candidate] = []
        for candidate in (turns + straights).sorted(by: { $0.rank > $1.rank }) {
            guard picked.count < AppConfig.myRoadViaMax else { break }
            guard picked.allSatisfy({ abs($0.along - candidate.along) >= AppConfig.myRoadViaSpacingMeters })
            else { continue }
            picked.append(candidate)
        }
        return picked.sorted { $0.along < $1.along }.map { ($0.point, $0.bearing, $0.along) }
    }

    /// Поворот от `a` к `b`, градусы со знаком (−180…180].
    static func angle(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let cross = a.x * b.y - a.y * b.x
        let dot = simd_dot(a, b)
        return atan2(cross, dot) * 180 / .pi
    }

    /// Курс вектора плоской проекции (x — восток, y — север), 0–359°.
    static func bearing(_ v: SIMD2<Double>) -> Int {
        let degrees = atan2(v.x, v.y) * 180 / .pi
        return (Int(degrees.rounded()) % 360 + 360) % 360
    }

    // MARK: - Тот же путь

    /// Маршрут через опорные точки годится: не длиннее линии (с подъездом)
    /// больше чем на `myRoadMaxExtraShare` — иначе это разворот или петля у
    /// опорной точки — и идёт по ней в обе стороны (`commuteRouteOverlap`).
    static func accepts(distance: CLLocationDistance, path: [CLLocationCoordinate2D], plan: Plan) -> Bool {
        let expected = plan.lineLength + plan.startOffset
        guard expected > 0, distance <= expected * (1 + AppConfig.myRoadMaxExtraShare) else { return false }
        return follows(path, plan.line)
    }

    /// Вариант движка, который и так идёт своей дорогой (перекрытие в обе
    /// стороны не меньше `commuteRouteOverlap`): помечаем его, второй не
    /// строим. Несколько — где перекрытие больше.
    static func matching(_ paths: [[CLLocationCoordinate2D]], plan: Plan) -> Int? {
        var best: (index: Int, score: Double)?
        for (index, path) in paths.enumerated() {
            let there = DetourAdvisor.overlap(path, with: plan.line)
            guard there >= AppConfig.commuteRouteOverlap else { continue }
            let back = DetourAdvisor.overlap(plan.line, with: path)
            guard back >= AppConfig.commuteRouteOverlap else { continue }
            if best.map({ there + back > $0.score }) ?? true { best = (index, there + back) }
        }
        return best?.index
    }

    static func follows(_ path: [CLLocationCoordinate2D], _ line: [CLLocationCoordinate2D]) -> Bool {
        DetourAdvisor.overlap(path, with: line) >= AppConfig.commuteRouteOverlap
            && DetourAdvisor.overlap(line, with: path) >= AppConfig.commuteRouteOverlap
    }

    /// Мест для вариантов `myRoadMaxVariants`: своя дорога встаёт на место
    /// самого долгого из вариантов движка (`times` — с пробками). nil —
    /// место есть, вытеснять никого не нужно.
    static func slotToFree(times: [TimeInterval], limit: Int = AppConfig.myRoadMaxVariants) -> Int? {
        guard times.count >= limit, let slowest = times.indices.max(by: { times[$0] < times[$1] }) else { return nil }
        return slowest
    }

    // MARK: - Время

    /// Своя дорога от точки старта «сейчас»: своё время этим путём в этот
    /// час — та же база, что у призрака в пути и «сейчас ~44 мин» (24.2:
    /// строки по близости выезда, поправка на светофоры, наклон по выезду,
    /// сдвиг журнала `plan.bias`; медиана всего дня в три ночи — не
    /// «сейчас»), плюс пробки толпы заметно хуже своей медианы и подъезд к
    /// линии медленным ходом. nil — у часа нет трёх поездок.
    static func estimate(_ plan: Plan, now: Date, snapshot: TrafficSnapshot?,
                         calendar: Calendar = .current) -> Estimate? {
        let variant = plan.variant
        guard let selected = CommuteGhost.select(variant.rows, weekend: UzHolidays.isDayOff(now, calendar: calendar),
                                                 departure: now, calendar: calendar),
              selected.tier < .allDay,
              let base = CommuteGhost.calibratedBaseline(variant, selection: selected, bias: plan.bias)
        else { return nil }
        var jam = 0.0
        if let snapshot, snapshot.isFresh(now: now) {
            let crowd = CommuteEstimate.crowdSeconds(line: variant.coordinates, base: base, snapshot: snapshot)
            jam = CommuteEstimate.jamExtra(base, crowd: crowd, from: base.locate(plan.fromAlong).segment)
        }
        let approach = plan.startOffset / AppConfig.myRoadApproachSpeedMps
        return Estimate(seconds: base.usualRemaining(at: plan.fromAlong) + jam + approach, jamSeconds: jam)
    }
}
