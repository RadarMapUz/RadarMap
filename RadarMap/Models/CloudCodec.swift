//
//  CloudCodec.swift
//  RadarMap
//
//  Как запись выглядит в iCloud (27.F) — чисто, без CloudKit: CloudWire —
//  словари открытых и зашифрованных полей, которые транспорт один к одному
//  кладёт в CKRecord и CKRecord.encryptedValues.
//
//  ГЛАВНОЕ ПРАВИЛО: всё содержимое — в зашифрованных полях. Открыто лежат
//  только время правки, флаг удаления и версия формата: по ним сервер не
//  узнает ни где человек ездил, ни сколько, ни когда. Координаты, треки,
//  адреса, суммы штрафов, имена близких — в `encryptedValues` (ключ у Apple
//  ID человека; с расширенной защитой данных его не видит и Apple). Тест
//  перебирает открытые поля и падает на любом лишнем.
//
//  Содержимое — канонический JSON (ключи по алфавиту: одинаковые данные дают
//  одинаковые байты и один отпечаток на любом телефоне), сжатый LZFSE. Трек
//  поездки — отдельным полем: его вырезает срок хранения на телефоне, а в
//  iCloud он живёт дальше.
//
//  Близкие уходят БЕЗ ключа записи и адреса ссылки (FamilyContact): ключ
//  даёт право писать маме «в пути», вынести его — значит раздать это право.
//  На новом телефоне близкий восстанавливается с новой ссылкой, которую надо
//  отправить заново.
//

import Foundation
import os

/// Значение поля записи.
nonisolated enum CloudValue: Equatable, Sendable {
    case date(Date)
    case int(Int64)
    case data(Data)
    case string(String)
}

/// Запись в том виде, в каком её видит транспорт.
nonisolated struct CloudWire: Equatable, Sendable {
    let recordName: String
    let recordType: String
    let zone: CloudZone
    /// Открытые поля — только служебные (`CloudCodec.plainKeys`).
    var plain: [String: CloudValue]
    /// Зашифрованные поля (CKRecord.encryptedValues).
    var encrypted: [String: CloudValue]
    /// Зашифрованные поля, которые надо стереть (надгробие).
    var cleared: [String] = []
}

nonisolated enum CloudCodec {
    static let modifiedKey = "modifiedAt"
    static let deletedKey = "deleted"
    static let schemaKey = "schema"
    static let bodyKey = "body"
    static let trackKey = "track"
    /// Всё, что лежит в iCloud открыто. Расширять — только служебным.
    static let plainKeys: Set<String> = [modifiedKey, deletedKey, schemaKey]
    /// Версия формата содержимого.
    static let schema: Int64 = 1

    /// Своя запись → провод. nil — не сжалось или не влезает в запись.
    static func wire(for item: CloudItem) -> CloudWire? {
        var wire = CloudWire(recordName: item.key.recordName,
                             recordType: item.key.kind.recordType,
                             zone: item.key.kind.zone,
                             plain: [modifiedKey: .date(item.modifiedAt),
                                     deletedKey: .int(item.deleted ? 1 : 0),
                                     schemaKey: .int(schema)],
                             encrypted: [:])
        if item.deleted {
            wire.cleared = [bodyKey, trackKey]
            return wire
        }
        guard let body = item.body, let packed = compress(body) else { return nil }
        var size = packed.count
        wire.encrypted[bodyKey] = .data(packed)
        if let track = item.track, let packedTrack = compress(track) {
            size += packedTrack.count
            wire.encrypted[trackKey] = .data(packedTrack)
        }
        guard size <= AppConfig.cloudRecordMaxBytes else {
            Log.cloud.error("запись \(item.key.kind.rawValue, privacy: .public) не влезает в iCloud: \(size, privacy: .public) байт")
            return nil
        }
        return wire
    }

    /// Пришедшая запись → провод разобран. nil — чужое или битое (в журнал).
    static func item(from wire: CloudWire) -> CloudItem? {
        guard let key = CloudKey(recordName: wire.recordName) else {
            Log.cloud.error("чужое имя записи в iCloud: \(wire.recordName, privacy: .private)")
            return nil
        }
        guard case .date(let modified)? = wire.plain[modifiedKey] else {
            Log.cloud.error("запись без времени правки: \(key.kind.rawValue, privacy: .public)")
            return nil
        }
        if case .int(let version)? = wire.plain[schemaKey], version > schema {
            // Запись новой сборки: не разбираем наполовину, ждём обновления.
            Log.cloud.notice("запись формата \(version, privacy: .public) новее этой сборки — пропущена")
            return nil
        }
        let deleted: Bool
        if case .int(let flag)? = wire.plain[deletedKey] { deleted = flag != 0 } else { deleted = false }
        if deleted { return .tombstone(key, at: modified) }
        guard case .data(let packed)? = wire.encrypted[bodyKey], let body = decompress(packed) else {
            Log.cloud.error("запись \(key.kind.rawValue, privacy: .public) без содержимого")
            return nil
        }
        var track: Data?
        if case .data(let packedTrack)? = wire.encrypted[trackKey] { track = decompress(packedTrack) }
        return CloudItem(key: key, body: body, track: track, modifiedAt: modified, deleted: false)
    }

    // MARK: - Сжатие

    static func compress(_ data: Data) -> Data? {
        do {
            return try (data as NSData).compressed(using: .lzfse) as Data
        } catch {
            Log.cloud.error("сжатие записи: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func decompress(_ data: Data) -> Data? {
        do {
            return try (data as NSData).decompressed(using: .lzfse) as Data
        } catch {
            Log.cloud.error("распаковка записи: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// Содержимое записей: что именно из своих данных уходит в iCloud.
nonisolated enum CloudPayload {

    /// Канонический JSON: ключи по алфавиту, даты числом.
    static func canonical<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(value)
        } catch {
            Log.cloud.error("кодирование \(String(describing: T.self), privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            Log.cloud.error("разбор \(String(describing: T.self), privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: Поездки

    static func tripKey(_ record: TripRecord) -> CloudKey {
        CloudKey(kind: .trip, partition: TripStore.Month(record.startedAt).key, id: String(record.id))
    }

    static func tripID(_ key: CloudKey) -> Double? {
        key.kind == .trip ? Double(key.id) : nil
    }

    /// Поездка: содержимое без трека и трек отдельно.
    static func tripItem(_ record: TripRecord) -> CloudItem? {
        var slim = record
        slim.track = nil
        guard let body = canonical(slim) else { return nil }
        return CloudItem(key: tripKey(record), body: body,
                         track: record.track.flatMap { canonical($0) },
                         natural: record.endedAt)
    }

    static func tripRecord(from item: CloudItem) -> TripRecord? {
        guard var record = decode(TripRecord.self, from: item.body) else { return nil }
        // Ключ — правда о месте записи: чужой id в содержимом не принимаем.
        guard String(record.id) == item.key.id else {
            Log.cloud.error("поездка в iCloud: id в имени и в содержимом разошлись")
            return nil
        }
        record.track = decode([Double].self, from: item.track)
        return record
    }

    // MARK: Сводка

    struct Summary: Codable, Equatable, Sendable {
        var days: [TripDay]
        var lifetime: LifetimeStats
    }

    static let summaryKey = CloudKey(kind: .summary, id: "summary")

    // MARK: Близкие

    /// Близкий в iCloud: кто и как видит поездку. Ключа записи W, адреса
    /// ссылки R и отметки «ссылку отправили» здесь нет и не будет.
    struct FamilyContact: Codable, Equatable, Sendable {
        var id: UUID
        var name: String
        var emoji: String
        var mode: FamilyRecipient.Mode
        var enabled: Bool
        var createdAt: Date

        init(_ recipient: FamilyRecipient) {
            id = recipient.id
            name = recipient.name
            emoji = recipient.emoji
            mode = recipient.mode
            enabled = recipient.enabled
            createdAt = recipient.createdAt
        }
    }

    /// «Как вас назовут близким».
    struct FamilyDriver: Codable, Equatable, Sendable {
        var driverName: String
    }

    static let familyDriverID = "driver"

    static func familyItems(_ circle: FamilyCircle) -> [CloudItem] {
        var items = circle.recipients.compactMap { recipient -> CloudItem? in
            canonical(FamilyContact(recipient)).map {
                CloudItem(key: CloudKey(kind: .family, id: recipient.id.uuidString), body: $0)
            }
        }
        let name = circle.driverName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, let body = canonical(FamilyDriver(driverName: circle.driverName)) {
            items.append(CloudItem(key: CloudKey(kind: .family, id: familyDriverID), body: body))
        }
        return items
    }

    // MARK: Места

    /// Место без привязки к главному актору (SavedPlace живёт в настройках).
    struct Place: Codable, Equatable, Sendable {
        var title: String
        var lat: Double
        var lon: Double
    }

    /// id записей мест: Дом и Работа — по одному месту, недавние и
    /// избранные — списком (порядок значим).
    enum PlaceSlot: String, CaseIterable, Sendable {
        case home, work, recent, favorite
    }

    // MARK: Машина

    struct Vehicle: Codable, Equatable, Sendable {
        /// VehicleEnergy.rawValue — строкой: новый тип машины в будущей
        /// сборке не роняет разбор старой.
        var energy: String
        var profile: FuelProfile
    }

    static let vehicleID = "profile"
}
