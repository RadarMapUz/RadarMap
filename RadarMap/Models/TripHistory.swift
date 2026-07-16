//
//  TripHistory.swift
//  RadarMap
//
//  Аналитика истории поездок: чистые функции без состояния — рейтинг, экономия,
//  сводки, группировки, чистка хранилища. Всё покрывается тестами напрямую;
//  вьюхи и TripStats читают готовые результаты.
//

import Foundation
import CoreLocation

nonisolated enum TripHistory {
    /// Сколько поездок показывает список истории.
    static let visibleHistory = 7
    /// Потолок хранилища: дальше даже «цифры для статистики» не копим.
    static let maxHistory = 50

    // MARK: - Чистка хранилища

    /// Список живёт 7 поездками, более старые нужны только статистике
    /// (рейтинг и экономия за 30 дней) — у них выбрасываем тяжёлый трек,
    /// а старше 30 дней удаляем совсем (пожизненные цифры давно в lifetime).
    static func pruned(_ history: [TripRecord], now: Date = Date()) -> [TripRecord] {
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

    // MARK: - Рейтинг и экономия

    /// Средний балл поездок за интервал, взвешенный по дистанции
    /// (длинная трасса весит больше короткой поездки до магазина).
    static func weightedRating(_ history: [TripRecord],
                               within interval: TimeInterval, now: Date) -> Int? {
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

    /// «Сэкономлено на штрафах» за последние 30 дней.
    static func monthSaved(_ history: [TripRecord], now: Date = Date()) -> Double {
        let from = now.addingTimeInterval(-30 * 86400)
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
    static func fineRisk(of passes: [PassedCamera]) -> Double {
        passes.reduce(0.0) { total, pass in
            guard let limit = pass.limitKmh else { return total }
            return total + FineSchedule.fine(overKmh: pass.speedKmh - Double(limit))
        }
    }

    // MARK: - Сводки для экрана Итогов

    /// Сводка за последние 7 дней — заголовок истории.
    static func weekSummary(_ history: [TripRecord], now: Date = Date())
        -> (trips: Int, distance: CLLocationDistance, cameras: Int)? {
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)
        let recent = history.filter { $0.startedAt > weekAgo }
        guard !recent.isEmpty else { return nil }
        return (recent.count,
                recent.reduce(0) { $0 + $1.distanceMeters },
                recent.reduce(0) { $0 + $1.camerasPassed })
    }

    /// Километры по дням последней недели (7 точек, нулевые дни включены) —
    /// данные недельного графика.
    static func weekDaily(_ history: [TripRecord], calendar: Calendar = .current,
                          now: Date = Date()) -> [(day: Date, km: Double)] {
        let today = calendar.startOfDay(for: now)
        return (0..<7).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let km = history
                .filter { calendar.isDate($0.startedAt, inSameDayAs: day) }
                .reduce(0.0) { $0 + $1.distanceMeters } / 1000
            return (day, km)
        }
    }

    struct DayGroup {
        let day: Date
        let records: [TripRecord]
    }

    /// История приходит от новых к старым — группировка по календарным дням
    /// сохраняет порядок и не пересортировывает записи внутри дня.
    static func dayGroups(_ history: [TripRecord],
                          calendar: Calendar = .current) -> [DayGroup] {
        var groups: [DayGroup] = []
        for record in history {
            let day = calendar.startOfDay(for: record.startedAt)
            if let last = groups.indices.last, groups[last].day == day {
                groups[last] = DayGroup(day: day, records: groups[last].records + [record])
            } else {
                groups.append(DayGroup(day: day, records: [record]))
            }
        }
        return groups
    }

    /// Что показывать в шапке Итогов: живую сессию (nil) или последнюю поездку.
    static func fallbackRecord(history: [TripRecord], isTripActive: Bool,
                               liveDistance: CLLocationDistance) -> TripRecord? {
        (isTripActive || liveDistance > 0) ? nil : history.first
    }

    // MARK: - Гео-чистка проездов

    /// Расстояние (метры) от точки до ломаной трека — по сегментам, не по вершинам:
    /// после Дугласа-Пекера прямые участки хранят только концы.
    static func distanceToTrack(lat: Double, lon: Double, track: [TrackPoint]) -> Double {
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
    /// поэтому допуск шире живого гейта (80 м) в PassTracking.
    static let passCleanupMaxMeters = 120.0

    /// Ретро-чистка истории: убирает «проезды» камер, до которых трек ближе
    /// 120 м не подходил (раньше засчитывались камеры с параллельных улиц),
    /// и пересчитывает балл затронутых поездок. Возвращает (история, менялось ли).
    static func sanitized(_ history: [TripRecord]) -> ([TripRecord], Bool) {
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
}
