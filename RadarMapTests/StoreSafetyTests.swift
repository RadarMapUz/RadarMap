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
        let file = TripStats.LifetimeFile(lifetime: saved, alertRecall: AlertRecall.Tally())
        let loaded = TripStats.lifetimeSource(.loaded(file), legacy: nil, legacyRecall: nil,
                                              startedBlocked: true, decodedTrips: trips)
        XCTAssertEqual(loaded.file.lifetime.trips, 120)
        XCTAssertFalse(loaded.needsWrite)
        XCTAssertTrue(loaded.trusted)

        let migrated = TripStats.lifetimeSource(.missing, legacy: saved, legacyRecall: nil,
                                                startedBlocked: true, decodedTrips: trips)
        XCTAssertEqual(migrated.file.lifetime.trips, 120, "запись UserDefaults настоящая — переносим")
        XCTAssertTrue(migrated.needsWrite)

        let blind = TripStats.lifetimeSource(.missing, legacy: nil, legacyRecall: nil,
                                             startedBlocked: true, decodedTrips: trips)
        XCTAssertFalse(blind.trusted, "до разблокировки пустые UserDefaults — не правда")
        XCTAssertFalse(blind.needsWrite)

        let fresh = TripStats.lifetimeSource(.missing, legacy: nil, legacyRecall: nil,
                                             startedBlocked: false, decodedTrips: trips)
        XCTAssertEqual(fresh.file.lifetime.trips, 2, "версия без счётчиков — из истории")
        XCTAssertTrue(fresh.trusted)

        let empty = TripStats.lifetimeSource(.missing, legacy: nil, legacyRecall: nil,
                                             startedBlocked: true, decodedTrips: [])
        XCTAssertTrue(empty.trusted, "истории нет — новый человек, нулям можно верить")

        let corrupt = TripStats.lifetimeSource(.corrupt(CocoaError(.fileReadCorruptFile)), legacy: saved, legacyRecall: nil,
                                               startedBlocked: false, decodedTrips: trips)
        XCTAssertEqual(corrupt.file.lifetime.trips, 120, "битый файл: лучшее из оставшегося")
        XCTAssertTrue(corrupt.needsWrite)
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
        XCTAssertEqual(TripStats.inflightAction(snapshotStartedAt: t, liveStartedAt: t, historyIDs: []), .live)
        XCTAssertEqual(TripStats.inflightAction(snapshotStartedAt: t, liveStartedAt: nil,
                                                historyIDs: [t.timeIntervalSince1970]), .duplicate)
        XCTAssertEqual(TripStats.inflightAction(snapshotStartedAt: t, liveStartedAt: t.addingTimeInterval(60),
                                                historyIDs: []), .restore)
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
