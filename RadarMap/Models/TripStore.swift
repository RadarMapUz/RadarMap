//
//  TripStore.swift
//  RadarMap
//
//  История поездок по месяцам (15.1): Documents/trips/<гггг-ММ>.json и
//  маленький индекс Documents/trips/index.json.
//
//  До 15.1 вся история лежала одним trips.json и читалась целиком на старте:
//  поднять срок хранения (15.2) значило бы растить запуск вместе с историей.
//  Теперь месяц — свой файл, а индекс (месяцы, число поездок, сколько с
//  треком, крайние даты) говорит, что лежит на диске, не читая его. На старте
//  читаются месяцы последних `AppConfig.tripHistoryLaunchDays` дней — и не
//  меньше `keepLast` новейших поездок, — остальное по запросу.
//
//  Кто прав. Файлы месяцев — правда, индекс — кэш: список месяцев берётся из
//  папки, а строке индекса верим, только если размер файла совпал с
//  записанным. Не совпал (вылет между файлом месяца и индексом) — месяц
//  перечитывается. Индекс не может стать причиной потерять запись.
//
//  Месяц — по UTC: ключ записи не должен зависеть от пояса телефона. Иначе
//  после перелёта запись «переехала» бы в соседний месяц, который мог не
//  читаться, — и запись поверх стёрла бы его содержимое.
//
//  Перенос trips.json (migrateLegacy): месяцы пишутся атомарно, потом индекс,
//  потом месяцы перечитываются и сверяются по id, и только после этого
//  старый файл удаляется. Вылет на любом шаге оставляет trips.json целым, а
//  повтор переноса идемпотентен: объединение по id.
//
//  Всё здесь nonisolated: решения чистые, файлы читаются из @concurrent-кода
//  и из очереди записи JSONFile. Покрыто TripStoreTests.
//

import Foundation
import os

nonisolated enum TripStore {

    // MARK: - Месяц

    /// Календарный месяц по UTC — ключ файла и строки индекса.
    struct Month: Hashable, Comparable, Sendable, CustomStringConvertible {
        let year: Int
        let month: Int

        init(year: Int, month: Int) {
            self.year = year
            self.month = month
        }

        init(_ date: Date) {
            let parts = TripStore.utc.dateComponents([.year, .month], from: date)
            self.init(year: parts.year ?? 1970, month: parts.month ?? 1)
        }

        /// «2026-10» → месяц; чужое имя (index, отложенная копия) — nil.
        init?(key: String) {
            let parts = key.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].count == 4, parts[1].count == 2,
                  let year = Int(parts[0]), let month = Int(parts[1]),
                  (1...12).contains(month) else { return nil }
            self.init(year: year, month: month)
        }

        var key: String { String(format: "%04d-%02d", year, month) }
        var description: String { key }

        var next: Month {
            month == 12 ? Month(year: year + 1, month: 1) : Month(year: year, month: month + 1)
        }

        static func < (a: Month, b: Month) -> Bool { (a.year, a.month) < (b.year, b.month) }
    }

    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    /// Записи по месяцам; внутри месяца — порядок истории (от новых к старым).
    static func grouped(_ records: [TripRecord]) -> [Month: [TripRecord]] {
        var result: [Month: [TripRecord]] = [:]
        for record in records {
            result[Month(record.startedAt), default: []].append(record)
        }
        return result
    }

    /// Месяцы окна запуска: от месяца `now − windowDays` по текущий.
    static func windowMonths(now: Date, windowDays: Int) -> [Month] {
        var month = windowStart(now: now, windowDays: windowDays)
        let last = Month(now)
        var result: [Month] = []
        while month <= last {
            result.append(month)
            month = month.next
        }
        return result
    }

    // MARK: - Индекс

    /// Строка индекса: что лежит в файле месяца, без его чтения.
    struct Entry: Codable, Equatable, Sendable {
        let month: String
        let count: Int
        /// Сколько записей ещё с треком: чистке трека не нужно читать месяц.
        let tracks: Int
        let newest: Date
        let oldest: Date
        /// Размер файла месяца на момент записи индекса. Не совпал с диском —
        /// строке не верим, месяц перечитывается.
        var bytes: Int?
    }

    struct Index: Codable, Equatable, Sendable {
        var version = Index.currentVersion
        var months: [Entry] = []

        static let currentVersion = 1
    }

    static func entry(_ month: Month, records: [TripRecord], bytes: Int? = nil) -> Entry? {
        guard let first = records.first else { return nil }
        var newest = first.startedAt, oldest = first.startedAt, tracks = 0
        for record in records {
            newest = max(newest, record.startedAt)
            oldest = min(oldest, record.startedAt)
            if record.track != nil { tracks += 1 }
        }
        return Entry(month: month.key, count: records.count, tracks: tracks,
                     newest: newest, oldest: oldest, bytes: bytes)
    }

    // MARK: - Пути

    struct Paths: Sendable {
        let documents: URL

        /// Один файл на всю историю — формат до 15.1, только источник переноса.
        var legacy: URL { documents.appendingPathComponent("trips.json") }
        var directory: URL { documents.appendingPathComponent("trips", isDirectory: true) }
        var index: URL { directory.appendingPathComponent("index.json") }

        func shard(_ month: Month) -> URL {
            directory.appendingPathComponent(month.key + ".json")
        }

        static var standard: Paths {
            Paths(documents: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])
        }
    }

    /// Месяцы на диске и размеры их файлов. Папки нет — месяцев нет; nil —
    /// папка есть, но не перечисляется (тогда и читать нельзя).
    static func listShards(_ paths: Paths) -> [Month: Int]? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.directory.path) else { return [:] }
        do {
            var result: [Month: Int] = [:]
            for url in try fm.contentsOfDirectory(at: paths.directory, includingPropertiesForKeys: [.fileSizeKey])
            where url.pathExtension == "json" {
                guard let month = Month(key: url.deletingPathExtension().lastPathComponent) else { continue }
                result[month] = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            }
            return result
        } catch {
            Log.trips.error("месяцы истории не перечислены: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func fileSize(_ url: URL) -> Int? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        } catch {
            Log.trips.error("размер \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Порядок записей

    static func sortedNewestFirst(_ records: [TripRecord]) -> [TripRecord] {
        records.sorted { $0.startedAt != $1.startedAt ? $0.startedAt > $1.startedAt : $0.id > $1.id }
    }

    /// Объединение по id; при совпадении остаётся запись из `preferred`.
    static func union(_ preferred: [TripRecord], _ other: [TripRecord]) -> [TripRecord] {
        let ids = Set(preferred.map(\.id))
        return sortedNewestFirst(preferred + other.filter { !ids.contains($0.id) })
    }

    /// Влить записи месяца в историю по времени (от новых к старым), без
    /// повторов id: совпавшая запись остаётся та, что в памяти, — она новее.
    static func merging(_ history: [TripRecord], with records: [TripRecord]) -> [TripRecord] {
        let known = Set(history.map(\.id))
        var result = history
        for record in records where !known.contains(record.id) {
            let index = result.firstIndex { $0.startedAt < record.startedAt } ?? result.endIndex
            result.insert(record, at: index)
        }
        return result
    }

    // MARK: - Запуск

    /// Читать ли месяц на старте (месяцы идут от новых к старым): все, что
    /// задевают последние дни окна, и дальше вглубь, пока прочитанных поездок
    /// меньше `minRecords`, — список последних поездок не пустеет у того, кто
    /// ездит раз в месяц. `all` — разовым чисткам истории нужна вся история.
    /// Считаются поездки, реально прочитанные, а не строки индекса: после
    /// вылета строка текущего месяца устарела бы, и запуск читал бы всё.
    static func readsMonth(_ month: Month, windowStart: Month, loaded: Int,
                           minRecords: Int, all: Bool) -> Bool {
        all || month >= windowStart || loaded < minRecords
    }

    static func windowStart(now: Date, windowDays: Int) -> Month {
        Month(now.addingTimeInterval(-Double(windowDays) * 86400))
    }

    /// План запуска по известным числам — то же правило, что readLaunch
    /// применяет по прочитанному (для проверки правила тестом).
    static func launchMonths(present: Set<Month>, counts: [Month: Int], now: Date,
                             windowDays: Int, minRecords: Int, all: Bool) -> Set<Month> {
        let start = windowStart(now: now, windowDays: windowDays)
        var chosen: Set<Month> = []
        var records = 0
        for month in present.sorted(by: >) {
            guard readsMonth(month, windowStart: start, loaded: records, minRecords: minRecords, all: all)
            else { break }
            chosen.insert(month)
            records += counts[month] ?? 0
        }
        return chosen
    }

    /// Что прочитано на старте.
    struct Launch: Sendable {
        /// Записи прочитанных месяцев — от новых к старым, без повторов id.
        var records: [TripRecord] = []
        /// Что лежит на диске для месяцев, которые теперь в памяти целиком
        /// (прочитанные и заведомо пустые). С ним сравнивается память: месяц
        /// пишется, только если отличается. Пустой массив у месяца с битыми
        /// записями — переписать без них.
        var written: [Month: [TripRecord]] = [:]
        /// Строки индекса, которым можно верить, — по всем месяцам на диске.
        var entries: [Month: Entry] = [:]
        /// На диске, но не в памяти — от новых к старым.
        var older: [Month] = []
        /// Из `older`: строки нет или она устарела — перечитать фоном.
        var unknown: Set<Month> = []
        /// Битые записи: файл отложить копией (месяц перепишется без них).
        var lossy: [Month] = []
        /// Не разбирается совсем: файл отложить, месяц пустой.
        var corrupt: [Month] = []
        /// Индекс на диске расходится с прочитанным — переписать.
        var indexStale = false
        /// Перенесено из trips.json (nil — переноса не было).
        var migrated: Int?
    }

    enum LaunchResult: Sendable {
        case ready(Launch)
        /// Файлы есть, но не читаются (до первой разблокировки) — ничего не
        /// писать, повторить позже.
        case unreadable
    }

    static func readLaunch(paths: Paths, now: Date, windowDays: Int, minRecords: Int,
                           all: Bool) -> LaunchResult {
        var launch = Launch()
        switch migrateLegacy(paths: paths) {
        case .none: break
        case .migrated(let count): launch.migrated = count
        case .unreadable, .failed: return .unreadable
        }
        guard let present = listShards(paths) else { return .unreadable }
        var disk: [String: Entry] = [:]
        switch JSONFile.loadChecked(Index.self, from: paths.index, log: Log.trips) {
        case .missing, .corrupt:
            break   // кэш: перепишется по прочитанному
        case .unreadable:
            return .unreadable
        case .loaded(let index):
            if index.version == Index.currentVersion {
                for entry in index.months { disk[entry.month] = entry }
            }
        }
        var entries: [Month: Entry] = [:]
        for (month, bytes) in present {
            if let entry = disk[month.key], entry.bytes == bytes { entries[month] = entry }
        }
        let start = windowStart(now: now, windowDays: windowDays)
        var seen = Set<Double>()
        for month in present.keys.sorted(by: >) {
            guard readsMonth(month, windowStart: start, loaded: launch.records.count,
                             minRecords: minRecords, all: all) else { break }
            switch JSONFile.loadChecked(LossyArray<TripRecord>.self, from: paths.shard(month), log: Log.trips) {
            case .missing:
                launch.written[month] = []
                entries[month] = nil
            case .unreadable:
                return .unreadable
            case .corrupt:
                launch.corrupt.append(month)
                launch.written[month] = []
                entries[month] = nil
            case .loaded(let lossy):
                if lossy.dropped > 0 {
                    Log.trips.fault("месяц \(month.key, privacy: .public): битых записей \(lossy.dropped, privacy: .public) — \(lossy.firstError ?? "", privacy: .public)")
                    if lossy.elements.isEmpty {
                        launch.corrupt.append(month)
                        launch.written[month] = []
                        entries[month] = nil
                        continue
                    }
                    launch.lossy.append(month)
                }
                // Повтор id в двух файлах (не должен случаться) — в память
                // один раз; файл с повтором перепишется: в памяти его нет.
                launch.records += lossy.elements.filter { seen.insert($0.id).inserted }
                launch.written[month] = lossy.dropped > 0 ? [] : lossy.elements
                entries[month] = entry(month, records: lossy.elements, bytes: present[month])
            }
        }
        // Месяцы окна без файла — заведомо пустые: новая поездка ляжет туда
        // без проверки диска.
        for month in windowMonths(now: now, windowDays: windowDays)
        where launch.written[month] == nil && present[month] == nil {
            launch.written[month] = []
        }
        launch.older = present.keys.filter { launch.written[$0] == nil }.sorted(by: >)
        launch.unknown = Set(launch.older.filter { entries[$0] == nil })
        launch.entries = entries
        launch.indexStale = disk != Dictionary(uniqueKeysWithValues: entries.map { ($0.key.key, $0.value) })
        return .ready(launch)
    }

    // MARK: - Перенос trips.json

    enum Migration: Equatable, Sendable {
        case none
        case migrated(Int)
        /// trips.json или месяц не читаются (до разблокировки) — позже.
        case unreadable
        /// Запись не прошла или не сошлась сверка — trips.json цел, повтор позже.
        case failed
    }

    static func migrateLegacy(paths: Paths) -> Migration {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.legacy.path) else { return .none }
        let legacy: LossyArray<TripRecord>
        switch JSONFile.loadChecked(LossyArray<TripRecord>.self, from: paths.legacy, log: Log.trips) {
        case .missing:
            return .none
        case .unreadable:
            return .unreadable
        case .corrupt:
            // Не разбирается целиком — отложить, как отложило бы прежнее
            // чтение; переносить нечего.
            return JSONFile.setAside(paths.legacy, log: Log.trips) ? .migrated(0) : .unreadable
        case .loaded(let value):
            legacy = value
        }
        do {
            try fm.createDirectory(at: paths.directory, withIntermediateDirectories: true)
        } catch {
            Log.trips.error("папка истории не создана: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
        let byMonth = grouped(legacy.elements)
        var migrated: [Month: [TripRecord]] = [:]
        for (month, records) in byMonth {
            let url = paths.shard(month)
            var merged = sortedNewestFirst(records)
            switch JSONFile.loadChecked(LossyArray<TripRecord>.self, from: url, log: Log.trips) {
            case .missing:
                break
            case .unreadable:
                return .unreadable
            case .corrupt:
                guard JSONFile.setAside(url, log: Log.trips) else { return .unreadable }
            case .loaded(let existing):
                // Прошлая попытка переноса, оборванная вылетом, или старая
                // сборка после отката: объединить, при совпадении id — запись
                // из trips.json (она та, что переносится сейчас).
                if existing.dropped > 0, !JSONFile.setAside(url, copy: true, log: Log.trips) { return .unreadable }
                merged = union(records, existing.elements)
            }
            guard JSONFile.save(merged, to: url, log: Log.trips) else { return .failed }
            migrated[month] = merged
        }
        // Индекс — после месяцев. Строки прочих месяцев — как были: им всё
        // равно не поверят без совпадения размера.
        var entries: [Month: Entry] = [:]
        if case .loaded(let old) = JSONFile.loadChecked(Index.self, from: paths.index, log: Log.trips) {
            for entry in old.months {
                if let month = Month(key: entry.month) { entries[month] = entry }
            }
        }
        for (month, records) in migrated { entries[month] = entry(month, records: records) }
        writeIndex(entries, paths: paths)
        // Сверка: каждая перенесённая запись читается из своего месяца.
        for (month, records) in byMonth {
            guard case .loaded(let back) = JSONFile.loadChecked(LossyArray<TripRecord>.self,
                                                                from: paths.shard(month), log: Log.trips),
                  back.dropped == 0,
                  Set(back.elements.map(\.id)).isSuperset(of: records.map(\.id)) else {
                Log.trips.fault("перенос истории: месяц \(month.key, privacy: .public) не сошёлся — trips.json остаётся")
                return .failed
            }
        }
        // Битые элементы trips.json не перенести, но и стирать их нельзя —
        // копией в сторону, как делало прежнее чтение.
        if legacy.dropped > 0 {
            Log.trips.fault("перенос истории: битых записей \(legacy.dropped, privacy: .public) — \(legacy.firstError ?? "", privacy: .public)")
            guard JSONFile.setAside(paths.legacy, copy: true, log: Log.trips) else { return .failed }
        }
        do {
            try fm.removeItem(at: paths.legacy)
        } catch {
            // Перенос сделан; trips.json перенесётся ещё раз — по id это то же самое.
            Log.trips.error("trips.json не удалён после переноса: \(error.localizedDescription, privacy: .public)")
        }
        Log.trips.notice("история перенесена по месяцам: \(legacy.elements.count, privacy: .public) поездок, \(byMonth.count, privacy: .public) мес.")
        return .migrated(legacy.elements.count)
    }

    // MARK: - Запись

    /// Один шаг записи: изменившиеся месяцы, потом индекс.
    struct WritePlan: Sendable {
        var shards: [Month: [TripRecord]] = [:]
        var removals: Set<Month> = []
        /// Строки индекса после шага — по всем известным месяцам.
        var index: [Month: Entry] = [:]

        var isEmpty: Bool { shards.isEmpty && removals.isEmpty }
    }

    /// Выполняется в очереди записи JSONFile (TripStats.persist).
    static func perform(_ plan: WritePlan, paths: Paths) {
        var index = plan.index
        if !plan.shards.isEmpty {
            do {
                try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true)
            } catch {
                Log.trips.error("папка истории не создана: \(error.localizedDescription, privacy: .public)")
            }
        }
        for (month, records) in plan.shards where !JSONFile.save(records, to: paths.shard(month), log: Log.trips) {
            // Файл остался прежним, а строка описывала бы новый: без строки
            // месяц на следующем запуске перечитается.
            index[month] = nil
        }
        for month in plan.removals {
            JSONFile.remove(at: paths.shard(month), log: Log.trips)
            index[month] = nil
        }
        writeIndex(index, paths: paths)
    }

    /// Индекс с размерами файлов на момент записи: строка без файла не пишется.
    static func writeIndex(_ entries: [Month: Entry], paths: Paths) {
        guard FileManager.default.fileExists(atPath: paths.directory.path) else { return }
        var months: [Entry] = []
        for (month, entry) in entries.sorted(by: { $0.key > $1.key }) {
            guard let bytes = fileSize(paths.shard(month)) else { continue }
            var stamped = entry
            stamped.bytes = bytes
            months.append(stamped)
        }
        JSONFile.save(Index(months: months), to: paths.index, log: Log.trips)
    }

    /// Прочитать один месяц (по запросу, сверка индекса, чистка по сроку).
    enum MonthRead: Sendable {
        case missing
        case loaded([TripRecord], dropped: Int)
        case unreadable
        case corrupt
    }

    static func readMonth(_ month: Month, paths: Paths) -> MonthRead {
        switch JSONFile.loadChecked(LossyArray<TripRecord>.self, from: paths.shard(month), log: Log.trips) {
        case .missing: return .missing
        case .unreadable: return .unreadable
        case .corrupt: return .corrupt
        case .loaded(let lossy):
            return lossy.elements.isEmpty && lossy.dropped > 0 ? .corrupt : .loaded(lossy.elements, dropped: lossy.dropped)
        }
    }

    /// «Удалить всю историю»: месяцы, индекс, старый trips.json и отложенные
    /// копии — в них те же поездки. Живой слепок идущей поездки не трогаем.
    static func removeAll(paths: Paths) {
        let fm = FileManager.default
        for url in [paths.directory, paths.legacy] where fm.fileExists(atPath: url.path) {
            do {
                try fm.removeItem(at: url)
            } catch {
                Log.trips.error("история не стёрта: \(url.lastPathComponent, privacy: .public) — \(error.localizedDescription, privacy: .public)")
            }
        }
        do {
            for name in try fm.contentsOfDirectory(atPath: paths.documents.path) where isSetAsideHistory(name) {
                JSONFile.remove(at: paths.documents.appendingPathComponent(name), log: Log.trips)
            }
        } catch {
            Log.trips.error("отложенные копии истории не перечислены: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Отложенная копия файла истории (JSONFile.setAside): `trips.corrupt-…json`.
    static func isSetAsideHistory(_ name: String) -> Bool {
        let stems = ["trips", "trip_days", "lifetime", "lifetime_session"]
        return stems.contains { name.hasPrefix($0 + ".corrupt-") }
            || (name.hasPrefix("trip_inflight") && name.contains(".corrupt-"))
    }

    // MARK: - Чистка по сроку непрочитанных месяцев

    enum SweepAction: Equatable, Sendable { case keep, delete, rewrite }

    /// Что сделать с непрочитанным месяцем, когда история чистится по сроку.
    /// `offset` — сколько записей НОВЕЕ этого месяца остаётся. `delete` и
    /// `keep` решаются по строке индекса, `rewrite` — месяц читается и
    /// чистится той же TripHistory.pruned со сдвигом.
    static func sweepAction(_ entry: Entry, offset: Int, retention: TripHistory.Retention,
                            now: Date) -> SweepAction {
        let recordCutoff = retention.recordCutoff(now: now)
        if offset >= retention.keepLast {
            if let cutoff = recordCutoff, entry.newest <= cutoff { return .delete }
            if let cap = retention.maxRecords, offset >= cap { return .delete }
        }
        let byAge = recordCutoff.map { entry.oldest <= $0 } ?? false
        let byCap = retention.maxRecords.map { offset + entry.count > $0 } ?? false
        let byTrack = entry.tracks > 0 && (retention.trackCutoff(now: now).map { entry.oldest <= $0 } ?? false)
        return byAge || byCap || byTrack ? .rewrite : .keep
    }
}
