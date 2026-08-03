//
//  RoadShape.swift
//  RadarMap
//
//  Дорога камеры: класс и короткий кусок проезжей части вокруг неё.
//
//  Ось (0–179°) не различает направления, поэтому на разделённой дороге камера
//  обратной стороны считалась «нашей». Теперь у односторонних проезжих частей
//  есть направление (`dir`), а у камер — кусок геометрии их дороги: по нему
//  считается настоящее «я на этой дороге» (расстояние до ломаной), а не
//  эвристический коридор, и берётся истинный курс дороги в точке камеры — на
//  кривой одна ось врёт, а ломаная нет.
//
//  Чистые типы без CoreLocation-состояния, покрыты тестами (RoadShapeTests).
//

import CoreLocation

/// Класс дороги OSM — мгновенный контекст «город или трасса» и ширина полосы.
nonisolated enum RoadClass: Equatable {
    case motorway, trunk, primary, secondary, tertiary, residential, service
    /// Тротуар, переход, платформа: не проезжая часть.
    case pedestrian
    case unknown

    init(raw: String?) {
        switch raw {
        case "motorway", "motorway_link": self = .motorway
        case "trunk", "trunk_link":       self = .trunk
        case "primary", "primary_link":   self = .primary
        case "secondary", "secondary_link": self = .secondary
        case "tertiary", "tertiary_link": self = .tertiary
        case "residential", "living_street", "unclassified": self = .residential
        case "service", "track":          self = .service
        case "footway", "path", "cycleway", "steps", "pedestrian", "platform", "bus_stop":
            self = .pedestrian
        default:                          self = .unknown
        }
    }

    /// Проезжая часть. Камера стоит над дорогой, а не над тротуаром, поэтому
    /// пешеходный класс — это признак ошибки сопоставления в снапе (в базе v10
    /// таких 39). Профилю такой «дороги» верить нельзя: её направление и
    /// геометрия к движению машин отношения не имеют, а переход и вовсе идёт
    /// ПОПЕРЁК проезжей части — по нему камера была бы заглушена гейтом оси.
    var isVehicleRoad: Bool { self != .pedestrian }

    /// Трасса по классу дороги: сигнал сильнее и мгновеннее, чем средняя скорость.
    var isHighway: Bool {
        self == .motorway || self == .trunk
    }

    /// Городская улица — тихий режим оповещений даже при разгоне.
    var isCityStreet: Bool {
        self == .residential || self == .service
    }

    /// Сколько полос ожидать, если тега `lanes` в OSM не было.
    var assumedLanes: Int {
        switch self {
        case .motorway, .trunk: return 4
        case .primary:          return 4
        case .secondary:        return 2
        case .tertiary:         return 2
        case .residential:      return 2
        case .service:          return 1
        // Пешеходный профиль — ошибка снапа; ширину берём как у обычной улицы,
        // потому что реальная дорога камеры где-то рядом.
        case .pedestrian:       return 2
        case .unknown:          return 2
        }
    }
}

/// Кусок проезжей части вокруг камеры, распакованный из базы.
nonisolated struct RoadShape {
    /// Точки дороги (обычно 3–9) вокруг камеры.
    let points: [CLLocationCoordinate2D]

    /// nil — у камеры нет куска дороги (старая база или снап не нашёл дорогу).
    init?(camera: Camera) {
        guard let road = camera.road, road.count >= 4, road.count % 2 == 0 else { return nil }
        var points: [CLLocationCoordinate2D] = []
        points.reserveCapacity(road.count / 2)
        for index in stride(from: 0, to: road.count, by: 2) {
            points.append(CLLocationCoordinate2D(
                latitude: camera.lat + Double(road[index]) / 1e6,
                longitude: camera.lon + Double(road[index + 1]) / 1e6))
        }
        self.points = points
    }

    /// Боковое отклонение точки от проезжей части камеры (метры) — честная
    /// проверка «я на этой дороге», различающая полосы разных направлений.
    ///
    /// `nil` — доказательства нет: кусок дороги кончился раньше нас, наша
    /// проекция лежит за его концом. Это НЕ «другая дорога», а «здесь нечего
    /// мерить»: кусок короткий (сотня метров, а на перекрёстке и того меньше,
    /// потому что в OSM дорога разрезана), и на подходе к камере мы почти всегда
    /// дальше его края. Раньше здесь мерилось обычное расстояние до ломаной, и
    /// продольный разрыв («до куска ещё 80 м») сравнивался с боковым допуском
    /// (~20 м) — камера глохла ровно на подъезде к ней, у всей базы.
    func lateralOffset(from coordinate: CLLocationCoordinate2D) -> Double? {
        guard let first = points.first, points.count >= 2 else { return nil }
        let metersPerLon = 111_320.0 * cos(first.latitude * .pi / 180)
        func flat(_ point: CLLocationCoordinate2D) -> (x: Double, y: Double) {
            ((point.longitude - first.longitude) * metersPerLon,
             (point.latitude - first.latitude) * 111_320.0)
        }
        let p = flat(coordinate)
        var best = Double.greatestFiniteMagnitude
        var bestIndex = 1
        var bestT = 0.0
        for index in 1..<points.count {
            let a = flat(points[index - 1]), b = flat(points[index])
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            guard len2 > 0 else { continue }   // дубликат вершины: отрезка нет
            let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
            let distance = hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
            if distance < best { best = distance; bestIndex = index; bestT = t }
        }
        guard best < .greatestFiniteMagnitude else { return nil }
        // Проекция упёрлась в самый КОНЕЦ ломаной — мы не сбоку от дороги, а за
        // её отрезком: воздерживаемся. Внутренние вершины не в счёт, там мы
        // по-прежнему вдоль дороги.
        let beyondStart = bestIndex == 1 && bestT <= 0
        let beyondEnd = bestIndex == points.count - 1 && bestT >= 1
        return (beyondStart || beyondEnd) ? nil : best
    }

    /// Ось (0–179°) ближайшего к точке участка дороги. На кривой это честнее
    /// единственной оси всей дороги, записанной в базе.
    func axis(near coordinate: CLLocationCoordinate2D) -> Double? {
        guard points.count >= 2 else { return nil }
        var best = Double.greatestFiniteMagnitude
        var bestIndex = 1
        for index in 1..<points.count {
            let middle = CLLocationCoordinate2D(
                latitude: (points[index - 1].latitude + points[index].latitude) / 2,
                longitude: (points[index - 1].longitude + points[index].longitude) / 2)
            let distance = GeoMath.fastDistance(coordinate.latitude, coordinate.longitude,
                                                middle.latitude, middle.longitude)
            if distance < best { best = distance; bestIndex = index }
        }
        let bearing = GeoMath.bearing(from: points[bestIndex - 1], to: points[bestIndex])
        return bearing.truncatingRemainder(dividingBy: 180)
    }
}

nonisolated enum RoadGeometry {
    /// Половина ширины проезжей части плюс запас на неточность координаты в
    /// реестре: до этого расстояния от ломаной считаем, что мы на этой дороге.
    /// Раньше это была одна константа на весь город (30 м), из-за которой
    /// параллельная проезжая часть в 20 м попадала в «нашу дорогу».
    static func halfWidth(lanes: Int?, roadClass: RoadClass) -> Double {
        let count = max(1, lanes ?? roadClass.assumedLanes)
        let roadWidth = Double(count) * AppConfig.laneWidthMeters
        return roadWidth / 2 + AppConfig.roadPositionSlackMeters
    }
}
