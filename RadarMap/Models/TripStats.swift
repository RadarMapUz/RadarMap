//
//  TripStats.swift
//  RadarMap
//
//  Статистика поездки: живые метрики + лог пройденных камер со скоростью + история.
//

import Foundation
import Observation
import CoreLocation

/// Факт прохождения камеры: скорость зафиксирована в точке максимального сближения.
struct PassedCamera: Codable, Identifiable {
    let id: UUID
    let cameraID: Int
    let typeRaw: String
    let location: String
    let speedKmh: Double
    let date: Date

    var kind: CameraType { CameraType(raw: typeRaw) }
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

    var camerasPassed: Int { passed.count }
    var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }
    var averageSpeedKmh: Double { duration > 0 ? distanceMeters / duration * 3.6 : 0 }
    var endCoordinate: CLLocationCoordinate2D? {
        guard let endLat, let endLon else { return nil }
        return CLLocationCoordinate2D(latitude: endLat, longitude: endLon)
    }
}

@MainActor
@Observable
final class TripStats {
    private(set) var maxSpeedKmh: Double = 0
    private(set) var distanceMeters: CLLocationDistance = 0
    private(set) var startedAt: Date?
    private(set) var lastPointAt: Date?
    /// Пройденные камеры текущей/последней поездки (со скоростью прохождения).
    private(set) var passed: [PassedCamera] = []

    private(set) var history: [TripRecord] = []

    @ObservationIgnored private var lastCoordinate: CLLocationCoordinate2D?
    private static let maxHistory = 50

    init() { loadHistory() }

    var camerasPassed: Int { passed.count }

    var durationSeconds: TimeInterval {
        guard let startedAt, let lastPointAt else { return 0 }
        return max(0, lastPointAt.timeIntervalSince(startedAt))
    }
    var averageSpeedKmh: Double {
        durationSeconds > 0 ? distanceMeters / durationSeconds * 3.6 : 0
    }

    func begin() {
        maxSpeedKmh = 0
        distanceMeters = 0
        lastCoordinate = nil
        passed = []
        startedAt = Date()
        lastPointAt = startedAt
    }

    func update(coordinate: CLLocationCoordinate2D, speedKmh: Double) {
        if let last = lastCoordinate {
            let step = CLLocation(latitude: last.latitude, longitude: last.longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            if step < 500 { distanceMeters += step }
        }
        lastCoordinate = coordinate
        maxSpeedKmh = max(maxSpeedKmh, speedKmh)
        lastPointAt = Date()
    }

    /// Зафиксировать прохождение камеры (скорость — в точке максимального сближения).
    func registerPass(camera: Camera, speedKmh: Double) {
        passed.append(PassedCamera(
            id: UUID(), cameraID: camera.id, typeRaw: camera.type,
            location: camera.displayTitle, speedKmh: speedKmh, date: Date()
        ))
    }

    func finish() {
        defer { startedAt = nil }
        guard let startedAt, distanceMeters >= 100 else { return }
        let record = TripRecord(
            id: startedAt.timeIntervalSince1970,
            startedAt: startedAt,
            endedAt: lastPointAt ?? Date(),
            distanceMeters: distanceMeters,
            maxSpeedKmh: maxSpeedKmh,
            passed: passed,
            endLat: lastCoordinate?.latitude,
            endLon: lastCoordinate?.longitude
        )
        history.insert(record, at: 0)
        if history.count > Self.maxHistory { history.removeLast(history.count - Self.maxHistory) }
        persist()
    }

    func clearHistory() {
        history = []
        persist()
    }

    // MARK: - Хранение

    private var storeURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("trips.json")
    }
    private func loadHistory() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([TripRecord].self, from: data) else { return }
        history = decoded
    }
    private func persist() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
