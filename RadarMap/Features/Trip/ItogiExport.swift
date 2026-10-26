//
//  ItogiExport.swift
//  RadarMap
//
//  «Выгрузить период» в «Итогах» (31E, п. 6): CSV или PDF поездок окна —
//  через системный «Поделиться». Чистая часть (строки, CSV, имена) —
//  PeriodExport; здесь сборка на главном акторе (районы по базе камер,
//  подписи на языке приложения) и запись файлов вне main.
//
//  Файлы — во временной папке, которую экран удаляет после «Поделиться»;
//  оставленные вылетом — при следующей выгрузке (как у архива TripExport).
//

import SwiftUI
import CoreLocation
import os

enum ItogiExport {
    enum Format { case csv, pdf }

    /// Готовые к записи данные: всё, что требует главного актора, — уже здесь.
    struct Input: Sendable {
        let format: Format
        let rows: [PeriodExport.Row]
        let shifts: [WorkShift]
        let interval: DateInterval
        let timeZone: TimeZone
        let pdf: PeriodExportPDF.Document?
    }

    nonisolated static let workPrefix = "RadarMap-period-"

    /// Собрать выгрузку периода. nil — в окне нет хранящихся поездок.
    @MainActor
    static func prepare(_ format: Format, env: AppEnvironment, period: StatsPeriod, anchor: Date,
                        summary: PeriodSummary) -> Input? {
        let interval = period.interval(containing: anchor)
        let records = TripHistory.records(env.trip.history, period: period, anchor: anchor)
        guard !records.isEmpty else { return nil }
        var ends: [Double: PeriodExport.Ends] = [:]
        for record in records {
            ends[record.id] = PeriodExport.Ends(from: record.startCoordinate.flatMap { district(at: $0, env: env) },
                                                to: record.endCoordinate.flatMap { district(at: $0, env: env) })
        }
        let rows = PeriodExport.rows(records, ends: ends)
        let shifts = PeriodExport.shifts(records, in: interval)
        let pdf = format == .pdf
            ? document(rows: rows, shifts: shifts, title: period.rangeTitle(containing: anchor), summary: summary)
            : nil
        return Input(format: format, rows: rows, shifts: shifts, interval: interval, timeZone: .current, pdf: pdf)
    }

    /// Район ближайшей камеры базы (не своей и не отметки водителей).
    @MainActor
    private static func district(at point: CLLocationCoordinate2D, env: AppEnvironment) -> String? {
        guard let camera = env.cameras.nearest(to: point, limit: 4)
            .first(where: { $0.id < CameraStore.firstCustomID }) else { return nil }
        let distance = GeoMath.fastDistance(point.latitude, point.longitude, camera.lat, camera.lon)
        return PeriodExport.district(city: camera.city, distance: distance)
    }

    @MainActor
    private static func document(rows: [PeriodExport.Row], shifts: [WorkShift], title: String,
                                 summary: PeriodSummary) -> PeriodExportPDF.Document {
        let totals = PeriodExport.totals(rows)
        func day(_ date: Date) -> String { Formatting.date(date, .dateTime.day().month(.abbreviated)) }
        var lines = [
            String(format: String(localized: "Поездок: %1$lld · %2$@ · в движении %3$@"),
                   totals.trips, Formatting.distance(totals.distanceMeters), Formatting.duration(totals.movingSeconds)),
        ]
        if totals.workTrips > 0 {
            lines.append(String(format: String(localized: "Рабочие рейсы: %1$lld · %2$@"),
                                totals.workTrips, Formatting.distance(totals.workMeters)))
        }
        var tables = [PeriodExportPDF.Table(
            title: String(localized: "Поездки"),
            headers: [String(localized: "Дата"), String(localized: "Время"), String(localized: "Км"),
                      String(localized: "В пути"), String(localized: "Откуда"), String(localized: "Куда")],
            widths: [0.13, 0.17, 0.10, 0.14, 0.23, 0.23],
            rows: rows.map { row in
                [day(row.start),
                 "\(Formatting.clock(row.start))–\(Formatting.clock(row.end))",
                 Formatting.decimal(row.distanceMeters / 1000),
                 Formatting.duration(row.totalSeconds),
                 row.from ?? "—", row.to ?? "—"]
            })]
        if !shifts.isEmpty {
            tables.append(PeriodExportPDF.Table(
                title: String(localized: "Смены"),
                headers: [String(localized: "Дата"), String(localized: "Время"), String(localized: "Рейсов"),
                          String(localized: "Км"), String(localized: "В движении")],
                widths: [0.18, 0.24, 0.16, 0.18, 0.24],
                rows: shifts.sorted { $0.start < $1.start }.map { shift in
                    [day(shift.start), "\(Formatting.clock(shift.start))–\(Formatting.clock(shift.end))",
                     "\(shift.trips)", Formatting.decimal(shift.distanceMeters / 1000),
                     Formatting.duration(shift.movingSeconds)]
                }))
        }
        // Записи поездок живут 30 дней: если в окне их было больше, чем
        // хранится, — сказать, а не выдать неполную таблицу за полную.
        var footer = String(localized: "RadarMap. Районы — по ближайшей камере из базы; адресов и координат в файле нет.")
        if summary.trips > totals.trips {
            footer += " " + String(format: String(localized: "За период поездок %1$lld, подробно хранятся %2$lld (записи живут 30 дней)."),
                                   summary.trips, totals.trips)
        }
        return PeriodExportPDF.Document(title: String(format: String(localized: "Поездки: %@"), title),
                                        subtitle: String(localized: "Отчёт RadarMap о поездках"),
                                        totals: lines, tables: tables, footer: footer)
    }

    /// Записать файлы во временную папку. Возвращает файлы и папку (её
    /// удалить после «Поделиться»).
    @concurrent
    static func write(_ input: Input, root: URL = FileManager.default.temporaryDirectory) async throws
        -> (files: [URL], folder: URL) {
        TripExport.cleanUpStale(in: root, prefix: workPrefix)
        let folder = root.appendingPathComponent(workPrefix + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var files: [URL] = []
            switch input.format {
            case .csv:
                let trips = folder.appendingPathComponent(PeriodExport.fileName(input.interval, ext: "csv",
                                                                                timeZone: input.timeZone))
                try PeriodExport.tripsCSV(input.rows, timeZone: input.timeZone)
                    .write(to: trips, atomically: true, encoding: .utf8)
                files.append(trips)
                if !input.shifts.isEmpty {
                    let shifts = folder.appendingPathComponent(PeriodExport.fileName(
                        input.interval, suffix: "-shifts", ext: "csv", timeZone: input.timeZone))
                    try PeriodExport.shiftsCSV(input.shifts, timeZone: input.timeZone)
                        .write(to: shifts, atomically: true, encoding: .utf8)
                    files.append(shifts)
                }
            case .pdf:
                guard let document = input.pdf else { break }
                let file = folder.appendingPathComponent(PeriodExport.fileName(input.interval, ext: "pdf",
                                                                               timeZone: input.timeZone))
                try PeriodExportPDF.render(document).write(to: file, options: .atomic)
                files.append(file)
            }
            return (files, folder)
        } catch {
            Log.trips.error("выгрузка периода не собралась: \(error.localizedDescription, privacy: .public)")
            TripExport.remove(folder)
            throw error
        }
    }
}

extension TripStatsSheet {
    /// Собрать и отдать в «Поделиться» выгрузку периода (31E).
    func export(_ format: ItogiExport.Format, summary: PeriodSummary) {
        guard let input = ItogiExport.prepare(format, env: env, period: period, anchor: anchor,
                                              summary: summary) else {
            exportFailed = true
            return
        }
        exporting = true
        Task {
            defer { exporting = false }
            do {
                let written = try await ItogiExport.write(input)
                exportShare = ShareFilesPayload(files: written.files, folder: written.folder)
            } catch {
                // Причина — в журнале (ItogiExport); человеку — что делать.
                exportFailed = true
            }
        }
    }

}

/// Несколько файлов в системный «Поделиться»; по закрытию — убрать папку.
struct ShareFilesPayload: Identifiable {
    let id = UUID()
    let files: [URL]
    let folder: URL
}

struct ActivityFilesSheet: UIViewControllerRepresentable {
    let payload: ShareFilesPayload
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: payload.files, applicationActivities: nil)
        let folder = payload.folder
        controller.completionWithItemsHandler = { _, _, _, _ in
            Task.detached(priority: .utility) { TripExport.remove(folder) }
            dismiss()
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
