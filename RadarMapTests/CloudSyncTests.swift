//
//  CloudSyncTests.swift
//  RadarMapTests
//
//  Поездки в iCloud (27.F) без CloudKit: решения слияния и надгробий, вид
//  записи (что открыто, что зашифровано, что ключ записи близких не уходит),
//  перенос старых данных, проход двух телефонов через заглушку iCloud и
//  поведение без iCloud. CloudKit здесь не вызывается ни разу — транспорт
//  подменён протоколом (FakeCloud).
//

import XCTest
@testable import RadarMap

// MARK: - Заглушка iCloud

/// Приватная база в памяти: зоны, записи с порядковым номером изменения,
/// «последняя правка» при записи — как CloudKitTransport.
actor FakeCloud: CloudTransport {
    struct Stored { var wire: CloudWire; var seq: Int }
    private(set) var zones: [CloudZone: [String: Stored]] = [:]
    private var seq = 0
    var currentAccount: CloudAccount = .available("user-1")
    var offline = false
    private(set) var savedCount = 0
    private(set) var calls = 0

    func setOffline(_ value: Bool) { offline = value }
    func setAccount(_ value: CloudAccount) { currentAccount = value }

    func account() async -> CloudAccount {
        calls += 1
        return currentAccount
    }

    func prepare(zones list: [CloudZone]) async throws {
        calls += 1
        if offline { throw CloudFailure.offline }
        for zone in list where zones[zone] == nil { zones[zone] = [:] }
    }

    func fetch(zone: CloudZone, token: Data?, limit: Int) async throws -> CloudPage {
        calls += 1
        if offline { throw CloudFailure.offline }
        guard let records = zones[zone] else { throw CloudFailure.zoneMissing }
        let since = token.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        let changed = records.values.filter { $0.seq > since }.sorted { $0.seq < $1.seq }
        let page = Array(changed.prefix(limit))
        let last = page.last?.seq ?? since
        return CloudPage(records: page.map(\.wire), deletedNames: [],
                         token: Data(String(max(last, since)).utf8), more: changed.count > limit)
    }

    func save(_ records: [CloudWire]) async throws -> [String: CloudSaveOutcome] {
        calls += 1
        if offline { throw CloudFailure.offline }
        var outcomes: [String: CloudSaveOutcome] = [:]
        for wire in records {
            guard zones[wire.zone] != nil else { throw CloudFailure.zoneMissing }
            let existing = zones[wire.zone]?[wire.recordName]
            if case .date(let stored)? = existing?.wire.plain[CloudCodec.modifiedKey],
               case .date(let ours)? = wire.plain[CloudCodec.modifiedKey], stored > ours {
                outcomes[wire.recordName] = .serverNewer
                continue
            }
            var merged = existing?.wire ?? CloudWire(recordName: wire.recordName, recordType: wire.recordType,
                                                    zone: wire.zone, plain: [:], encrypted: [:])
            merged.plain.merge(wire.plain) { $1 }
            merged.encrypted.merge(wire.encrypted) { $1 }
            for key in wire.cleared { merged.encrypted[key] = nil }
            seq += 1
            zones[wire.zone]?[wire.recordName] = Stored(wire: merged, seq: seq)
            savedCount += 1
            outcomes[wire.recordName] = .saved
        }
        return outcomes
    }

    func delete(zones list: [CloudZone]) async throws {
        calls += 1
        if offline { throw CloudFailure.offline }
        for zone in list { zones[zone] = nil }
    }

    func wire(_ name: String) -> CloudWire? {
        zones.values.lazy.compactMap { $0[name]?.wire }.first
    }

    func names(in zone: CloudZone) -> Set<String> { Set(zones[zone]?.keys.map { $0 } ?? []) }

    /// Чужая запись прямо в базе (другое устройство записало позже).
    func inject(_ wire: CloudWire) {
        if zones[wire.zone] == nil { zones[wire.zone] = [:] }
        seq += 1
        zones[wire.zone]?[wire.recordName] = Stored(wire: wire, seq: seq)
    }
}

/// Источник в памяти: записи по ключу, разделы (месяцы) и «горячие» из них.
@MainActor
final class MemorySource: CloudSource {
    nonisolated deinit {}
    let kind: CloudKind
    var items: [CloudKey: CloudItem] = [:]
    var partitions: Set<String>
    /// nil — все разделы в памяти.
    var hot: Set<String>?
    var ready = true
    private(set) var applyCalls = 0

    init(_ kind: CloudKind, partitions: Set<String> = [""]) {
        self.kind = kind
        self.partitions = partitions
    }

    var isReady: Bool { ready }
    func hotPartitions() -> Set<String> { hot ?? partitions }
    func allPartitions() async -> Set<String>? { partitions }

    func items(in parts: Set<String>) async -> [CloudItem]? {
        items.values.filter { parts.contains($0.key.partition) }
            .map { CloudItem(key: $0.key, body: $0.body, track: $0.track, natural: $0.natural) }
    }

    func apply(upserts: [CloudItem], deletions: [CloudKey]) async -> Bool {
        applyCalls += 1
        for item in upserts {
            items[item.key] = CloudItem(key: item.key, body: item.body, track: item.track)
            partitions.insert(item.key.partition)
        }
        for key in deletions { items[key] = nil }
        return true
    }

    func put(_ id: String, _ text: String, partition: String = "", track: String? = nil, natural: Date? = nil) {
        let key = CloudKey(kind: kind, partition: partition, id: id)
        items[key] = CloudItem(key: key, body: Data(text.utf8), track: track.map { Data($0.utf8) }, natural: natural)
        partitions.insert(partition)
    }

    func text(_ id: String, partition: String = "") -> String? {
        items[CloudKey(kind: kind, partition: partition, id: id)]?.body.map { String(decoding: $0, as: UTF8.self) }
    }
}

/// Один телефон: источники, журнал в памяти, движок, свои часы.
@MainActor
final class FakeDevice {
    nonisolated deinit {}
    let trips = MemorySource(.trip, partitions: [])
    let fines = MemorySource(.fine)
    let vehicle = MemorySource(.vehicle)
    let summary = MemorySource(.summary)
    var clock = Date(timeIntervalSince1970: 1_792_497_600)
    private(set) var ledger = CloudLedger()
    var engine: CloudSyncEngine!

    init(cloud: FakeCloud) {
        engine = CloudSyncEngine(transport: cloud, sources: [trips, summary, fines, vehicle],
                                 ledger: ledger) { [weak self] next in self?.ledger = next }
        engine.now = { [weak self] in self?.clock ?? Date() }
        engine.scanPause = 0
    }

    func tick(_ seconds: TimeInterval = 60) { clock = clock.addingTimeInterval(seconds) }

    @discardableResult
    func sync(scan: Bool = false) async -> CloudSyncEngine.Outcome {
        tick()
        return await engine.run(scan: scan)
    }
}

// MARK: - Решения слияния

final class CloudMergeTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_792_497_600)

    private func item(_ id: String, _ text: String, kind: CloudKind = .fine, partition: String = "",
                      track: String? = nil, at: Date = .distantPast, deleted: Bool = false) -> CloudItem {
        CloudItem(key: CloudKey(kind: kind, partition: partition, id: id),
                  body: deleted ? nil : Data(text.utf8), track: track.map { Data($0.utf8) },
                  modifiedAt: at, deleted: deleted)
    }

    func testNewLocalItemIsQueuedOnceAndRepeatIsIdempotent() {
        var ledger = CloudLedger()
        let items = [item("a", "1"), item("b", "2")]
        XCTAssertEqual(CloudMerge.detectLocal(items, kind: .fine, partitions: [""], ledger: &ledger, now: t0), 2)
        XCTAssertEqual(ledger.pendingKeys.count, 2)
        let before = ledger
        XCTAssertEqual(CloudMerge.detectLocal(items, kind: .fine, partitions: [""], ledger: &ledger, now: t0 + 60), 0,
                       "тот же снимок — ни одного изменения")
        XCTAssertEqual(ledger, before)
    }

    func testEditBumpsTimeEvenIfClockWentBack() throws {
        var ledger = CloudLedger()
        CloudMerge.detectLocal([item("a", "1")], kind: .fine, partitions: [""], ledger: &ledger, now: t0)
        CloudMerge.markSent(CloudKey(kind: .fine, id: "a"), modifiedAt: t0, ledger: &ledger)
        XCTAssertTrue(ledger.pendingKeys.isEmpty)
        // Часы телефона ушли назад — правка всё равно новее прошлой версии.
        CloudMerge.detectLocal([item("a", "2")], kind: .fine, partitions: [""], ledger: &ledger, now: t0 - 3600)
        let entry = try XCTUnwrap(ledger.entries["fine..a"])
        XCTAssertTrue(entry.pending)
        XCTAssertGreaterThan(entry.modifiedAt, t0)
    }

    func testPrunedTrackIsNotAnEdit() {
        var ledger = CloudLedger()
        let full = item("1", "{}", kind: .trip, partition: "2026-10", track: "[41.3,69.2,50]")
        CloudMerge.detectLocal([full], kind: .trip, partitions: ["2026-10"], ledger: &ledger, now: t0)
        CloudMerge.markSent(full.key, modifiedAt: t0, ledger: &ledger)
        let slim = item("1", "{}", kind: .trip, partition: "2026-10")
        XCTAssertEqual(CloudMerge.detectLocal([slim], kind: .trip, partitions: ["2026-10"], ledger: &ledger, now: t0 + 60), 0,
                       "вырезанный сроком трек — не правка: в iCloud он живёт дальше")
        XCTAssertNotNil(ledger.entries[full.key.recordName]?.track)
        // А новый трек (склейка) — правка.
        let longer = item("1", "{}", kind: .trip, partition: "2026-10", track: "[41.3,69.2,50,41.4,69.3,60]")
        XCTAssertEqual(CloudMerge.detectLocal([longer], kind: .trip, partitions: ["2026-10"], ledger: &ledger, now: t0 + 120), 1)
    }

    func testMissingItemIsTombstonedOnlyInCoveredPartitions() throws {
        var ledger = CloudLedger()
        let oct = item("1", "x", kind: .trip, partition: "2026-10")
        let sep = item("2", "y", kind: .trip, partition: "2026-09")
        CloudMerge.detectLocal([oct, sep], kind: .trip, partitions: ["2026-10", "2026-09"], ledger: &ledger, now: t0)
        // Сентябрь не прочитан с диска — его отсутствие в снимке ничего не значит.
        XCTAssertEqual(CloudMerge.detectLocal([oct], kind: .trip, partitions: ["2026-10"], ledger: &ledger, now: t0 + 60), 0)
        XCTAssertEqual(ledger.entries[sep.key.recordName]?.deleted, false)
        // Октябрь в памяти целиком — пропавшая запись удалена.
        XCTAssertEqual(CloudMerge.detectLocal([], kind: .trip, partitions: ["2026-10"], ledger: &ledger, now: t0 + 120), 1)
        let tomb = try XCTUnwrap(ledger.entries[oct.key.recordName])
        XCTAssertTrue(tomb.deleted)
        XCTAssertTrue(tomb.pending)
        XCTAssertNil(tomb.fields)
    }

    func testUnknownRecordFromCloudWins() {
        XCTAssertEqual(CloudMerge.resolve(item("a", "1", at: t0), entry: nil), .applyRemote,
                       "журнал записи не знает — восстановление: iCloud прав")
    }

    func testLastEditWins() {
        var ledger = CloudLedger()
        CloudMerge.detectLocal([item("a", "local")], kind: .fine, partitions: [""], ledger: &ledger, now: t0)
        XCTAssertEqual(CloudMerge.resolve(item("a", "remote", at: t0 + 1), entry: ledger.entries["fine..a"]), .applyRemote)
        XCTAssertEqual(CloudMerge.resolve(item("a", "remote", at: t0 - 1), entry: ledger.entries["fine..a"]), .keepLocal)
        XCTAssertEqual(CloudMerge.resolve(item("a", "local", at: t0 - 1), entry: ledger.entries["fine..a"]), .same)
    }

    /// Равное время и разное содержимое: оба телефона выбирают одно и то же.
    func testTieIsDecidedTheSameOnBothDevices() {
        var a = CloudLedger(), b = CloudLedger()
        CloudMerge.detectLocal([item("x", "alpha", at: t0)], kind: .fine, partitions: [""], ledger: &a, now: t0)
        CloudMerge.detectLocal([item("x", "omega", at: t0)], kind: .fine, partitions: [""], ledger: &b, now: t0)
        let onA = CloudMerge.resolve(item("x", "omega", at: t0), entry: a.entries["fine..x"])
        let onB = CloudMerge.resolve(item("x", "alpha", at: t0), entry: b.entries["fine..x"])
        XCTAssertNotEqual(onA, .same)
        XCTAssertNotEqual(onA, onB, "один принимает чужое, другой оставляет своё — сходятся к одному")
    }

    func testTombstoneAgainstEdits() {
        var ledger = CloudLedger()
        CloudMerge.detectLocal([item("a", "edit")], kind: .fine, partitions: [""], ledger: &ledger, now: t0)
        let entry = ledger.entries["fine..a"]
        XCTAssertEqual(CloudMerge.resolve(item("a", "", at: t0 + 5, deleted: true), entry: entry), .applyRemote,
                       "правка старше надгробия его не воскрешает")
        XCTAssertEqual(CloudMerge.resolve(item("a", "", at: t0 - 5, deleted: true), entry: entry), .keepLocal,
                       "правка новее удаления — живёт")
        XCTAssertEqual(CloudMerge.resolve(item("a", "", at: t0, deleted: true), entry: entry), .applyRemote,
                       "равное время — надгробие сильнее")
    }

    func testSentMarkIgnoredIfEditedSince() {
        var ledger = CloudLedger()
        let key = CloudKey(kind: .fine, id: "a")
        CloudMerge.detectLocal([item("a", "1")], kind: .fine, partitions: [""], ledger: &ledger, now: t0)
        CloudMerge.detectLocal([item("a", "2")], kind: .fine, partitions: [""], ledger: &ledger, now: t0 + 10)
        CloudMerge.markSent(key, modifiedAt: t0, ledger: &ledger)
        XCTAssertEqual(ledger.entries[key.recordName]?.pending, true, "отправлена старая версия — новая ждёт")
    }

    func testSummaryAlwaysMerges() {
        var ledger = CloudLedger()
        CloudMerge.detectLocal([item("summary", "mine", kind: .summary)], kind: .summary, partitions: [""],
                               ledger: &ledger, now: t0)
        XCTAssertEqual(CloudMerge.resolve(item("summary", "theirs", kind: .summary, at: t0 - 100),
                                          entry: ledger.entries["summary..summary"]), .applyRemote,
                       "сводку решает слияние, а не время")
    }

    func testForeignWipeOnlyAfterFirstSync() {
        var ledger = CloudLedger()
        XCTAssertFalse(CloudMerge.isForeignWipe(t0, ledger: ledger), "новый телефон: старая отметка — не повод")
        ledger.syncedOnce = true
        XCTAssertTrue(CloudMerge.isForeignWipe(t0, ledger: ledger))
        ledger.wipeSeen = t0
        XCTAssertFalse(CloudMerge.isForeignWipe(t0, ledger: ledger), "своя отметка")
    }

    func testRecordNameRoundTrip() {
        let key = CloudKey(kind: .trip, partition: "2026-10", id: "1792497600.125")
        XCTAssertEqual(key.recordName, "trip.2026-10.1792497600.125")
        XCTAssertEqual(CloudKey(recordName: key.recordName), key)
        XCTAssertEqual(CloudKey(recordName: "fine..ABC"), CloudKey(kind: .fine, id: "ABC"))
        XCTAssertNil(CloudKey(recordName: "alien.x.y"))
        XCTAssertNil(CloudKey(recordName: "trip.2026-10."))
    }

    /// Журнал старой сборки без новых полей читается, а не теряется.
    func testLedgerFromOlderBuildDecodes() throws {
        let old = try JSONDecoder().decode(CloudLedger.self, from: Data(#"{"version":1,"entries":{"fine..a":{"modifiedAt":0,"deleted":false,"pending":true}}}"#.utf8))
        XCTAssertEqual(old.entries.count, 1)
        XCTAssertFalse(old.syncedOnce)
        XCTAssertTrue(old.pendingWipeZones.isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(CloudLedger.self, from: Data("{}".utf8)), CloudLedger())
    }

    func testForgetZoneKeepsOtherZone() {
        var ledger = CloudLedger()
        CloudMerge.detectLocal([item("1", "x", kind: .trip, partition: "2026-10")], kind: .trip,
                               partitions: ["2026-10"], ledger: &ledger, now: t0)
        CloudMerge.detectLocal([item("a", "y")], kind: .fine, partitions: [""], ledger: &ledger, now: t0)
        ledger.tokens = ["Trips": Data([1]), "Data": Data([2])]
        ledger.scanned = ["2026-09": t0]
        ledger.forget(zone: .trips)
        XCTAssertEqual(Set(ledger.entries.keys), ["fine..a"])
        XCTAssertEqual(Set(ledger.tokens.keys), ["Data"])
        XCTAssertTrue(ledger.scanned.isEmpty)
    }
}

// MARK: - Вид записи в iCloud

final class CloudCodecTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_792_497_600)

    private func trip() -> TripRecord {
        var pass = PassedCamera(id: UUID(), cameraID: 42, typeRaw: "radar", location: "ул. Нурафшон",
                                speedKmh: 71, date: start.addingTimeInterval(300))
        pass.lat = 41.311081
        pass.lon = 69.240562
        var record = TripRecord(id: start.timeIntervalSince1970 + 0.25, startedAt: start,
                                endedAt: start.addingTimeInterval(1800), distanceMeters: 12_345,
                                maxSpeedKmh: 88, passed: [pass], endLat: 41.338877, endLon: 69.334321,
                                track: [41.311081, 69.240562, 50, 41.338877, 69.334321, 60], score: 87)
        record.startLat = 41.299496
        record.startLon = 69.240073
        return record
    }

    private func plainText(_ wire: CloudWire) -> String {
        wire.plain.map { key, value in
            switch value {
            case .date(let date): return "\(key)=\(date.timeIntervalSince1970)"
            case .int(let number): return "\(key)=\(number)"
            case .data(let data): return "\(key)=\(String(decoding: data, as: UTF8.self))"
            case .string(let text): return "\(key)=\(text)"
            }
        }.joined(separator: ";")
    }

    /// Главное правило: открыто — только служебное, всё содержимое — в
    /// зашифрованных полях.
    func testOnlyServiceFieldsAreInTheClear() throws {
        var item = try XCTUnwrap(CloudPayload.tripItem(trip()))
        item.modifiedAt = start
        let wire = try XCTUnwrap(CloudCodec.wire(for: item))
        XCTAssertTrue(Set(wire.plain.keys).isSubset(of: CloudCodec.plainKeys), "\(wire.plain.keys)")
        for value in wire.plain.values {
            switch value {
            case .date, .int: continue
            case .data, .string: XCTFail("открытое поле с содержимым: \(value)")
            }
        }
        let clear = plainText(wire)
        for secret in ["41.31", "69.24", "41.33", "Нурафшон", "12345", "radar"] {
            XCTAssertFalse(clear.contains(secret), "«\(secret)» лежит открыто")
        }
        XCTAssertEqual(Set(wire.encrypted.keys), [CloudCodec.bodyKey, CloudCodec.trackKey])
        // Зашифрованное — и правда содержит координаты (а не пустое место).
        guard case .data(let packed)? = wire.encrypted[CloudCodec.bodyKey] else { return XCTFail("нет содержимого") }
        let body = String(decoding: try XCTUnwrap(CloudCodec.decompress(packed)), as: UTF8.self)
        XCTAssertTrue(body.contains("41.311081"))
    }

    func testTripRoundTripsWithTrack() throws {
        let record = trip()
        var item = try XCTUnwrap(CloudPayload.tripItem(record))
        XCTAssertEqual(item.key.partition, "2026-10")
        XCTAssertEqual(item.natural, record.endedAt, "новая запись берёт время конца поездки")
        item.modifiedAt = start
        let wire = try XCTUnwrap(CloudCodec.wire(for: item))
        let back = try XCTUnwrap(CloudCodec.item(from: wire))
        XCTAssertEqual(back.modifiedAt, start)
        XCTAssertEqual(CloudPayload.tripRecord(from: back), record)
    }

    func testTrackIsSeparateSoPruningKeepsBodyFingerprint() throws {
        let record = trip()
        var slim = record
        slim.track = nil
        let full = try XCTUnwrap(CloudPayload.tripItem(record))
        let cut = try XCTUnwrap(CloudPayload.tripItem(slim))
        XCTAssertEqual(full.body, cut.body, "трек не входит в содержимое")
        XCTAssertNil(cut.track)
    }

    func testTombstoneCarriesNoContent() throws {
        let wire = try XCTUnwrap(CloudCodec.wire(for: .tombstone(CloudKey(kind: .fine, id: "a"), at: start)))
        XCTAssertTrue(wire.encrypted.isEmpty)
        XCTAssertEqual(Set(wire.cleared), [CloudCodec.bodyKey, CloudCodec.trackKey])
        XCTAssertEqual(wire.plain[CloudCodec.deletedKey], .int(1))
        let back = try XCTUnwrap(CloudCodec.item(from: wire))
        XCTAssertTrue(back.deleted)
        XCTAssertNil(back.body)
    }

    func testFutureSchemaIsSkipped() throws {
        var wire = try XCTUnwrap(CloudCodec.wire(for: CloudItem(key: CloudKey(kind: .fine, id: "a"),
                                                                body: Data("{}".utf8), modifiedAt: start)))
        wire.plain[CloudCodec.schemaKey] = .int(CloudCodec.schema + 1)
        XCTAssertNil(CloudCodec.item(from: wire), "запись новой сборки не разбирается наполовину")
    }

    func testTooLargeRecordIsRefused() {
        var noise = Data(count: AppConfig.cloudRecordMaxBytes * 2)
        for index in noise.indices { noise[index] = UInt8.random(in: 0...255) }
        XCTAssertNil(CloudCodec.wire(for: CloudItem(key: CloudKey(kind: .fine, id: "a"), body: noise)))
    }

    /// Ключ записи близкого (W) и адрес ссылки не уходят никогда.
    func testFamilyWriteKeyNeverLeaves() throws {
        let now = Date(timeIntervalSince1970: 1_792_497_600)
        var mom = FamilyRecipient(name: "Мама", emoji: "👩‍🦳", mode: .home, now: now)
        mom.linkSentAt = now
        let legacy = FamilyRecipient(name: "Брат", now: now)
        var circle = FamilyCircle(recipients: [mom, legacy], driverName: "Зафар")
        circle.pausedUntil = now
        let items = CloudPayload.familyItems(circle)
        XCTAssertEqual(items.count, 3)
        let secrets = [mom.key, mom.token, legacy.key, legacy.token].compactMap { $0 } + [mom.write.address]
        for item in items {
            let body = String(decoding: try XCTUnwrap(item.body), as: UTF8.self)
            for secret in secrets {
                XCTAssertFalse(body.contains(secret), "ключ записи или адрес ссылки ушёл в iCloud")
            }
            for field in ["\"key\"", "\"token\"", "linkSentAt", "pausedUntil"] {
                XCTAssertFalse(body.contains(field), "поле \(field) ушло в iCloud")
            }
            let wire = try XCTUnwrap(CloudCodec.wire(for: item))
            guard case .data(let packed)? = wire.encrypted[CloudCodec.bodyKey],
                  let raw = CloudCodec.decompress(packed) else { return XCTFail("нет содержимого") }
            for secret in secrets {
                XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains(secret))
            }
        }
        let contact = try XCTUnwrap(CloudPayload.decode(CloudPayload.FamilyContact.self, from: items[0].body))
        XCTAssertEqual(contact.name, "Мама")
        XCTAssertEqual(contact.mode, .home)
    }

    /// Поездка старого формата (до необязательных полей) — тоже уходит и
    /// возвращается той же записью.
    func testLegacyTripWithoutNewFieldsRoundTrips() throws {
        let json = #"{"id":1700000000,"startedAt":721692800,"endedAt":721694600,"distanceMeters":5000,"maxSpeedKmh":60,"passed":[]}"#
        let legacy = try JSONDecoder().decode(TripRecord.self, from: Data(json.utf8))
        XCTAssertNil(legacy.startLat)
        let item = try XCTUnwrap(CloudPayload.tripItem(legacy))
        XCTAssertNil(item.track)
        XCTAssertEqual(CloudPayload.tripRecord(from: item), legacy)
    }

    func testTripIDMismatchIsRejected() throws {
        var item = try XCTUnwrap(CloudPayload.tripItem(trip()))
        item = CloudItem(key: CloudKey(kind: .trip, partition: "2026-10", id: "1"), body: item.body)
        XCTAssertNil(CloudPayload.tripRecord(from: item), "id в имени и в содержимом разошлись — не принимаем")
    }
}

// MARK: - Проход: два телефона через заглушку

final class CloudSyncEngineTests: XCTestCase {

    func testFirstUploadSendsMemoryAndDiskMonthsThenNothing() async {
        let cloud = FakeCloud()
        let phone = FakeDevice(cloud: cloud)
        phone.trips.put("1", "oct-1", partition: "2026-10")
        phone.trips.put("2", "oct-2", partition: "2026-10")
        phone.trips.put("3", "sep-1", partition: "2026-09")
        phone.trips.put("4", "aug-1", partition: "2026-08", track: "[1,2,3]")
        phone.trips.hot = ["2026-10"]   // август и сентябрь — только на диске
        phone.fines.put("f", "fine")
        let outcome = await phone.sync()
        XCTAssertEqual(outcome, .synced)
        let names = await cloud.names(in: .trips)
        XCTAssertEqual(names, ["trip.2026-10.1", "trip.2026-10.2", "trip.2026-09.3", "trip.2026-08.4"])
        let dataNames = await cloud.names(in: .data)
        XCTAssertEqual(dataNames, ["fine..f"])
        XCTAssertEqual(phone.ledger.tripsInCloud, 4)
        XCTAssertNotNil(phone.ledger.fullScanAt)
        let saved = await cloud.savedCount
        await phone.sync()
        let savedAgain = await cloud.savedCount
        XCTAssertEqual(saved, savedAgain, "повтор ничего не отправляет")
        XCTAssertTrue(phone.ledger.pendingKeys.isEmpty)
    }

    /// Новый телефон: всё из iCloud — к себе, своё — в iCloud, своё «пустое»
    /// не спорит с настоящим.
    func testRestoreOnNewPhoneMergesWithLocal() async {
        let cloud = FakeCloud()
        let old = FakeDevice(cloud: cloud)
        old.trips.put("1", "trip-1", partition: "2026-09")
        old.trips.put("2", "trip-2", partition: "2026-10")
        old.vehicle.put("profile", "byd")
        await old.sync()

        let fresh = FakeDevice(cloud: cloud)
        fresh.clock = old.clock.addingTimeInterval(86_400)
        fresh.trips.put("9", "new-phone-trip", partition: "2026-10")
        fresh.vehicle.put("profile", "default")   // профиль нового телефона, ещё не настроен
        let outcome = await fresh.sync()
        XCTAssertEqual(outcome, .synced)
        XCTAssertEqual(fresh.trips.text("1", partition: "2026-09"), "trip-1")
        XCTAssertEqual(fresh.trips.text("2", partition: "2026-10"), "trip-2")
        XCTAssertEqual(fresh.trips.text("9", partition: "2026-10"), "new-phone-trip", "своё не пропало")
        XCTAssertEqual(fresh.vehicle.text("profile"), "byd", "первый проход: iCloud прав")
        let names = await cloud.names(in: .trips)
        XCTAssertTrue(names.contains("trip.2026-10.9"), "своё уехало в iCloud")
        await old.sync()
        XCTAssertEqual(old.trips.text("9", partition: "2026-10"), "new-phone-trip")
    }

    func testLastEditWinsAcrossDevices() async {
        let cloud = FakeCloud()
        let a = FakeDevice(cloud: cloud), b = FakeDevice(cloud: cloud)
        a.fines.put("x", "v1")
        await a.sync()
        await b.sync()
        XCTAssertEqual(b.fines.text("x"), "v1")
        // A правит раньше, B позже; синхронизируются в обратном порядке.
        a.fines.put("x", "from-a")
        a.tick(10)
        b.clock = a.clock.addingTimeInterval(300)
        b.fines.put("x", "from-b")
        await b.sync()
        await a.sync()
        await b.sync()
        XCTAssertEqual(a.fines.text("x"), "from-b")
        XCTAssertEqual(b.fines.text("x"), "from-b")
    }

    func testDeletionTravelsAsTombstone() async {
        let cloud = FakeCloud()
        let a = FakeDevice(cloud: cloud), b = FakeDevice(cloud: cloud)
        a.trips.put("1", "trip", partition: "2026-10")
        a.trips.put("2", "keep", partition: "2026-10")
        await a.sync()
        await b.sync()
        XCTAssertNotNil(b.trips.text("1", partition: "2026-10"))
        a.trips.items[CloudKey(kind: .trip, partition: "2026-10", id: "1")] = nil
        await a.sync()
        let tomb = await cloud.wire("trip.2026-10.1")
        XCTAssertEqual(tomb?.plain[CloudCodec.deletedKey], .int(1))
        XCTAssertNil(tomb?.encrypted[CloudCodec.bodyKey], "у надгробия нет содержимого")
        b.clock = a.clock.addingTimeInterval(60)
        await b.sync()
        XCTAssertNil(b.trips.text("1", partition: "2026-10"))
        XCTAssertEqual(b.trips.text("2", partition: "2026-10"), "keep")
        // Повтор — без изменений.
        let applies = b.trips.applyCalls
        await b.sync()
        XCTAssertEqual(b.trips.applyCalls, applies)
    }

    func testOfflineKeepsQueueAndSendsLater() async {
        let cloud = FakeCloud()
        let phone = FakeDevice(cloud: cloud)
        await phone.sync()
        await cloud.setOffline(true)
        phone.fines.put("a", "1")
        let outcome = await phone.sync()
        XCTAssertEqual(outcome, .offline)
        XCTAssertEqual(phone.fines.text("a"), "1", "на телефоне всё как было")
        XCTAssertEqual(phone.ledger.pendingKeys, [CloudKey(kind: .fine, id: "a")], "очередь пережила обрыв")
        await cloud.setOffline(false)
        let outcome1 = await phone.sync()
        XCTAssertEqual(outcome1, .synced)
        XCTAssertTrue(phone.ledger.pendingKeys.isEmpty)
        let names = await cloud.names(in: .data)
        XCTAssertTrue(names.contains("fine..a"))
    }

    func testNoAccountTouchesNothing() async {
        let cloud = FakeCloud()
        await cloud.setAccount(.noAccount)
        let phone = FakeDevice(cloud: cloud)
        phone.trips.put("1", "trip", partition: "2026-10")
        let outcome2 = await phone.sync()
        XCTAssertEqual(outcome2, .account(.noAccount))
        let calls = await cloud.calls
        XCTAssertEqual(calls, 1, "только вопрос об аккаунте")
        XCTAssertEqual(phone.trips.text("1", partition: "2026-10"), "trip")
        XCTAssertTrue(phone.ledger.entries.isEmpty)
        await cloud.setAccount(.notProvisioned)
        let outcome3 = await phone.sync()
        XCTAssertEqual(outcome3, .account(.notProvisioned))
    }

    func testNotReadySourceWaits() async {
        let cloud = FakeCloud()
        let phone = FakeDevice(cloud: cloud)
        phone.trips.ready = false
        let outcome4 = await phone.sync()
        XCTAssertEqual(outcome4, .notReady, "история не прочитана — проход ждёт")
        let calls = await cloud.calls
        XCTAssertEqual(calls, 0)
    }

    func testAnotherAccountStartsLedgerOver() async {
        let cloud = FakeCloud()
        let phone = FakeDevice(cloud: cloud)
        phone.fines.put("a", "1")
        await phone.sync()
        XCTAssertFalse(phone.ledger.entries.isEmpty)
        await cloud.setAccount(.available("user-2"))
        await phone.sync()
        XCTAssertEqual(phone.ledger.account, "user-2")
        XCTAssertEqual(phone.fines.text("a"), "1", "свои данные на телефоне остаются")
    }

    /// «Удалить всю историю»: iCloud стирается раньше, чем что-то
    /// получено, — стёртое не возвращается на телефон.
    func testWipeBeforePullNeverBringsHistoryBack() async {
        let cloud = FakeCloud()
        let phone = FakeDevice(cloud: cloud)
        phone.trips.put("1", "trip", partition: "2026-10")
        phone.summary.put("summary", "days")
        phone.fines.put("f", "fine")
        await phone.sync()
        // Удалили на телефоне без сети.
        await cloud.setOffline(true)
        phone.trips.items = [:]
        phone.summary.items = [:]
        phone.engine.requestWipe([.trips])
        let outcome5 = await phone.sync()
        XCTAssertEqual(outcome5, .offline)
        XCTAssertNotNil(phone.ledger.pendingWipe, "удаление ждёт сети")
        await cloud.setOffline(false)
        let outcome6 = await phone.sync()
        XCTAssertEqual(outcome6, .synced)
        XCTAssertTrue(phone.trips.items.isEmpty, "стёртое не вернулось из iCloud")
        XCTAssertTrue(phone.summary.items.isEmpty)
        let trips = await cloud.names(in: .trips)
        XCTAssertTrue(trips.isEmpty)
        let data = await cloud.names(in: .data)
        XCTAssertTrue(data.contains("fine..f"), "штрафы при удалении истории остаются")
        XCTAssertTrue(data.contains("marker..wipe"), "отметка для других устройств")
        XCTAssertNil(phone.ledger.pendingWipe)
    }

    /// Другой телефон видит отметку удаления: останавливается и не
    /// возвращает свои копии, свои данные не трогает.
    func testOtherDeviceStopsOnWipe() async {
        let cloud = FakeCloud()
        let a = FakeDevice(cloud: cloud), b = FakeDevice(cloud: cloud)
        a.trips.put("1", "trip", partition: "2026-10")
        await a.sync()
        await b.sync()
        a.trips.items = [:]
        a.engine.requestWipe([.trips])
        await a.sync()
        b.clock = a.clock.addingTimeInterval(60)
        let outcome7 = await b.sync()
        XCTAssertEqual(outcome7, .remoteWiped)
        XCTAssertEqual(b.trips.text("1", partition: "2026-10"), "trip", "своё на телефоне остаётся")
        let trips = await cloud.names(in: .trips)
        XCTAssertTrue(trips.isEmpty, "стёртое не вернулось в iCloud")
        // Своя же отметка — не повод останавливаться.
        let outcome8 = await a.sync()
        XCTAssertEqual(outcome8, .synced)
    }

    func testWholeCopyDeletionStartsLedgerOver() async {
        let cloud = FakeCloud()
        let phone = FakeDevice(cloud: cloud)
        phone.fines.put("f", "fine")
        await phone.sync()
        phone.engine.requestWipe([.trips, .data])
        let outcome9 = await phone.engine.runPendingWipe()
        XCTAssertEqual(outcome9, .synced)
        let zones = await cloud.zones
        XCTAssertTrue(zones.isEmpty)
        XCTAssertTrue(phone.ledger.entries.isEmpty)
        XCTAssertFalse(phone.ledger.syncedOnce)
        XCTAssertEqual(phone.ledger.account, "user-1")
    }

    /// В iCloud версия новее (записали между нашим получением и отправкой):
    /// своя старая её не перетирает, а следующим проходом приходит новая.
    func testServerNewerIsNotOverwritten() async {
        let cloud = FakeCloud()
        let phone = FakeDevice(cloud: cloud)
        phone.fines.put("x", "old")
        await phone.sync()
        phone.fines.put("x", "mine")
        let later = phone.clock.addingTimeInterval(3600)
        let theirs = CloudCodec.wire(for: CloudItem(key: CloudKey(kind: .fine, id: "x"), body: Data("theirs".utf8),
                                                    modifiedAt: later))!
        await cloud.inject(theirs)
        await phone.sync()
        XCTAssertEqual(phone.fines.text("x"), "theirs")
        let stored = await cloud.wire("fine..x")
        guard case .data(let packed)? = stored?.encrypted[CloudCodec.bodyKey] else { return XCTFail("нет записи") }
        XCTAssertEqual(CloudCodec.decompress(packed), Data("theirs".utf8))
    }

    func testSummaryIsMergedNotOverwritten() async {
        let cloud = FakeCloud()
        let a = FakeDevice(cloud: cloud)
        a.summary.put("summary", "a-days")
        await a.sync()
        let b = FakeDevice(cloud: cloud)
        b.summary.put("summary", "b-days")
        await b.sync()
        XCTAssertEqual(b.summary.applyCalls, 1, "сводка из iCloud ушла в слияние источника")
    }

    func testTripStartStopsBetweenPortions() async {
        let cloud = FakeCloud()
        let phone = FakeDevice(cloud: cloud)
        for month in ["2026-01", "2026-02", "2026-03", "2026-04"] { phone.trips.put(month, "t", partition: month) }
        phone.trips.hot = ["2026-04"]
        var portions = 0
        phone.engine.mayContinue = {
            portions += 1
            return portions < 2
        }
        let outcome = await phone.sync()
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertNil(phone.ledger.fullScanAt, "первая выгрузка не закончена")
        phone.engine.mayContinue = { true }
        let outcome10 = await phone.sync()
        XCTAssertEqual(outcome10, .synced)
        let names = await cloud.names(in: .trips)
        XCTAssertEqual(names.count, 4, "продолжилось с места")
    }

    func testScanWaitsInLowPower() async {
        let cloud = FakeCloud()
        let phone = FakeDevice(cloud: cloud)
        phone.trips.put("1", "t", partition: "2026-01")
        phone.trips.put("2", "t", partition: "2026-02")
        phone.trips.hot = ["2026-02"]
        phone.engine.mayScan = { false }
        await phone.sync()
        let names = await cloud.names(in: .trips)
        XCTAssertEqual(names, ["trip.2026-02.2"], "в энергосбережении — только то, что в памяти")
    }
}

// MARK: - Настройки через iCloud

final class CloudSettingsSyncTests: XCTestCase {
    func testPushOnlyChanged() {
        let local: [String: CloudSettingValue] = ["a": .bool(true), "b": .double(400), "c": .string("smart")]
        let pushed: [String: CloudSettingValue] = ["a": .bool(true), "b": .double(300)]
        XCTAssertEqual(CloudSettingsSync.toPush(local: local, pushed: pushed), ["b": .double(400), "c": .string("smart")])
    }

    func testFirstEnableRestoresFromCloud() {
        let local: [String: CloudSettingValue] = ["a": .bool(true), "b": .double(400), "only": .bool(false)]
        let remote: [String: CloudSettingValue] = ["a": .bool(false), "b": .double(400)]
        let plan = CloudSettingsSync.initial(local: local, remote: remote)
        XCTAssertEqual(plan.apply, ["a": .bool(false)], "прежний телефон прав")
        XCTAssertEqual(plan.push, ["only": .bool(false)], "своё — только там, где в iCloud пусто")
        let first = CloudSettingsSync.initial(local: local, remote: [:])
        XCTAssertEqual(first.push, local)
        XCTAssertTrue(first.apply.isEmpty)
    }

    func testValueKindsAreStrict() {
        XCTAssertEqual(CloudSettingsSync.value(from: NSNumber(value: true), kind: .bool), .bool(true))
        XCTAssertEqual(CloudSettingsSync.value(from: NSNumber(value: 400.0), kind: .double), .double(400))
        XCTAssertNil(CloudSettingsSync.value(from: "x", kind: .bool))
        XCTAssertNil(CloudSettingsSync.value(from: NSNumber(value: 1), kind: .string))
    }

    /// Телефонное (Bluetooth машины, госномер, места с координатами) в
    /// хранилище настроек не попадает никогда.
    func testDeviceOnlyKeysStayOnPhone() {
        let synced = Set(AppSettings.cloudSettingKinds.keys)
        XCTAssertTrue(synced.isDisjoint(with: AppSettings.deviceOnlySettingKeys),
                      "\(synced.intersection(AppSettings.deviceOnlySettingKeys))")
        for key in ["licensePlate", "carDevices", "homePlace", "workPlace", "recentPlaces", "favoritePlaces"] {
            XCTAssertFalse(synced.contains(key), key)
        }
    }
}

// MARK: - Права сборки

final class EntitlementProbeTests: XCTestCase {

    /// Контейнер в коде, в обоих файлах прав и в собранной сборке — один и тот
    /// же: другой id в CKContainer(identifier:) уронил бы приложение.
    func testContainerMatchesEntitlementFiles() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for name in ["RadarMap.entitlements", "RadarMapCarPlay.entitlements"] {
            let data = try Data(contentsOf: root.appendingPathComponent("RadarMap").appendingPathComponent(name))
            let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            XCTAssertEqual(plist[EntitlementProbe.containersKey] as? [String], [AppConfig.cloudContainerID], name)
            XCTAssertEqual(plist[EntitlementProbe.servicesKey] as? [String], ["CloudKit"], name)
            XCTAssertNotNil(plist["com.apple.developer.ubiquity-kvstore-identifier"], name)
        }
    }

    /// Симулятор: права в секции __TEXT,__entitlements исполняемого файла.
    func testRunningBuildDeclaresTheContainer() throws {
        let containers = try XCTUnwrap(EntitlementProbe.cloudKitContainers(), "права сборки не прочитаны")
        XCTAssertTrue(containers.contains(AppConfig.cloudContainerID))
    }

    /// Устройство: права в блобе подписи (SuperBlob, big-endian) — собранный
    /// в памяти Mach-O с одной командой LC_CODE_SIGNATURE.
    func testCodeSignatureBlobIsParsed() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>com.apple.developer.icloud-services</key><array><string>CloudKit</string></array><key>com.apple.developer.icloud-container-identifiers</key><array><string>iCloud.uz.radarmap.ios</string></array></dict></plist>
        """
        func le(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
        func be(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.bigEndian, Array.init) }
        let ents = Array(xml.utf8)
        // SuperBlob: magic, length, count=1, index (type, offset=20), blob.
        let blobLength = UInt32(8 + ents.count)
        var superBlob = be(0xfade_0cc0) + be(UInt32(20) + blobLength) + be(1) + be(5) + be(20)
        superBlob += be(0xfade_7171) + be(blobLength) + ents
        // Заголовок Mach-O 64 + одна команда LC_CODE_SIGNATURE (16 байт).
        let sigOffset: UInt32 = 32 + 16
        var file = le(0xfeed_facf) + le(0x0100_000c) + le(0) + le(2) + le(1) + le(16) + le(0) + le(0)
        file += le(0x1d) + le(16) + le(sigOffset) + le(UInt32(superBlob.count))
        file += superBlob
        let data = Data(file)
        let parsed = try XCTUnwrap(EntitlementProbe.parse { offset, length in
            guard offset >= 0, offset < data.count else { return nil }
            return data.subdata(in: offset..<min(data.count, offset + length))
        })
        XCTAssertEqual(parsed[EntitlementProbe.containersKey] as? [String], ["iCloud.uz.radarmap.ios"])
    }

    func testGarbageIsNotEntitlements() {
        let data = Data(repeating: 0x42, count: 256)
        XCTAssertNil(EntitlementProbe.parse { offset, length in
            offset < data.count ? data.subdata(in: offset..<min(data.count, offset + length)) : nil
        })
    }
}

// MARK: - Без iCloud

@MainActor
final class CloudSyncServiceTests: XCTestCase {

    /// Сборка без контейнера (транспорта нет): включение не падает, строка
    /// честная, на телефоне ничего не меняется.
    func testWithoutContainerStatusIsHonest() async throws {
        let savedMode = Storage.string(.cloudSyncMode)
        let savedOffer = Storage.bool(.cloudOfferAnswered)
        defer {
            if let savedMode { Storage.set(savedMode, for: .cloudSyncMode) } else { Storage.remove(.cloudSyncMode) }
            Storage.set(savedOffer, for: .cloudOfferAnswered)
        }
        let service = CloudSyncService()
        service.makeTransport = { nil }
        service.setMode(.iCloud)
        for _ in 0..<50 where service.status != .notProvisioned {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(service.status, .notProvisioned)
        XCTAssertTrue(service.isEnabled, "выбор человека запомнен — заработает, когда iCloud появится")
        service.setMode(.local)
        XCTAssertEqual(service.status, .off)
    }

    func testOfferOnlyOnceAndOnlyWithHistory() {
        let savedMode = Storage.string(.cloudSyncMode)
        let savedOffer = Storage.bool(.cloudOfferAnswered)
        defer {
            if let savedMode { Storage.set(savedMode, for: .cloudSyncMode) } else { Storage.remove(.cloudSyncMode) }
            Storage.set(savedOffer, for: .cloudOfferAnswered)
        }
        Storage.remove(.cloudSyncMode)
        Storage.remove(.cloudOfferAnswered)
        let service = CloudSyncService()
        XCTAssertFalse(service.shouldOffer(storedTrips: 1), "терять нечего — не спрашиваем")
        XCTAssertTrue(service.shouldOffer(storedTrips: 10))
        XCTAssertFalse(service.isEnabled, "молча не включается")
        service.answerOffer(accept: false)
        XCTAssertFalse(service.shouldOffer(storedTrips: 10), "ответили — больше не спрашиваем")
        XCTAssertEqual(service.mode, .local)
    }

    /// Строки состояния — на обоих языках (каталог).
    func testStatusLinesAreLocalized() throws {
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Shared/Localizable.xcstrings"))) as? [String: Any]
        let strings = try XCTUnwrap(catalog?["strings"] as? [String: Any])
        let keys = ["Поездки хранятся только на этом iPhone", "Проверяем iCloud…",
                    "В этой версии iCloud ещё не подключён — поездки хранятся на телефоне.",
                    "Сохранять поездки в iCloud?", "Хранить поездки", "Копия истории в iCloud"]
        for key in keys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let uz = ((entry["localizations"] as? [String: Any])?["uz"] as? [String: Any])?["stringUnit"] as? [String: Any]
            XCTAssertEqual(uz?["state"] as? String, "translated", key)
        }
    }
}
