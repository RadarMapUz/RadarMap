//
//  LegacyLimitIndex.swift
//  RadarMapTests
//
//  Эталон «до» для LimitIndexEquivalenceTests (пакет памяти 2.19).
//

import CoreLocation
import Foundation
import MapKit
@testable import RadarMap

/// Замороженная копия LimitIndex до пакета памяти 2.19 (main, 20.10) — эталон
/// для теста совпадения результатов. Не трогать: он и есть «до».
struct LegacyLimitIndex: Sendable {
    struct Segment: Sendable {
        let limit: Int
        /// Класс дороги. `.unknown` у файла формата 1 — там его просто нет.
        let cls: RoadClass
        let pts: [MKMapPoint]
        /// Рамка сегмента в единицах MKMapPoint.
        ///
        /// Ячейка грида — 1,1 км, а совпадением считается 35 м: почти всё, что
        /// попало в кольцо ячеек, до дороги под колесом не дотягивается. Без
        /// рамки `match` обходил ВСЕ пары точек ВСЕХ сегментов кольца — в
        /// плотном центре это тысячи пар на каждом GPS-тике. Рамка отсекает
        /// сегмент четырьмя сравнениями, до того как начнётся геометрия.
        let minX, minY, maxX, maxY: Double

        init(limit: Int, cls: RoadClass = .unknown, pts: [MKMapPoint]) {
            self.limit = limit
            self.cls = cls
            self.pts = pts
            var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
            var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
            for point in pts {
                minX = min(minX, point.x); maxX = max(maxX, point.x)
                minY = min(minY, point.y); maxY = max(maxY, point.y)
            }
            self.minX = minX; self.minY = minY
            self.maxX = maxX; self.maxY = maxY
        }

        /// Может ли эта дорога оказаться ближе `reach` (в единицах MKMapPoint).
        func mayReach(_ p: MKMapPoint, within reach: Double) -> Bool {
            p.x >= minX - reach && p.x <= maxX + reach
                && p.y >= minY - reach && p.y <= maxY + reach
        }
    }

    let segments: [Segment]
    let grid: [Int: [Int32]]   // ячейка 0.01° → индексы сегментов

    // MARK: - Дороги для схемы на приборке

    /// Индекс лимитов — по совместительству ЕДИНСТВЕННАЯ дорожная геометрия,
    /// которая уже лежит на телефоне: 21 558 сегментов, 183 483 точки, офлайн.
    /// Мы качали его ради матчинга лимита, а он несёт настоящие линии дорог —
    /// с перекрёстками и развязками. Первый источник для RoadSketch, пока не
    /// собран собственный roads.json (см. RoadNetwork.swift).
    ///
    /// Чего этот источник НЕ знает: класса дороги, моста, односторонности —
    /// в файле их нет. Поэтому все линии помечены как «без подробностей», и
    /// вью рисует их ровно, не выдавая догадку за измеренное.
    func roads(near coordinate: CLLocationCoordinate2D,
               radius: CLLocationDistance) -> [RoadLine] {
        // Ячейка грида 0.01° ≈ 1,1 км — берём кольцо ячеек по радиусу.
        let span = max(1, Int((radius / 1100).rounded(.up)))
        let centerLat = Int((coordinate.latitude + 90) * 100)
        let centerLon = Int((coordinate.longitude + 180) * 100)

        var seen = Set<Int32>()
        for latCell in (centerLat - span)...(centerLat + span) {
            for lonCell in (centerLon - span)...(centerLon + span) {
                if let found = grid[latCell * 40_000 + lonCell] { seen.formUnion(found) }
            }
        }
        guard !seen.isEmpty else { return [] }

        let origin = MKMapPoint(coordinate)
        // Радиус в единицах MKMapPoint, и сравниваем КВАДРАТЫ — в тех же
        // единицах, что и точки сегмента.
        //
        // Здесь была путаница в единицах: `MKMapPoint.distance` возвращает
        // МЕТРЫ, а сравнивали его с радиусом, уже переведённым в единицы карты.
        // На широте Ташкента это множитель ~8,8 — «дороги в радиусе 570 м»
        // отдавались в радиусе пяти километров. Схема потом всё равно обрезала
        // их своим масштабом, поэтому на экране это не проявлялось: просто
        // каждая пересборка тащила в несколько раз больше геометрии, чем
        // просила, и делала это на телефоне в держателе.
        let limitSquared = Self.points(radius, at: coordinate) * Self.points(radius, at: coordinate)
        func within(_ point: MKMapPoint) -> Bool {
            let dx = point.x - origin.x, dy = point.y - origin.y
            return dx * dx + dy * dy <= limitSquared
        }
        let reach = Self.points(radius, at: coordinate)
        return seen.compactMap { index -> RoadLine? in
            let segment = segments[Int(index)]
            guard segment.mayReach(origin, within: reach) else { return nil }
            // Точки за радиусом отбрасываем, но линию не рвём: берём кусок от
            // первой до последней попавшей — иначе дорога рассыпалась бы на
            // обрывки там, где она просто длинная.
            guard let first = segment.pts.firstIndex(where: within),
                  let last = segment.pts.lastIndex(where: within),
                  last > first else { return nil }
            return RoadLine(points: segment.pts[first...last].map(\.coordinate))
        }
    }

    nonisolated private static func cellKey(lat: Double, lon: Double) -> Int {
        let latCell = Int((lat + 90) * 100)
        let lonCell = Int((lon + 180) * 100)
        return latCell * 40_000 + lonCell
    }

    nonisolated static func build(from data: Data) -> LegacyLimitIndex? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["segments"] as? [[Any]] else {
            Log.route.error("speed_limits.json: неожиданный формат")
            return nil
        }

        var segments: [Segment] = []
        segments.reserveCapacity(raw.count)
        var grid: [Int: [Int32]] = [:]

        for entry in raw {
            // Границы значения — второй забор после подписи. Подписанный
            // индекс (LimitsTrust, server/publish_limits.sh) гарантирует, что
            // файл собрал владелец, но не что OSM прав; а на переходный путь,
            // пока подписанного индекса телефон не видел, этот забор — вообще
            // единственная защита: файл приходит по HTTPS, но без подписи.
            // Явно отвергаем невозможные лимиты: в Узбекистане минимум 20
            // (дворы), максимум 110–130, и «5» с «300» означают испорченные
            // данные, а не дорогу. Отвергаем СЕГМЕНТ, а не файл: один битый
            // лимит не должен выключить двадцать тысяч честных.
            // Форматов ДВА. Первый — [limit, geometry], он остаётся на бою для
            // уже установленных приложений. Второй — [limit, cls, geometry]:
            // без класса дороги лимит это половина ответа, потому что отличить
            // проспект от идущего вдоль него дублёра больше нечем.
            guard let limit = (entry.first as? NSNumber)?.intValue,
                  AppConfig.plausibleSpeedLimits.contains(limit),
                  let flat = entry.last as? [NSNumber], flat.count >= 4,
                  entry.count == 2 || entry.count == 3 else { continue }
            let cls: RoadClass = entry.count == 3
                ? RoadClass(code: (entry[1] as? NSNumber)?.intValue ?? 0)
                : .unknown

            var pts: [MKMapPoint] = []
            pts.reserveCapacity(flat.count / 2)
            let segmentIndex = Int32(segments.count)
            var cells = Set<Int>()

            var previous: (lat: Double, lon: Double)?
            for i in stride(from: 0, to: flat.count - 1, by: 2) {
                let lat = flat[i].doubleValue, lon = flat[i + 1].doubleValue
                pts.append(MKMapPoint(CLLocationCoordinate2D(latitude: lat, longitude: lon)))
                cells.insert(cellKey(lat: lat, lon: lon))
                // Длинные прямые перегоны: отмечаем и промежуточные ячейки (шаг ~0.005°).
                if let p = previous {
                    let steps = Int(max(abs(lat - p.lat), abs(lon - p.lon)) / 0.005)
                    if steps > 1 {
                        for s in 1..<steps {
                            let f = Double(s) / Double(steps)
                            cells.insert(cellKey(lat: p.lat + (lat - p.lat) * f,
                                                 lon: p.lon + (lon - p.lon) * f))
                        }
                    }
                }
                previous = (lat, lon)
            }
            segments.append(Segment(limit: limit, cls: cls, pts: pts))
            for cell in cells { grid[cell, default: []].append(segmentIndex) }
        }
        return segments.isEmpty ? nil : LegacyLimitIndex(segments: segments, grid: grid)
    }

    /// Кандидаты кольца 3×3 ячеек вокруг точки. Один сегмент лежит в нескольких
    /// ячейках, поэтому Set: без него длинный проспект перебирался бы девять раз.
    nonisolated private func candidates(around coordinate: CLLocationCoordinate2D) -> Set<Int32> {
        var found = Set<Int32>()
        for dLat in -1...1 {
            for dLon in -1...1 {
                let key = Self.cellKey(lat: coordinate.latitude + Double(dLat) * 0.01,
                                       lon: coordinate.longitude + Double(dLon) * 0.01)
                if let list = grid[key] { found.formUnion(list) }
            }
        }
        return found
    }

    /// Найденная дорога: лимит, ближайшая точка ПОЛОТНА и его направление.
    ///
    /// Точка и азимут нужны снапу картинки к дороге (RoadSnapper): тот же
    /// проход, что ищет лимит, отдаёт их бесплатно — второй запрос по кольцу
    /// на каждом тике стоил бы столько же, сколько сам матчинг.
    struct RoadHit: Sendable {
        let limit: Int
        /// Класс дороги, чей лимит взят. `.unknown` — файл формата 1 (класса в
        /// нём нет ни у кого) либо вызов, которому класс не нужен вовсе.
        var cls: RoadClass = .unknown
        /// Ближайшая точка оси дороги.
        let coordinate: CLLocationCoordinate2D
        /// Направление сегмента в этой точке (0–360°, куда «идёт» линия;
        /// дорога двусторонняя — потребитель сам выбирает ближнюю из двух).
        let bearingDegrees: Double
        /// Насколько мы в стороне от оси, метры.
        let distanceMeters: Double
    }

    /// Ближайшая дорога кольца.
    ///
    /// Общее тело для `match` и `limit(near:)` — они обязаны сходиться в том,
    /// какую дорогу считают ближайшей, а раньше это были две копии одного
    /// цикла, расходившиеся при каждой правке.
    ///
    /// Считаем в КВАДРАТАХ единиц карты, а не в метрах: `MKMapPoint.distance`
    /// на каждую пару точек — это корень и пересчёт масштаба по широте, а нам
    /// нужно только сравнить, что ближе. Порядок сравнений от этого не меняется
    /// (масштаб внутри кольца постоянен), а метры остаются только на границе.
    /// `prefersMajorRoads` — победитель выбирается не по одной близости.
    ///
    /// Вдоль ташкентского проспекта идёт дублёр: он параллелен, значит
    /// проходит проверку направления, и при сносе GPS на пару метров он ближе.
    /// Лимит при этом берётся ЕГО — а у проспекта тега maxspeed может не быть
    /// вовсе. Поэтому к расстоянию прибавляется цена класса: проспект в
    /// двадцати метрах перебивает дублёр в пятнадцати, но служебный проезд ПОД
    /// колесом перебивает проспект в двадцати — иначе получим зеркальную
    /// ошибку и будем считать лимит проспекта во дворе.
    ///
    /// Корень берётся один раз на СЕГМЕНТ, а не на пару точек: внутренний цикл
    /// остаётся на квадратах, как и был (бюджет тика ~0,11 мс).
    nonisolated private func nearestRoad(
        to p: MKMapPoint, within reach: Double, candidates: Set<Int32>,
        prefersMajorRoads: Bool = false,
        accepts: (_ dx: Double, _ dy: Double) -> Bool
    ) -> RoadHit? {
        let reachSquared = reach * reach
        let unit = Self.points(1, at: p.coordinate)
        var bestScore = Double.greatestFiniteMagnitude
        var best: (limit: Int, cls: RoadClass, point: MKMapPoint,
                   dx: Double, dy: Double, distance: Double)?
        for candidate in candidates {
            let segment = segments[Int(candidate)]
            // Рамка: четыре сравнения вместо обхода всех точек сегмента.
            guard segment.mayReach(p, within: reach) else { continue }
            // Тротуар и переход — не проезжая часть, и их maxspeed не про нас.
            if prefersMajorRoads, segment.cls == .pedestrian { continue }
            var localSquared = reachSquared
            var local: (point: MKMapPoint, dx: Double, dy: Double)?
            let pts = segment.pts
            for i in 0..<(pts.count - 1) {
                let a = pts[i], b = pts[i + 1]
                // Ближайшая точка на отрезке AB.
                let dx = b.x - a.x, dy = b.y - a.y
                let len2 = dx * dx + dy * dy
                guard len2 > 0 else { continue }
                let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
                let closest = MKMapPoint(x: a.x + t * dx, y: a.y + t * dy)
                let ox = closest.x - p.x, oy = closest.y - p.y
                let squared = ox * ox + oy * oy
                guard squared < localSquared else { continue }
                guard accepts(dx, dy) else { continue }
                localSquared = squared
                local = (closest, dx, dy)
            }
            guard let local else { continue }
            let distance = localSquared.squareRoot()
            let score = distance + (prefersMajorRoads ? Self.classPenalty(segment.cls) * unit : 0)
            guard score < bestScore else { continue }
            bestScore = score
            best = (segment.limit, segment.cls, local.point, local.dx, local.dy, distance)
        }
        guard let best else { return nil }
        let coordinate = best.point.coordinate
        // Меркатор конформен: азимут корректен прямо из map-точек (y растёт на юг).
        let bearing = (atan2(best.dx, -best.dy) * 180 / .pi + 360)
            .truncatingRemainder(dividingBy: 360)
        return RoadHit(limit: best.limit, cls: best.cls, coordinate: coordinate,
                       bearingDegrees: bearing,
                       distanceMeters: best.distance
                           * MKMetersPerMapPointAtLatitude(coordinate.latitude))
    }

    /// Цена класса в метрах: насколько дальше может лежать дорога, чтобы всё
    /// равно победить. Ноль у магистральных — они и есть предпочтительный
    /// ответ; дороже всего служебный проезд, который чаще всего и оказывался
    /// ближайшим вдоль проспекта.
    nonisolated private static func classPenalty(_ cls: RoadClass) -> Double {
        switch cls {
        case .motorway, .trunk, .primary, .secondary: return 0
        case .tertiary, .residential:                 return AppConfig.limitMinorRoadPenaltyMeters
        case .service, .pedestrian:                   return AppConfig.limitServiceRoadPenaltyMeters
        // Формат 1: класса нет ни у кого, значит штраф одинаковый и порядок
        // прежний — правка не меняет поведение, пока сервер не выложит формат 2.
        case .unknown:                                return 0
        }
    }

    /// Метры в единицы MKMapPoint на этой широте.
    nonisolated private static func points(_ meters: Double,
                                           at coordinate: CLLocationCoordinate2D) -> Double {
        meters / MKMetersPerMapPointAtLatitude(coordinate.latitude)
    }

    /// Лимит дороги в точке: ближе 35 м к линии и направление совпадает с курсом (±40°, обе стороны).
    nonisolated func match(_ coordinate: CLLocationCoordinate2D, courseDegrees: Double) -> Int? {
        matchHit(coordinate, courseDegrees: courseDegrees)?.limit
    }

    /// То же, но с точкой полотна и азимутом — для снапа картинки к дороге.
    nonisolated func matchHit(_ coordinate: CLLocationCoordinate2D,
                              courseDegrees: Double) -> RoadHit? {
        nearestRoad(to: MKMapPoint(coordinate),
                    within: Self.points(35, at: coordinate),
                    candidates: candidates(around: coordinate),
                    prefersMajorRoads: true) { dx, dy in
            // Совпадение направления (дорогу считаем двусторонней).
            // Меркатор конформен: азимут корректно берётся прямо из map-точек (y растёт на юг).
            let segmentBearing = (atan2(dx, -dy) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
            var diff = abs(segmentBearing - courseDegrees).truncatingRemainder(dividingBy: 360)
            if diff > 180 { diff = 360 - diff }
            return min(diff, 180 - diff) <= 40
        }
    }

    /// Лимит ближайшей дороги без учёта курса — для карточки камеры
    /// (камера стоит, курса нет; берём просто ближайшую дорогу до 45 м).
    nonisolated func limit(near coordinate: CLLocationCoordinate2D) -> Int? {
        nearestRoad(to: MKMapPoint(coordinate),
                    within: Self.points(45, at: coordinate),
                    candidates: candidates(around: coordinate)) { _, _ in true }?.limit
    }
}
