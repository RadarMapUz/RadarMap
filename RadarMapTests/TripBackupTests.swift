//
//  TripBackupTests.swift
//  RadarMapTests
//
//  Восстановление истории из файла. Тесты здесь написаны против одного
//  страха: импорт, который что-то стирает. Человек берёт копию, чтобы НЕ
//  потерять данные, и обмен «вернул старое, потерял новое» для него ничем не
//  лучше исходной пропажи.
//

import XCTest
@testable import RadarMap

final class TripBackupTests: XCTestCase {

    private func record(id: Double, day: Int) -> TripRecord {
        TripRecord(id: id,
                   startedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(day) * 86400),
                   endedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(day) * 86400 + 1800),
                   distanceMeters: 12_000, maxSpeedKmh: 90, passed: [])
    }

    private func day(_ index: Int, trips: Int) -> TripDay {
        var row = TripDay(day: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 86400))
        row.trips = trips
        row.distanceMeters = Double(trips) * 10_000
        return row
    }

    private func backup(history: [TripRecord] = [], days: [TripDay] = [],
                        lifetime: LifetimeStats = LifetimeStats()) -> TripBackup {
        var archive = TripBackup()
        archive.history = history
        archive.days = days
        archive.lifetime = lifetime
        return archive
    }

    // MARK: - Формат

    func testFreshArchiveIsReadable() {
        XCTAssertTrue(TripBackup().isReadable)
    }

    func testForeignFileIsRejectedBeforeAnythingChanges() {
        // Чужой JSON не должен разбираться наполовину: импорт либо проходит
        // целиком, либо не начинается.
        var alien = TripBackup()
        alien.app = "some.other.app"
        XCTAssertFalse(alien.isReadable)
    }

    func testFutureSchemaIsRejected() {
        // Файл из будущей версии читатель понять не может — и обязан сказать
        // об этом, а не сделать вид, что понял.
        var future = TripBackup()
        future.schema = TripBackup.currentSchema + 1
        XCTAssertFalse(future.isReadable)
    }

    func testEmptyArchiveIsRecognised() {
        XCTAssertTrue(TripBackup().isEmpty)
        XCTAssertFalse(backup(history: [record(id: 1, day: 0)]).isEmpty)
    }

    // MARK: - Слияние поездок

    func testImportAddsMissingTripsAndKeepsOwn() {
        let archive = backup(history: [record(id: 1, day: 0), record(id: 2, day: 1)])
        let result = TripBackupMerge.merge(archive,
                                           history: [record(id: 3, day: 2)],
                                           days: [], lifetime: LifetimeStats(),
                                           customCameras: [], hiddenCameraIDs: [])
        XCTAssertEqual(result.history.count, 3)
        XCTAssertEqual(result.addedTrips, 2)
        XCTAssertTrue(result.history.contains { $0.id == 3 }, "своя поездка не должна пропасть")
    }

    func testRestoringOntoAPhoneWithTripsLosesNothing() {
        // Главный сценарий: человек поездил, потом вспомнил про копию.
        let own = [record(id: 10, day: 5), record(id: 11, day: 6)]
        let archive = backup(history: [record(id: 1, day: 0)])
        let result = TripBackupMerge.merge(archive, history: own, days: [],
                                           lifetime: LifetimeStats(),
                                           customCameras: [], hiddenCameraIDs: [])
        XCTAssertEqual(Set(result.history.map(\.id)), [1, 10, 11])
    }

    func testDuplicateTripIsNotCountedTwice() {
        let shared = record(id: 7, day: 3)
        let result = TripBackupMerge.merge(backup(history: [shared]),
                                           history: [shared], days: [],
                                           lifetime: LifetimeStats(),
                                           customCameras: [], hiddenCameraIDs: [])
        XCTAssertEqual(result.history.count, 1)
        XCTAssertEqual(result.addedTrips, 0, "дубль не «добавленная» поездка")
    }

    func testHistoryStaysNewestFirst() {
        let result = TripBackupMerge.merge(backup(history: [record(id: 1, day: 0)]),
                                           history: [record(id: 2, day: 9)], days: [],
                                           lifetime: LifetimeStats(),
                                           customCameras: [], hiddenCameraIDs: [])
        XCTAssertEqual(result.history.first?.id, 2, "порядок истории — от новых к старым")
    }

    // MARK: - Слияние дней

    func testFullerDayRowWins() {
        // Дневные сводки переживают вычистку истории: полнее — значит ближе к
        // правде, и обеднять их импортом нельзя.
        let result = TripBackupMerge.merge(backup(days: [day(0, trips: 5)]),
                                           history: [], days: [day(0, trips: 2)],
                                           lifetime: LifetimeStats(),
                                           customCameras: [], hiddenCameraIDs: [])
        XCTAssertEqual(result.days.count, 1)
        XCTAssertEqual(result.days.first?.trips, 5)
    }

    func testOwnDayWinsWhenItIsFuller() {
        let result = TripBackupMerge.merge(backup(days: [day(0, trips: 1)]),
                                           history: [], days: [day(0, trips: 4)],
                                           lifetime: LifetimeStats(),
                                           customCameras: [], hiddenCameraIDs: [])
        XCTAssertEqual(result.days.first?.trips, 4)
    }

    func testDaysFromArchiveThatPhoneNeverHadAreAdded() {
        let result = TripBackupMerge.merge(backup(days: [day(0, trips: 3), day(1, trips: 2)]),
                                           history: [], days: [day(1, trips: 2)],
                                           lifetime: LifetimeStats(),
                                           customCameras: [], hiddenCameraIDs: [])
        XCTAssertEqual(result.days.count, 2)
        XCTAssertEqual(result.addedDays, 1)
    }

    // MARK: - Пожизненные счётчики

    func testLifetimeTakesMaximumAndNeverShrinks() {
        var own = LifetimeStats()
        own.trips = 40; own.distanceMeters = 900_000; own.bestStreak = 3
        var archived = LifetimeStats()
        archived.trips = 55; archived.distanceMeters = 500_000; archived.bestStreak = 9

        let merged = TripBackupMerge.maxed(own, archived)
        XCTAssertEqual(merged.trips, 55)
        XCTAssertEqual(merged.distanceMeters, 900_000, "пробег не имеет права убыть")
        XCTAssertEqual(merged.bestStreak, 9)
    }

    func testLifetimeIsNeverSummed() {
        // Копия и телефон пересекаются: сложение удвоило бы общий пробег и
        // превратило «сэкономлено» в выдумку.
        var stats = LifetimeStats()
        stats.trips = 30; stats.distanceMeters = 400_000
        let merged = TripBackupMerge.maxed(stats, stats)
        XCTAssertEqual(merged.trips, 30)
        XCTAssertEqual(merged.distanceMeters, 400_000)
    }

    // MARK: - Свои и скрытые камеры

    func testHiddenCamerasAreUnioned() {
        var archive = TripBackup()
        archive.hiddenCameraIDs = [1, 2]
        let result = TripBackupMerge.merge(archive, history: [], days: [],
                                           lifetime: LifetimeStats(),
                                           customCameras: [], hiddenCameraIDs: [2, 3])
        XCTAssertEqual(result.hiddenCameraIDs, [1, 2, 3])
    }

    // MARK: - S15: итоги дня сходятся со списком

    /// На телефоне в этот день поездка A, в копии — B и C того же дня.
    /// Слияние даёт три поездки в списке — и три в итогах дня, а не две
    /// «более полной» строки копии.
    func testRestoredDayMatchesTheTripList() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let dayStart = utc.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        func trip(_ id: Double, hour: Double) -> TripRecord {
            TripRecord(id: id, startedAt: dayStart.addingTimeInterval(hour * 3600),
                       endedAt: dayStart.addingTimeInterval(hour * 3600 + 1200),
                       distanceMeters: 5000, maxSpeedKmh: 60, passed: [])
        }
        let own = [trip(1, hour: 9)]
        let archived = [trip(2, hour: 13), trip(3, hour: 18)]
        let result = TripBackupMerge.merge(backup(history: archived,
                                                  days: TripDayBook.rebuilt(from: archived, calendar: utc)),
                                           history: own, days: TripDayBook.rebuilt(from: own, calendar: utc),
                                           lifetime: LifetimeStats(), customCameras: [], hiddenCameraIDs: [],
                                           calendar: utc)
        XCTAssertEqual(result.history.count, 3)
        XCTAssertEqual(result.days.first(where: { $0.day == dayStart })?.trips, 3)
        XCTAssertEqual(result.days.first(where: { $0.day == dayStart })?.distanceMeters ?? 0, 15_000, accuracy: 0.1)
    }
}
