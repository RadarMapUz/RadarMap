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
    case motorway, trunk, primary, secondary, tertiary, residential, service, unknown

    init(raw: String?) {
        switch raw {
        case "motorway", "motorway_link": self = .motorway
        case "trunk", "trunk_link":       self = .trunk
        case "primary", "primary_link":   self = .primary
        case "secondary", "secondary_link": self = .secondary
        case "tertiary", "tertiary_link": self = .tertiary
        case "residential", "living_street", "unclassified": self = .residential
        case "service", "track":          self = .service
        default:                          self = .unknown
        }
    }

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

    /// Расстояние от точки до ломаной дороги (метры) — честная проверка
    /// «я на этой проезжей части», различающая полосы разных направлений.
    func distance(from coordinate: CLLocationCoordinate2D) -> Double {
        guard let first = points.first else { return .greatestFiniteMagnitude }
        let metersPerLon = 111_320.0 * cos(first.latitude * .pi / 180)
        func flat(_ point: CLLocationCoordinate2D) -> (x: Double, y: Double) {
            ((point.longitude - first.longitude) * metersPerLon,
             (point.latitude - first.latitude) * 111_320.0)
        }
        let p = flat(coordinate)
        guard points.count >= 2 else { return hypot(p.x, p.y) }
        var best = Double.greatestFiniteMagnitude
        var a = flat(points[0])
        for index in 1..<points.count {
            let b = flat(points[index])
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            let t = len2 > 0
                ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
                : 0
            best = min(best, hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy)))
            a = b
        }
        return best
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
