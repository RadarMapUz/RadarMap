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
        /// (дистанция, скорость) на подходе в пределах зоны измерения.
        var zone: [(dist: Double, speed: Double)] = []
    }

    /// Завершённый проезд, готовый к записи в поездку.
    struct Pass {
        let camera: Camera
        let speedKmh: Double
        let limitKmh: Int?
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
    /// «Пройдено» — только если траверз был ближе passTraverseMaxMeters:
    /// камера с параллельной улицы (400+ м) не наша, её лимит не про нас.
    mutating func update(nearest: Camera?, nearestDistance: CLLocationDistance?,
                         coordinate: CLLocationCoordinate2D, speedKmh: Double,
                         roadLimit: Int?, radius: CLLocationDistance) -> [Pass] {
        // Вошли в радиус камеры впереди — начинаем следить.
        if let nearest, let distance = nearestDistance,
           distance <= radius, tracked[nearest.id] == nil {
            var tracker = Tracker(camera: nearest, minDist: distance,
                                  speedAtMin: speedKmh, limitAtMin: roadLimit)
            if distance <= AppConfig.passTraverseMaxMeters {
                tracker.zone.append((distance, speedKmh))
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
                tracker.limitAtMin = roadLimit ?? tracker.limitAtMin
                // Пока приближаемся — копим сэмплы зоны измерения.
                if distance <= AppConfig.passTraverseMaxMeters {
                    tracker.zone.append((distance, speedKmh))
                    if tracker.zone.count > 8 { tracker.zone.removeFirst() }
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

    /// Гейт по траверзу: проезд засчитывается, только если реально прошли рядом.
    private static func pass(from tracker: Tracker) -> Pass? {
        guard tracker.minDist <= AppConfig.passTraverseMaxMeters else { return nil }
        return Pass(camera: tracker.camera,
                    speedKmh: measuredSpeed(zone: tracker.zone, fallback: tracker.speedAtMin),
                    limitKmh: tracker.limitAtMin)
    }
}
