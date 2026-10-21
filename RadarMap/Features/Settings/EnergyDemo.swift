//
//  EnergyDemo.swift
//  RadarMap
//
//  DEBUG: «Машина и расходы» на снимок без ручного ввода (21.10).
//  `-demoEnergy` — гибрид с розеткой владельца (CLTC 120 км, 18,3 кВт·ч,
//  заряд каждую ночь дома); `-demoLongTrip` вместе с ним — поездка 300 км
//  по трассе позавчера; `-demoEnergyLegacy` — гибрид, настроенный до 21.10
//  одной долей (вопрос про розетку); `-demoEnergyBlank` — пустой профиль
//  (мастер). В релизную сборку не попадает.
//

#if DEBUG
import Foundation
import CoreLocation

enum EnergyDemo {
    static func seed(_ env: AppEnvironment, args: [String]) {
        let settings = env.settings
        if args.contains("-demoEnergyBlank") {
            settings.vehicleEnergy = .fuel
            settings.fuelProfile = FuelProfile()
            return
        }
        if args.contains("-demoEnergyLegacy") {
            settings.vehicleEnergy = .hybrid
            settings.fuelProfile = FuelProfile(
                rates: [.petrol: FuelRate(per100Km: 6, price: 13_000),
                        .electricity: FuelRate(per100Km: 15, price: 1_000)],
                secondShare: 0.6, pricesUpdatedAt: Date().addingTimeInterval(-3 * 86_400))
            return
        }
        var profile = FuelProfile()
        profile.rates = [.petrol: FuelRate(per100Km: 5.5, price: 13_000),
                         .electricity: FuelRate(per100Km: 0, price: 1_000)]
        profile.evPassportKm = 120
        profile.evCycle = .cltc
        profile.batteryKWh = 18.3
        profile.chargeSchedule = .nightly
        profile.chargePlace = .home
        profile.stationPrice = 2_500
        profile.pricesUpdatedAt = Date().addingTimeInterval(-5 * 86_400)
        profile.hybridPlugConfirmed = true
        profile.setupDone = true
        settings.vehicleEnergy = .hybrid
        settings.fuelProfile = profile
        if args.contains("-demoLongTrip") { addLongTrip(env) }
    }

    /// Ташкент — Самарканд позавчера: 300 км, трасса 100 км/ч, посёлки по 50.
    private static func addLongTrip(_ env: AppEnvironment) {
        let calendar = Calendar.current
        guard let day = calendar.date(byAdding: .day, value: -2, to: calendar.startOfDay(for: Date())) else { return }
        let start = day.addingTimeInterval(9 * 3_600)
        let from = CLLocationCoordinate2D(latitude: 41.311, longitude: 69.279)
        let to = CLLocationCoordinate2D(latitude: 39.654, longitude: 66.975)
        let steps = 300
        var track: [Double] = []
        for step in 0...steps {
            let t = Double(step) / Double(steps)
            let speed = step % 40 < 4 ? 50.0 : 100.0
            track += [from.latitude + (to.latitude - from.latitude) * t,
                      from.longitude + (to.longitude - from.longitude) * t, speed]
        }
        let record = TripRecord(id: start.timeIntervalSince1970, startedAt: start,
                                endedAt: start.addingTimeInterval(3.5 * 3_600), distanceMeters: 300_000,
                                maxSpeedKmh: 108, passed: [], endLat: to.latitude, endLon: to.longitude,
                                track: track, score: 92, endedManually: true)
        let history = (env.trip.history.filter { $0.id != record.id } + [record])
            .sorted { $0.startedAt > $1.startedAt }
        env.trip.applyRestored(history: history, days: TripDayBook.rebuilt(from: history),
                               lifetime: LifetimeStats.rebuilt(from: history))
    }
}
#endif
