//
//  CarLog.swift
//  RadarMap
//
//  Автодневник — расходы, журнал заправок, обслуживание, смены таксиста и
//  выгрузки — за одним переключателем «Машина и расходы» (план 78).
//  Большинству нужен антирадар, а не бухгалтерия: у новой установки
//  дневник выключен, у тех, кто уже вёл записи, включается один раз сам.
//  Данные при выключении не стираются — только прячется их интерфейс.
//
//  Чистая логика — CarLogTests.
//

import Foundation

nonisolated enum CarLog {

    /// Места интерфейса, которые принадлежат дневнику.
    enum Surface: CaseIterable, Sendable {
        /// «Расходы» в «Итогах», стоимость поездки в её деталях.
        case expenses
        /// Журнал заправок и зарядок, цены, расход, мастер настройки.
        case journal
        /// Обслуживание: строка «Итогов», ссылки в настройках, напоминания.
        case maintenance
        /// «Смены» в «Итогах».
        case shifts
        /// Переключатель «Работаю водителем».
        case workDriver
        /// Выгрузка периода (CSV/PDF), архив поездок и треки GPX.
        case export
    }

    struct State: Equatable, Sendable {
        var enabled: Bool
        /// «Работаю водителем» включён прямо сейчас.
        var workDriver = false
    }

    /// Показывать ли место интерфейса. Включённый режим водителя виден и при
    /// выключенном дневнике: иначе его не выключить, а он меняет голос и учёбу.
    static func shows(_ surface: Surface, _ state: State) -> Bool {
        if state.enabled { return true }
        switch surface {
        case .workDriver, .shifts: return state.workDriver
        case .expenses, .journal, .maintenance, .export: return false
        }
    }

    /// Что уже лежит на телефоне — для однократного переноса.
    struct Records: Equatable, Sendable {
        var journalEntries = 0
        /// Журнал заправок прочитан с диска (до этого «пусто» — не ответ).
        var journalLoaded = false
        var workShifts = 0
        var workDriver = false
        var maintenanceFilled = false
        var fuelProfileFilled = false
    }

    /// Включить ли дневник тому, кто обновился: да — если записи есть хоть
    /// где-то; нет — только когда журнал прочитан и пуст вместе с остальным;
    /// nil — ждать чтения журнала.
    static func migrated(_ records: Records) -> Bool? {
        if records.journalEntries > 0 || records.workShifts > 0 || records.workDriver
            || records.maintenanceFilled || records.fuelProfileFilled {
            return true
        }
        return records.journalLoaded ? false : nil
    }
}
