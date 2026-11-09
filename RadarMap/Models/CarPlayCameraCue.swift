//
//  CarPlayCameraCue.swift
//  RadarMap
//
//  Как машина говорит о камере впереди (25.F, решение 21.10 «как у Яндекса,
//  но грамотно»).
//
//  Руководство CarPlay (стр. 7, 36) не разрешает своих панелей поверх карты
//  в базовом виде; Waze и Google Maps держат в углу только скорость с
//  лимитом и проходят ревью, а о событии на дороге говорят системным
//  баннером и значком на самой карте. У нас так же:
//    • док — только скорость и знак ограничения (камеры в нём больше нет);
//    • камера впереди — системный баннер (CarPlayCameraBanner) на всё
//      приближение, подпись с расстоянием у её значка на карте и, на iOS 27,
//      строка «📷 400 м» в оценках поездки (CPRouteDetail);
//    • своя камера (голос о ней молчит, CameraFamiliarity) — ни баннера, ни
//      подписи: только значок с галочкой, как и на телефоне. Тревожный облик
//      значка ей тоже не нужен — с ним пропала бы галочка.
//  Решение «есть ли тревога» по-прежнему принимают гейты оповещений
//  (LocationService.isApproachingCamera: в радиусе, т. е. уровень ≥ 1, на
//  скорости от directionalMinSpeedKmh и с живым сигналом); здесь — только
//  как её показать. Голос и звук это не трогает.
//
//  Чистая логика; CarPlayCameraCueTests.
//

import CoreLocation

nonisolated enum CarPlayCameraCue {

    struct Cue: Equatable, Sendable {
        /// Системный баннер камеры.
        let banner: Bool
        /// Камера в тревожном облике на карте (крупная, с ореолом); nil — нет.
        let mapAlertID: Int?
        /// Подпись «400 м» у значка на карте и строка в оценках поездки.
        let distanceLabel: Bool

        static let none = Cue(banner: false, mapAlertID: nil, distanceLabel: false)
    }

    /// `approaching` — решение гейтов (LocationService.isApproachingCamera).
    static func decide(cameraID: Int?, approaching: Bool, familiar: Bool) -> Cue {
        guard approaching, let cameraID, !familiar else { return .none }
        return Cue(banner: true, mapAlertID: cameraID, distanceLabel: true)
    }

    /// Что стоит в доке справа внизу. Камеры среди этого нет никогда.
    enum DockItem: Equatable, Sendable {
        /// Прибытие — только пока карточку манёвра и оценки не рисует сама
        /// машина (без навигационной сессии).
        case arrival
        /// Дорога на работу без маршрута (призрак).
        case ghost
        /// Скорость со знаком ограничения — всегда.
        case speed
    }

    static func dock(ownArrival: Bool, hasRoute: Bool, hasGhost: Bool, fitsSecond: Bool) -> [DockItem] {
        var items: [DockItem] = []
        if fitsSecond {
            if ownArrival { items.append(.arrival) } else if !hasRoute, hasGhost { items.append(.ghost) }
        }
        items.append(.speed)
        return items
    }

    /// Пора ли переписать подпись на карте: камера сменилась — сразу; та же
    /// камера — только новая цифра и не чаще `interval` (каждая запись —
    /// расстановка символов движком).
    static func shouldRefreshLabel(shown: Label?, new: Label?, sinceLast: TimeInterval,
                                   interval: TimeInterval = AppConfig.carPlayCameraLabelUpdateSeconds) -> Bool {
        guard shown != new else { return false }
        guard let shown, let new, shown.id == new.id else { return true }
        return sinceLast >= interval
    }

    /// Показать ли «до камеры N м» в приборе плитки. Нет — когда маршрут дал
    /// камере ноль, а по прямой до неё далеко. Гейт кандидатов держит камеру
    /// маршрута «0 м» до `routePassedToleranceMeters` за ней: светофор в 40–60 м
    /// за камерой — и весь красный на плитке «0 м» про камеру за спиной (жалоба
    /// владельца 05.11). То же у камеры за стартом маршрута, которой координата
    /// не даёт выйти из маршрута (RouteLineEnds.coordinateProves), и у камеры
    /// между стартом и машиной после перестроения. Ноль рядом с камерой по
    /// прямой — настоящий траверз, он показывается. Только показ: оповещения,
    /// гейты и голос это не читают.
    static func gaugeShows(distance: Double, straight: Double) -> Bool {
        distance >= AppConfig.carPlayGaugeZeroMeters || straight <= AppConfig.carPlayGaugeZeroStraightMeters
    }

    /// Что в приборе плитки на месте камеры.
    enum GaugeCamera: Equatable, Sendable {
        case hidden
        /// Фиксов нет: прежнее расстояние показывать нельзя, оно стоит.
        case noSignal
        case distance
    }

    /// `distance` — до ближайшей камеры для показа, nil — её нет. Как и на
    /// телефоне (NearestCameraReadout): на экране машины о потере сигнала
    /// говорит чип, у плитки чипов нет. Только показ.
    static func gaugeCamera(signalStale: Bool, distance: Double?, straight: Double) -> GaugeCamera {
        if signalStale { return .noSignal }
        guard let distance, distance <= AppConfig.carPlayNearestCameraMeters,
              gaugeShows(distance: distance, straight: straight) else { return .hidden }
        return .distance
    }

    /// Подпись с расстоянием у значка алерт-камеры.
    struct Label: Equatable, Sendable {
        let id: Int
        let latitude: Double
        let longitude: Double
        let text: String

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }
}
