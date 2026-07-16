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
    /// Рейтинг поездки 0–100 (у старых записей отсутствует).
    var score: Double?

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
    /// Пожизненные счётчики — живут отдельно от истории (она обрезается до 50 поездок).
    private(set) var lifetime = LifetimeStats()
    /// Вызывается после сохранения поездки (AppEnvironment вешает сюда недельный дайджест).
    @ObservationIgnored var onTripFinished: (() -> Void)?

    @ObservationIgnored private var lastCoordinate: CLLocationCoordinate2D?
    /// Сырой трек текущей поездки: точка каждые ≥30 м, упрощается при финише.
    @ObservationIgnored private var trackBuffer: [TrackPoint] = []
    private static let maxHistory = 50
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
        history = Self.pruned(history)
        lifetime = LifetimeStats.updated(lifetime, passes: scorePasses, distanceMeters: distanceMeters)
        persist()
        persistLifetime()
        onTripFinished?()
    }

    /// Сколько поездок показывает список истории.
    static let visibleHistory = 7

    /// Чистка хранилища: список живёт 7 поездками, более старые нужны только
    /// статистике (рейтинг и экономия за 30 дней) — у них выбрасываем тяжёлый трек,
    /// а старше 30 дней удаляем совсем (пожизненные цифры давно в lifetime).
    nonisolated static func pruned(_ history: [TripRecord], now: Date = Date()) -> [TripRecord] {
        let monthAgo = now.addingTimeInterval(-30 * 86400)
        var result: [TripRecord] = []
        result.reserveCapacity(min(history.count, maxHistory))
        for (index, record) in history.enumerated() {
            if index < visibleHistory {
                result.append(record)
            } else if record.startedAt > monthAgo && result.count < maxHistory {
                var slim = record
                slim.track = nil
                result.append(slim)
            }
        }
        return result
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

    // MARK: - Рейтинг и экономия

    /// Текущий рейтинг: средний балл поездок за 30 дней, взвешенный по дистанции
    /// (длинная трасса весит больше короткой поездки до магазина).
    var rating: Int? {
        Self.weightedRating(history, within: 30 * 86400, now: Date())
    }

    /// Тренд к прошлой неделе: (текущая неделя, прошлая неделя) — для стрелки у кольца.
    var ratingTrend: Int? {
        let now = Date()
        guard let current = Self.weightedRating(history, within: 7 * 86400, now: now),
              let previous = Self.weightedRating(history, within: 7 * 86400,
                                                 now: now.addingTimeInterval(-7 * 86400))
        else { return nil }
        return current - previous
    }

    nonisolated private static func weightedRating(_ history: [TripRecord],
                                                   within interval: TimeInterval,
                                                   now: Date) -> Int? {
        let from = now.addingTimeInterval(-interval)
        var weightedSum = 0.0
        var weight = 0.0
        for record in history where record.startedAt > from && record.startedAt <= now {
            guard let score = record.score else { continue }
            let w = max(record.distanceMeters, 500)
            weightedSum += score * w
            weight += w
        }
        guard weight > 0 else { return nil }
        return Int((weightedSum / weight).rounded())
    }

    /// «Сэкономлено на штрафах» за последние 30 дней (по истории; пожизненное — в lifetime).
    var monthSaved: Double {
        let from = Date().addingTimeInterval(-30 * 86400)
        var sum = 0.0
        for record in history where record.startedAt > from {
            for pass in record.passed {
                guard let limit = pass.limitKmh else { continue }
                if FineSchedule.fine(overKmh: pass.speedKmh - Double(limit)) == 0 {
                    sum += FineSchedule.minimumFine
                }
            }
        }
        return sum
    }

    /// «Возможные штрафы» поездки/записи — красная строка в деталке.
    nonisolated static func fineRisk(of passes: [PassedCamera]) -> Double {
        passes.reduce(0.0) { total, pass in
            guard let limit = pass.limitKmh else { return total }
            return total + FineSchedule.fine(overKmh: pass.speedKmh - Double(limit))
        }
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

    // MARK: - Гео-чистка проездов

    /// Расстояние (метры) от точки до ломаной трека — по сегментам, не по вершинам:
    /// после Дугласа-Пекера прямые участки хранят только концы.
    nonisolated static func distanceToTrack(lat: Double, lon: Double,
                                            track: [TrackPoint]) -> Double {
        guard let first = track.first else { return .greatestFiniteMagnitude }
        let metersPerLat = 111_320.0
        let metersPerLon = 111_320.0 * cos(first.lat * .pi / 180)
        func project(_ plat: Double, _ plon: Double) -> (x: Double, y: Double) {
            ((plon - first.lon) * metersPerLon, (plat - first.lat) * metersPerLat)
        }
        let p = project(lat, lon)
        guard track.count >= 2 else {
            let a = project(first.lat, first.lon)
            return hypot(p.x - a.x, p.y - a.y)
        }
        var best = Double.greatestFiniteMagnitude
        var a = project(track[0].lat, track[0].lon)
        for i in 1..<track.count {
            let b = project(track[i].lat, track[i].lon)
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            let t = len2 > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2)) : 0
            best = min(best, hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy)))
            a = b
        }
        return best
    }

    /// Порог ретро-чистки: трек упрощён (±22 м) и записан раз в 30 м,
    /// поэтому допуск шире живого гейта в LocationService.
    nonisolated static let passCleanupMaxMeters = 120.0

    /// Ретро-чистка истории: убирает «проезды» камер, до которых трек ближе
    /// 120 м не подходил (раньше засчитывались камеры с параллельных улиц),
    /// и пересчитывает балл затронутых поездок. Возвращает (история, менялось ли).
    nonisolated static func sanitized(_ history: [TripRecord]) -> ([TripRecord], Bool) {
        var changed = false
        let cleaned = history.map { record -> TripRecord in
            let track = record.trackPoints
            guard track.count >= 2, !record.passed.isEmpty else { return record }
            let kept = record.passed.filter { pass in
                guard let lat = pass.lat, let lon = pass.lon else { return true }
                return distanceToTrack(lat: lat, lon: lon, track: track) <= passCleanupMaxMeters
            }
            guard kept.count != record.passed.count else { return record }
            changed = true
            return TripRecord(id: record.id, startedAt: record.startedAt,
                              endedAt: record.endedAt,
                              distanceMeters: record.distanceMeters,
                              maxSpeedKmh: record.maxSpeedKmh, passed: kept,
                              endLat: record.endLat, endLon: record.endLon,
                              track: record.track,
                              score: DrivingScore.tripScore(
                                  passes: kept.map {
                                      DrivingScore.Pass(speedKmh: $0.speedKmh,
                                                        limitKmh: $0.limitKmh)
                                  },
                                  trackSpeeds: track.map(\.speedKmh)))
        }
        return (cleaned, changed)
    }

    // MARK: - Хранение

    private var storeURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("trips.json")
    }
    private static let lifetimeKey = "lifetimeStats"

    private func loadHistory() {
        if let data = try? Data(contentsOf: storeURL),
           let decoded = try? JSONDecoder().decode([TripRecord].self, from: data) {
            history = decoded
        }
        if let data = UserDefaults.standard.data(forKey: Self.lifetimeKey),
           let decoded = try? JSONDecoder().decode(LifetimeStats.self, from: data) {
            lifetime = decoded
        }
        // Одноразовая гео-чистка: старые версии засчитывали камеры с параллельных
        // улиц — выкидываем их из истории и пересчитываем баллы и счётчики.
        let cleanupKey = "passGeoCleanup1"
        if !UserDefaults.standard.bool(forKey: cleanupKey) {
            let (cleaned, changed) = Self.sanitized(history)
            if changed {
                history = cleaned
                lifetime = LifetimeStats.rebuilt(from: history)
                persist()
                persistLifetime()
            }
            UserDefaults.standard.set(true, forKey: cleanupKey)
        }
        // Обновились с версии без счётчиков, а поездки уже есть — восстанавливаем
        // из истории, чтобы экономия и достижения не начинались с нуля.
        if lifetime.trips == 0 && !history.isEmpty {
            lifetime = LifetimeStats.rebuilt(from: history)
            persistLifetime()
        }
    }

    private func persistLifetime() {
        guard let data = try? JSONEncoder().encode(lifetime) else { return }
        UserDefaults.standard.set(data, forKey: Self.lifetimeKey)
    }
    private func persist() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
