//
//  AddPoint.swift
//  RadarMap
//
//  Что ставит прицел на карте и куда это уходит: своя камера — навсегда и
//  только у вас, тренога — отметкой для всех водителей. Чистая логика,
//  покрыта AddPointTests.
//

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
/// Сервер не знает, где водитель, и дальность не проверяет — проверяет телефон.
nonisolated enum TripodAvailability: Equatable {
    case available
    /// Отметки водителей выключены (настройка или пульт).
    case reportsOff
    /// Своего положения нет — «рядом» не доказать.
    case noPosition
    /// Прицел дальше `AppConfig.addTripodMaxDistanceMeters` от водителя.
    case tooFar

    var isAvailable: Bool { self == .available }

    static func check(point: CLLocationCoordinate2D?,
                      driver: CLLocationCoordinate2D?,
                      reportsEnabled: Bool,
                      maxMeters: CLLocationDistance = AppConfig.addTripodMaxDistanceMeters) -> TripodAvailability {
        guard reportsEnabled else { return .reportsOff }
        guard let driver, Self.isReal(driver) else { return .noPosition }
        guard let point, Self.isReal(point) else { return .tooFar }
        let meters = GeoMath.fastDistance(point.latitude, point.longitude,
                                          driver.latitude, driver.longitude)
        return meters <= maxMeters ? .available : .tooFar
    }

    private static func isReal(_ c: CLLocationCoordinate2D) -> Bool {
        CLLocationCoordinate2DIsValid(c) && !(c.latitude == 0 && c.longitude == 0)
    }
}
