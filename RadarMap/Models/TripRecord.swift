//
//  TripRecord.swift
//  RadarMap
//
//  Данные поездки: проезд камеры, запись завершённой поездки, точка трека.
//  Чистые Codable-структуры без логики — формат хранения trips.json.
//

import Foundation
import CoreLocation

/// Факт прохождения камеры: скорость зафиксирована в точке максимального сближения.
struct PassedCamera: Codable, Identifiable {
    let id: UUID
    let cameraID: Int
    let typeRaw: String
    let location: String
    let speedKmh: Double
    let date: Date
    // Координаты камеры и лимит дороги в момент проезда (у старых записей отсутствуют).
    var lat: Double?
    var lon: Double?
    var limitKmh: Int?

    var kind: CameraType { CameraType(raw: typeRaw) }
    var coordinate: CLLocationCoordinate2D? {
        guard let lat, let lon else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
    /// Реальное превышение относительно лимита дороги (если лимит известен).
    var overLimitKmh: Double? {
        guard let limitKmh else { return nil }
        return speedKmh - Double(limitKmh)
    }
}

/// Одна завершённая поездка.
struct TripRecord: Codable, Identifiable {
    let id: Double
    let startedAt: Date
    let endedAt: Date
    let distanceMeters: CLLocationDistance
    let maxSpeedKmh: Double
    let passed: [PassedCamera]
    // Точка финиша — чтобы повторить маршрут из истории (у старых записей отсутствует).
    var endLat: Double?
    var endLon: Double?
    /// Упрощённый трек: плоский массив [lat, lon, speed, lat, lon, speed, …].
    var track: [Double]?
    /// Рейтинг поездки 0–100 (у старых записей отсутствует).
    var score: Double?

    var camerasPassed: Int { passed.count }
    var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }
    /// «Чистая» поездка: ни одного проезда со штрафуемым превышением
    /// (проезды без известного лимита не считаем нарушением — как в month30).
    var isClean: Bool {
        passed.allSatisfy { pass in
            guard let limit = pass.limitKmh else { return true }
            return FineSchedule.fine(overKmh: pass.speedKmh - Double(limit)) == 0
        }
    }
    var averageSpeedKmh: Double { duration > 0 ? distanceMeters / duration * 3.6 : 0 }
    var endCoordinate: CLLocationCoordinate2D? {
        guard let endLat, let endLon else { return nil }
        return CLLocationCoordinate2D(latitude: endLat, longitude: endLon)
    }

    /// Точки трека (lat, lon, speed) из плоского хранения.
    var trackPoints: [TrackPoint] {
        guard let track, track.count >= 6 else { return [] }
        return stride(from: 0, to: track.count - 2, by: 3).map {
            TrackPoint(lat: track[$0], lon: track[$0 + 1], speedKmh: track[$0 + 2])
        }
    }
}

struct TrackPoint {
    let lat: Double
    let lon: Double
    let speedKmh: Double
}
