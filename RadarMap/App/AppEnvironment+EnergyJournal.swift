//
//  AppEnvironment+EnergyJournal.swift
//  RadarMap
//
//  Журнал заправок и зарядок (21.6) в композиционном корне: какие записи
//  предлагать этой машине и сохранение записи — вместе с ценой профиля,
//  если водитель сам согласился её обновить.
//

import Foundation

/// Что открыть листом: новую заправку, новую зарядку или правку записи.
struct JournalEntryRequest: Identifiable {
    enum Mode { case fill, charge }

    let mode: Mode
    var editing: JournalEntry?
    #if DEBUG
    /// Снимки экрана: поля уже заполнены (`-journalEntry fill|charge|typo`).
    var demo: JournalForm?
    #endif
    let id = UUID()

    init(mode: Mode, editing: JournalEntry? = nil) {
        self.mode = mode
        self.editing = editing
    }

    static func edit(_ entry: JournalEntry) -> JournalEntryRequest {
        JournalEntryRequest(mode: entry.kind.isCharge ? .charge : .fill, editing: entry)
    }
}

extension AppEnvironment {

    /// Заправки этой машины (бензин; метан или пропан — первым).
    var journalFillKinds: [JournalKind] { JournalKind.fills(for: settings.vehicleEnergy) }

    /// Зарядки — у машины с розеткой; первой — где обычно заряжают.
    var journalChargeKinds: [JournalKind] {
        let kinds = JournalKind.charges(for: settings.vehicleEnergy)
        guard settings.fuelProfile.chargePlace == .station else { return kinds }
        return kinds.sorted { $0 == .stationCharge && $1 != .stationCharge }
    }

    /// Записи и кнопки журнала есть у машины, которая что-то заправляет.
    var journalModes: [JournalEntryRequest.Mode] {
        (journalFillKinds.isEmpty ? [] : [.fill]) + (journalChargeKinds.isEmpty ? [] : [.charge])
    }

    /// Сохранить запись; цена профиля меняется только с согласия водителя.
    func saveJournalEntry(_ entry: JournalEntry, price: EnergyJournal.PriceUpdate?) {
        energyJournal.upsert(entry)
        if let price { settings.update(price.number, to: price.new) }
    }

    func deleteJournalEntry(_ id: UUID) {
        energyJournal.remove(id)
    }

    /// Журнал за окно периода «Итогов».
    func journalPeriod(_ interval: DateInterval) -> EnergyJournal.Period {
        EnergyJournal.period(energyJournal.entries, in: interval)
    }
}
