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
