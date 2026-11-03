//
//  FamilyKeysTests.swift
//  RadarMapTests
//
//  Ключи семейных ссылок переезжают из файла настроек в связку ключей. Отказ
//  здесь — мёртвая ссылка у близкого, поэтому проверяем прежде всего, что
//  сбой связки ключ НЕ теряет.
//

import XCTest
@testable import RadarMap

/// Подменная связка: словарь плюс выключатели сбоев.
nonisolated final class FakeSecretStore: SecretStore, @unchecked Sendable {
    var items: [String: String] = [:]
    var failReads = false
    var failWrites = false
    var failDeletes = false
    private(set) var writes = 0

    struct Down: Error {}

    func read(account: String) throws -> String? {
        if failReads { throw Down() }
        return items[account]
    }

    func write(_ secret: String, account: String) throws {
        if failWrites { throw Down() }
        writes += 1
        items[account] = secret
    }

    func delete(account: String) throws {
        if failDeletes { throw Down() }
        items[account] = nil
    }
}

final class FamilyKeysTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// Круг, как его записала сборка до связки: ключи в файле.
    private func oldDiskCircle() -> FamilyCircle {
        var mother = FamilyRecipient(name: "Мама", now: now)
        mother.linkSentAt = now
        let wife = FamilyRecipient(name: "Жена", now: now)
        return FamilyCircle(recipients: [mother, wife], driverName: "Азиз")
    }

    private func roundTrip(_ circle: FamilyCircle) throws -> FamilyCircle {
        try JSONDecoder().decode(FamilyCircle.self, from: JSONEncoder().encode(circle))
    }

    func testMigrationMovesKeysOutOfTheFileWithoutLosingThem() throws {
        let store = FakeSecretStore()
        let disk = try roundTrip(oldDiskCircle())
        var loaded = FamilyKeys.restored(disk, from: store, now: now)
        XCTAssertTrue(loaded.needsResave, "ключи из файла ушли в связку — файл переписать")
        XCTAssertEqual(loaded.circle, disk, "в памяти ничего не поменялось: те же ключи и адреса")

        let rewritten = try roundTrip(FamilyKeys.persisted(loaded.circle, in: store, known: &loaded.known))
        for (stored, original) in zip(rewritten.recipients, disk.recipients) {
            XCTAssertNil(stored.key, "в файле ключа больше нет")
            XCTAssertEqual(stored.keyInKeychain, true)
            XCTAssertEqual(stored.token, original.token, "адрес у близкого не меняется")
            XCTAssertEqual(store.items[original.id.uuidString], original.key)
        }

        // Следующий запуск: ключи — из связки, ссылки те же.
        let next = FamilyKeys.restored(rewritten, from: store, now: now)
        XCTAssertFalse(next.needsResave)
        XCTAssertEqual(next.circle.recipients.map(\.key), disk.recipients.map(\.key))
        XCTAssertEqual(next.circle.recipients.map(\.write), disk.recipients.map(\.write))
    }

    func testKeychainRefusingTheKeyKeepsItInTheFile() throws {
        let store = FakeSecretStore()
        store.failWrites = true
        let disk = try roundTrip(oldDiskCircle())
        var loaded = FamilyKeys.restored(disk, from: store, now: now)
        XCTAssertFalse(loaded.needsResave, "связка не приняла — файл не трогаем")
        let rewritten = FamilyKeys.persisted(loaded.circle, in: store, known: &loaded.known)
        XCTAssertEqual(rewritten.recipients.map(\.key), disk.recipients.map(\.key),
                       "сбой связки — ключ остаётся в файле, как до этой версии")
        XCTAssertEqual(rewritten.recipients.map(\.keyInKeychain), [nil, nil])
    }

    func testFileKeyWinsOverAnOlderKeychainKey() throws {
        // Прошлая запись в связку не удалась после «Сменить ссылку»: в связке
        // старый ключ, в файле — новый. Писать надо новым.
        let store = FakeSecretStore()
        var circle = try roundTrip(oldDiskCircle())
        let id = circle.recipients[0].id
        store.items[id.uuidString] = "старый"
        circle.recipients[0].keyInKeychain = nil
        let loaded = FamilyKeys.restored(circle, from: store, now: now)
        XCTAssertEqual(loaded.circle.recipients[0].key, circle.recipients[0].key)
        XCTAssertEqual(store.items[id.uuidString], circle.recipients[0].key)
    }

    func testLockedKeychainLosesNothingAndBlocksWriting() throws {
        let store = FakeSecretStore()
        var known: [UUID: String] = [:]
        let original = oldDiskCircle()
        let disk = try roundTrip(FamilyKeys.persisted(original, in: store, known: &known))

        store.failReads = true
        var loaded = FamilyKeys.restored(disk, from: store, now: now)
        XCTAssertTrue(loaded.circle.recipients.allSatisfy(\.isKeyLocked),
                      "связка не отдала ключ — писать нечем, адресом вместо ключа не пишем")
        // Пока связка недоступна, круг правят и сохраняют — ключи не стираются.
        var edited = loaded.circle
        edited.recipients[0].name = "Мамочка"
        let saved = try roundTrip(FamilyKeys.persisted(edited, in: store, known: &loaded.known))
        XCTAssertEqual(saved.recipients.map(\.keyInKeychain), [true, true])
        XCTAssertEqual(store.items.count, 2, "в связке оба ключа на месте")

        store.failReads = false
        let back = FamilyKeys.restored(saved, from: store, now: now)
        XCTAssertEqual(back.circle.recipients.map(\.key), original.recipients.map(\.key))
        XCTAssertFalse(back.circle.recipients.contains(where: \.isKeyLocked))
    }

    func testMissingKeychainEntryIsALostLinkNotEndlessRetries() throws {
        // Новый телефон из незашифрованной копии: файл приехал, связка — нет.
        // `nil` — это навсегда (в отличие от ошибки «связка заперта»).
        let original = FakeSecretStore()
        var known: [UUID: String] = [:]
        let old = oldDiskCircle()
        let disk = try roundTrip(FamilyKeys.persisted(old, in: original, known: &known))

        let fresh = FakeSecretStore()
        var loaded = FamilyKeys.restored(disk, from: fresh, now: now)
        XCTAssertTrue(loaded.needsResave, "новый ключ — в связку и в файл")
        for (lost, before) in zip(loaded.circle.recipients, old.recipients) {
            XCTAssertEqual(lost.linkLost, true, "«Близкие» просят отправить ссылку заново")
            XCTAssertNil(lost.linkSentAt)
            XCTAssertFalse(lost.isReachable, "поездки ему не шлются — и повторов нет")
            XCTAssertFalse(lost.isKeyLocked)
            XCTAssertNotEqual(lost.key, before.key)
            XCTAssertEqual(lost.token, EtaShare.address(forKey: lost.key ?? ""))
            XCTAssertEqual(lost.name, before.name)
        }
        let saved = try roundTrip(FamilyKeys.persisted(loaded.circle, in: fresh, known: &loaded.known))
        XCTAssertEqual(saved.recipients.map(\.linkLost), [true, true], "пометка переживает перезапуск")
        XCTAssertEqual(fresh.items.count, 2)
        // Отправили заново — пометка снимается сменой ссылки или отправкой.
        XCTAssertNil(loaded.circle.recipients[0].withNewLink(now: now).linkLost)
    }

    func testLegacyLinkWithoutKeyIsLeftAlone() throws {
        // Ссылка до 14.12: ключа нет вовсе, пишет адрес — так и было.
        var legacy = FamilyRecipient(name: "Папа", now: now)
        legacy.key = nil
        legacy.token = "legacy-token"
        let store = FakeSecretStore()
        var known: [UUID: String] = [:]
        let disk = FamilyKeys.persisted(FamilyCircle(recipients: [legacy]), in: store, known: &known)
        XCTAssertNil(disk.recipients[0].keyInKeychain)
        XCTAssertFalse(disk.recipients[0].isKeyLocked)
        XCTAssertEqual(disk.recipients[0].write, .legacy("legacy-token"))
        XCTAssertTrue(store.items.isEmpty)
    }

    func testRemovedRecipientKeyLeavesTheKeychainAndUnchangedKeysAreNotRewritten() {
        let store = FakeSecretStore()
        var known: [UUID: String] = [:]
        var circle = oldDiskCircle()
        _ = FamilyKeys.persisted(circle, in: store, known: &known)
        XCTAssertEqual(store.writes, 2)
        _ = FamilyKeys.persisted(circle, in: store, known: &known)
        XCTAssertEqual(store.writes, 2, "неизменный ключ в связку повторно не пишется")

        let removed = circle.recipients.removeFirst()
        _ = FamilyKeys.persisted(circle, in: store, known: &known)
        XCTAssertNil(store.items[removed.id.uuidString])
        XCTAssertEqual(store.items.count, 1)

        circle.recipients[0] = circle.recipients[0].withNewLink(now: now)
        _ = FamilyKeys.persisted(circle, in: store, known: &known)
        XCTAssertEqual(store.items[circle.recipients[0].id.uuidString], circle.recipients[0].key,
                       "«Сменить ссылку» — новый ключ в связке")
    }

    func testOldBuildRecordStillDecodes() throws {
        // Запись до поля keyInKeychain (ARCHITECTURE, правило 18).
        let json = """
        {"recipients":[{"id":"6F0A0CFF-302A-452F-0084-4CD900000001","name":"Мама","token":"t","key":"k",\
        "createdAt":0}],"driverName":""}
        """
        let circle = try JSONDecoder().decode(FamilyCircle.self, from: Data(json.utf8))
        XCTAssertEqual(circle.recipients.first?.key, "k")
        XCTAssertNil(circle.recipients.first?.keyInKeychain)
    }
}
