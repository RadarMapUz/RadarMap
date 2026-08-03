//
//  PeriodSummary.swift
//  RadarMap
//
//  Сводка за период для отчёта «Неделя / Месяц / Всё время». Раньше на экране
//  Итогов была одна строчка «за 7 дней: N поездок» — по ней нельзя понять,
//  стал ты ездить аккуратнее или нет. Здесь считается всё, что отвечает на
//  вопрос «как прошла неделя», включая сравнение с прошлой.
//
//  Чистые функции без Date.now по умолчанию внутри вычислений — время всегда
//  приходит параметром, поэтому всё воспроизводимо в тестах (PeriodSummaryTests).
//

import Foundation
import CoreLocation

/// Период отчёта. nonisolated: читается из чистого TripHistory и его тестов.
nonisolated enum StatsPeriod: String, CaseIterable, Identifiable {
    case week, month, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week:  return String(localized: "Неделя")
        case .month: return String(localized: "Месяц")
        case .all:   return String(localized: "Всё время")
        }
    }

    /// Длина окна в секундах; nil — без ограничения.
    var interval: TimeInterval? {
        switch self {
        case .week:  return 7 * 86400
        case .month: return 30 * 86400
        case .all:   return nil
        }
    }

    /// Сколько столбиков в графике по дням (для «всего времени» график не нужен).
    var chartDays: Int? {
        switch self {
        case .week:  return 7
        case .month: return 30
        case .all:   return nil
        }
    }
}

/// Всё, что показывает отчёт за период.
nonisolated struct PeriodSummary: Equatable {
    var trips = 0
    var distance: CLLocationDistance = 0
    /// Время в движении — стоянки склеенных поездок исключены.
    var movingDuration: TimeInterval = 0
    var cameras = 0
    /// Проезды камер в лимите и с штрафуемым превышением.
    var cleanPasses = 0
    var overPasses = 0
    var maxSpeedKmh: Double = 0
    /// Средний балл за период, взвешенный по дистанции.
    var rating: Int?
    /// Возможные штрафы за период (по реальным ступеням BRV).
    var fineRisk: Double = 0
    /// Камера, где превышали чаще всего — «зона риска».
    var topOverLocation: String?
    /// Самый активный день периода.
    var busiestDay: Date?
    var busiestDayKm: Double = 0
    /// Дистанция за предыдущий такой же период — база для дельты.
    var previousDistance: CLLocationDistance = 0

    var isEmpty: Bool { trips == 0 }
    var averageSpeedKmh: Double {
        movingDuration > 0 ? distance / movingDuration * 3.6 : 0
    }
    /// Доля чистых проездов 0…1 (nil — камер за период не было).
    var cleanShare: Double? {
        let total = cleanPasses + overPasses
        return total > 0 ? Double(cleanPasses) / Double(total) : nil
    }
    /// Насколько больше/меньше проехали, чем в предыдущем таком же периоде.
    /// nil — сравнивать не с чем (первый период).
    var distanceDeltaPercent: Int? {
        guard previousDistance > 500 else { return nil }
        return Int(((distance / previousDistance - 1) * 100).rounded())
    }
}

extension TripHistory {

    /// Сводка за период. `now` параметром — чтобы тесты не зависели от часов.
    static func summary(_ history: [TripRecord], period: StatsPeriod,
                        calendar: Calendar = .current,
                        now: Date = Date()) -> PeriodSummary {
        var result = PeriodSummary()
        let records = self.records(history, period: period, now: now)
        guard !records.isEmpty else { return result }

        var overByLocation: [String: Int] = [:]
        var kmByDay: [Date: Double] = [:]
        for record in records {
            result.trips += 1
            result.distance += record.distanceMeters
            result.movingDuration += record.movingDuration
            result.cameras += record.camerasPassed
            result.maxSpeedKmh = max(result.maxSpeedKmh, record.maxSpeedKmh)
            let day = calendar.startOfDay(for: record.startedAt)
            kmByDay[day, default: 0] += record.distanceMeters / 1000

            for pass in record.passed {
                // Без известного лимита нарушения не выдумываем — как в month30.
                guard let limit = pass.limitKmh else { continue }
                let fine = FineSchedule.fine(overKmh: pass.speedKmh - Double(limit))
                if fine > 0 {
                    result.overPasses += 1
                    result.fineRisk += fine
                    if !pass.location.isEmpty { overByLocation[pass.location, default: 0] += 1 }
                } else {
                    result.cleanPasses += 1
                }
            }
        }
        result.topOverLocation = overByLocation.max { $0.value < $1.value }?.key
        if let busiest = kmByDay.max(by: { $0.value < $1.value }) {
            result.busiestDay = busiest.key
            result.busiestDayKm = busiest.value
        }
        result.rating = weightedRating(
            history,
            from: period.interval.map { now.addingTimeInterval(-$0) } ?? .distantPast,
            now: now)
        result.previousDistance = previousDistance(history, period: period, now: now)
        return result
    }

    /// Записи, попадающие в период.
    static func records(_ history: [TripRecord], period: StatsPeriod,
                        now: Date = Date()) -> [TripRecord] {
        guard let interval = period.interval else { return history }
        let from = now.addingTimeInterval(-interval)
        return history.filter { $0.startedAt > from && $0.startedAt <= now }
    }

    /// Дистанция за предыдущее такое же окно — для стрелки «больше/меньше».
    private static func previousDistance(_ history: [TripRecord], period: StatsPeriod,
                                         now: Date) -> CLLocationDistance {
        guard let interval = period.interval else { return 0 }
        let to = now.addingTimeInterval(-interval)
        let from = to.addingTimeInterval(-interval)
        return history
            .filter { $0.startedAt > from && $0.startedAt <= to }
            .reduce(0) { $0 + $1.distanceMeters }
    }

    /// Километры по дням периода (нулевые дни включены) — данные графика.
    static func dailyKm(_ history: [TripRecord], days: Int,
                        calendar: Calendar = .current,
                        now: Date = Date()) -> [(day: Date, km: Double)] {
        let today = calendar.startOfDay(for: now)
        var kmByDay: [Date: Double] = [:]
        for record in history {
            kmByDay[calendar.startOfDay(for: record.startedAt), default: 0]
                += record.distanceMeters / 1000
        }
        return (0..<days).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today)
            else { return nil }
            return (day, kmByDay[day] ?? 0)
        }
    }

    /// Треки периода для карты отчёта: только те записи, у которых трек ещё жив
    /// (см. pruned — за пределами недели он выброшен).
    static func tracks(_ history: [TripRecord], period: StatsPeriod,
                       now: Date = Date()) -> [[TrackPoint]] {
        records(history, period: period, now: now)
            .map(\.trackPoints)
            .filter { $0.count >= 2 }
    }

    /// Проезды камер периода, сгруппированные по точке: сколько раз проезжали и
    /// было ли превышение. Маркеры карты отчёта.
    static func passMarkers(_ history: [TripRecord], period: StatsPeriod,
                            now: Date = Date()) -> [PassMarker] {
        var byCamera: [Int: PassMarker] = [:]
        for record in records(history, period: period, now: now) {
            for pass in record.passed {
                guard let lat = pass.lat, let lon = pass.lon else { continue }
                let over = pass.limitKmh.map {
                    FineSchedule.fine(overKmh: pass.speedKmh - Double($0)) > 0
                } ?? false
                if var existing = byCamera[pass.cameraID] {
                    existing.times += 1
                    existing.overTimes += over ? 1 : 0
                    byCamera[pass.cameraID] = existing
                } else {
                    byCamera[pass.cameraID] = PassMarker(
                        cameraID: pass.cameraID, lat: lat, lon: lon,
                        location: pass.location, times: 1, overTimes: over ? 1 : 0)
                }
            }
        }
        return byCamera.values.sorted { $0.times > $1.times }
    }
}

/// Камера на карте отчёта: сколько раз проезжали и сколько из них с превышением.
nonisolated struct PassMarker: Identifiable, Equatable {
    let cameraID: Int
    let lat: Double
    let lon: Double
    let location: String
    var times: Int
    var overTimes: Int

    var id: Int { cameraID }
    var hasViolation: Bool { overTimes > 0 }
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}
