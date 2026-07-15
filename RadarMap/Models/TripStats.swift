//
//  TripStats.swift
//  RadarMap
//
//  Статистика поездки: живые метрики + лог пройденных камер со скоростью,
//  трек поездки (упрощённый Дугласом-Пекером) и история.
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

    var camerasPassed: Int { passed.count }
    var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }
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
    /// Сырой трек текущей поездки: точка каждые ≥30 м, упрощается при финише.
    @ObservationIgnored private var trackBuffer: [TrackPoint] = []
    private static let maxHistory = 50
    private static let trackStepMeters = 30.0
    private static let trackTolerance = 0.00022   // ~22 м — упрощение Дугласа-Пекера
    private static let trackMaxPoints = 400

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
        trackBuffer = []
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

        // Трек: точка каждые ≥30 м (память копеечная, финальное сжатие при финише).
        if let last = trackBuffer.last {
            if GeoMath.fastDistance(last.lat, last.lon,
                                    coordinate.latitude, coordinate.longitude) >= Self.trackStepMeters {
                trackBuffer.append(TrackPoint(lat: coordinate.latitude,
                                              lon: coordinate.longitude, speedKmh: speedKmh))
            }
        } else {
            trackBuffer.append(TrackPoint(lat: coordinate.latitude,
                                          lon: coordinate.longitude, speedKmh: speedKmh))
        }
    }

    /// Зафиксировать прохождение камеры (скорость — в точке максимального сближения).
    func registerPass(camera: Camera, speedKmh: Double, limitKmh: Int?) {
        passed.append(PassedCamera(
            id: UUID(), cameraID: camera.id, typeRaw: camera.type,
            location: camera.displayTitle, speedKmh: speedKmh, date: Date(),
            lat: camera.lat, lon: camera.lon, limitKmh: limitKmh
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
            endLon: lastCoordinate?.longitude,
            track: Self.packTrack(Self.simplify(trackBuffer,
                                                tolerance: Self.trackTolerance,
                                                maxPoints: Self.trackMaxPoints))
        )
        history.insert(record, at: 0)
        if history.count > Self.maxHistory { history.removeLast(history.count - Self.maxHistory) }
        persist()
    }

    func deleteRecord(id: Double) {
        history.removeAll { $0.id == id }
        persist()
    }

    func clearHistory() {
        history = []
        persist()
    }

    /// Сводка за последние 7 дней — заголовок истории.
    var weekSummary: (trips: Int, distance: CLLocationDistance, cameras: Int)? {
        let weekAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        let recent = history.filter { $0.startedAt > weekAgo }
        guard !recent.isEmpty else { return nil }
        return (recent.count,
                recent.reduce(0) { $0 + $1.distanceMeters },
                recent.reduce(0) { $0 + $1.camerasPassed })
    }

    // MARK: - Трек: упаковка и упрощение (Дуглас-Пекер)

    nonisolated private static func packTrack(_ points: [TrackPoint]) -> [Double]? {
        guard points.count >= 2 else { return nil }
        var flat: [Double] = []
        flat.reserveCapacity(points.count * 3)
        for p in points {
            flat.append((p.lat * 1e5).rounded() / 1e5)
            flat.append((p.lon * 1e5).rounded() / 1e5)
            flat.append((p.speedKmh * 10).rounded() / 10)
        }
        return flat
    }

    /// Классический Дуглас-Пекер по (lat, lon); скорость сохраняется у оставленных точек.
    nonisolated static func simplify(_ points: [TrackPoint], tolerance: Double,
                                     maxPoints: Int) -> [TrackPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true

        var stack: [(Int, Int)] = [(0, points.count - 1)]
        while let (lo, hi) = stack.popLast() {
            guard hi > lo + 1 else { continue }
            var worst = 0.0
            var worstIndex = lo
            for i in (lo + 1)..<hi {
                let d = perpendicular(points[i], points[lo], points[hi])
                if d > worst { worst = d; worstIndex = i }
            }
            if worst > tolerance {
                keep[worstIndex] = true
                stack.append((lo, worstIndex))
                stack.append((worstIndex, hi))
            }
        }
        var result = points.indices.filter { keep[$0] }.map { points[$0] }
        // Страховка от гигантских треков: равномерное прореживание до лимита.
        if result.count > maxPoints {
            let step = Double(result.count - 1) / Double(maxPoints - 1)
            result = (0..<maxPoints).map { result[Int((Double($0) * step).rounded())] }
        }
        return result
    }

    nonisolated private static func perpendicular(_ p: TrackPoint, _ a: TrackPoint, _ b: TrackPoint) -> Double {
        let dx = b.lon - a.lon, dy = b.lat - a.lat
        let len2 = dx * dx + dy * dy
        if len2 == 0 { return hypot(p.lon - a.lon, p.lat - a.lat) }
        let t = max(0, min(1, ((p.lon - a.lon) * dx + (p.lat - a.lat) * dy) / len2))
        return hypot(p.lon - (a.lon + t * dx), p.lat - (a.lat + t * dy))
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
