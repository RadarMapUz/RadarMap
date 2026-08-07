//
//  PassTracking.swift
//  RadarMap
//
//  Учёт прохождения камер: минимальное сближение (траверз) + зона измерения
//  скорости на подходе — как меряет настоящий радар. Чистая логика без
//  CLLocationManager: каждый гейт и каждый сэмпл покрыты тестами.
//

import CoreLocation

nonisolated struct PassTracking {
    /// Слежение за одной камерой в зоне оповещения.
    struct Tracker {
        let camera: Camera
        var minDist: Double
        var speedAtMin: Double
        var limitAtMin: Int?
        /// Лимит был предположен по классу дороги, а не взят из OSM.
        var limitAssumedAtMin = false
        /// (дистанция, скорость) на подходе в пределах зоны измерения.
        var zone: [(dist: Double, speed: Double)] = []
        /// В точке максимального сближения было ДОКАЗАНО, что мы на другой
        /// дороге. Проверяется именно там: коридор оповещений щедр на подходе
        /// (68–93 м бокового допуска в 400 м впереди) и проверяется лишь в
        /// момент захвата — дальше камера соседней улицы ехала «своим ходом»
        /// до самой записи в историю.
        var offRoadAtMin = false
    }

    /// Завершённый проезд, готовый к записи в поездку.
    struct Pass {
        let camera: Camera
        let speedKmh: Double
        let limitKmh: Int?
        /// Лимит предположен по классу дороги: годится для рейтинга и голоса,
        /// но не для конкретной суммы штрафа (см. PassedCamera.limitIsCertain).
        let limitAssumed: Bool
    }

    private(set) var tracked: [Int: Tracker] = [:]

    /// Скорость проезда: минимальная из зоны измерения (80 м перед камерой) —
    /// разгон ПОСЛЕ проезда или смещённая координата камеры в базе не завышают
    /// оценку. Фолбэк при редких GPS-фиксах — скорость траверза.
    static func measuredSpeed(zone: [(dist: Double, speed: Double)],
                              fallback: Double) -> Double {
        zone.map(\.speed).min() ?? fallback
    }

    /// Один GPS-тик: начать слежение за ближайшей камерой в радиусе, обновить
    /// траверзы всех отслеживаемых, вернуть завершённые проезды.
    /// «Пройдено» — только если траверз был близко И геометрия дороги камеры
    /// это не опровергла: камера соседней улицы не наша, её проезд не про нас.
    /// `offRoad` — доказательство «мы не на дороге этой камеры» в текущей точке
    /// (см. PassGeometry). Считается только в момент нового сближения, то есть
    /// пару раз за проезд. По умолчанию доказательства нет — прежнее поведение.
    mutating func update(nearest: Camera?, nearestDistance: CLLocationDistance?,
                         coordinate: CLLocationCoordinate2D, speedKmh: Double,
                         roadLimit: Int?, roadLimitAssumed: Bool = false,
                         radius: CLLocationDistance,
                         offRoad: (Camera, CLLocationCoordinate2D) -> Bool = { _, _ in false })
        -> [Pass] {
        // Вошли в радиус камеры впереди — начинаем следить.
        if let nearest, let distance = nearestDistance,
           distance <= radius, tracked[nearest.id] == nil {
            var tracker = Tracker(camera: nearest, minDist: distance,
                                  speedAtMin: speedKmh, limitAtMin: roadLimit,
                                  limitAssumedAtMin: roadLimitAssumed)
            if distance <= AppConfig.passZoneMeters {
                tracker.zone.append((distance, speedKmh))
                tracker.offRoadAtMin = offRoad(nearest, coordinate)
            }
            tracked[nearest.id] = tracker
        }

        // Точку сближения обновляем для ВСЕХ отслеживаемых: после проезда камера
        // уходит из «ближайших впереди» (направленный фильтр), но траверз ещё не пройден.
        var completed: [Pass] = []
        for (id, entry) in tracked {
            var tracker = entry
            let distance = GeoMath.fastDistance(coordinate.latitude, coordinate.longitude,
                                                tracker.camera.lat, tracker.camera.lon)
            if distance < tracker.minDist {
                tracker.minDist = distance
                tracker.speedAtMin = speedKmh
                if roadLimit != nil {
                    tracker.limitAtMin = roadLimit
                    tracker.limitAssumedAtMin = roadLimitAssumed
                }
                // Пока приближаемся — копим сэмплы зоны измерения и проверяем
                // геометрию: важна именно точка сближения, а не подход к ней.
                if distance <= AppConfig.passZoneMeters {
                    tracker.zone.append((distance, speedKmh))
                    if tracker.zone.count > 8 { tracker.zone.removeFirst() }
                    tracker.offRoadAtMin = offRoad(tracker.camera, coordinate)
                }
                tracked[id] = tracker
            } else if distance > radius + AppConfig.passReleaseHysteresisMeters {
                if let pass = Self.pass(from: tracker) { completed.append(pass) }
                tracked.removeValue(forKey: id)
            }
        }
        return completed
    }

    /// Завершение поездки: зафиксировать камеры, мимо которых ещё «проезжали».
    mutating func flush() -> [Pass] {
        let passes = tracked.values.compactMap(Self.pass(from:))
        tracked.removeAll()
        return passes
    }

    mutating func reset() {
        tracked.removeAll()
    }

    /// Два гейта записи, оба по точке максимального сближения.
    ///
    /// Первый — расстояние: камера снимает проезжую часть, над которой стоит,
    /// и пройти под ней в полусотне метров нельзя. Второй — геометрия её
    /// собственной дороги: он ловит случай, когда мы прошли близко, но по
    /// соседней полосе-дублёру или поперечной улице развязки.
    private static func pass(from tracker: Tracker) -> Pass? {
        guard tracker.minDist <= PassGeometry.traverseLimit(for: tracker.camera),
              !tracker.offRoadAtMin else { return nil }
        return Pass(camera: tracker.camera,
                    speedKmh: measuredSpeed(zone: tracker.zone, fallback: tracker.speedAtMin),
                    limitKmh: tracker.limitAtMin,
                    limitAssumed: tracker.limitAssumedAtMin)
    }
}
