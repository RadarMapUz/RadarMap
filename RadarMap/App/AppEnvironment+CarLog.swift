//
//  AppEnvironment+CarLog.swift
//  RadarMap
//
//  «Машина и расходы» (CarLog): что из автодневника видно и однократный
//  перенос для тех, кто уже вёл записи. Решения — CarLog (чистое, с тестом).
//

import UIKit
import os

extension AppEnvironment {

    var carLogState: CarLog.State {
        CarLog.State(enabled: settings.carLog, workDriver: settings.workDriverMode)
    }

    func showsCarLog(_ surface: CarLog.Surface) -> Bool {
        CarLog.shows(surface, carLogState)
    }

    /// Переключатель сменился: напоминания об обслуживании следуют за ним.
    func carLogChanged() {
        refreshMaintenanceReminders(moment: .opened)
    }

    /// Однократно: записи на телефоне есть — дневник включён. До разблокировки
    /// хранилище читается пустым, и «записей нет» было бы ложью.
    func migrateCarLogIfNeeded() {
        guard UIApplication.shared.isProtectedDataAvailable, !Storage.bool(.carLogMigrated1) else { return }
        let profile = settings.fuelProfile
        let records = CarLog.Records(
            journalEntries: energyJournal.entries.count,
            journalLoaded: energyJournal.isLoaded,
            workShifts: Storage.decoded([WorkShift].self, for: .workShiftLog)?.count ?? 0,
            workDriver: settings.workDriverMode,
            maintenanceFilled: maintenance.book != MaintenanceBook(),
            fuelProfileFilled: profile.setupDone == true || !profile.isBlank)
        guard let enabled = CarLog.migrated(records) else { return }
        Storage.set(true, for: .carLogMigrated1)
        guard enabled, !settings.carLog else { return }
        settings.carLog = true
        Log.app.notice("«Машина и расходы» включены переносом: записи уже есть")
        carLogChanged()
    }
}
