//
//  CloudKitTransport.swift
//  RadarMap
//
//  CloudKit под протоколом CloudTransport (27.F): приватная база человека,
//  контейнер `AppConfig.cloudContainerID`, две свои зоны. Никакой логики —
//  только перевод CloudWire ↔ CKRecord и ошибок CloudKit в CloudFailure;
//  решения принимает CloudSyncEngine, и он же покрыт тестами на заглушке.
//
//  Создаётся только через `make()`: контейнер, которого нет в правах сборки,
//  CloudKit не возвращает ошибкой, а роняет процесс (EntitlementProbe).
//
//  «Последняя правка» и на сервере: перед записью читаются время правки и
//  флаг удаления того, что уже лежит в iCloud; там новее — запись не
//  перетирается (исход .serverNewer), а придёт следующим получением.
//  Запись — с `.ifServerRecordUnchanged`: если между чтением и записью
//  успело записать другое устройство, CloudKit откажет, и это тоже
//  .serverNewer, а не потеря.
//

import CloudKit
import os

nonisolated final class CloudKitTransport: CloudTransport, @unchecked Sendable {
    private let container: CKContainer
    private var database: CKDatabase { container.privateCloudDatabase }

    private init(container: CKContainer) {
        self.container = container
    }

    /// nil — у сборки нет прав на контейнер: CloudKit не трогаем вовсе.
    static func make(containerID: String = AppConfig.cloudContainerID) -> CloudKitTransport? {
        guard let containers = EntitlementProbe.cloudKitContainers() else {
            Log.cloud.error("права сборки не прочитаны — iCloud выключен")
            return nil
        }
        guard containers.contains(containerID) else {
            Log.cloud.notice("контейнера \(containerID, privacy: .public) нет в правах сборки — iCloud недоступен")
            return nil
        }
        return CloudKitTransport(container: CKContainer(identifier: containerID))
    }

    private static func zoneID(_ zone: CloudZone) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zone.rawValue, ownerName: CKCurrentUserDefaultName)
    }

    // MARK: - Аккаунт

    func account() async -> CloudAccount {
        let status: CKAccountStatus
        do {
            status = try await container.accountStatus()
        } catch {
            Log.cloud.error("состояние iCloud: \(error.localizedDescription, privacy: .public)")
            return Self.failure(error) == .notProvisioned ? .notProvisioned : .unknown
        }
        switch status {
        case .available:
            do {
                let id = try await container.userRecordID()
                return .available(CloudMerge.fingerprint(Data(id.recordName.utf8)))
            } catch {
                // Без id — работать можно, смену аккаунта поймает уведомление.
                Log.cloud.error("id пользователя iCloud: \(error.localizedDescription, privacy: .public)")
                return Self.failure(error) == .notProvisioned ? .notProvisioned : .available(nil)
            }
        case .noAccount: return .noAccount
        case .restricted: return .restricted
        case .temporarilyUnavailable: return .temporarilyUnavailable
        case .couldNotDetermine: return .unknown
        @unknown default: return .unknown
        }
    }

    // MARK: - Зоны

    func prepare(zones: [CloudZone]) async throws {
        do {
            let result = try await database.modifyRecordZones(saving: zones.map { CKRecordZone(zoneID: Self.zoneID($0)) },
                                                              deleting: [])
            for (_, outcome) in result.saveResults {
                if case .failure(let error) = outcome { throw Self.failure(error) }
            }
        } catch let failure as CloudFailure {
            throw failure
        } catch {
            throw Self.failure(error)
        }
    }

    func delete(zones: [CloudZone]) async throws {
        do {
            let result = try await database.modifyRecordZones(saving: [], deleting: zones.map(Self.zoneID))
            for (_, outcome) in result.deleteResults {
                if case .failure(let error) = outcome, Self.failure(error) != .zoneMissing { throw Self.failure(error) }
            }
        } catch let failure as CloudFailure {
            throw failure
        } catch {
            throw Self.failure(error)
        }
    }

    // MARK: - Получение

    func fetch(zone: CloudZone, token: Data?, limit: Int) async throws -> CloudPage {
        let since = token.flatMap(Self.unarchive)
        do {
            let changes = try await database.recordZoneChanges(inZoneWith: Self.zoneID(zone), since: since,
                                                               desiredKeys: nil, resultsLimit: limit)
            var page = CloudPage()
            for (id, result) in changes.modificationResultsByID {
                switch result {
                case .success(let modification):
                    page.records.append(Self.wire(from: modification.record, zone: zone))
                case .failure(let error):
                    Log.cloud.error("запись \(id.recordName, privacy: .private) не получена: \(error.localizedDescription, privacy: .public)")
                }
            }
            page.deletedNames = changes.deletions.map(\.recordID.recordName)
            page.token = Self.archive(changes.changeToken)
            page.more = changes.moreComing
            return page
        } catch {
            throw Self.failure(error)
        }
    }

    // MARK: - Запись

    func save(_ records: [CloudWire]) async throws -> [String: CloudSaveOutcome] {
        guard let first = records.first else { return [:] }
        let ids = records.map { CKRecord.ID(recordName: $0.recordName, zoneID: Self.zoneID($0.zone)) }
        var existing: [CKRecord.ID: CKRecord] = [:]
        do {
            let found = try await database.records(for: ids, desiredKeys: [CloudCodec.modifiedKey, CloudCodec.deletedKey])
            for (id, result) in found {
                switch result {
                case .success(let record): existing[id] = record
                case .failure(let error):
                    // Нет такой — значит новая; остальное — в журнал.
                    if (error as? CKError)?.code != .unknownItem {
                        Log.cloud.error("чтение перед записью: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        } catch {
            let failure = Self.failure(error)
            // Зона пропала у новой записи — её создаст движок; остальное наверх.
            if failure != .zoneMissing { throw failure }
            Log.cloud.notice("зона \(first.zone.rawValue, privacy: .public) пропала перед записью")
            throw failure
        }
        var outcomes: [String: CloudSaveOutcome] = [:]
        var saving: [CKRecord] = []
        for (wire, id) in zip(records, ids) {
            let record = existing[id] ?? CKRecord(recordType: wire.recordType, recordID: id)
            if let stored = record[CloudCodec.modifiedKey] as? Date,
               case .date(let ours)? = wire.plain[CloudCodec.modifiedKey], stored > ours {
                outcomes[wire.recordName] = .serverNewer
                continue
            }
            Self.fill(record, from: wire)
            saving.append(record)
        }
        guard !saving.isEmpty else { return outcomes }
        do {
            let result = try await database.modifyRecords(saving: saving, deleting: [],
                                                          savePolicy: .ifServerRecordUnchanged, atomically: false)
            for (id, outcome) in result.saveResults {
                switch outcome {
                case .success: outcomes[id.recordName] = .saved
                case .failure(let error):
                    let failure = Self.failure(error)
                    outcomes[id.recordName] = (error as? CKError)?.code == .serverRecordChanged ? .serverNewer : .failed(failure)
                }
            }
        } catch {
            throw Self.failure(error)
        }
        return outcomes
    }

    // MARK: - CKRecord ↔ провод

    private static func fill(_ record: CKRecord, from wire: CloudWire) {
        for (key, value) in wire.plain {
            switch value {
            case .date(let date): record[key] = date as NSDate
            case .int(let number): record[key] = NSNumber(value: number)
            case .data(let data): record[key] = data as NSData
            case .string(let text): record[key] = text as NSString
            }
        }
        for (key, value) in wire.encrypted {
            switch value {
            case .date(let date): record.encryptedValues[key] = date
            case .int(let number): record.encryptedValues[key] = number
            case .data(let data): record.encryptedValues[key] = data
            case .string(let text): record.encryptedValues[key] = text
            }
        }
        for key in wire.cleared {
            record.encryptedValues[key] = Optional<Data>.none
        }
    }

    private static func wire(from record: CKRecord, zone: CloudZone) -> CloudWire {
        var plain: [String: CloudValue] = [:]
        if let date = record[CloudCodec.modifiedKey] as? Date { plain[CloudCodec.modifiedKey] = .date(date) }
        if let flag = record[CloudCodec.deletedKey] as? NSNumber { plain[CloudCodec.deletedKey] = .int(flag.int64Value) }
        if let schema = record[CloudCodec.schemaKey] as? NSNumber { plain[CloudCodec.schemaKey] = .int(schema.int64Value) }
        var encrypted: [String: CloudValue] = [:]
        for key in [CloudCodec.bodyKey, CloudCodec.trackKey] {
            let data: Data? = record.encryptedValues[key]
            if let data { encrypted[key] = .data(data) }
        }
        return CloudWire(recordName: record.recordID.recordName, recordType: record.recordType,
                         zone: zone, plain: plain, encrypted: encrypted)
    }

    // MARK: - Метка изменений

    private static func archive(_ token: CKServerChangeToken) -> Data? {
        do {
            return try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        } catch {
            Log.cloud.error("метка изменений не сохранилась: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func unarchive(_ data: Data) -> CKServerChangeToken? {
        do {
            return try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
        } catch {
            Log.cloud.error("метка изменений не читается — зона перечитается: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Ошибки

    static func failure(_ error: Error) -> CloudFailure {
        guard let error = error as? CKError else { return .other(error.localizedDescription) }
        switch error.code {
        case .zoneNotFound, .userDeletedZone: return .zoneMissing
        case .changeTokenExpired: return .tokenExpired
        case .networkUnavailable, .networkFailure, .serviceUnavailable: return .offline
        case .requestRateLimited, .zoneBusy: return .rateLimited(error.retryAfterSeconds ?? 60)
        case .quotaExceeded: return .quota
        case .notAuthenticated: return .notSignedIn
        case .badContainer, .missingEntitlement, .permissionFailure: return .notProvisioned
        case .limitExceeded: return .tooLarge
        case .partialFailure:
            // Общая ошибка с частными внутри: решает первая частная.
            if let first = error.partialErrorsByItemID?.values.first { return failure(first) }
            return .other("partialFailure")
        default: return .other("CKError \(error.code.rawValue)")
        }
    }
}
