//
//  TripStoreTests.swift
//  RadarMapTests
//
//  История по месяцам (15.1): ключ месяца, план запуска, перенос trips.json
//  без потерь и при вылете на любом шаге, индекс как кэш, которому верят
//  только при совпадении размера, чистка кусками = чистка целиком.
//

import XCTest
@testable import RadarMap

final class TripStoreTests: XCTestCase {

    // MARK: - Окружение

    private func tempPaths() -> TripStore.Paths {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TripStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return TripStore.Paths(documents: dir)
    }

    /// 20.10.2026 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_792_497_600)

    private func record(_ start: Date, km: Double = 5, track: Bool = true) -> TripRecord {
        TripRecord(id: start.timeIntervalSince1970, startedAt: start,
                   endedAt: start.addingTimeInterval(900), distanceMeters: km * 1000,
                   maxSpeedKmh: 60, passed: [], endLat: 41.3, endLon: 69.2,
                   track: track ? [41.3, 69.2, 40, 41.31, 69.21, 50] : nil, score: 95)
    }

    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    private func month(_ key: String) -> TripStore.Month {
        guard let month = TripStore.Month(key: key) else {
            XCTFail("ключ \(key)")
            return TripStore.Month(year: 1970, month: 1)
        }
        return month
    }

    private func launch(_ paths: TripStore.Paths, all: Bool = false,
                        file: StaticString = #filePath, line: UInt = #line) -> TripStore.Launch? {
        guard case .ready(let launch) = TripStore.readLaunch(paths: paths, now: now, windowDays: 62,
                                                             minRecords: 7, all: all) else {
            XCTFail("история не прочиталась", file: file, line: line)
            return nil
        }
        return launch
    }

    private func write(_ records: [TripRecord], to paths: TripStore.Paths) {
        var plan = TripStore.WritePlan()
        for (month, chunk) in TripStore.grouped(records) {
            plan.shards[month] = chunk
            plan.index[month] = TripStore.entry(month, records: chunk)
        }
        TripStore.perform(plan, paths: paths)
    }

    /// Файл trips.json, каким его писали прошлые версии: у старой записи нет
    /// ничего, кроме обязательных полей, у проезда — ни координат, ни лимита;
    /// у новой — всё, включая остановку, рейс и судьбу штрафа. Вторая запись
    /// — 30.09 21:40 UTC, в Ташкенте это уже 1 октября: месяц файла — по UTC.
    private let legacyJSON = #"""
    [
     {"id":1791810000,"startedAt":813502800,"endedAt":813504660,"distanceMeters":14250.5,"maxSpeedKmh":82.4,
      "passed":[{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","cameraID":1204,"typeRaw":"Стационар радар",
                 "location":"Амира Темура","speedKmh":64.2,"date":813503400,"lat":41.3111,"lon":69.2797,
                 "limitKmh":60,"roadLimitKmh":50,"limitAssumed":true,"courseDegrees":12.5,"speedAfterKmh":71,
                 "finePaid":true,"silent":true},
                {"id":"A1B2C3D4-0000-4000-8000-000000000001","cameraID":1300,"typeRaw":"Стационар камера",
                 "location":"Юнусабад","speedKmh":90,"date":813503500,"limitKmh":60,"fineDismissed":true}],
      "endLat":41.33,"endLon":69.3,"track":[41.3,69.2,40,41.31,69.21,55.5,41.32,69.22,60],"score":91,
      "stops":[{"id":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","lat":41.305,"lon":69.205,
                "from":813503000,"to":813503300,"title":"Корзинка"}],
      "endedManually":true,"batteryDropPercent":4,"startLat":41.3,"startLon":69.2,"work":true},
     {"id":1790804400,"startedAt":812497200,"endedAt":812498700,"distanceMeters":5200,"maxSpeedKmh":61,
      "passed":[{"id":"16FD2706-8BAF-433B-82EB-8C7FADA847DA","cameraID":77,"typeRaw":"Стационар камера",
                 "location":"Чиланзар","speedKmh":58,"date":812498000}],
      "endLat":41.28,"endLon":69.21},
     {"id":1788419700,"startedAt":810112500,"endedAt":810114720,"distanceMeters":8000,"maxSpeedKmh":70,
      "passed":[]}
    ]
    """#

    private func legacyRecords() throws -> [TripRecord] {
        try JSONDecoder().decode([TripRecord].self, from: Data(legacyJSON.utf8))
    }

    private func writeLegacy(_ paths: TripStore.Paths, _ text: String? = nil) throws {
        try Data((text ?? legacyJSON).utf8).write(to: paths.legacy)
    }

    private func shard(_ paths: TripStore.Paths, _ key: String) throws -> [TripRecord] {
        try JSONDecoder().decode([TripRecord].self, from: Data(contentsOf: paths.shard(month(key))))
    }

    // MARK: - Месяц

    func testMonthKeyIsUTC() {
        // 30.09 21:40 UTC = 1.10 02:40 в Ташкенте — месяц файла сентябрь,
        // и он не меняется от пояса телефона.
        let instant = Date(timeIntervalSince1970: 1_790_804_400)
        XCTAssertEqual(TripStore.Month(instant).key, "2026-09")
        XCTAssertEqual(TripStore.Month(key: "2026-09"), TripStore.Month(instant))
        XCTAssertEqual(TripStore.Month(year: 2026, month: 12).next.key, "2027-01")
        for bad in ["index", "2026-13", "2026-10.corrupt-1800000000", "26-10", "2026-1", "2026-10-01"] {
            XCTAssertNil(TripStore.Month(key: bad), bad)
        }
        XCTAssertEqual(TripStore.windowMonths(now: now, windowDays: 62).map(\.key),
                       ["2026-08", "2026-09", "2026-10"])
    }

    // MARK: - План запуска

    func testLaunchReadsTheWindowAndAtLeastTheNewestTrips() {
        let present: Set<TripStore.Month> = Set(["2026-10", "2026-09", "2026-08", "2026-07", "2026-05", "2026-01"]
            .map(month))
        // Окно (с 19.08) уже дало 10 поездок — дальше не читаем.
        let busy = TripStore.launchMonths(present: present,
                                          counts: [month("2026-10"): 5, month("2026-09"): 3, month("2026-08"): 2],
                                          now: now, windowDays: 62, minRecords: 7, all: false)
        XCTAssertEqual(busy, Set(["2026-10", "2026-09", "2026-08"].map(month)))
        // Ездит раз в месяц: окно дало 3 — вглубь, пока не наберётся 7.
        // У мая строки нет — считаем нулём и читаем дальше.
        let rare = TripStore.launchMonths(present: present,
                                          counts: [month("2026-10"): 1, month("2026-09"): 1, month("2026-08"): 1,
                                                   month("2026-07"): 1, month("2026-01"): 10],
                                          now: now, windowDays: 62, minRecords: 7, all: false)
        XCTAssertEqual(rare, present)
        // Разовые чистки ждут — читается всё.
        XCTAssertEqual(TripStore.launchMonths(present: present, counts: [:], now: now, windowDays: 62,
                                              minRecords: 0, all: true), present)
    }

    func testLaunchLeavesOlderMonthsOnDisk() throws {
        let paths = tempPaths()
        let recent = (0..<10).map { record(daysAgo(Double($0) * 3)) }
        let old = (0..<6).map { record(daysAgo(120 + Double($0) * 20), track: false) }
        write(recent + old, to: paths)
        let launch = try XCTUnwrap(launch(paths))
        XCTAssertEqual(launch.records.map(\.id), recent.map(\.id), "в памяти — только окно, от новых к старым")
        XCTAssertFalse(launch.older.isEmpty)
        XCTAssertTrue(launch.older.allSatisfy { $0 < month("2026-08") })
        XCTAssertTrue(launch.unknown.isEmpty, "индекс свежий — непрочитанным месяцам верим")
        XCTAssertEqual(launch.older.reduce(0) { $0 + (launch.entries[$1]?.count ?? 0) }, old.count)
        XCTAssertFalse(launch.indexStale)
        // Месяцы окна — в памяти целиком, и пустой август тоже.
        XCTAssertEqual(launch.written[month("2026-08")], [])
    }

    // MARK: - Перенос trips.json

    func testMigrationOfAnOldFileKeepsEveryRecordAndField() throws {
        let paths = tempPaths()
        try writeLegacy(paths)
        let original = try legacyRecords()
        let launch = try XCTUnwrap(launch(paths))
        XCTAssertEqual(launch.migrated, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.legacy.path), "старый файл убран после сверки")
        XCTAssertEqual(launch.records, original, "все поля, включая старые пустые, — как были")
        XCTAssertEqual(try shard(paths, "2026-10").map(\.id), [1_791_810_000])
        XCTAssertEqual(try shard(paths, "2026-09").map(\.id), [1_790_804_400, 1_788_419_700])
        let index = try JSONDecoder().decode(TripStore.Index.self, from: Data(contentsOf: paths.index))
        XCTAssertEqual(index.months.map(\.month), ["2026-10", "2026-09"])
        XCTAssertEqual(index.months.map(\.count), [1, 2])
        XCTAssertEqual(index.months.map(\.tracks), [1, 0])
        XCTAssertFalse(launch.indexStale)
        // Второй запуск: переносить нечего, читается то же самое.
        XCTAssertEqual(TripStore.migrateLegacy(paths: paths), .none)
        XCTAssertEqual(self.launch(paths)?.records, original)
    }

    /// Вылет после части месяцев (старый файл цел, месяц уже записан, индекса
    /// нет) и вылет перед удалением старого файла: повтор даёт то же самое,
    /// без повторов и потерь.
    func testMigrationSurvivesACrashAtAnyStep() throws {
        let original = try legacyRecords()
        // Вылет после первого месяца.
        let partial = tempPaths()
        try writeLegacy(partial)
        try FileManager.default.createDirectory(at: partial.directory, withIntermediateDirectories: true)
        try JSONEncoder().encode([original[0]]).write(to: partial.shard(month("2026-10")))
        XCTAssertEqual(TripStore.migrateLegacy(paths: partial), .migrated(3))
        XCTAssertEqual(launch(partial)?.records, original)
        // Вылет перед удалением trips.json: месяцы и индекс уже на месте.
        let late = tempPaths()
        try writeLegacy(late)
        XCTAssertEqual(TripStore.migrateLegacy(paths: late), .migrated(3))
        try writeLegacy(late)
        let before = try shard(late, "2026-09")
        XCTAssertEqual(TripStore.migrateLegacy(paths: late), .migrated(3))
        XCTAssertEqual(try shard(late, "2026-09"), before, "повтор переноса ничего не меняет")
        XCTAssertEqual(launch(late)?.records, original)
    }

    /// Откат на старую сборку и обратно: в месяце уже есть поездка, которой
    /// нет в trips.json, и старая версия общей поездки. Объединение по id,
    /// при совпадении — trips.json.
    func testMigrationMergesWithWhatIsAlreadyThere() throws {
        let paths = tempPaths()
        let original = try legacyRecords()
        var stale = original[0]
        stale.passed = []
        let onlyInShard = record(Date(timeIntervalSince1970: 1_791_000_000))
        try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true)
        try JSONEncoder().encode([stale, onlyInShard]).write(to: paths.shard(month("2026-10")))
        try writeLegacy(paths)
        let records = try XCTUnwrap(launch(paths)?.records)
        XCTAssertEqual(records.count, 4)
        XCTAssertEqual(records.first { $0.id == original[0].id }?.passed.count, 2, "версия из trips.json")
        XCTAssertTrue(records.contains { $0.id == onlyInShard.id }, "поездка только из месяца не пропала")
    }

    /// Файл есть, но не читается (до первой разблокировки): ничего не
    /// трогать, не писать, повторить позже. Каталог на месте файла — тот же
    /// отказ чтения.
    func testUnreadableOldFileIsLeftAlone() throws {
        let paths = tempPaths()
        try FileManager.default.createDirectory(at: paths.legacy, withIntermediateDirectories: true)
        guard case .unreadable = TripStore.readLaunch(paths: paths, now: now, windowDays: 62,
                                                      minRecords: 7, all: false) else {
            return XCTFail("нечитаемое — повтор позже, а не пустая история")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.directory.path), "ничего не записано")
    }

    func testCorruptOldFileIsSetAsideNotLost() throws {
        let paths = tempPaths()
        try writeLegacy(paths, "{не json")
        XCTAssertEqual(TripStore.migrateLegacy(paths: paths), .migrated(0))
        let names = try FileManager.default.contentsOfDirectory(atPath: paths.documents.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("trips.corrupt-") }, "\(names)")
        XCTAssertFalse(names.contains("trips.json"))
    }

    func testBrokenRecordsOfTheOldFileAreKeptAsACopy() throws {
        let paths = tempPaths()
        let broken = legacyJSON.replacingOccurrences(of: #""distanceMeters":5200,"#, with: #""distanceMeters":"много","#)
        try writeLegacy(paths, broken)
        XCTAssertEqual(TripStore.migrateLegacy(paths: paths), .migrated(2))
        let names = try FileManager.default.contentsOfDirectory(atPath: paths.documents.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("trips.corrupt-") }, "битая запись — копией в сторону: \(names)")
        XCTAssertEqual(launch(paths)?.records.count, 2)
    }

    // MARK: - Индекс — кэш

    /// Вылет между записью месяца и индекса: размер не совпал — строке не
    /// верим. Месяц окна перечитывается, непрочитанный — в сверку.
    func testIndexIsTrustedOnlyWhenTheSizeMatches() throws {
        let paths = tempPaths()
        let recent = record(daysAgo(2.5))
        let old = record(daysAgo(200), track: false)
        let older = record(daysAgo(240), track: false)
        write((0..<8).map { record(daysAgo(Double($0) + 1)) } + [old, older], to: paths)
        // Месяц дописан мимо индекса.
        let oldMonth = TripStore.Month(old.startedAt)
        let extra = record(old.startedAt.addingTimeInterval(3600), track: false)
        try JSONEncoder().encode([extra, old]).write(to: paths.shard(oldMonth))
        let recentMonth = TripStore.Month(recent.startedAt)
        try JSONEncoder().encode([recent] + (try shard(paths, recentMonth.key)))
            .write(to: paths.shard(recentMonth))
        let launch = try XCTUnwrap(launch(paths))
        XCTAssertTrue(launch.unknown.contains(oldMonth), "непрочитанный месяц со старой строкой — перечитать")
        XCTAssertFalse(launch.unknown.contains(TripStore.Month(older.startedAt)))
        XCTAssertEqual(launch.entries[recentMonth]?.count, try shard(paths, recentMonth.key).count,
                       "месяц окна — по прочитанному")
        XCTAssertTrue(launch.indexStale)
        XCTAssertNil(launch.written[oldMonth], "окно дало 9 поездок — старые месяцы не читаются")
    }

    func testMonthWithoutAnIndexLineIsStillRead() throws {
        let paths = tempPaths()
        try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true)
        let fresh = record(daysAgo(1))
        try JSONEncoder().encode([fresh]).write(to: paths.shard(TripStore.Month(fresh.startedAt)))
        XCTAssertEqual(launch(paths)?.records.map(\.id), [fresh.id], "вылет до первого индекса — поездка видна")
    }

    func testWriteStepStampsSizesAndRemovesEmptiedMonths() throws {
        let paths = tempPaths()
        let a = record(daysAgo(1)), b = record(daysAgo(100))
        write([a, b], to: paths)
        var index = try JSONDecoder().decode(TripStore.Index.self, from: Data(contentsOf: paths.index))
        for entry in index.months {
            let size = TripStore.fileSize(paths.shard(month(entry.month)))
            XCTAssertEqual(entry.bytes, size, entry.month)
        }
        let bMonth = TripStore.Month(b.startedAt)
        var plan = TripStore.WritePlan()
        plan.removals = [bMonth]
        plan.index = [TripStore.Month(a.startedAt): try XCTUnwrap(TripStore.entry(TripStore.Month(a.startedAt),
                                                                                  records: [a])),
                      bMonth: try XCTUnwrap(TripStore.entry(bMonth, records: [b]))]
        TripStore.perform(plan, paths: paths)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.shard(bMonth).path))
        index = try JSONDecoder().decode(TripStore.Index.self, from: Data(contentsOf: paths.index))
        XCTAssertEqual(index.months.map(\.month), [TripStore.Month(a.startedAt).key], "строки без файла нет")
    }

    func testDuplicateIDAcrossMonthsIsLoadedOnce() throws {
        let paths = tempPaths()
        let trip = record(daysAgo(3))
        try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true)
        try JSONEncoder().encode([trip]).write(to: paths.shard(TripStore.Month(trip.startedAt)))
        try JSONEncoder().encode([trip]).write(to: paths.shard(month("2026-08")))
        let launch = try XCTUnwrap(launch(paths))
        XCTAssertEqual(launch.records.map(\.id), [trip.id])
        XCTAssertEqual(launch.written[month("2026-08")], [trip], "файл с повтором перепишется: в памяти его нет")
    }

    // MARK: - Срок хранения кусками

    /// Чистка по месяцам от новых к старым со сдвигом — то же самое, что
    /// чистка всей истории: и с сегодняшними числами, и со сроком «год».
    func testPruningMonthByMonthEqualsPruningEverything() {
        let starts = (0..<140).map { daysAgo(Double($0) * 2.6 + Double($0 % 5) * 0.1) }
        let history = starts.map { record($0) }
        let year = TripHistory.Retention(recordDays: 365, keepLast: 7, maxRecords: nil, trackDays: 90)
        let tight = TripHistory.Retention(recordDays: 30, keepLast: 7, maxRecords: 12, trackDays: 7)
        for retention in [TripHistory.Retention.current, .legacy, year, tight] {
            let whole = TripHistory.pruned(history, retention: retention, now: now)
            var chunked: [TripRecord] = []
            for month in TripStore.grouped(history).keys.sorted(by: >) {
                let chunk = history.filter { TripStore.Month($0.startedAt) == month }
                chunked += TripHistory.pruned(chunk, retention: retention, now: now, offset: chunked.count)
            }
            XCTAssertEqual(chunked, whole, "\(retention)")
        }
        XCTAssertEqual(TripHistory.pruned(history, now: now), TripHistory.pruned(history, retention: .current, now: now),
                       "значения по умолчанию — сегодняшние числа")
    }

    /// Решение по строке индекса не расходится с чисткой самого месяца.
    func testSweepDecisionMatchesThePrune() throws {
        let year = TripHistory.Retention(recordDays: 365, keepLast: 7, maxRecords: nil, trackDays: 90)
        let cases: [(days: [Double], track: Bool)] = [
            ([40, 45, 50], false), ([40, 45, 50], true), ([20, 25], true),
            ([5, 6], false), ([400, 410], false), ([300, 380], false), ([80, 100], true),
        ]
        for retention in [TripHistory.Retention.current, .legacy, year] {
            for (days, track) in cases {
                let records = days.map { record(daysAgo($0), track: track) }
                let entry = try XCTUnwrap(TripStore.entry(TripStore.Month(records[0].startedAt), records: records))
                for offset in [0, 3, 7, 49, 50, 60] {
                    let pruned = TripHistory.pruned(records, retention: retention, now: now, offset: offset)
                    switch TripStore.sweepAction(entry, offset: offset, retention: retention, now: now) {
                    case .delete: XCTAssertTrue(pruned.isEmpty, "\(days) \(offset) \(retention)")
                    case .keep: XCTAssertEqual(pruned, records, "\(days) \(offset) \(retention)")
                    case .rewrite: break
                    }
                }
            }
        }
    }

    // MARK: - Слияние и удаление

    func testMergingKeepsOrderAndTheVersionInMemory() {
        let a = record(daysAgo(1)), b = record(daysAgo(5)), c = record(daysAgo(9)), d = record(daysAgo(40))
        var changed = b
        changed.score = 10
        let merged = TripStore.merging([a, changed, c], with: [b, d])
        XCTAssertEqual(merged.map(\.id), [a, b, c, d].map(\.id))
        XCTAssertEqual(merged[1].score, 10)
    }

    func testRemoveAllTakesHistoryAndItsCopiesButNotTheLiveTrip() throws {
        let paths = tempPaths()
        write([record(daysAgo(1)), record(daysAgo(90))], to: paths)
        try writeLegacy(paths)
        let docs = paths.documents
        let names = ["trips.corrupt-1800000000.json", "trip_days.corrupt-1800000001.json",
                     "lifetime.corrupt-1800000002.json", "trip_inflight-1790000000-ab12cd34.corrupt-1800000003.json",
                     "trip_inflight-1792490000-ef56ab78.json", "trip_days.json", "lifetime.json"]
        for name in names { try Data("[]".utf8).write(to: docs.appendingPathComponent(name)) }
        TripStore.removeAll(paths: paths)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: docs.path))
        XCTAssertEqual(left, ["trip_inflight-1792490000-ef56ab78.json", "trip_days.json", "lifetime.json"],
                       "дни и «за всё время» обнуляет TripStats, живой слепок не трогаем")
    }
}
