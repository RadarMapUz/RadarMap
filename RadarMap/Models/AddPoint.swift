//
//  AddPoint.swift
//  RadarMap
//
//  Что ставит прицел на карте и куда это уходит: своя камера — навсегда и
//  только у вас, тренога — отметкой для всех водителей. Чистая логика,
//  покрыта AddPointTests.
//

import CoreGraphics
import CoreLocation

nonisolated enum AddPointKind: String, CaseIterable, Identifiable, Sendable {
    case speedCamera, signalCamera, tripod

    var id: String { rawValue }

    enum Route: Equatable {
        /// Своя камера (`custom`): на телефоне, навсегда.
        case ownCamera(CameraType)
        /// Отметка водителя: сервер, видят все, живёт часы.
        case report(ReportKind)
    }

    /// Скорость — первой: молчание о камере скорости хуже лишнего сигнала, а
    /// камеру на светофоре режим «Только радары» в фоне не будит.
    var route: Route {
        switch self {
        case .speedCamera:  return .ownCamera(.stationaryRadar)
        case .signalCamera: return .ownCamera(.stationaryCamera)
        case .tripod:       return .report(.tripod)
        }
    }

    /// Тип для значка — тот же, каким точка встанет на карте.
    var cameraType: CameraType {
        switch route {
        case .ownCamera(let type): return type
        case .report(let kind):    return kind.cameraType
        }
    }

    var isOwnCamera: Bool {
        if case .ownCamera = route { return true }
        return false
    }
}

/// Можно ли поставить отметку для всех пальцем — прицелом или «Радар здесь».
/// Сервер не знает, где водитель, и дальность не проверяет — проверяет телефон:
/// рядом с собой или там, где сам проезжал недавно («видел по дороге, отмечаю
/// дома»). Остальное — отметка «с дивана», а её видят все водители.
nonisolated enum TripodAvailability: Equatable {
    /// Рядом с водителем (`AppConfig.addTripodMaxDistanceMeters`).
    case available
    /// На своём пути за `AppConfig.addTripodTrackWindowSeconds`; дата — когда
    /// проезжал мимо (уходит на сервер возрастом отметки).
    case passedBy(Date)
    /// Отметки водителей выключены (настройка или пульт).
    case reportsOff
    /// Своего положения нет, и мимо точки недавно не проезжали.
    case noPosition
    /// Прицел далеко и от водителя, и от его недавнего пути.
    case tooFar

    var isAvailable: Bool {
        switch self {
        case .available, .passedBy: return true
        case .reportsOff, .noPosition, .tooFar: return false
        }
    }

    /// Когда точку видели, если не сейчас: момент проезда мимо неё.
    var observedAt: Date? {
        if case .passedBy(let date) = self { return date }
        return nil
    }

    /// `path` считается, только если рядом не вышло: трек — тысячи точек.
    static func check(point: CLLocationCoordinate2D?,
                      driver: CLLocationCoordinate2D?,
                      reportsEnabled: Bool,
                      path: @autoclosure () -> RecentPath = .empty,
                      now: Date = Date(),
                      maxMeters: CLLocationDistance = AppConfig.addTripodMaxDistanceMeters) -> TripodAvailability {
        guard reportsEnabled else { return .reportsOff }
        let me = driver.flatMap { Self.isReal($0) ? $0 : nil }
        guard let point, Self.isReal(point) else { return me == nil ? .noPosition : .tooFar }
        if let me, GeoMath.fastDistance(point.latitude, point.longitude,
                                        me.latitude, me.longitude) <= maxMeters {
            return .available
        }
        if let passed = path().passage(near: point, now: now) { return .passedBy(passed) }
        return me == nil ? .noPosition : .tooFar
    }

    private static func isReal(_ c: CLLocationCoordinate2D) -> Bool {
        CLLocationCoordinate2DIsValid(c) && !(c.latitude == 0 && c.longitude == 0)
    }
}

/// Свой недавний путь: точки поездок со временем — для отметки «видел по
/// дороге». Живёт только на телефоне; на сервер уходит одна дата проезда.
nonisolated struct RecentPath: Equatable, Sendable {
    struct Point: Equatable, Sendable {
        let lat: Double
        let lon: Double
        /// Секунды Unix. У трека без времени точек — начало поездки: самое
        /// раннее, когда точку могли проехать, — окно от этого только строже.
        let time: Double
    }

    /// Каждая поездка — своя ломаная: от конца одной до начала другой не ехали.
    var legs: [[Point]] = []

    static let empty = RecentPath()

    /// Ломаная поездки. `times` — секунды Unix по точкам; нет их, не та
    /// длина или NaN — начало поездки.
    static func leg(track: [TrackPoint], times: [Double]?, startedAt: Date) -> [Point] {
        let start = startedAt.timeIntervalSince1970
        let timed = times?.count == track.count ? times : nil
        return track.indices.map { index in
            let time = timed.map { $0[index] }.flatMap { $0.isFinite ? $0 : nil } ?? start
            return Point(lat: track[index].lat, lon: track[index].lon, time: time)
        }
    }

    /// Последний проезд не дальше `maxMeters` от точки за окно — момент
    /// ближайшего подхода на отрезке; nil — не проезжали. Отрезок, а не
    /// вершины: упрощённый трек на прямой держит точку раз в километр.
    func passage(near point: CLLocationCoordinate2D, now: Date,
                 window: TimeInterval = AppConfig.addTripodTrackWindowSeconds,
                 maxMeters: Double = AppConfig.addTripodTrackMaxMeters) -> Date? {
        let latest = now.timeIntervalSince1970
        let earliest = latest - window
        let metersPerDegree = 111_320.0
        let lonScale = cos(point.latitude * .pi / 180) * metersPerDegree
        func local(_ p: Point) -> (x: Double, y: Double) {
            ((p.lon - point.longitude) * lonScale, (p.lat - point.latitude) * metersPerDegree)
        }
        func fresh(_ p: Point) -> Bool { p.time >= earliest && p.time <= latest }
        var best: Double?
        for leg in legs {
            for index in leg.indices where fresh(leg[index]) {
                let a = leg[index]
                let b = index + 1 < leg.count && fresh(leg[index + 1]) ? leg[index + 1] : a
                let pa = local(a), pb = local(b)
                let dx = pb.x - pa.x, dy = pb.y - pa.y
                let length = dx * dx + dy * dy
                let share = length > 0 ? min(1, max(0, -(pa.x * dx + pa.y * dy) / length)) : 0
                let x = pa.x + dx * share, y = pa.y + dy * share
                guard (x * x + y * y).squareRoot() <= maxMeters else { continue }
                let time = a.time + (b.time - a.time) * share
                best = max(best ?? time, time)
            }
        }
        return best.map { Date(timeIntervalSince1970: $0) }
    }
}

/// Где на экране прицел: середина ВИДИМОЙ карты — между верхней стопкой панелей
/// и верхним краем нижней. В центре всего экрана он прятался под панелью.
nonisolated enum AddPointAim {

    /// `insets` — доли высоты, закрытые панелями (MapFrameState); нижняя 0 —
    /// «ещё не мерили», тогда низ — край вида.
    static func point(width: Double, height: Double, insets: MapViewport.Insets) -> CGPoint {
        guard width > 0, height > 0 else { return .zero }
        let top = min(max(0, insets.top), 1) * height
        let bottom = height - min(max(0, insets.bottom), 1) * height
        let y = bottom > top ? (top + bottom) / 2 : height / 2
        return CGPoint(x: width / 2, y: y)
    }
}
