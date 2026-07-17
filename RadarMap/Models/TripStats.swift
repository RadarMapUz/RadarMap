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
import os

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
    /// Пожизненные счётчики — живут отдельно от истории (она обрезается до 50 поездок).
    private(set) var lifetime = LifetimeStats()
    /// Вызывается после сохранения поездки (AppEnvironment вешает сюда недельный дайджест).
    @ObservationIgnored var onTripFinished: (() -> Void)?

    @ObservationIgnored private var lastCoordinate: CLLocationCoordinate2D?
    /// Сырой трек текущей поездки: точка каждые ≥30 м, упрощается при финише.
    @ObservationIgnored private var trackBuffer: [TrackPoint] = []
    private static let trackStepMeters = 30.0
    private static let trackTolerance = 0.00022   // ~22 м — упрощение Дугласа-Пекера
    private static let trackMaxPoints = 400

    init() { loadHistory() }

    var camerasPassed: Int { passed.count }

    /// finish() обнуляет startedAt — длительность последней поездки храним отдельно,
    /// иначе «средняя км/ч» и «в пути» на экране Итогов превращаются в нули.
    private var finishedDuration: TimeInterval = 0

    var durationSeconds: TimeInterval {
        guard let startedAt, let lastPointAt else { return finishedDuration }
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
        finishedDuration = 0
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
        finishedDuration = durationSeconds
        defer { startedAt = nil }
        guard let startedAt, distanceMeters >= 100 else { return }
        // Рейтинг считаем по сырому треку (упрощённый теряет пики скорости).
        let scorePasses = passed.map { DrivingScore.Pass(speedKmh: $0.speedKmh, limitKmh: $0.limitKmh) }
        let score = DrivingScore.tripScore(passes: scorePasses,
                                           trackSpeeds: trackBuffer.map(\.speedKmh))
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
                                                maxPoints: Self.trackMaxPoints)),
            score: score
        )
        history.insert(record, at: 0)
        history = TripHistory.pruned(history)
        lifetime = LifetimeStats.updated(lifetime, passes: scorePasses, distanceMeters: distanceMeters)
        persist()
        persistLifetime()
        onTripFinished?()
    }

    func deleteRecord(id: Double) {
        history.removeAll { $0.id == id }
        persist()
    }

    func clearHistory() {
        history = []
        persist()
    }

    // MARK: - Рейтинг и экономия

    /// Текущий рейтинг: средний балл поездок за 30 дней, взвешенный по дистанции.
    var rating: Int? {
        TripHistory.weightedRating(history, within: 30 * 86400, now: Date())
    }

    /// Тренд к прошлой неделе — для стрелки у кольца рейтинга.
    var ratingTrend: Int? {
        let now = Date()
        guard let current = TripHistory.weightedRating(history, within: 7 * 86400, now: now),
              let previous = TripHistory.weightedRating(history, within: 7 * 86400,
                                                        now: now.addingTimeInterval(-7 * 86400))
        else { return nil }
        return current - previous
    }

    /// Сводка за последние 7 дней — заголовок истории.
    var weekSummary: (trips: Int, distance: CLLocationDistance, cameras: Int)? {
        TripHistory.weekSummary(history)
    }

    /// Что показывать в шапке Итогов: живую сессию (nil) или последнюю поездку.
    func fallbackRecord(isTripActive: Bool) -> TripRecord? {
        TripHistory.fallbackRecord(history: history, isTripActive: isTripActive,
                                   liveDistance: distanceMeters)
    }

    /// «Сэкономлено на штрафах» за последние 30 дней (по истории; пожизненное — в lifetime).
    var month30: (clean: Int, over: Int, risk: Double, topOverLocation: String?) {
        TripHistory.month30(history)
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
        if let decoded = JSONFile.load([TripRecord].self, from: storeURL, log: Log.trips) {
            history = decoded
        }
        if let data = Storage.data(.lifetimeStats) {
            do {
                lifetime = try JSONDecoder().decode(LifetimeStats.self, from: data)
            } catch {
                // Не читается — ниже восстановим из истории (backfill).
                Log.trips.error("lifetimeStats не декодировались: \(error.localizedDescription, privacy: .public)")
            }
        }
        // Одноразовая гео-чистка: старые версии засчитывали камеры с параллельных
        // улиц — выкидываем их из истории и пересчитываем баллы и счётчики.
        if !Storage.bool(.passGeoCleanup1) {
            let (cleaned, changed) = TripHistory.sanitized(history)
            if changed {
                history = cleaned
                lifetime = LifetimeStats.rebuilt(from: history)
                persist()
                persistLifetime()
            }
            Storage.set(true, for: .passGeoCleanup1)
        }
        // Обновились с версии без счётчиков, а поездки уже есть — восстанавливаем
        // из истории, чтобы экономия и достижения не начинались с нуля.
        if lifetime.trips == 0 && !history.isEmpty {
            lifetime = LifetimeStats.rebuilt(from: history)
            persistLifetime()
        }
    }

    private func persistLifetime() {
        do {
            Storage.set(try JSONEncoder().encode(lifetime), for: .lifetimeStats)
        } catch {
            Log.trips.error("lifetimeStats не сохранились: \(error.localizedDescription, privacy: .public)")
        }
    }
    private func persist() {
        JSONFile.save(history, to: storeURL, log: Log.trips)
    }
}
