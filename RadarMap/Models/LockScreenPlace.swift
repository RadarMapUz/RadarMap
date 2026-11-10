//
//  LockScreenPlace.swift
//  RadarMap
//
//  Что написать о цели маршрута на плашке экрана блокировки. Экран виден
//  любому рядом с телефоном, поэтому адрес дома и работы туда не попадает:
//  цель рядом с ними называется словом, откуда бы маршрут ни пришёл (Siri,
//  поиск, история). Чистая логика; LockScreenPlaceTests.
//

import CoreLocation

nonisolated enum LockScreenPlace: Equatable {
    case hidden
    case home
    case work
    case named(String)

    static func label(routeName: String, destination: CLLocationCoordinate2D?,
                      home: CLLocationCoordinate2D?, work: CLLocationCoordinate2D?,
                      privateMode: Bool,
                      radius: CLLocationDistance = AppConfig.commutePlaceRadiusMeters) -> LockScreenPlace {
        guard !privateMode else { return .hidden }
        func near(_ place: CLLocationCoordinate2D?) -> Bool {
            guard let place, let destination else { return false }
            return GeoMath.fastDistance(destination.latitude, destination.longitude,
                                        place.latitude, place.longitude) <= radius
        }
        if near(home) { return .home }
        if near(work) { return .work }
        return routeName.isEmpty ? .hidden : .named(routeName)
    }
}
