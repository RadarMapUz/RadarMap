//
//  EnergySplit+Examples.swift
//  RadarMap
//
//  Примеры для страницы «Машина и расходы» (21.3): «ваш обычный день»
//  (медиана своих дней), «длинная поездка» (своя самая длинная за месяц
//  или пример по трассе) и «на бензине вышло бы». Тот же расчёт EnergySplit
//  — отдельным днём с полным зарядом. Тесты — EnergySplitTests.
//

import Foundation

nonisolated extension EnergySplit {

    /// Путь отдельным днём с полным зарядом — «ваш обычный день» и «длинная
    /// поездка» на странице машины.
    static func example(meters: Double, highwayMeters: Double? = nil, model: Model) -> Use {
        var budget = model.rangeKm.map { $0 * 1_000 } ?? 0
        return use(Trip(id: nil, start: .distantPast, meters: meters, highwayMeters: highwayMeters),
                   model: model, budget: &budget)
    }

    /// «Ваш обычный день»: медиана дней с поездками за окно; nil — таких
    /// дней меньше порога, и сводка покажет пример с подписью.
    static func usualDayMeters(tripDays: [TripDay], now: Date, calendar: Calendar = .current) -> Double? {
        guard let since = calendar.date(byAdding: .day, value: -AppConfig.energyUsualDayWindowDays,
                                        to: calendar.startOfDay(for: now)) else { return nil }
        let distances = tripDays.filter { $0.day >= since && $0.day <= now && $0.distanceMeters > 0 }
            .map(\.distanceMeters).sorted()
        guard distances.count >= AppConfig.energyUsualDayMinDays else { return nil }
        let middle = distances.count / 2
        return distances.count % 2 == 1 ? distances[middle] : (distances[middle - 1] + distances[middle]) / 2
    }

    /// Длинная поездка для сводки: своя самая длинная за 30 дней — если она
    /// длиннее запаса (иначе ничего не покажет); иначе — пример по трассе.
    struct LongTrip: Equatable, Sendable {
        var meters: Double
        var highwayMeters: Double?
        /// Своя поездка, а не пример.
        var isOwn: Bool
    }

    static func longTrip(records: [TripRecord], model: Model, now: Date) -> LongTrip {
        let since = now.addingTimeInterval(-30 * 86_400)
        let floor = max(model.rangeKm ?? 0, 100) * 1_000
        if let longest = records.filter({ $0.startedAt >= since }).max(by: { $0.distanceMeters < $1.distanceMeters }),
           longest.distanceMeters > floor {
            return LongTrip(meters: longest.distanceMeters, highwayMeters: highwayMeters(of: longest), isOwn: true)
        }
        let example = AppConfig.energyExampleLongTripKm * 1_000
        return LongTrip(meters: example, highwayMeters: example, isOwn: false)
    }

    /// «На бензине вышло бы»: тот же путь целиком на бензине по расходу и
    /// цене, которые водитель указал. nil — не указал.
    static func allPetrolCost(meters: Double, model: Model) -> Double? {
        guard meters > 0, let per100 = model.per100[.petrol], per100 > 0,
              let price = model.price[.petrol], price > 0 else { return nil }
        return meters / 100_000 * per100 * price
    }
}
