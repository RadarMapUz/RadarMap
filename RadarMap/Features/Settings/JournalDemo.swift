//
//  JournalDemo.swift
//  RadarMap
//
//  DEBUG: журнал заправок и зарядок на снимок без ручного ввода (21.6).
//  `-demoJournal` (вместе с `-demoEnergy`) — месяц гибрида владельца:
//  бензин «бак к баку» с пробегом, зарядки дома каждые два-три дня, одна
//  на станции. `-journalEntry fill|charge|typo` — лист записи с уже
//  вписанными цифрами (на странице журнала, `-settingsPage journal`, и на
//  «Машине и расходах»). В релизную сборку не попадает.
//

#if DEBUG
import Foundation

enum JournalDemo {
    static func seed(_ env: AppEnvironment, now: Date = Date()) {
        func at(_ daysAgo: Double, _ hour: Double) -> Date {
            Calendar.current.startOfDay(for: now).addingTimeInterval(-daysAgo * 86_400 + hour * 3_600)
        }
        let entries: [JournalEntry] = [
            JournalEntry(date: at(24, 18.5), kind: .petrol, quantity: 38, amount: 486_400,
                         odometerKm: 86_100, full: true),
            JournalEntry(date: at(11, 9.2), kind: .petrol, quantity: 20, amount: 256_000),
            JournalEntry(date: at(2, 19.1), kind: .petrol, quantity: 31, amount: 403_000,
                         odometerKm: 87_240, full: true),
            JournalEntry(date: at(18, 22), kind: .homeCharge, quantity: 17.5, amount: 17_500),
            JournalEntry(date: at(15, 22.5), kind: .homeCharge, quantity: 16.8, amount: 16_800),
            JournalEntry(date: at(13, 14), kind: .stationCharge, quantity: 20, amount: 50_000),
            JournalEntry(date: at(9, 23), kind: .homeCharge, quantity: 17.2, amount: 17_200),
            JournalEntry(date: at(6, 22), kind: .homeCharge, quantity: 16.9, amount: 16_900,
                         odometerKm: 86_950, full: true),
            JournalEntry(date: at(4, 21.5), kind: .homeCharge, quantity: 16.5, amount: 16_500),
            JournalEntry(date: at(1, 22.2), kind: .homeCharge, quantity: 17.2, amount: 17_200,
                         odometerKm: 87_190, full: true),
        ]
        env.energyJournal.seedDemo(entries)
    }

    /// Лист записи с цифрами для снимка: `-journalEntry fill|charge|typo`.
    @MainActor
    static func request(_ args: [String], env: AppEnvironment) -> JournalEntryRequest? {
        guard let i = args.firstIndex(of: "-journalEntry"), i + 1 < args.count else { return nil }
        var request: JournalEntryRequest
        var form: JournalForm
        switch args[i + 1] {
        case "charge":
            request = JournalEntryRequest(mode: .charge)
            form = JournalForm(kind: env.journalChargeKinds.first ?? .homeCharge, now: Date())
            form.quantity = "18,3"
            form.amount = FineForm.grouped(18_300)
        case "typo":
            request = JournalEntryRequest(mode: .fill)
            form = JournalForm(kind: env.journalFillKinds.first ?? .petrol, now: Date())
            form.quantity = "30"
            form.amount = FineForm.grouped(3_000)
        default:
            request = JournalEntryRequest(mode: .fill)
            form = JournalForm(kind: env.journalFillKinds.first ?? .petrol, now: Date())
            form.quantity = "30"
            form.amount = FineForm.grouped(390_000)
            form.odometer = FineForm.grouped(87_655)
            form.full = true
        }
        request.demo = form
        return request
    }
}
#endif
