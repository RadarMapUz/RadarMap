//
//  CloudSync.swift
//  RadarMap
//
//  Свои данные в iCloud самого человека (27.F) — чистая часть синхронизации:
//  что такое запись, как узнать свою правку, кто прав при встрече двух версий
//  и что значит «удалено». Ни CloudKit, ни диска: проход (CloudSyncEngine) и
//  транспорт (CloudKitTransport) — снаружи, решения — здесь, под
//  CloudSyncTests.
//
//  Правила.
//  * Запись — по id: поездка — по своему id, штраф — по своему. Одна
//    поездка — одна запись в iCloud.
//  * «Последняя правка» — по modifiedAt: новее выигрывает целиком. Равные по
//    времени и разные по содержанию — выигрывает больший отпечаток: решение
//    одно и то же на любом телефоне, и два устройства сходятся.
//  * Удаление — надгробие: запись остаётся с deleted = 1 и временем удаления,
//    без содержимого. Правка старше надгробия его не воскрешает; при равном
//    времени надгробие сильнее.
//  * Своя правка узнаётся сравнением с отпечатком в журнале (CloudLedger), а
//    не крючками в сорока местах, где правятся данные: забыть крючок нельзя,
//    потому что крючков нет.
//  * Трек, вырезанный по сроку на телефоне, — не правка: у записи остаётся
//    прежний отпечаток трека, а в iCloud трек живёт дальше.
//  * Сводка дней и «за всё время» — не «последняя правка», а слияние (как у
//    копии в файл, TripBackupMerge): у старых месяцев правда только там.
//  * Записи, которых журнал не знает, при встрече с iCloud уступают ему:
//    так новый телефон восстанавливает историю, а не затирает её своим
//    пустым профилем машины.
//

import Foundation
import CryptoKit

/// Что синхронизируется. Сырые значения — часть имени записи в iCloud:
/// менять нельзя.
nonisolated enum CloudKind: String, CaseIterable, Codable, Sendable {
    /// Одна поездка (TripRecord): содержимое и трек отдельно.
    case trip
    /// Дневные сводки и «за всё время» — одной записью, слиянием.
    case summary
    /// Запись журнала заправок и зарядок.
    case journal
    /// Пришедший штраф.
    case fine
    /// Близкий — без ключа записи и адреса ссылки.
    case family
    /// Дом, Работа, недавние и избранные места.
    case place
    /// Тип машины и её профиль расхода.
    case vehicle
    /// Служебная отметка «историю удалили» (другие устройства узнают из неё).
    case marker

    var zone: CloudZone {
        switch self {
        case .trip, .summary: return .trips
        case .journal, .fine, .family, .place, .vehicle, .marker: return .data
        }
    }

    /// Тип записи CloudKit.
    var recordType: String {
        switch self {
        case .trip:    return "Trip"
        case .summary: return "TripSummary"
        case .journal: return "JournalEntry"
        case .fine:    return "ReceivedFine"
        case .family:  return "FamilyContact"
        case .place:   return "Place"
        case .vehicle: return "Vehicle"
        case .marker:  return "Marker"
        }
    }

    /// Встреча двух версий решается слиянием, а не «последней правкой».
    var merges: Bool { self == .summary }
}

/// Зоны приватной базы. «Поездки» стираются целиком одним действием
/// («Удалить всю историю»), «Данные» живут дольше: штрафы, места, машина.
nonisolated enum CloudZone: String, CaseIterable, Codable, Sendable {
    case trips = "Trips"
    case data = "Data"
}

/// Ключ записи: вид, раздел (месяц поездки — чтобы удаление нашло файл
/// месяца, не читая всю историю) и id.
nonisolated struct CloudKey: Hashable, Comparable, Codable, Sendable {
    let kind: CloudKind
    let partition: String
    let id: String

    init(kind: CloudKind, partition: String = "", id: String) {
        self.kind = kind
        self.partition = partition
        self.id = id
    }

    /// «trip.2026-10.1760000000.5» — имя записи в iCloud. id идёт последним:
    /// в нём самом могут быть точки.
    var recordName: String { "\(kind.rawValue).\(partition).\(id)" }

    init?(recordName: String) {
        let parts = recordName.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let kind = CloudKind(rawValue: String(parts[0])),
              !parts[2].isEmpty else { return nil }
        self.init(kind: kind, partition: String(parts[1]), id: String(parts[2]))
    }

    static func < (a: CloudKey, b: CloudKey) -> Bool { a.recordName < b.recordName }
}

/// Одна запись в «проводе» между источником и iCloud: содержимое уже
/// закодировано (канонический JSON), сжатие и шифрование — у кодека.
nonisolated struct CloudItem: Equatable, Sendable {
    let key: CloudKey
    /// Канонический JSON без трека; nil у надгробия.
    var body: Data?
    /// Канонический JSON трека; nil — трека нет (или вырезан на телефоне).
    var track: Data?
    /// Время правки. У пришедших — из записи; у своих его ставит журнал.
    var modifiedAt: Date
    var deleted: Bool
    /// Своё «естественное» время для записи, которой журнал ещё не видел:
    /// конец поездки. nil — «сейчас».
    var natural: Date?

    init(key: CloudKey, body: Data?, track: Data? = nil, modifiedAt: Date = .distantPast,
         deleted: Bool = false, natural: Date? = nil) {
        self.key = key
        self.body = body
        self.track = track
        self.modifiedAt = modifiedAt
        self.deleted = deleted
        self.natural = natural
    }

    static func tombstone(_ key: CloudKey, at date: Date) -> CloudItem {
        CloudItem(key: key, body: nil, track: nil, modifiedAt: date, deleted: true)
    }
}

/// Журнал синхронизации: что о каждой записи известно этому телефону. Он же —
/// очередь отправки (pending), переживающая выключение сети и перезапуск.
nonisolated struct CloudLedger: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        /// Отпечаток содержимого без трека; nil у надгробия.
        var fields: String?
        /// Отпечаток трека; nil — трека не было.
        var track: String?
        var modifiedAt: Date
        var deleted: Bool
        /// Своя версия ещё не в iCloud.
        var pending: Bool
    }

    var version = CloudLedger.currentVersion
    /// По имени записи.
    var entries: [String: Entry] = [:]
    /// Метки изменений CloudKit по зонам (архив CKServerChangeToken).
    var tokens: [String: Data] = [:]
    /// Зоны, созданные в iCloud.
    var readyZones: Set<String> = []
    /// Первый проход завершён: дальше своё сверяется раньше чужого.
    var syncedOnce = false
    /// Месяцы поездок, сверенные с диском (первая выгрузка, недельная сверка).
    var scanned: [String: Date] = [:]
    /// Когда последний раз вся история сверялась с диском.
    var fullScanAt: Date?
    /// Последняя известная отметка «историю удалили».
    var wipeSeen: Date?
    /// «Удалить всю историю» нажато, но iCloud ещё не стёрт (нет сети).
    var pendingWipe: Date?
    /// Какие зоны стереть: «Поездки» — история, обе — вся копия.
    var pendingWipeZones: Set<String> = []
    /// Чей iCloud: отпечаток id пользователя. Сменился — журнал чужой.
    var account: String?
    /// Последний удачный проход.
    var lastSyncAt: Date?

    static let currentVersion = 1

    init() {}

    private enum CodingKeys: String, CodingKey {
        case version, entries, tokens, readyZones, syncedOnce, scanned, fullScanAt,
             wipeSeen, pendingWipe, pendingWipeZones, account, lastSyncAt
    }

    /// Всё — с умолчаниями (правило 18): журнал старой сборки не теряется.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        entries = try c.decodeIfPresent([String: Entry].self, forKey: .entries) ?? [:]
        tokens = try c.decodeIfPresent([String: Data].self, forKey: .tokens) ?? [:]
        readyZones = try c.decodeIfPresent(Set<String>.self, forKey: .readyZones) ?? []
        syncedOnce = try c.decodeIfPresent(Bool.self, forKey: .syncedOnce) ?? false
        scanned = try c.decodeIfPresent([String: Date].self, forKey: .scanned) ?? [:]
        fullScanAt = try c.decodeIfPresent(Date.self, forKey: .fullScanAt)
        wipeSeen = try c.decodeIfPresent(Date.self, forKey: .wipeSeen)
        pendingWipe = try c.decodeIfPresent(Date.self, forKey: .pendingWipe)
        pendingWipeZones = try c.decodeIfPresent(Set<String>.self, forKey: .pendingWipeZones) ?? []
        account = try c.decodeIfPresent(String.self, forKey: .account)
        lastSyncAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncAt)
    }

    /// Ключи, ждущие отправки, — по порядку имени (стабильно для порций).
    var pendingKeys: [CloudKey] {
        entries.compactMap { name, entry in entry.pending ? CloudKey(recordName: name) : nil }.sorted()
    }

    /// Поездок в iCloud: живые и отправленные.
    var tripsInCloud: Int {
        entries.reduce(0) { count, pair in
            let isTrip = pair.key.hasPrefix(CloudKind.trip.rawValue + ".")
            return count + (isTrip && !pair.value.deleted && !pair.value.pending ? 1 : 0)
        }
    }

    /// Ещё не отправлено (для строки состояния).
    var pendingCount: Int { entries.values.reduce(0) { $0 + ($1.pending ? 1 : 0) } }

    /// Забыть всё про зону: её стёрли (своё «Удалить всё» или чужое).
    mutating func forget(zone: CloudZone) {
        let kinds = Set(CloudKind.allCases.filter { $0.zone == zone }.map(\.rawValue))
        entries = entries.filter { name, _ in
            guard let kind = name.split(separator: ".").first else { return true }
            return !kinds.contains(String(kind))
        }
        tokens[zone.rawValue] = nil
        readyZones.remove(zone.rawValue)
        if zone == .trips {
            scanned = [:]
            fullScanAt = nil
        }
    }
}

/// Решения синхронизации — чистые.
nonisolated enum CloudMerge {

    /// Отпечаток содержимого: 128 бит SHA-256 в hex.
    static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Время своей правки строго новее прежнего: часы телефона могли уйти
    /// назад, а правка обязана победить собственную прошлую версию.
    static func editTime(now: Date, after previous: Date) -> Date {
        now > previous ? now : previous.addingTimeInterval(0.001)
    }

    /// Свои изменения — снимок источника против журнала. `partitions` — какие
    /// разделы снимок покрывает целиком: только там отсутствие записи значит
    /// «удалили» (месяц поездок, не прочитанный с диска, — не удаление).
    /// Возвращает число изменений; повторный вызов с тем же снимком — ноль.
    @discardableResult
    static func detectLocal(_ items: [CloudItem], kind: CloudKind, partitions: Set<String>,
                            ledger: inout CloudLedger, now: Date) -> Int {
        var seen = Set<String>()
        var changes = 0
        for item in items where item.key.kind == kind && !item.deleted {
            let name = item.key.recordName
            seen.insert(name)
            let fields = item.body.map(fingerprint)
            let track = item.track.map(fingerprint)
            if var entry = ledger.entries[name] {
                let fieldsChanged = entry.deleted || entry.fields != fields
                // Трек пропал — его вырезал срок хранения, это не правка.
                let trackChanged = track != nil && track != entry.track
                guard fieldsChanged || trackChanged else { continue }
                entry.fields = fields
                if let track { entry.track = track }
                entry.deleted = false
                entry.modifiedAt = editTime(now: now, after: entry.modifiedAt)
                entry.pending = true
                ledger.entries[name] = entry
            } else {
                ledger.entries[name] = CloudLedger.Entry(fields: fields, track: track,
                                                         modifiedAt: item.natural ?? now,
                                                         deleted: false, pending: true)
            }
            changes += 1
        }
        let prefix = kind.rawValue + "."
        let gone = ledger.entries.compactMap { name, entry -> String? in
            guard !entry.deleted, name.hasPrefix(prefix), !seen.contains(name),
                  let key = CloudKey(recordName: name), partitions.contains(key.partition) else { return nil }
            return name
        }
        for name in gone {
            guard let entry = ledger.entries[name] else { continue }
            ledger.entries[name] = CloudLedger.Entry(fields: nil, track: entry.track,
                                                     modifiedAt: editTime(now: now, after: entry.modifiedAt),
                                                     deleted: true, pending: true)
            changes += 1
        }
        return changes
    }

    enum Resolution: Equatable, Sendable {
        /// Пришедшая версия новее — применить у себя.
        case applyRemote
        /// Своя новее — оставить и отправить.
        case keepLocal
        /// То же самое — ничего не делать.
        case same
    }

    /// Встреча пришедшей версии со своей.
    static func resolve(_ remote: CloudItem, entry: CloudLedger.Entry?) -> Resolution {
        // Журнал записи не знает — в iCloud она раньше нас: восстановление.
        guard let entry else { return .applyRemote }
        let remoteFields = remote.deleted ? nil : remote.body.map(fingerprint)
        if remote.deleted == entry.deleted && remoteFields == entry.fields { return .same }
        // Сводку решает слияние: применить пришедшее всегда, своё лишнее
        // уедет следующей сверкой.
        if remote.key.kind.merges { return .applyRemote }
        if remote.modifiedAt > entry.modifiedAt { return .applyRemote }
        if remote.modifiedAt < entry.modifiedAt { return .keepLocal }
        if remote.deleted != entry.deleted { return remote.deleted ? .applyRemote : .keepLocal }
        return (remoteFields ?? "") > (entry.fields ?? "") ? .applyRemote : .keepLocal
    }

    /// Журнал после применения пришедшей версии: она теперь и своя.
    static func absorb(_ remote: CloudItem, into ledger: inout CloudLedger) {
        let name = remote.key.recordName
        let previous = ledger.entries[name]
        ledger.entries[name] = CloudLedger.Entry(
            fields: remote.deleted ? nil : remote.body.map(fingerprint),
            track: remote.track.map(fingerprint) ?? previous?.track,
            modifiedAt: remote.modifiedAt,
            deleted: remote.deleted,
            pending: false)
    }

    /// Пришедшая версия разобрана: что сделать у себя и с журналом.
    static func receive(_ remote: CloudItem, ledger: inout CloudLedger) -> Resolution {
        let name = remote.key.recordName
        let resolution = resolve(remote, entry: ledger.entries[name])
        switch resolution {
        case .applyRemote:
            absorb(remote, into: &ledger)
        case .keepLocal:
            ledger.entries[name]?.pending = true
        case .same:
            // Своё уже там: отправлять нечего, время — из iCloud.
            if var entry = ledger.entries[name] {
                entry.pending = false
                entry.modifiedAt = max(entry.modifiedAt, remote.modifiedAt)
                if entry.track == nil { entry.track = remote.track.map(fingerprint) }
                ledger.entries[name] = entry
            }
        }
        return resolution
    }

    /// Отправка удалась. Журнал снимает «ждёт», только если с тех пор своей
    /// правки не было: иначе новая версия уехала бы в никуда.
    static func markSent(_ key: CloudKey, modifiedAt: Date, ledger: inout CloudLedger) {
        let name = key.recordName
        guard var entry = ledger.entries[name], entry.modifiedAt == modifiedAt else { return }
        entry.pending = false
        ledger.entries[name] = entry
    }

    /// Отметка «историю удалили»: чужая и новее виденной — стереть ли у себя
    /// копию из iCloud и остановиться. Своя (или первый проход) — просто
    /// запомнить.
    static func isForeignWipe(_ marker: Date, ledger: CloudLedger) -> Bool {
        guard ledger.syncedOnce else { return false }
        return marker > (ledger.wipeSeen ?? .distantPast)
    }
}
