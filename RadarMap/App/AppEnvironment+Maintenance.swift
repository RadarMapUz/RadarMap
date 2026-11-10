//
//  AppEnvironment+Maintenance.swift
//  RadarMap
//
//  Напоминания об обслуживании (18.3): когда пересчитывать и что сказать.
//  Решение «что и когда» — MaintenanceReminders (чистое, с тестами); здесь
//  только сбор входов, журнал в Storage и тексты.
//

import Foundation
import os
import UserNotifications

extension AppEnvironment {

    /// Пересчитать напоминания: конец/начало поездки (`.parked` — машина
    /// стоит, в поездке план снимает поставленное), открытие приложения и
    /// правка пункта (`.opened`). Идемпотентно: журнал помнит поставленное и
    /// показанное, повтор ничего не делает.
    func refreshMaintenanceReminders(moment: MaintenanceReminders.Moment,
                                     acknowledged: Set<MaintenanceKind> = [], now: Date = Date()) {
        // До чтения истории пробег не досчитан (дни поездок не прочитаны) —
        // «скоро» по такому пробегу было бы ложным, а «не скоро» сняло бы
        // настоящее. Прочитается — onHistoryLoaded пересчитает.
        guard trip.isLoaded else {
            // А поездка уже идёт (автостарт до разблокировки): поставленное
            // снять всё равно — «не в дороге» важнее точного плана. Из журнала —
            // тоже, если он читается: иначе прошедшее в дороге время показа
            // сочлось бы «показанным», и напоминание пропало бы.
            if location.isTripActive {
                notifications.cancelPendingMaintenance()
                if let ledger = Storage.decoded([String: Date].self, for: .maintenanceReminders) {
                    Storage.encode(ledger.filter { $0.value <= now }, for: .maintenanceReminders)
                }
            }
            return
        }
        maintenance.reloadIfNeeded()
        let ledger = Storage.decoded([String: Date].self, for: .maintenanceReminders) ?? [:]
        let states = maintenance.states(now: now)
        let plan = MaintenanceReminders.plan(
            states: states, ledger: ledger,
            enabled: settings.maintenanceReminders && settings.carLog && notifications.canNotify,
            tripActive: location.isTripActive, moment: moment, now: now, acknowledged: acknowledged)
        guard !plan.schedule.isEmpty || !plan.cancel.isEmpty || plan.ledger != ledger else { return }
        let byKind = Dictionary(uniqueKeysWithValues: states.map { ($0.kind, $0) })
        let notes = plan.schedule.compactMap { reminder -> NotificationService.MaintenanceNote? in
            guard let state = byKind[reminder.kind] else { return nil }
            return NotificationService.MaintenanceNote(id: reminder.id, fire: reminder.fire,
                                                       title: reminder.kind.title,
                                                       body: MaintenanceText.notificationBody(state))
        }
        if !notes.isEmpty || !plan.cancel.isEmpty {
            Log.app.info("обслуживание: поставлено \(notes.count, privacy: .public), снято \(plan.cancel.count, privacy: .public)")
        }
        // Ушло из журнала, не будучи снятым, — показанное о прошлом цикле.
        let outdated = Set(ledger.keys).subtracting(plan.ledger.keys).subtracting(plan.cancel)
        notifications.scheduleMaintenance(notes, cancel: plan.cancel, outdated: outdated.sorted())
        Storage.encode(plan.ledger, for: .maintenanceReminders)
    }

    /// Водитель правил пункт или пробег. Первое заполнение спрашивает
    /// разрешение на уведомления — ради них он и вводит даты.
    func maintenanceEdited(_ seen: Set<MaintenanceKind>) {
        guard settings.maintenanceReminders, notifications.authorizationStatus == .notDetermined else {
            refreshMaintenanceReminders(moment: .opened, acknowledged: seen)
            return
        }
        Task {
            _ = await notifications.requestAuthorizationResult()
            refreshMaintenanceReminders(moment: .opened, acknowledged: seen)
        }
    }

    /// Выключатель «Напоминать» на экране обслуживания.
    func setMaintenanceReminders(_ on: Bool) {
        if settings.maintenanceReminders != on { settings.maintenanceReminders = on }
        guard on, notifications.authorizationStatus == .notDetermined else {
            refreshMaintenanceReminders(moment: .opened)
            return
        }
        Task {
            let granted = await notifications.requestAuthorizationResult()
            if !granted { Log.app.notice("напоминания об обслуживании: уведомления запрещены") }
            refreshMaintenanceReminders(moment: .opened)
        }
    }
}
