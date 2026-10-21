//
//  TripExport.swift
//  RadarMap
//
//  «Экспорт всех поездок» (15.3): архив ZIP — trips.csv, одна строка на
//  поездку (начало, конец, км, время в движении, балл, проезды камер, риск
//  штрафов, рейс), и GPX каждой поездки, у которой трек ещё хранится.
//  С 21.6 — и energy_journal.csv, журнал заправок и зарядок, если он не пуст:
//  «Скачать мои данные» обещает всё, что человек вписал сам.
//
//  Ни Дома, ни Работы в выгрузке нет: файл уходит туда, куда его отправит
//  человек, и подпись «→ Дом» в каждой строке превратила бы таблицу в адрес.
//  Координаты — только в треках, о которых человек и просил.
//
//  Чистая часть (CSV, имена файлов) покрыта TripExportTests. Архив
//  собирается вне main (@concurrent) во временной папке, которую экран
//  удаляет после «Поделиться»; оставленные вылетом — при следующей выгрузке.
//

import Foundation
import os

nonisolated enum TripExport {

    // MARK: - CSV

    static let csvHeader = ["trip_id", "start", "end", "distance_km", "moving_minutes", "score",
                            "camera_passes", "fine_risk_uzs", "work", "gpx"]

    /// Поле CSV по RFC 4180: запятая, кавычка или перевод строки — в
    /// кавычки, кавычка удваивается. Текст, начатый с = + - @, получает
    /// апостроф: иначе таблица выполнит его как формулу. Числа не трогаем.
    static func escape(_ field: String) -> String {
        var value = field
        if let first = value.first, "=+-@\t\r".contains(first), Double(value) == nil {
            value = "'" + value
        }
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func line(_ fields: [String]) -> String {
        fields.map(escape).joined(separator: ",")
    }

    /// Таблица поездок от старых к новым. Время — местное: человек читает
    /// свои поездки по своим часам, а таблицы разбирают «2026-10-20 08:22:05»
    /// сами. Числа — с точкой, как требует CSV, независимо от языка.
    static func csv(_ records: [TripRecord], gpxNames: [Double: String], timeZone: TimeZone) -> String {
        let stamp = formatter("yyyy-MM-dd HH:mm:ss", timeZone: timeZone)
        var rows = [line(csvHeader)]
        for record in records.sorted(by: { $0.startedAt < $1.startedAt }) {
            rows.append(line([
                String(format: "%.0f", record.id),
                stamp.string(from: record.startedAt),
                stamp.string(from: record.endedAt),
                String(format: "%.2f", record.distanceMeters / 1000),
                String(format: "%.1f", record.movingDuration / 60),
                record.score.map { String(Int($0.rounded())) } ?? "",
                String(record.passed.count),
                String(format: "%.0f", TripHistory.fineRisk(of: record.passed)),
                record.work == true ? "1" : "0",
                gpxNames[record.id].map { "gpx/" + $0 } ?? "",
            ]))
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: - Журнал заправок и зарядок (21.6)

    static let journalFile = "energy_journal.csv"
    static let journalHeader = ["date", "kind", "quantity", "unit", "amount_uzs", "price_per_unit_uzs",
                                "odometer_km", "full"]

    /// Единица — латиницей: таблицу открывают где угодно, а «кВт·ч» в
    /// чужой кодировке превращается в кракозябры.
    static func unit(_ fuel: Fuel) -> String {
        switch fuel {
        case .petrol, .propane: return "l"
        case .methane: return "m3"
        case .electricity: return "kWh"
        }
    }

    /// Журнал от старых к новым; вид — как в файле журнала (petrol,
    /// homeCharge…), числа — с точкой.
    static func journalCSV(_ entries: [JournalEntry], timeZone: TimeZone) -> String {
        let stamp = formatter("yyyy-MM-dd HH:mm", timeZone: timeZone)
        var rows = [line(journalHeader)]
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            rows.append(line([
                stamp.string(from: entry.date),
                entry.kind.rawValue,
                String(format: "%.2f", entry.quantity),
                unit(entry.kind.fuel),
                String(format: "%.0f", entry.amount),
                entry.unitPrice.map { String(format: "%.0f", $0) } ?? "",
                entry.odometerKm.map { String(format: "%.0f", $0) } ?? "",
                entry.isFull ? "1" : "0",
            ]))
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: - Имена файлов

    /// Папка и архив: «RadarMap-trips-2026-10-20». Латиницей: имя вложения
    /// в почте и мессенджерах с кириллицей иногда приходит кракозябрами.
    static func archiveName(now: Date, timeZone: TimeZone) -> String {
        "RadarMap-trips-" + formatter("yyyy-MM-dd", timeZone: timeZone).string(from: now)
    }

    /// GPX поездки — по её началу в местном времени: «2026-10-20_08-22-05.gpx»
    /// (без двоеточий: их не любят файловые системы). Совпало — «…-2.gpx».
    static func gpxNames(for records: [TripRecord], timeZone: TimeZone) -> [Double: String] {
        let stamp = formatter("yyyy-MM-dd_HH-mm-ss", timeZone: timeZone)
        var used = Set<String>()
        var result: [Double: String] = [:]
        for record in records.sorted(by: { $0.startedAt < $1.startedAt }) {
            let base = stamp.string(from: record.startedAt)
            var name = base + ".gpx"
            var suffix = 2
            while used.contains(name) {
                name = "\(base)-\(suffix).gpx"
                suffix += 1
            }
            used.insert(name)
            result[record.id] = name
        }
        return result
    }

    private static func formatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }

    // MARK: - Архив

    /// Готовый архив и папка, в которой он лежит (её и удалить после отправки).
    struct Archive: Sendable {
        let file: URL
        let folder: URL
    }

    static let workPrefix = "RadarMap-export-"

    @concurrent
    static func makeArchive(_ records: [TripRecord], journal: [JournalEntry] = [], now: Date,
                            timeZone: TimeZone,
                            root: URL = FileManager.default.temporaryDirectory) async throws -> Archive {
        cleanUpStale(in: root)
        let fm = FileManager.default
        let work = root.appendingPathComponent(workPrefix + UUID().uuidString, isDirectory: true)
        let folder = work.appendingPathComponent(archiveName(now: now, timeZone: timeZone), isDirectory: true)
        do {
            try fm.createDirectory(at: folder.appendingPathComponent("gpx", isDirectory: true),
                                   withIntermediateDirectories: true)
            // Подробный трек со временем, если он ещё лежит, иначе упрощённый.
            var tracks: [Double: TimedTrack.Trip] = [:]
            for record in records {
                let trip = TimedTrackStore.trip(of: record)
                if trip.points.count >= 2 { tracks[record.id] = trip }
            }
            let names = gpxNames(for: records.filter { tracks[$0.id] != nil }, timeZone: timeZone)
            try csv(records, gpxNames: names, timeZone: timeZone)
                .write(to: folder.appendingPathComponent("trips.csv"), atomically: true, encoding: .utf8)
            if !journal.isEmpty {
                try journalCSV(journal, timeZone: timeZone)
                    .write(to: folder.appendingPathComponent(journalFile), atomically: true, encoding: .utf8)
            }
            for (id, name) in names {
                guard let trip = tracks[id] else { continue }
                try TimedTrack.gpx(trips: [trip])
                    .write(to: folder.appendingPathComponent("gpx/" + name), atomically: true, encoding: .utf8)
            }
            let file = work.appendingPathComponent(folder.lastPathComponent + ".zip")
            try zip(folder, to: file)
            try fm.removeItem(at: folder)
            return Archive(file: file, folder: work)
        } catch {
            Log.trips.error("экспорт поездок не собрался: \(error.localizedDescription, privacy: .public)")
            remove(work)
            throw error
        }
    }

    /// ZIP системными средствами: координатор файлов отдаёт папку архивом
    /// («для отправки»), архив живёт только внутри вызова — копируем.
    static func zip(_ folder: URL, to destination: URL) throws {
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading],
                                       error: &coordinatorError) { zipped in
            do {
                try FileManager.default.copyItem(at: zipped, to: destination)
            } catch {
                copyError = error
            }
        }
        if let error = coordinatorError ?? copyError { throw error }
    }

    /// Убрать папку выгрузки (после «Поделиться»).
    static func remove(_ folder: URL) {
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            Log.trips.error("папка экспорта не удалена: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Выгрузки, оставленные вылетом посреди «Поделиться»: в них вся история.
    static func cleanUpStale(in root: URL) {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        } catch {
            Log.trips.error("временная папка не перечислена: \(error.localizedDescription, privacy: .public)")
            return
        }
        for name in names where name.hasPrefix(workPrefix) {
            remove(root.appendingPathComponent(name, isDirectory: true))
        }
    }
}
