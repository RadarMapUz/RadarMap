//
//  CloudSources.swift
//  RadarMap
//
//  Что из своих данных уходит в iCloud (27.F) и как пришедшее ложится
//  обратно: по источнику на вид. Каждый — тонкий переходник к уже
//  существующему хранилищу (TripStats, EnergyJournalStore, FineStore,
//  FamilyShareService, AppSettings); правила хранения остаются у них
//  (не прочитан файл — не готов, правка до чтения — поверх диска).
//
//  Пустое не отправляется: профиль машины по умолчанию, незаданный Дом,
//  пустые недавние. Иначе новый телефон со своими «нулями» спорил бы с
//  настоящими данными в iCloud.
//

import Foundation
import os

// MARK: - Поездки

@MainActor
final class TripCloudSource: CloudSource {
    nonisolated deinit {}
    let kind = CloudKind.trip
    private weak var trip: TripStats?

    init(trip: TripStats) { self.trip = trip }

    var isReady: Bool { trip.map { $0.isLoaded && $0.isLifetimeTrusted } ?? false }

    func hotPartitions() -> Set<String> {
        Set(trip?.cloudMonthsInMemory().keys.map(\.key) ?? [])
    }

    func allPartitions() async -> Set<String>? {
        guard let months = await TripStats.cloudMonthsOnDisk() else { return nil }
        return Set(months.map(\.key)).union(hotPartitions())
    }

    func items(in partitions: Set<String>) async -> [CloudItem]? {
        guard let trip else { return nil }
        let memory = trip.cloudMonthsInMemory()
        var records: [TripRecord] = []
        for key in partitions {
            guard let month = TripStore.Month(key: key) else { continue }
            if let held = memory[month] {
                records += held
            } else {
                guard let disk = await TripStats.cloudReadMonth(month) else { return nil }
                records += disk
            }
        }
        return await Self.encode(records)
    }

    func apply(upserts: [CloudItem], deletions: [CloudKey]) async -> Bool {
        guard let trip else { return false }
        let records = await Self.decode(upserts)
        var removals: [Double: TripStore.Month] = [:]
        for key in deletions {
            guard let id = CloudPayload.tripID(key), let month = TripStore.Month(key: key.partition) else { continue }
            removals[id] = month
        }
        return await trip.cloudApply(upserts: records, removals: removals)
    }

    @concurrent private nonisolated static func encode(_ records: [TripRecord]) async -> [CloudItem] {
        records.compactMap(CloudPayload.tripItem)
    }

    @concurrent private nonisolated static func decode(_ items: [CloudItem]) async -> [TripRecord] {
        items.compactMap(CloudPayload.tripRecord(from:))
    }
}

// MARK: - Сводка дней и «за всё время»

@MainActor
final class SummaryCloudSource: CloudSource {
    nonisolated deinit {}
    let kind = CloudKind.summary
    private weak var trip: TripStats?

    init(trip: TripStats) { self.trip = trip }

    var isReady: Bool { trip.map { $0.isLoaded && $0.isLifetimeTrusted } ?? false }
    func hotPartitions() -> Set<String> { [""] }
    func allPartitions() async -> Set<String>? { [""] }

    func items(in partitions: Set<String>) async -> [CloudItem]? {
        guard let trip else { return nil }
        guard partitions.contains(""), !trip.days.isEmpty || !trip.lifetime.isEmpty else { return [] }
        return await Self.encode(CloudPayload.Summary(days: trip.days, lifetime: trip.lifetime))
    }

    func apply(upserts: [CloudItem], deletions: [CloudKey]) async -> Bool {
        // Надгробие сводки — значит, у другого телефона история пуста; свои
        // дни это не стирает (их стирает только «Удалить всю историю»).
        guard let trip, let item = upserts.first else { return true }
        guard let summary = await Self.decode(item) else { return true }
        return trip.mergeCloudSummary(days: summary.days, lifetime: summary.lifetime)
    }

    @concurrent private nonisolated static func encode(_ summary: CloudPayload.Summary) async -> [CloudItem] {
        guard let body = CloudPayload.canonical(summary) else { return [] }
        return [CloudItem(key: CloudPayload.summaryKey, body: body)]
    }

    @concurrent private nonisolated static func decode(_ item: CloudItem) async -> CloudPayload.Summary? {
        CloudPayload.decode(CloudPayload.Summary.self, from: item.body)
    }
}

// MARK: - Журнал заправок и зарядок

@MainActor
final class JournalCloudSource: CloudSource {
    nonisolated deinit {}
    let kind = CloudKind.journal
    private weak var store: EnergyJournalStore?

    init(store: EnergyJournalStore) { self.store = store }

    var isReady: Bool { store?.isLoaded ?? false }
    func hotPartitions() -> Set<String> { [""] }
    func allPartitions() async -> Set<String>? { [""] }

    func items(in partitions: Set<String>) async -> [CloudItem]? {
        guard let store else { return nil }
        guard partitions.contains("") else { return [] }
        return store.entries.compactMap { entry in
            CloudPayload.canonical(entry).map { CloudItem(key: CloudKey(kind: .journal, id: entry.id.uuidString), body: $0) }
        }
    }

    func apply(upserts: [CloudItem], deletions: [CloudKey]) async -> Bool {
        guard let store, store.isLoaded else { return false }
        for item in upserts {
            guard let entry = CloudPayload.decode(JournalEntry.self, from: item.body),
                  entry.id.uuidString == item.key.id else { continue }
            store.upsert(entry)
        }
        for key in deletions {
            if let id = UUID(uuidString: key.id) { store.remove(id) }
        }
        return true
    }
}

// MARK: - Пришедшие штрафы

@MainActor
final class FineCloudSource: CloudSource {
    nonisolated deinit {}
    let kind = CloudKind.fine
    private weak var store: FineStore?

    init(store: FineStore) { self.store = store }

    var isReady: Bool { store?.isLoaded ?? false }
    func hotPartitions() -> Set<String> { [""] }
    func allPartitions() async -> Set<String>? { [""] }

    func items(in partitions: Set<String>) async -> [CloudItem]? {
        guard let store else { return nil }
        guard partitions.contains("") else { return [] }
        return store.fines.compactMap { fine in
            CloudPayload.canonical(fine).map { CloudItem(key: CloudKey(kind: .fine, id: fine.id.uuidString), body: $0) }
        }
    }

    func apply(upserts: [CloudItem], deletions: [CloudKey]) async -> Bool {
        guard let store, store.isLoaded else { return false }
        for item in upserts {
            guard let fine = CloudPayload.decode(ReceivedFine.self, from: item.body),
                  fine.id.uuidString == item.key.id else { continue }
            store.upsert(fine)
        }
        for key in deletions {
            if let id = UUID(uuidString: key.id) { store.remove(id) }
        }
        return true
    }
}

// MARK: - Близкие (без ключей записи)

@MainActor
final class FamilyCloudSource: CloudSource {
    nonisolated deinit {}
    let kind = CloudKind.family
    private weak var family: FamilyShareService?

    init(family: FamilyShareService) { self.family = family }

    var isReady: Bool { family != nil }
    func hotPartitions() -> Set<String> { [""] }
    func allPartitions() async -> Set<String>? { [""] }

    func items(in partitions: Set<String>) async -> [CloudItem]? {
        guard let family else { return nil }
        guard partitions.contains("") else { return [] }
        return CloudPayload.familyItems(family.circle)
    }

    func apply(upserts: [CloudItem], deletions: [CloudKey]) async -> Bool {
        guard let family else { return false }
        var contacts: [CloudPayload.FamilyContact] = []
        var driverName: String?
        for item in upserts {
            if item.key.id == CloudPayload.familyDriverID {
                driverName = CloudPayload.decode(CloudPayload.FamilyDriver.self, from: item.body)?.driverName
            } else if let contact = CloudPayload.decode(CloudPayload.FamilyContact.self, from: item.body),
                      contact.id.uuidString == item.key.id {
                contacts.append(contact)
            }
        }
        let removed = Set(deletions.compactMap { UUID(uuidString: $0.id) })
        let driverRemoved = deletions.contains { $0.id == CloudPayload.familyDriverID }
        family.applyCloud(contacts: contacts, removed: removed,
                          driverName: driverRemoved ? "" : driverName)
        return true
    }
}

// MARK: - Места

@MainActor
final class PlaceCloudSource: CloudSource {
    nonisolated deinit {}
    let kind = CloudKind.place
    private weak var settings: AppSettings?

    init(settings: AppSettings) { self.settings = settings }

    var isReady: Bool { settings != nil }
    func hotPartitions() -> Set<String> { [""] }
    func allPartitions() async -> Set<String>? { [""] }

    private static func place(_ saved: SavedPlace) -> CloudPayload.Place {
        CloudPayload.Place(title: saved.title, lat: saved.lat, lon: saved.lon)
    }

    private static func saved(_ place: CloudPayload.Place) -> SavedPlace {
        SavedPlace(title: place.title, lat: place.lat, lon: place.lon)
    }

    func items(in partitions: Set<String>) async -> [CloudItem]? {
        guard let settings else { return nil }
        guard partitions.contains("") else { return [] }
        func key(_ slot: CloudPayload.PlaceSlot) -> CloudKey { CloudKey(kind: .place, id: slot.rawValue) }
        var items: [CloudItem] = []
        if let home = settings.homePlace, let body = CloudPayload.canonical(Self.place(home)) {
            items.append(CloudItem(key: key(.home), body: body))
        }
        if let work = settings.workPlace, let body = CloudPayload.canonical(Self.place(work)) {
            items.append(CloudItem(key: key(.work), body: body))
        }
        if !settings.recentPlaces.isEmpty,
           let body = CloudPayload.canonical(settings.recentPlaces.map(Self.place)) {
            items.append(CloudItem(key: key(.recent), body: body))
        }
        if !settings.favoritePlaces.isEmpty,
           let body = CloudPayload.canonical(settings.favoritePlaces.map(Self.place)) {
            items.append(CloudItem(key: key(.favorite), body: body))
        }
        return items
    }

    func apply(upserts: [CloudItem], deletions: [CloudKey]) async -> Bool {
        guard let settings else { return false }
        for item in upserts {
            switch CloudPayload.PlaceSlot(rawValue: item.key.id) {
            case .home?:
                if let place = CloudPayload.decode(CloudPayload.Place.self, from: item.body) {
                    settings.setPlace(Self.saved(place), for: .home)
                }
            case .work?:
                if let place = CloudPayload.decode(CloudPayload.Place.self, from: item.body) {
                    settings.setPlace(Self.saved(place), for: .work)
                }
            case .recent?:
                if let list = CloudPayload.decode([CloudPayload.Place].self, from: item.body) {
                    settings.recentPlaces = list.map(Self.saved)
                }
            case .favorite?:
                if let list = CloudPayload.decode([CloudPayload.Place].self, from: item.body) {
                    settings.favoritePlaces = list.map(Self.saved)
                }
            case nil:
                Log.cloud.notice("место «\(item.key.id, privacy: .public)» этой сборке неизвестно")
            }
        }
        for key in deletions {
            switch CloudPayload.PlaceSlot(rawValue: key.id) {
            case .home?: settings.setPlace(nil, for: .home)
            case .work?: settings.setPlace(nil, for: .work)
            case .recent?: settings.recentPlaces = []
            case .favorite?: settings.favoritePlaces = []
            case nil: continue
            }
        }
        return true
    }
}

// MARK: - Машина

@MainActor
final class VehicleCloudSource: CloudSource {
    nonisolated deinit {}
    let kind = CloudKind.vehicle
    private weak var settings: AppSettings?

    init(settings: AppSettings) { self.settings = settings }

    var isReady: Bool { settings != nil }
    func hotPartitions() -> Set<String> { [""] }
    func allPartitions() async -> Set<String>? { [""] }

    func items(in partitions: Set<String>) async -> [CloudItem]? {
        guard let settings else { return nil }
        guard partitions.contains("") else { return [] }
        // Не настроено — нечего хранить: умолчание не должно спорить с
        // настоящим профилем в iCloud.
        guard settings.vehicleEnergy != .fuel || settings.fuelProfile != FuelProfile() else { return [] }
        let vehicle = CloudPayload.Vehicle(energy: settings.vehicleEnergy.rawValue, profile: settings.fuelProfile)
        guard let body = CloudPayload.canonical(vehicle) else { return nil }
        return [CloudItem(key: CloudKey(kind: .vehicle, id: CloudPayload.vehicleID), body: body)]
    }

    func apply(upserts: [CloudItem], deletions: [CloudKey]) async -> Bool {
        guard let settings else { return false }
        if deletions.contains(where: { $0.id == CloudPayload.vehicleID }) {
            // На другом телефоне профиль сброшен — тот же сброс здесь: иначе
            // свой профиль ушёл бы обратно как «более новая правка».
            if settings.vehicleEnergy != .fuel { settings.vehicleEnergy = .fuel }
            if settings.fuelProfile != FuelProfile() { settings.fuelProfile = FuelProfile() }
            return true
        }
        guard let item = upserts.first(where: { $0.key.id == CloudPayload.vehicleID }),
              let vehicle = CloudPayload.decode(CloudPayload.Vehicle.self, from: item.body) else { return true }
        if let energy = VehicleEnergy(rawValue: vehicle.energy), energy != settings.vehicleEnergy {
            settings.vehicleEnergy = energy
        }
        if vehicle.profile != settings.fuelProfile { settings.fuelProfile = vehicle.profile }
        return true
    }
}
