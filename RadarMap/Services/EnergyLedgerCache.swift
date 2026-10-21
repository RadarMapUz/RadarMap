//
//  EnergyLedgerCache.swift
//  RadarMap
//
//  Расходы по всей истории (EnergySplit) — один расчёт на изменение данных.
//
//  Экраны (деталь поездки, «Итоги», дорога на работу, смены, страница
//  машины) читают `env.energyLedger`. Пересчёт — только когда сменились
//  поездки (`TripStats.dataRevision`), профиль или тип машины: эти три
//  свойства наблюдаемы, и вью, прочитавшая расчёт, перерисуется сама, а
//  кэш ниже наблюдение не дёргает (иначе запись в него из body была бы
//  правкой состояния во время отрисовки).
//
//  Цена расчёта — проход по дням (годы — сотни строк) и по трекам записей
//  в памяти: около 7 мс на три года истории на симуляторе (EnergySplitTests,
//  бюджет). Почти всё это — разбор треков, а он зависит только от поездок:
//  дни для расчёта кэшируются отдельно по `dataRevision`, и правка цифры в
//  мастере (на каждое нажатие) пересчитывает лишь сам расклад — доли
//  миллисекунды. Синхронно: результат нужен в этом же кадре.
//

import Foundation

@MainActor
final class EnergyLedgerCache {
    static let shared = EnergyLedgerCache()

    private struct Key: Equatable {
        let revision: Int
        let profile: FuelProfile
        let energy: VehicleEnergy
    }

    private var cached: (key: Key, ledger: EnergySplit.Ledger)?
    /// Дни для расчёта (с долей трассы по трекам) — только от поездок.
    private var inputs: (revision: Int, days: [EnergySplit.Day])?

    func ledger(trip: TripStats, settings: AppSettings) -> EnergySplit.Ledger {
        let key = Key(revision: trip.dataRevision, profile: settings.fuelProfile, energy: settings.vehicleEnergy)
        if let cached, cached.key == key { return cached.ledger }
        let days: [EnergySplit.Day]
        if let inputs, inputs.revision == key.revision {
            days = inputs.days
        } else {
            days = EnergySplit.days(tripDays: trip.days, records: trip.history)
            inputs = (key.revision, days)
        }
        let built = EnergySplit.split(days, model: EnergySplit.model(profile: key.profile, energy: key.energy))
        cached = (key, built)
        return built
    }
}

extension AppEnvironment {
    /// Расходы по всей истории: по поездкам и по дням (EnergySplit).
    var energyLedger: EnergySplit.Ledger {
        EnergyLedgerCache.shared.ledger(trip: trip, settings: settings)
    }
}
