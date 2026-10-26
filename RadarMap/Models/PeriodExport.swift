//
//  PeriodExport.swift
//  RadarMap
//
//  Выгрузка поездок периода (31E, п. 6): CSV и PDF из «Итогов» через
//  системный «Поделиться» — служебные километры, отчёт таксиста.
//
//  Чем отличается от «Скачать мои данные» (TripExport, Настройки): там архив
//  всего, что лежит на телефоне, с треками; здесь — таблица выбранного
//  периода для человека или бухгалтерии. Поэтому:
//    * поля — дата, начало, конец, км, время в пути и в движении, откуда и
//      куда — и только;
//    * «откуда/куда» — НАЗВАНИЕМ РАЙОНА, и только если он уже есть на
//      телефоне: у камер базы записан район («Yunusobod tumani»), и район
//      ближайшей камеры не дальше `exportDistrictMaxMeters` — это он. Нет
//      камеры рядом — пусто, а не адрес: файл уходит туда, куда его отправят,
//      и ни дома, ни точек в нём быть не должно;
//    * для режима водителя — смены (WorkShift) вторым файлом.
//
//  Чистая часть — PeriodExportTests; PDF рисует PeriodExportPDF (UIKit).
//

import Foundation

nonisolated enum PeriodExport {

    /// Строка поездки — уже без координат.
    struct Row: Equatable, Sendable {
        let start: Date
        let end: Date
        let distanceMeters: Double
        let movingSeconds: TimeInterval
        let from: String?
        let to: String?
        let work: Bool

        var totalSeconds: TimeInterval { max(0, end.timeIntervalSince(start)) }
    }

    /// Районы концов поездки, посчитанные на main (база камер живёт там).
    struct Ends: Equatable, Sendable {
        let from: String?
        let to: String?
    }

    /// Строки периода от старых к новым.
    static func rows(_ records: [TripRecord], ends: [Double: Ends]) -> [Row] {
        records.sorted { $0.startedAt < $1.startedAt }.map { record in
            Row(start: record.startedAt, end: record.endedAt,
                distanceMeters: record.distanceMeters, movingSeconds: record.movingDuration,
                from: ends[record.id]?.from, to: ends[record.id]?.to, work: record.work == true)
        }
    }

    /// Район по ближайшей камере: её `city`, если она не дальше порога.
    /// Пустое название — нет района.
    static func district(city: String?, distance: Double,
                         maxMeters: Double = AppConfig.exportDistrictMaxMeters) -> String? {
        guard let city, distance <= maxMeters else { return nil }
        let trimmed = city.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - CSV

    static let tripsHeader = ["date", "start", "end", "distance_km", "duration_min", "moving_min",
                              "from_district", "to_district", "work"]
    static let shiftsHeader = ["date", "start", "end", "trips", "distance_km", "moving_min",
                               "overspeeds"]

    /// Таблица поездок. Время местное, числа с точкой (так требует CSV),
    /// заголовки латиницей — их разбирают программы, а кириллица в чужой
    /// кодировке превращается в кракозябры. Экранирование — общее с
    /// архивом (TripExport.escape: формулы и кавычки).
    static func tripsCSV(_ rows: [Row], timeZone: TimeZone) -> String {
        let day = formatter("yyyy-MM-dd", timeZone: timeZone)
        let clock = formatter("HH:mm", timeZone: timeZone)
        var lines = [TripExport.line(tripsHeader)]
        for row in rows {
            lines.append(TripExport.line([
                day.string(from: row.start),
                clock.string(from: row.start),
                clock.string(from: row.end),
                String(format: "%.2f", row.distanceMeters / 1000),
                String(format: "%.0f", row.totalSeconds / 60),
                String(format: "%.0f", row.movingSeconds / 60),
                row.from ?? "",
                row.to ?? "",
                row.work ? "1" : "0",
            ]))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Смены периода от старых к новым.
    static func shiftsCSV(_ shifts: [WorkShift], timeZone: TimeZone) -> String {
        let day = formatter("yyyy-MM-dd", timeZone: timeZone)
        let clock = formatter("HH:mm", timeZone: timeZone)
        var lines = [TripExport.line(shiftsHeader)]
        for shift in shifts.sorted(by: { $0.start < $1.start }) {
            lines.append(TripExport.line([
                day.string(from: shift.start),
                clock.string(from: shift.start),
                clock.string(from: shift.end),
                String(shift.trips),
                String(format: "%.2f", shift.distanceMeters / 1000),
                String(format: "%.0f", shift.movingSeconds / 60),
                String(shift.overspeeds),
            ]))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Итог для шапки PDF и проверки CSV сложением.
    struct Totals: Equatable, Sendable {
        var trips = 0
        var distanceMeters = 0.0
        var movingSeconds: TimeInterval = 0
        var workTrips = 0
        var workMeters = 0.0
    }

    static func totals(_ rows: [Row]) -> Totals {
        rows.reduce(into: Totals()) { sum, row in
            sum.trips += 1
            sum.distanceMeters += row.distanceMeters
            sum.movingSeconds += row.movingSeconds
            if row.work {
                sum.workTrips += 1
                sum.workMeters += row.distanceMeters
            }
        }
    }

    /// Смены, целиком лежащие в окне (смена через полночь границы — в окне
    /// своего начала).
    static func shifts(_ records: [TripRecord], in interval: DateInterval) -> [WorkShift] {
        WorkShift.shifts(from: records).filter { $0.start >= interval.start && $0.start < interval.end }
    }

    // MARK: - Имена файлов

    /// «RadarMap-2026-10-19_2026-10-25.csv»: латиницей, как у архива.
    static func fileName(_ interval: DateInterval, suffix: String = "", ext: String,
                         timeZone: TimeZone) -> String {
        let day = formatter("yyyy-MM-dd", timeZone: timeZone)
        let first = day.string(from: interval.start)
        let last = day.string(from: interval.end.addingTimeInterval(-1))
        let span = first == last ? first : "\(first)_\(last)"
        return "RadarMap-\(span)\(suffix).\(ext)"
    }

    private static func formatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }
}
