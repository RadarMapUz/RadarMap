//
//  RoadWeatherAlert.swift
//  RadarMap
//
//  «На перевале Камчик туман» — одна спокойная фраза и баннер за 20–40 км
//  до опасного места (план 20.10, 19.2).
//
//  Снег и туман на перевале — самый опасный момент дальней поездки, а связь
//  там пропадает. Сказать нужно заранее и один раз:
//    * с маршрутом — точки не дальше `roadWeatherRouteMeters` от линии
//      маршрута ВПЕРЕДИ, расстояние — по маршруту;
//    * без маршрута — только на трассе (детектор город/трасса), на ходу и с
//      доверенным курсом: точка по ходу в узком коридоре, как у «впереди
//      пробка» (JamAhead), только длиннее — коридор расширяется с дальностью;
//    * окно — до `roadWeatherAnnounceMeters.upperBound` (40 км: на трассе это
//      25–30 минут); обычно фраза звучит в 20–40 км. Ближе 20 км (маршрут
//      построен у самого перевала, данные пришли поздно) — тоже, один раз:
//      поздно, но не молча. Внутри самого участка — молчим: туман водитель
//      уже видит;
//    * одна фраза на перевал за поездку (группа точек), и только об
//      опасности, которая застанет водителя (идёт сейчас или начнётся в
//      ближайший час);
//    * данные старше двух часов — молчим;
//    * камера впереди — ждём: о камере говорят первой, а погода подождёт,
//      пока камеру проедем (то же правило, что у событий дороги).
//
//  Тон — как у треног и пробок, а не как у камер: это прогноз, и уверенно
//  сказанное о неточном стоит доверия. Поэтому сомнение (нет курса, не трасса,
//  нет данных) — молчание. Ни расстояния до метра, ни «срочно».
//
//  Чистая логика, время — параметром; покрыто RoadWeatherAlertTests.
//

import CoreLocation
import Foundation

nonisolated enum RoadWeatherAlert {

    /// Всё, что движку нужно знать о машине.
    struct Situation: Sendable {
        let position: CLLocationCoordinate2D
        /// Курс, 0…360; < 0 — не доверяем (LocationFilter).
        let course: CLLocationDirection
        let speedKmh: Double
        /// Детектор город/трасса говорит «трасса».
        let onHighway: Bool
        /// Линия маршрута впереди от машины; nil — едем без маршрута.
        let pathAhead: [CLLocationCoordinate2D]?
    }

    /// Что сказать и показать.
    struct Notice: Equatable, Sendable {
        /// Группа точек: о перевале — одна фраза за поездку.
        let key: String
        /// Ближайшая опасная точка группы по пути.
        let pointID: String
        /// Опасности по важности, не больше двух: «гололёд и снег».
        let hazards: [RoadWeatherPoint.Hazard]
        /// До неё по пути (без маршрута — по прямой вдоль курса), м.
        let distance: CLLocationDistance
        let name: RoadWeatherPoint.Text
        let place: RoadWeatherPoint.Text
        /// Ближе обычного окна (< 20 км) — сказано поздно.
        let isLate: Bool
    }

    enum Outcome: Equatable, Sendable {
        /// Сказать нечего.
        case silent
        /// Есть что сказать, но впереди камера: спросить снова на следующем фиксе.
        case wait(Notice)
        case announce(Notice)
    }

    /// Решение на этот фикс.
    static func decide(snapshot: RoadWeatherSnapshot?, situation: Situation, cameraBusy: Bool,
                       voiced: Set<String>, now: Date) -> Outcome {
        guard let snapshot, snapshot.isFresh(now: now) else { return .silent }
        // Ближайшая по пути опасная точка каждой группы; опасности группы —
        // со всех её опасных точек впереди: туман на подъезде и гололёд у
        // тоннеля — одна фраза о перевале, а не две.
        var groups: [String: (point: RoadWeatherPoint, along: Double, hazards: Set<RoadWeatherPoint.Hazard>)] = [:]
        for point in snapshot.points where !voiced.contains(point.group) {
            let hazards = point.hazards(at: now)
            guard !hazards.isEmpty, let along = self.along(to: point, situation: situation),
                  // Внутри участка точки водитель уже в нём — туман он видит.
                  along > point.radius else { continue }
            if let current = groups[point.group] {
                let nearer = along < current.along
                groups[point.group] = (nearer ? point : current.point, min(along, current.along),
                                       current.hazards.union(hazards))
            } else {
                groups[point.group] = (point, along, hazards)
            }
        }
        let window = AppConfig.roadWeatherAnnounceMeters
        // Дальше окна — рано: скажем, когда доедем до 40 км.
        guard let best = groups.values.filter({ $0.along <= window.upperBound })
            .min(by: { $0.along < $1.along }) else { return .silent }
        let notice = Notice(key: best.point.group, pointID: best.point.id,
                            hazards: Array(best.hazards.sorted().prefix(2)),
                            distance: best.along, name: best.point.name, place: best.point.place,
                            isLate: best.along < window.lowerBound)
        return cameraBusy ? .wait(notice) : .announce(notice)
    }

    /// Сколько до точки по нашему пути; nil — не на пути, позади или не знаем.
    static func along(to point: RoadWeatherPoint, situation: Situation) -> CLLocationDistance? {
        if let path = situation.pathAhead {
            return alongRoute(path, to: point.coordinate)
        }
        // Без маршрута — только трасса, ход и доверенный курс: в городе по
        // прямой «впереди» оказывается полстраны, а стоя курс — шум.
        guard situation.onHighway, situation.course >= 0, situation.course.isFinite,
              situation.speedKmh >= AppConfig.roadWeatherCorridorMinKmh else { return nil }
        let fix = RoadCorridor.fix(from: situation.position, course: situation.course, to: point.coordinate)
        guard fix.along > 0,
              fix.across <= AppConfig.roadWeatherCorridorMeters + fix.along * AppConfig.roadWeatherCorridorSlope
        else { return nil }
        return fix.along
    }

    /// Расстояние вдоль линии до ближайшего к точке места, если линия проходит
    /// не дальше `roadWeatherRouteMeters` от неё. Линия — уже «впереди»: то,
    /// что позади, сюда не входит. Длина линии — окно плюс
    /// `roadWeatherGroupSpanMeters`: дальние точки того же перевала попадают
    /// в ту же фразу.
    static func alongRoute(_ path: [CLLocationCoordinate2D], to target: CLLocationCoordinate2D) -> CLLocationDistance? {
        guard path.count >= 2 else { return nil }
        var travelled: CLLocationDistance = 0
        var best: (offset: Double, along: Double)?
        for index in 0..<(path.count - 1) {
            let a = path[index], b = path[index + 1]
            let length = GeoMath.fastDistance(a.latitude, a.longitude, b.latitude, b.longitude)
            let (offset, t) = project(target, a, b)
            if offset <= AppConfig.roadWeatherRouteMeters, best.map({ offset < $0.offset }) ?? true {
                best = (offset, travelled + t * length)
            }
            travelled += length
        }
        return best?.along
    }

    /// Расстояние от точки до отрезка и доля отрезка до проекции (0…1).
    /// Локальная проекция — отрезки маршрута короткие.
    static func project(_ p: CLLocationCoordinate2D, _ a: CLLocationCoordinate2D,
                        _ b: CLLocationCoordinate2D) -> (distance: Double, t: Double) {
        let kx = 111_320 * cos(p.latitude * .pi / 180), ky = 110_540.0
        let ax = (a.longitude - p.longitude) * kx, ay = (a.latitude - p.latitude) * ky
        let bx = (b.longitude - p.longitude) * kx, by = (b.latitude - p.latitude) * ky
        let dx = bx - ax, dy = by - ay
        let lengthSquared = dx * dx + dy * dy
        let t = lengthSquared > 0 ? max(0, min(1, -(ax * dx + ay * dy) / lengthSquared)) : 0
        let x = ax + t * dx, y = ay + t * dy
        return ((x * x + y * y).squareRoot(), t)
    }
}

// MARK: - Слова

/// Фраза и баннер — на главном потоке: Formatting знает язык приложения.
extension RoadWeatherAlert.Notice {
    /// Язык приложения — тот же, что у переведённых строк.
    static var isUzbek: Bool { Bundle.main.preferredLocalizations.first == "uz" }

    /// «туман», «гололёд и снег».
    var hazardsText: String {
        let words = hazards.map(\.word)
        guard words.count >= 2 else { return words.first ?? "" }
        return String(format: String(localized: "%1$@ и %2$@"), words[0], words[1])
    }

    /// «На перевале Камчик туман».
    var spoken: String { "\(place.value(uzbek: Self.isUzbek)) \(hazardsText)" }

    /// «Перевал Камчик».
    var title: String { name.value(uzbek: Self.isUzbek) }

    /// «Туман · через 32 км».
    var subtitle: String {
        let text = hazardsText
        let capitalized = text.prefix(1).uppercased() + text.dropFirst()
        // Целые километры: «через 32 км», а не «32,0 км» — до перевала
        // десятки километров, и десятые там шум.
        let km = Formatting.unbreakable(String(format: String(localized: "%@ км"),
                                               String(max(1, Int((distance / 1000).rounded())))))
        return String(format: String(localized: "%1$@ · через %2$@"), capitalized, km)
    }

    /// Значок главной опасности — один для телефона и машины.
    var symbol: String { hazards.first?.symbol ?? "cloud.fill" }
}

extension RoadWeatherPoint.Hazard {
    var word: String {
        switch self {
        case .ice:  return String(localized: "гололёд")
        case .snow: return String(localized: "снег")
        case .fog:  return String(localized: "туман")
        case .wind: return String(localized: "сильный ветер")
        }
    }

    var symbol: String {
        switch self {
        case .ice:  return "thermometer.snowflake"
        case .snow: return "cloud.snow.fill"
        case .fog:  return "cloud.fog.fill"
        case .wind: return "wind"
        }
    }
}
