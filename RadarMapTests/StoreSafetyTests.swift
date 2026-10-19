//
//  StoreSafetyTests.swift
//  RadarMapTests
//
//  Данные человека (сценарии S9, S11, S12, 20.10): битая запись не уносит
//  файл; битый файл откладывается, а не затирается; склеенная поездка не
//  считается дважды «за всё время».
//

import XCTest
@testable import RadarMap

final class StoreSafetyTests: XCTestCase {
    private struct Item: Codable, Equatable { let id: Int; let name: String }

    private func tempURL(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    func testOneBadRecordDoesNotLoseTheFile() throws {
        let json = #"[{"id":1,"name":"a"},{"id":"bad"},42,{"id":3,"name":"c"}]"#
        let lossy = try JSONDecoder().decode(LossyArray<Item>.self, from: Data(json.utf8))
        XCTAssertEqual(lossy.elements, [Item(id: 1, name: "a"), Item(id: 3, name: "c")])
        XCTAssertEqual(lossy.dropped, 2)
    }

    func testMissingCorruptAndLoadedAreDifferent() throws {
        let url = tempURL("trips.json")
        guard case .missing = JSONFile.loadChecked([Item].self, from: url, log: Log.trips) else {
            return XCTFail("нет файла — это «нет файла»")
        }
        try Data("{не json".utf8).write(to: url)
        guard case .corrupt = JSONFile.loadChecked([Item].self, from: url, log: Log.trips) else {
            return XCTFail("битый — это «битый», а не «пусто»")
        }
        JSONFile.setAside(url, log: Log.trips)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "битый отложен, на его месте — ничего")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertTrue(siblings.contains { $0.hasPrefix("trips.corrupt-") && $0.hasSuffix(".json") }, "\(siblings)")
        try JSONEncoder().encode([Item(id: 1, name: "a")]).write(to: url)
        guard case .loaded(let items) = JSONFile.loadChecked([Item].self, from: url, log: Log.trips) else {
            return XCTFail("целый — прочитан")
        }
        XCTAssertEqual(items, [Item(id: 1, name: "a")])
    }

    // MARK: - S11: склейка «за всё время»

    /// 10 км до магазина (один чистый проезд), потом ещё 3 км и проезд с
    /// превышением: за всё время — 13 км, ОДНА поездка, два проезда, серия
    /// оборвана штрафом второй ноги.
    func testMergedTripCountsOnce() {
        let clean = DrivingScore.Pass(speedKmh: 55, limitKmh: 60)
        let fined = DrivingScore.Pass(speedKmh: 95, limitKmh: 60)
        var stats = LifetimeStats(trips: 4, distanceMeters: 50_000, camerasPassed: 10, cleanStreak: 2, bestStreak: 3)
        stats = LifetimeStats.updated(stats, passes: [clean], distanceMeters: 10_000)
        XCTAssertEqual(stats.trips, 5)
        XCTAssertEqual(stats.cleanStreak, 3)
        let merged = LifetimeStats.updatedResumed(stats, basePasses: [clean], allPasses: [clean, fined],
                                                  distanceDelta: 3_000)
        XCTAssertEqual(merged.trips, 5, "та же поездка")
        XCTAssertEqual(merged.distanceMeters, 63_000, accuracy: 0.1)
        XCTAssertEqual(merged.camerasPassed, 12)
        XCTAssertEqual(merged.cleanStreak, 0, "штраф второй ноги обрывает серию")
        XCTAssertEqual(merged.bestStreak, 3, "рекорд 3 был и до первой ноги")
    }

    /// Рекорд, поднятый первой ногой, отменяется штрафом второй: склеенная
    /// поездка со штрафом не «чистая» и рекорда не ставит.
    func testMergedFinedTripTakesBackTheRecordItSet() {
        let clean = DrivingScore.Pass(speedKmh: 55, limitKmh: 60)
        let fined = DrivingScore.Pass(speedKmh: 95, limitKmh: 60)
        var stats = LifetimeStats(trips: 4, distanceMeters: 50_000, camerasPassed: 10, cleanStreak: 3, bestStreak: 3)
        stats = LifetimeStats.updated(stats, passes: [clean], distanceMeters: 10_000)
        XCTAssertEqual(stats.bestStreak, 4)
        let merged = LifetimeStats.updatedResumed(stats, basePasses: [clean], allPasses: [clean, fined],
                                                  distanceDelta: 3_000)
        XCTAssertEqual(merged.cleanStreak, 0)
        XCTAssertEqual(merged.bestStreak, 3, "рекорд 4 поставлен поездкой со штрафом — снят")
        // Старая копия без поля — рекорд не трогаем (лучше лишний, чем отнятый).
        var legacy = stats
        legacy.lastTripRaisedBest = nil
        XCTAssertEqual(LifetimeStats.updatedResumed(legacy, basePasses: [clean], allPasses: [clean, fined],
                                                    distanceDelta: 3_000).bestStreak, 4)
    }

    /// Первая нога без лимитных камер, вторая — чистая лимитная: шаг серии —
    /// один, за поездку; первая нога лимитная — шага повторно нет.
    func testMergedCleanTripStepsTheStreakOnce() {
        let clean = DrivingScore.Pass(speedKmh: 55, limitKmh: 60)
        let unlimited = DrivingScore.Pass(speedKmh: 55, limitKmh: nil)
        let base = LifetimeStats(trips: 1, distanceMeters: 1_000, camerasPassed: 1, cleanStreak: 1, bestStreak: 1)
        let first = LifetimeStats.updatedResumed(base, basePasses: [unlimited], allPasses: [unlimited, clean],
                                                 distanceDelta: 500)
        XCTAssertEqual(first.cleanStreak, 2)
        let again = LifetimeStats.updatedResumed(base, basePasses: [clean], allPasses: [clean, clean],
                                                 distanceDelta: 500)
        XCTAssertEqual(again.cleanStreak, 1, "шаг серии за эту поездку уже сделан")
    }
}

// MARK: - S10: удалили поездку — удалили и трек

final class TimedTrackPrivacyTests: XCTestCase {
    func testDeletingATripRemovesItsSecondByTrack() {
        let id = 4_000_000_000.0 + Double(Int.random(in: 0..<100_000))
        TimedTrackStore.save([TimedPoint(time: Date(), lat: 41.3, lon: 69.2, speedKmh: 40)], tripID: id)
        XCTAssertNotNil(TimedTrackStore.load(tripID: id))
        TimedTrackStore.remove(tripID: id)
        XCTAssertNil(TimedTrackStore.load(tripID: id))
    }

    func testTracksAreNotBackedUp() throws {
        let id = 4_000_000_000.0 + Double(Int.random(in: 0..<100_000))
        TimedTrackStore.save([TimedPoint(time: Date(), lat: 41.3, lon: 69.2, speedKmh: 40)], tripID: id)
        defer { TimedTrackStore.remove(tripID: id) }
        let values = try TimedTrackStore.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    // MARK: - Третий круг: старт до разблокировки

    private func record(_ id: Double, km: Double = 10) -> TripRecord {
        TripRecord(id: id, startedAt: Date(timeIntervalSince1970: id), endedAt: Date(timeIntervalSince1970: id + 1800),
                   distanceMeters: km * 1000, maxSpeedKmh: 60, passed: [])
    }

    /// Откуда «за всё время»: файл — правда; нет файла — перенос из
    /// UserDefaults; нет и там — пересборка, но не в процессе, поднятом до
    /// разблокировки при непустой истории: там пустота может быть пустым
    /// кэшем — не писать вовсе.
    func testLifetimeSource() {
        let trips = [record(1), record(2)]
        var saved = LifetimeStats()
        saved.trips = 120
        saved.distanceMeters = 3_000_000
        let unknown = TripStats.Legacy(lifetime: nil, recall: nil, known: false)
        let absent = TripStats.Legacy(lifetime: nil, recall: nil, known: true)
        let present = TripStats.Legacy(lifetime: saved, recall: nil, known: true)
        let file = TripStats.LifetimeFile(lifetime: saved, alertRecall: AlertRecall.Tally())
        let loaded = TripStats.lifetimeSource(.loaded(file), session: nil, legacy: unknown, decodedTrips: trips)
        XCTAssertEqual(loaded.file.lifetime.trips, 120)
        XCTAssertFalse(loaded.needsWrite)
        XCTAssertTrue(loaded.trusted)

        let migrated = TripStats.lifetimeSource(.missing, session: nil, legacy: present, decodedTrips: trips)
        XCTAssertEqual(migrated.file.lifetime.trips, 120, "старая запись настоящая — переносим")
        XCTAssertTrue(migrated.needsWrite)

        let blind = TripStats.lifetimeSource(.missing, session: nil, legacy: unknown, decodedTrips: trips)
        XCTAssertFalse(blind.trusted, "файл настроек не прочтён — нулям не верим")
        XCTAssertFalse(blind.needsWrite)
        XCTAssertFalse(TripStats.lifetimeSource(.missing, session: nil, legacy: unknown, decodedTrips: []).trusted,
                       "и с пустой историей: у человека, стёршего поездки, нули стёрли бы годы")

        let fresh = TripStats.lifetimeSource(.missing, session: nil, legacy: absent, decodedTrips: trips)
        XCTAssertEqual(fresh.file.lifetime.trips, 2, "записи точно нет (версия без счётчиков) — из истории")
        XCTAssertTrue(fresh.trusted)

        let corrupt = TripStats.lifetimeSource(.corrupt(CocoaError(.fileReadCorruptFile)), session: nil,
                                               legacy: present, decodedTrips: trips)
        XCTAssertEqual(corrupt.file.lifetime.trips, 120, "битый файл: лучшее из оставшегося")
        XCTAssertTrue(corrupt.needsWrite)
    }

    /// Старые счётчики — из самого файла настоящих: кэш настроек процесса,
    /// поднятого до разблокировки, может врать пустотой.
    func testLegacyFromThePreferencesFile() throws {
        var saved = LifetimeStats()
        saved.trips = 42
        let dict: [String: Any] = [Storage.Key.lifetimeStats.rawValue: try JSONEncoder().encode(saved),
                                   "другое": 1]
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
        let legacy = TripStats.legacyFromPlist(data)
        XCTAssertTrue(legacy.known)
        XCTAssertEqual(legacy.lifetime?.trips, 42)
        let none = TripStats.legacyFromPlist(try PropertyListSerialization.data(fromPropertyList: ["x": 1],
                                                                                format: .binary, options: 0))
        XCTAssertTrue(none.known, "файл прочтён, ключа нет — точно нет")
        XCTAssertNil(none.lifetime)
        XCTAssertFalse(TripStats.legacyFromPlist(Data("мусор".utf8)).known)
    }

    /// Поездка A кончилась до разблокировки, потом продолжена склейкой и ещё
    /// едет при чтении: её в истории нет, но вклад A — обязателен.
    func testWindowContributionsIncludeTheResumedFirstLeg() {
        let a = record(100), b = record(200)
        XCTAssertEqual(TripStats.windowContributions(window: [b], windowIDs: [100, 200], resumed: a).map(\.id),
                       [100, 200])
        XCTAssertEqual(TripStats.windowContributions(window: [b], windowIDs: [200], resumed: a).map(\.id), [200],
                       "склейка старой, прочитанной поездки — её вклад уже в файле")
    }

    /// Слепок живой поездки — не крэш; поездка уже в истории — дубль после
    /// штатного финиша (S14); иначе — восстановить.
    func testInflightActions() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let last = t.addingTimeInterval(1800)
        func action(continuation: Bool = false, live: Date? = nil, savedEnd: Date?) -> TripStats.InflightAction {
            TripStats.inflightAction(snapshotStartedAt: t, snapshotLastPoint: last, isContinuation: continuation,
                                     liveStartedAt: live, savedEndedAt: savedEnd)
        }
        XCTAssertEqual(action(live: t, savedEnd: nil), .live)
        XCTAssertEqual(action(savedEnd: last), .duplicate, "запись уже в истории — слепок пережил финиш")
        XCTAssertEqual(action(savedEnd: nil), .restore)
        XCTAssertEqual(action(continuation: true, savedEnd: t.addingTimeInterval(600)), .replace,
                       "в истории первая нога, слепок продолжения длиннее")
        XCTAssertEqual(action(continuation: true, savedEnd: last), .duplicate)
    }

    /// Вклад процесса, которому нельзя было верить UserDefaults, ложится
    /// после перенесённого: счётчики складываются, серия продолжается, если
    /// во вкладе не было штрафа; один и тот же вклад — один раз.
    func testSessionJournalReplaysOntoTheMigratedTotals() {
        var saved = LifetimeStats()
        saved.trips = 100
        saved.distanceMeters = 2_000_000
        saved.cleanStreak = 5
        saved.bestStreak = 6
        let clean = DrivingScore.Pass(speedKmh: 55, limitKmh: 60)
        let fined = DrivingScore.Pass(speedKmh: 95, limitKmh: 60)
        func trip(_ pass: DrivingScore.Pass) -> TripStats.LifetimeOp { .trip(passes: [pass], distance: 10_000) }
        // Три чистые через границу (серия 8 — новый рекорд), штраф, ещё одна.
        let session = TripStats.LifetimeSession(id: "S1", ops: [trip(clean), trip(clean), trip(clean),
                                                                 trip(fined), trip(clean), .trips(-1)])
        let file = TripStats.LifetimeFile(lifetime: saved, alertRecall: AlertRecall.Tally())
        let merged = TripStats.lifetimeSource(.loaded(file), session: session,
                                              legacy: TripStats.Legacy(lifetime: nil, recall: nil, known: true),
                                              decodedTrips: [])
        XCTAssertEqual(merged.file.lifetime.trips, 104, "пять поездок, одна склеена вручную")
        XCTAssertEqual(merged.file.lifetime.distanceMeters, 2_050_000)
        XCTAssertEqual(merged.file.lifetime.bestStreak, 8, "рекорд через границу не теряется")
        XCTAssertEqual(merged.file.lifetime.cleanStreak, 1)
        XCTAssertEqual(merged.file.mergedSession, "S1")
        let again = TripStats.lifetimeSource(.loaded(merged.file), session: session,
                                             legacy: TripStats.Legacy(lifetime: nil, recall: nil, known: true),
                                             decodedTrips: [])
        XCTAssertEqual(again.file.lifetime.trips, 104, "упали между записью и удалением журнала — не второй раз")
        // Флаг «поднял рекорд» мерится против настоящего рекорда, а не нуля.
        var high = LifetimeStats()
        high.cleanStreak = 2
        high.bestStreak = 10
        let one = TripStats.LifetimeSession(id: "S2", ops: [trip(clean)])
            .replayed(onto: TripStats.LifetimeFile(lifetime: high, alertRecall: AlertRecall.Tally()))
        XCTAssertEqual(one.lifetime.lastTripRaisedBest, false)
    }

    /// Поле, добавленное позже, не делает старый файл «битым».
    func testOldLifetimeFileStillDecodes() throws {
        let old = Data(#"{"trips":3,"distanceMeters":1000,"camerasPassed":2}"#.utf8)
        let stats = try JSONDecoder().decode(LifetimeStats.self, from: old)
        XCTAssertEqual(stats.trips, 3)
        XCTAssertEqual(stats.bestStreak, 0)
        let tally = try JSONDecoder().decode(AlertRecall.Tally.self, from: Data(#"{"passed":4}"#.utf8))
        XCTAssertEqual(tally.passed, 4)
    }

    /// Своя камера, добавленная, пока файл не читался, с тем же id, что у
    /// другой на диске, — не выбрасывается, а получает свободный id.
    func testCollidingCustomCameraGetsAFreeID() {
        func camera(_ id: Int, lat: Double) -> Camera {
            Camera(id: id, region: "Т", city: "", location: "к", lat: lat, lon: 69.2, type: "Стационар радар",
                   violations: [], needsReview: false, axis: nil, dir: nil, lanes: nil, cls: nil, bridge: nil,
                   road: nil, split: nil, twin: nil)
        }
        let disk = [camera(900_001, lat: 41.30)]
        let merged = CameraStore.merged(disk, [camera(900_001, lat: 41.35), camera(900_001, lat: 41.30)])
        XCTAssertEqual(merged.count, 2, "та же камера — один раз, новая — не потеряна")
        XCTAssertEqual(Set(merged.map(\.id)).count, 2)
    }
}
