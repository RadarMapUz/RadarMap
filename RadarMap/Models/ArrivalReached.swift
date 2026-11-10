//
//  ArrivalReached.swift
//  RadarMap
//
//  Приехали ли к цели маршрута (76). «По прямой до цели ≤ 60 м» срабатывало
//  на встречной стороне проспекта — цель через разделительную, до разворота
//  ещё километр — и на петле развязки, проходящей рядом с финишем: маршрут
//  снимался, «вы прибыли» звучало за разворот до цели.
//
//  У цели — это близко по прямой И мало осталось по линии. Мимо линии
//  (дальше `rerouteDriftMeters`) остаток ничего не значит — подъехали
//  двором, другой улицей, — и там хватает прямой, как раньше. Вторая ветка —
//  финиш по линии пройден, парковка чуть в стороне — прежняя.
//  Чистая логика, ArrivalReachedTests.
//

import CoreLocation

nonisolated enum ArrivalReached {

    /// `destinationDistance` — по прямой до цели, `remainingAlong` — остаток
    /// по линии маршрута, `deviation` — отклонение от линии.
    static func isReached(destinationDistance: CLLocationDistance, remainingAlong: CLLocationDistance,
                          deviation: CLLocationDistance) -> Bool {
        if destinationDistance <= AppConfig.arrivalRadiusMeters,
           remainingAlong <= AppConfig.arrivalNearRemainingMeters || deviation > AppConfig.rerouteDriftMeters {
            return true
        }
        return remainingAlong < AppConfig.arrivalPassedRemainingMeters
            && destinationDistance < AppConfig.arrivalPassedRadiusMeters
    }
}
