//
//  MaintenanceService.swift
//  RadarMap
//
//  Обслуживание машины (18.1–18.3): хранит то, что сказал водитель (пробег,
//  пункты), и отдаёт экрану готовые состояния. Решения — в чистых
//  `Maintenance` и `MaintenanceReminders`; здесь только хранение и правки.
//
//  Хранится только на телефоне (Storage, JSON), на сервер не уходит.
//

import Foundation

@MainActor
@Observable
final class MaintenanceService {
    nonisolated deinit {}

    private(set) var book: MaintenanceBook

    @ObservationIgnored private let trip: TripStats
    @ObservationIgnored private let settings: AppSettings
    /// Демо-состояние для снимков: на диск не пишется.
    @ObservationIgnored private var isDemo = false

    /// Водитель поправил пункт (или пробег) на экране — пересчитать
    /// напоминания; пункт, который он правил, уже увиден. Вешает AppEnvironment.
    @ObservationIgnored var onEdited: ((Set<MaintenanceKind>) -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onEdited,
                                               "MaintenanceService.onEdited") }
    }

    init(trip: TripStats, settings: AppSettings) {
        self.trip = trip
        self.settings = settings
        book = Storage.decoded(MaintenanceBook.self, for: .maintenanceBook) ?? MaintenanceBook()
    }

    /// Перечитать с диска: процесс мог подняться до первой разблокировки,
    /// когда UserDefaults ещё пусты (S9) — тогда в памяти пустая книжка.
    func reloadIfNeeded() {
        guard !isDemo, book == MaintenanceBook(),
              let stored = Storage.decoded(MaintenanceBook.self, for: .maintenanceBook) else { return }
        book = stored
    }

    // MARK: - Чтение

    /// Пробег сейчас, км: введённый плюс поездки после ввода.
    var odometerKm: Double? { Maintenance.odometer(book, days: trip.days) }

    /// Сколько прибавили поездки после ввода, км.
    var odometerAddedKm: Double? {
        guard let entered = book.odometerKm, let now = odometerKm else { return nil }
        return now - entered
    }

    /// Включённые пункты этой машины.
    func states(now: Date = Date()) -> [Maintenance.State] {
        Maintenance.states(book, energy: settings.vehicleEnergy, odometerKm: odometerKm, now: now)
    }

    /// Пункты этой машины, которые водитель выключил (или выключены по
    /// умолчанию) — их можно включить.
    var disabledKinds: [MaintenanceKind] {
        MaintenanceKind.allCases.filter { $0.applies(to: settings.vehicleEnergy) && !book.isEnabled($0) }
    }

    /// «Скоро», «пора», «просрочено» — самое срочное первым.
    func attention(now: Date = Date()) -> [Maintenance.State] {
        Maintenance.attention(states(now: now))
    }

    // MARK: - Правки

    func setOdometer(km: Double, now: Date = Date()) {
        // Новый пробег сдвигает сроки всех пунктов, а человек смотрит на них
        // все — напоминать о том, что он видит на экране, незачем.
        apply(Maintenance.settingOdometer(book, km: km, now: now, days: trip.days),
              seen: Set(MaintenanceKind.allCases))
    }

    func markDone(_ kind: MaintenanceKind, now: Date = Date()) {
        apply(Maintenance.markedDone(book, kind: kind, odometerKm: odometerKm, now: now), seen: [kind])
    }

    /// Правка из листа пункта: запись целиком.
    func update(_ kind: MaintenanceKind, record: MaintenanceRecord) {
        var next = book
        next.set(record, for: kind)
        apply(next, seen: [kind])
    }

    func setEnabled(_ kind: MaintenanceKind, _ enabled: Bool) {
        var record = book.record(kind)
        record.enabled = enabled
        update(kind, record: record)
    }

    private func apply(_ next: MaintenanceBook, seen: Set<MaintenanceKind>) {
        guard next != book else { return }
        book = next
        if !isDemo { Storage.encode(book, for: .maintenanceBook) }
        onEdited?(seen)
    }

    #if DEBUG
    /// `-demoMaintenance`: пробег и пункты во всех состояниях — для снимков.
    func seedDemo(now: Date = Date()) {
        isDemo = true
        let calendar = Calendar.current
        func ago(months: Int = 0, days: Int = 0) -> Date {
            calendar.date(byAdding: DateComponents(month: -months, day: -days), to: now) ?? now
        }
        func ahead(days: Int) -> Date { calendar.date(byAdding: .day, value: days, to: now) ?? now }
        var demo = Maintenance.settingOdometer(MaintenanceBook(), km: 87_240, now: ago(days: 12),
                                               days: trip.days)
        demo.set(MaintenanceRecord(doneKm: 79_600, doneAt: ago(months: 5)), for: .oil)
        demo.set(MaintenanceRecord(doneKm: 74_000, doneAt: ago(months: 7)), for: .airFilter)
        demo.set(MaintenanceRecord(doneKm: 72_500, doneAt: ago(months: 12, days: 5)), for: .cabinFilter)
        demo.set(MaintenanceRecord(doneAt: ago(months: 26)), for: .brakeFluid)
        demo.set(MaintenanceRecord(doneKm: 41_000), for: .timingBelt)
        demo.set(MaintenanceRecord(dueDate: ahead(days: 9)), for: .osago)
        demo.set(MaintenanceRecord(dueDate: ahead(days: 140)), for: .inspection)
        demo.set(MaintenanceRecord(dueDate: ahead(days: 200)), for: .gasCylinder)
        demo.set(MaintenanceRecord(enabled: true, dueDate: ahead(days: 0)), for: .tintPermit)
        book = demo
    }
    #endif
}
