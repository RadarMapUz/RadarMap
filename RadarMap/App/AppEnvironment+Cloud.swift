//
//  AppEnvironment+Cloud.swift
//  RadarMap
//
//  Поездки в iCloud (27.F): какие данные синхронизируются — решается здесь,
//  в композиционном корне, потому что они лежат в пяти разных хранилищах.
//  Сами хранилища про iCloud не знают; CloudSources — переходники к ним.
//

import Foundation

extension AppEnvironment {
    func wireCloud() {
        cloud.configure(sources: [TripCloudSource(trip: trip),
                                  SummaryCloudSource(trip: trip),
                                  JournalCloudSource(store: energyJournal),
                                  FineCloudSource(store: fines),
                                  FamilyCloudSource(family: family),
                                  PlaceCloudSource(settings: settings),
                                  VehicleCloudSource(settings: settings)],
                        settings: settings)
        // Разбор истории с диска (первая выгрузка) — не на горячем телефоне и
        // не в энергосбережении: истории не к спеху.
        cloud.mayScan = { [weak thermal] in
            !ProcessInfo.processInfo.isLowPowerModeEnabled && thermal?.mode == .full
        }
        #if DEBUG
        cloud.applyDemoArguments(ProcessInfo.processInfo.arguments)
        #endif
    }
}
