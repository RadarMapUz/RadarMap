//
//  CloudSyncEngine.swift
//  RadarMap
//
//  Один проход синхронизации с iCloud (27.F): своё → журнал, чужое → у себя,
//  ждущее → в iCloud. Решения — в CloudMerge (чисто), провод — CloudCodec,
//  сеть — CloudTransport (CloudKit или заглушка в тестах), данные —
//  CloudSource (поездки, журнал, штрафы, места, машина, близкие). Когда
//  запускать — не здесь, а в CloudSyncService (не в поездке, не на горячем
//  пути).
//
//  Порядок прохода.
//  1. «Удалить всю историю», ждущее сети, — первым: иначе следующий шаг
//     вернул бы стёртое из iCloud обратно на телефон.
//  2. Первый проход: сначала чужое (восстановление на новом телефоне —
//     iCloud прав), потом своё. Дальше — своё сначала: своя правка получает
//     время до встречи с чужой и честно в ней участвует.
//  3. Ждущее — порциями; удачное снимается из очереди, только если с тех пор
//     своей правки не было.
//  4. Первая выгрузка и недельная сверка — месяцами истории с диска, по
//     одному, с паузой; началась поездка — проход останавливается между
//     порциями.
//
//  Журнал (очередь) пишется после каждой порции: прерванный проход
//  продолжается с места, а повтор уже сделанного ничего не меняет.
//

import Foundation
import os

/// Аккаунт iCloud на телефоне.
nonisolated enum CloudAccount: Equatable, Sendable {
    /// Можно работать; строка — отпечаток пользователя (сменился — журнал чужой).
    case available(String?)
    case noAccount
    case restricted
    case temporarilyUnavailable
    /// Контейнер не выдан этой сборке (профиль без iCloud) — честно сказать.
    case notProvisioned
    case unknown
}

/// Почему не вышло.
nonisolated enum CloudFailure: Error, Equatable, Sendable {
    case zoneMissing
    case tokenExpired
    case offline
    case quota
    case notSignedIn
    case notProvisioned
    case tooLarge
    case rateLimited(TimeInterval)
    case other(String)
}

/// Страница изменений зоны.
nonisolated struct CloudPage: Sendable {
    var records: [CloudWire] = []
    /// Записи, удалённые в iCloud насовсем (не надгробием).
    var deletedNames: [String] = []
    var token: Data?
    var more = false
}

nonisolated enum CloudSaveOutcome: Equatable, Sendable {
    case saved
    /// В iCloud версия новее — придёт следующим получением.
    case serverNewer
    case failed(CloudFailure)
}

/// Транспорт до приватной базы.
nonisolated protocol CloudTransport: Sendable {
    func account() async -> CloudAccount
    func prepare(zones: [CloudZone]) async throws
    func fetch(zone: CloudZone, token: Data?, limit: Int) async throws -> CloudPage
    /// По имени записи — исход.
    func save(_ records: [CloudWire]) async throws -> [String: CloudSaveOutcome]
    func delete(zones: [CloudZone]) async throws
}

/// Один вид своих данных.
protocol CloudSource: AnyObject {
    var kind: CloudKind { get }
    /// Прочитан с диска — можно сверять и применять.
    var isReady: Bool { get }
    /// Разделы, которые дёшево сверять каждый проход (поездки — месяцы в
    /// памяти; остальные — один раздел "").
    func hotPartitions() -> Set<String>
    /// Все разделы (поездки — все месяцы на диске); nil — не перечисляются.
    func allPartitions() async -> Set<String>?
    /// Записи разделов; nil — не читаются сейчас.
    func items(in partitions: Set<String>) async -> [CloudItem]?
    /// Применить пришедшее. false — не применено (проход повторится).
    func apply(upserts: [CloudItem], deletions: [CloudKey]) async -> Bool
}

@MainActor
final class CloudSyncEngine {
    nonisolated deinit {}

    enum Outcome: Equatable {
        case synced
        case notReady
        case offline
        case account(CloudAccount)
        case remoteWiped
        case quota
        case cancelled
        case failed(String)
    }

    private(set) var ledger: CloudLedger
    private let transport: CloudTransport
    private let sources: [CloudSource]
    /// Куда записать журнал (файл; в тестах — память).
    private let persist: (CloudLedger) -> Void
    var now: () -> Date = { Date() }
    /// Продолжать ли между порциями: началась поездка — нет.
    var mayContinue: () -> Bool = { true }
    /// Разбор месяцев с диска разрешён (не экономия энергии, не перегрев).
    var mayScan: () -> Bool = { true }
    /// Сколько отправлено за проход — для строки состояния.
    var onProgress: ((Int) -> Void)?

    init(transport: CloudTransport, sources: [CloudSource], ledger: CloudLedger,
         persist: @escaping (CloudLedger) -> Void) {
        self.transport = transport
        self.sources = sources
        self.ledger = ledger
        self.persist = persist
    }

    private func source(_ kind: CloudKind) -> CloudSource? { sources.first { $0.kind == kind } }

    /// Порядок применения: поездки раньше сводки (сводка достраивает дни по
    /// записям).
    private static let applyOrder: [CloudKind] = [.trip, .summary, .journal, .fine, .family, .place, .vehicle]

    // MARK: - Проход

    func run(scan: Bool) async -> Outcome {
        guard sources.allSatisfy(\.isReady) else { return .notReady }
        switch await checkAccount() {
        case .some(let outcome): return outcome
        case .none: break
        }
        do {
            if ledger.pendingWipe != nil { try await performPendingWipe() }
            try await prepareZones()
            let first = !ledger.syncedOnce
            if first { try await pull() }
            try await detectHot()
            if !first { try await pull() }
            try await push()
            if mayScan() { try await scanDisk(force: scan) }
            ledger.syncedOnce = true
            ledger.lastSyncAt = now()
            commit()
            return .synced
        } catch let failure as CloudFailure {
            commit()
            return Self.outcome(for: failure)
        } catch is CancellationError {
            commit()
            return .cancelled
        } catch {
            commit()
            Log.cloud.error("проход синхронизации: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }

    /// Только стереть ждущее (хранение уже выключено, а «Удалить всю
    /// историю» обещало стереть и копию в iCloud).
    func runPendingWipe() async -> Outcome {
        guard ledger.pendingWipe != nil else { return .synced }
        if let outcome = await checkAccount() { return outcome }
        do {
            try await performPendingWipe()
            commit()
            return .synced
        } catch let failure as CloudFailure {
            return Self.outcome(for: failure)
        } catch {
            Log.cloud.error("удаление копии в iCloud: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }

    /// Поставить удаление в очередь и (если можно) выполнить. `zones` —
    /// «Поездки» для «Удалить всю историю», обе — «удалить копию из iCloud».
    func requestWipe(_ zones: Set<CloudZone>) {
        ledger.pendingWipe = now()
        ledger.pendingWipeZones = Set(zones.map(\.rawValue)).union(ledger.pendingWipeZones)
        commit()
    }

    /// Начать с чистого журнала (копию стёрли на другом устройстве и человек
    /// включил хранение заново, сменился аккаунт).
    func resetLedger() {
        let account = ledger.account
        ledger = CloudLedger()
        ledger.account = account
        commit()
    }

    private func commit() { persist(ledger) }

    private static func outcome(for failure: CloudFailure) -> Outcome {
        switch failure {
        case .offline, .rateLimited: return .offline
        case .quota: return .quota
        case .notSignedIn: return .account(.noAccount)
        case .notProvisioned: return .account(.notProvisioned)
        case .zoneMissing: return .remoteWiped
        case .tokenExpired, .tooLarge, .other: return .failed(String(describing: failure))
        }
    }

    /// nil — аккаунт годен.
    private func checkAccount() async -> Outcome? {
        let account = await transport.account()
        guard case .available(let id) = account else { return .account(account) }
        if let id, let known = ledger.account, known != id {
            // Другой Apple ID: журнал про чужую базу. Свои данные на телефоне
            // остаются и уедут уже в новый iCloud.
            Log.cloud.notice("сменился аккаунт iCloud — журнал синхронизации начат заново")
            ledger = CloudLedger()
        }
        if let id { ledger.account = id }
        return nil
    }

    private func prepareZones() async throws {
        let missing = CloudZone.allCases.filter { !ledger.readyZones.contains($0.rawValue) }
        guard !missing.isEmpty else { return }
        try await transport.prepare(zones: missing)
        for zone in missing { ledger.readyZones.insert(zone.rawValue) }
        commit()
    }

    // MARK: - Удаление

    private func performPendingWipe() async throws {
        guard let wipedAt = ledger.pendingWipe else { return }
        let zones = CloudZone.allCases.filter { ledger.pendingWipeZones.contains($0.rawValue) }
        do {
            try await transport.delete(zones: zones)
        } catch CloudFailure.zoneMissing {
            // Уже нет — то, чего и хотели.
        }
        let account = ledger.account
        if zones.contains(.data) {
            // Копия стёрта целиком: журнал начинается заново.
            ledger = CloudLedger()
            ledger.account = account
        } else {
            for zone in zones { ledger.forget(zone: zone) }
            ledger.pendingWipe = nil
            ledger.pendingWipeZones = []
            // Отметка — другим устройствам: «историю удалили, не возвращайте».
            ledger.wipeSeen = wipedAt
            if let body = CloudPayload.canonical(["wipedAt": wipedAt.timeIntervalSince1970]),
               let wire = CloudCodec.wire(for: CloudItem(key: CloudKey(kind: .marker, id: "wipe"),
                                                         body: body, modifiedAt: wipedAt)) {
                try await prepareZones()
                let outcome = try await transport.save([wire])
                if outcome[wire.recordName] != .saved {
                    Log.cloud.notice("отметка удаления истории не записана — другие устройства узнают по пропаже зоны")
                }
            }
        }
        commit()
        Log.cloud.notice("копия в iCloud стёрта: \(zones.map(\.rawValue).joined(separator: ", "), privacy: .public)")
    }

    // MARK: - Своё

    private func detectHot() async throws {
        for source in sources {
            let partitions = source.hotPartitions()
            guard let items = await source.items(in: partitions) else { throw CloudFailure.other("источник \(source.kind.rawValue) не читается") }
            ledger = await Self.detect(items, kind: source.kind, partitions: partitions,
                                       ledger: ledger, now: now())
        }
        commit()
    }

    @concurrent private nonisolated static func detect(_ items: [CloudItem], kind: CloudKind,
                                                       partitions: Set<String>, ledger: CloudLedger,
                                                       now: Date) async -> CloudLedger {
        var next = ledger
        CloudMerge.detectLocal(items, kind: kind, partitions: partitions, ledger: &next, now: now)
        return next
    }

    // MARK: - Чужое

    private func pull() async throws {
        for zone in [CloudZone.data, .trips] {
            try await pull(zone: zone)
        }
    }

    private func pull(zone: CloudZone) async throws {
        var token = ledger.tokens[zone.rawValue]
        var expiredOnce = false
        while true {
            let page: CloudPage
            do {
                page = try await transport.fetch(zone: zone, token: token, limit: AppConfig.cloudFetchLimit)
            } catch CloudFailure.tokenExpired where !expiredOnce {
                // Метка устарела — перечитать зону целиком: решения
                // идемпотентны, повтор ничего не испортит.
                expiredOnce = true
                token = nil
                ledger.tokens[zone.rawValue] = nil
                continue
            } catch CloudFailure.zoneMissing {
                // Зона была и пропала: копию стёрли (на другом устройстве или в
                // настройках iCloud). Не пересоздавать молча — человек решит.
                if ledger.syncedOnce { throw CloudFailure.zoneMissing }
                ledger.readyZones.remove(zone.rawValue)
                try await prepareZones()
                continue
            }
            let decoded = await Self.decode(page.records)
            var next = ledger
            var upserts: [CloudKind: [CloudItem]] = [:]
            var deletions: [CloudKind: [CloudKey]] = [:]
            var incoming = decoded
            incoming += page.deletedNames.compactMap { name in
                CloudKey(recordName: name).map { CloudItem.tombstone($0, at: now()) }
            }
            for item in incoming {
                if item.key.kind == .marker {
                    if !item.deleted, CloudMerge.isForeignWipe(item.modifiedAt, ledger: next) {
                        throw CloudFailure.zoneMissing
                    }
                    next.wipeSeen = max(next.wipeSeen ?? .distantPast, item.modifiedAt)
                    CloudMerge.absorb(item, into: &next)
                    continue
                }
                guard CloudMerge.receive(item, ledger: &next) == .applyRemote else { continue }
                if item.deleted {
                    deletions[item.key.kind, default: []].append(item.key)
                } else {
                    upserts[item.key.kind, default: []].append(item)
                }
            }
            for kind in Self.applyOrder {
                let up = upserts[kind] ?? [], down = deletions[kind] ?? []
                guard !up.isEmpty || !down.isEmpty else { continue }
                guard let source = source(kind), await source.apply(upserts: up, deletions: down) else {
                    Log.cloud.notice("пришедшее (\(kind.rawValue, privacy: .public)) не применено — повторим")
                    throw CloudFailure.other("не применено")
                }
            }
            next.tokens[zone.rawValue] = page.token
            ledger = next
            commit()
            token = page.token
            guard page.more else { return }
            guard mayContinue() else { throw CancellationError() }
        }
    }

    @concurrent private nonisolated static func decode(_ records: [CloudWire]) async -> [CloudItem] {
        records.compactMap(CloudCodec.item(from:))
    }

    // MARK: - Отправка

    private func push(only partition: String? = nil) async throws {
        let pending = ledger.pendingKeys.filter { partition == nil || $0.partition == partition }
        guard !pending.isEmpty else { return }
        // Живые записи берутся у источника заново: в очереди только ключи.
        let groups = Dictionary(grouping: pending) { $0.kind }
        var sent = 0
        for kind in Self.applyOrder {
            guard let keys = groups[kind], let source = source(kind) else { continue }
            let byPartition = Dictionary(grouping: keys) { $0.partition }
            for part in byPartition.keys.sorted(by: >) {
                let partKeys = byPartition[part] ?? []
                var items: [CloudItem] = []
                let live = partKeys.filter { ledger.entries[$0.recordName]?.deleted == false }
                if !live.isEmpty {
                    guard let found = await source.items(in: [part]) else { continue }
                    let wanted = Set(live)
                    items = found.filter { wanted.contains($0.key) }
                }
                for key in partKeys where ledger.entries[key.recordName]?.deleted == true {
                    items.append(.tombstone(key, at: ledger.entries[key.recordName]?.modifiedAt ?? now()))
                }
                for index in items.indices {
                    if let entry = ledger.entries[items[index].key.recordName] {
                        items[index].modifiedAt = entry.modifiedAt
                    }
                }
                sent += try await send(items)
                onProgress?(sent)
                guard mayContinue() else { throw CancellationError() }
            }
        }
    }

    /// Отправить порциями; вернуть число отправленных.
    private func send(_ items: [CloudItem]) async throws -> Int {
        let wires = await Self.encode(items)
        var batches: [[(CloudItem, CloudWire)]] = [[]]
        var bytes = 0
        for pair in wires {
            let size = Self.size(of: pair.1)
            if batches[batches.count - 1].count >= AppConfig.cloudSaveBatch
                || bytes + size > AppConfig.cloudSaveBatchBytes, !batches[batches.count - 1].isEmpty {
                batches.append([])
                bytes = 0
            }
            batches[batches.count - 1].append(pair)
            bytes += size
        }
        var sent = 0
        for batch in batches where !batch.isEmpty {
            sent += try await save(batch)
            guard mayContinue() else { throw CancellationError() }
        }
        return sent
    }

    private func save(_ batch: [(CloudItem, CloudWire)]) async throws -> Int {
        let outcomes: [String: CloudSaveOutcome]
        do {
            outcomes = try await transport.save(batch.map(\.1))
        } catch CloudFailure.tooLarge where batch.count > 1 {
            let half = batch.count / 2
            return try await save(Array(batch[..<half])) + save(Array(batch[half...]))
        }
        var sent = 0
        for (item, wire) in batch {
            switch outcomes[wire.recordName] {
            case .saved?:
                CloudMerge.markSent(item.key, modifiedAt: item.modifiedAt, ledger: &ledger)
                sent += 1
            case .serverNewer?:
                // Новее — придёт получением и победит по своему времени.
                continue
            case .failed(let failure)?:
                switch failure {
                case .quota, .notSignedIn, .notProvisioned, .offline: throw failure
                default:
                    Log.cloud.error("запись \(item.key.kind.rawValue, privacy: .public) не отправлена: \(String(describing: failure), privacy: .public)")
                }
            case nil:
                Log.cloud.error("запись \(item.key.kind.rawValue, privacy: .public): ответа нет")
            }
        }
        commit()
        return sent
    }

    @concurrent private nonisolated static func encode(_ items: [CloudItem]) async -> [(CloudItem, CloudWire)] {
        items.compactMap { item in CloudCodec.wire(for: item).map { (item, $0) } }
    }

    private static func size(of wire: CloudWire) -> Int {
        wire.encrypted.values.reduce(256) { total, value in
            if case .data(let data) = value { return total + data.count }
            return total + 16
        }
    }

    // MARK: - Месяцы с диска

    /// Первая выгрузка и недельная сверка: месяцы истории, которых нет в
    /// памяти, — по одному, с паузой, свой — сверить и отправить.
    private func scanDisk(force: Bool) async throws {
        guard let trips = source(.trip), let all = await trips.allPartitions() else { return }
        let hot = trips.hotPartitions()
        let stamp = now()
        let due = force || ledger.fullScanAt.map { stamp.timeIntervalSince($0) > AppConfig.cloudFullScanInterval } ?? true
        // Месяцы, известные журналу, но пропавшие с диска: все записи в них
        // удалены (файл месяца удаляется вместе с последней записью).
        let known = Set(ledger.entries.keys.compactMap { name -> String? in
            guard name.hasPrefix(CloudKind.trip.rawValue + "."), ledger.entries[name]?.deleted == false else { return nil }
            return CloudKey(recordName: name)?.partition
        })
        let candidates = all.union(due ? known : []).subtracting(hot)
        let months = candidates.filter { due || ledger.scanned[$0] == nil }.sorted(by: >)
        guard !months.isEmpty else {
            if due { ledger.fullScanAt = stamp }
            return
        }
        for month in months {
            guard mayContinue(), mayScan() else { throw CancellationError() }
            let items: [CloudItem]
            if all.contains(month) {
                guard let read = await trips.items(in: [month]) else { return }
                items = read
            } else {
                items = []
            }
            ledger = await Self.detect(items, kind: .trip, partitions: [month], ledger: ledger, now: now())
            try await push(only: month)
            ledger.scanned[month] = now()
            commit()
            await Task.pause(seconds: AppConfig.cloudScanPause)
        }
        ledger.fullScanAt = stamp
    }
}
