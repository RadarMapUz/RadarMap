//
//  FuelCost.swift
//  RadarMap
//
//  Сколько стоит дорога (план 19.10, 12б.3). Расход и цену знает только
//  водитель: цен по умолчанию нет — они меняются, и подставленная «средняя
//  по Ташкенту» через месяц соврала бы в каждой поездке. Через 60 дней
//  после последней правки цены приложение просит её обновить.
//
//  Вид топлива — из настройки «Машина» (VehicleEnergy), которая уже решает
//  плитки «АЗС/Метан/Зарядка» в CarPlay: машина на метане ездит на метане и
//  иногда на бензине, гибрид с розеткой — на бензине и иногда от сети.
//  Второе топливо — долей пробега (0…1).
//
//  Задним числом стоимость не хранится: старая поездка считается по
//  нынешней цене и помечается «по нынешней цене» — честнее, чем делать
//  вид, что мы знаем, сколько стоил литр в прошлом месяце.
//
//  Чистая логика — FuelCostTests.
//

import Foundation

/// Чем заправляется машина. Единица — то, в чём продают на заправке.
nonisolated enum Fuel: String, Codable, CodingKeyRepresentable, CaseIterable, Sendable {
    case petrol, methane, propane, electricity

    var title: String {
        switch self {
        case .petrol: return String(localized: "Бензин")
        case .methane: return String(localized: "Метан")
        case .propane: return String(localized: "Пропан")
        case .electricity: return String(localized: "Электричество")
        }
    }

    /// Единица продажи: литр, кубометр, киловатт-час.
    var unit: String {
        switch self {
        case .petrol, .propane: return String(localized: "л")
        case .methane: return String(localized: "м³")
        case .electricity: return String(localized: "кВт·ч")
        }
    }
}

/// Расход и цена одного вида топлива.
nonisolated struct FuelRate: Codable, Equatable, Sendable {
    /// Единиц на 100 км; 0 — не задан.
    var per100Km: Double = 0
    /// Сумов за единицу; 0 — не задана.
    var price: Double = 0

    var isSet: Bool { per100Km > 0 && price > 0 }
    /// Сумов на метр пути.
    var costPerMeter: Double { per100Km / 100_000 * price }
}

/// Всё, что водитель сказал о расходе. По виду топлива — свой расход и цена:
/// поменял «Машину» с метана на бензин — прежние цифры метана не пропали.
nonisolated struct FuelProfile: Codable, Equatable, Sendable {
    var rates: [Fuel: FuelRate] = [:]
    /// Доля пробега на втором топливе (0…1).
    var secondShare: Double = 0
    /// Когда последний раз правили цену — от него «обновите цены».
    var pricesUpdatedAt: Date?

    func rate(_ fuel: Fuel) -> FuelRate { rates[fuel] ?? FuelRate() }
}

extension VehicleEnergy {
    /// Основное и второе топливо машины.
    nonisolated var fuels: (primary: Fuel, second: Fuel?) {
        switch self {
        case .fuel: return (.petrol, nil)
        case .cng: return (.methane, .petrol)
        case .lpg: return (.propane, .petrol)
        case .electric: return (.electricity, nil)
        case .hybrid: return (.petrol, .electricity)
        }
    }
}

nonisolated enum FuelCost {
    /// Сумов на метр пути; nil — расход или цена основного топлива не заданы
    /// (или второго, если на нём есть доля пробега).
    static func costPerMeter(profile: FuelProfile, energy: VehicleEnergy) -> Double? {
        let (primary, second) = energy.fuels
        let main = profile.rate(primary)
        guard main.isSet else { return nil }
        guard let second, profile.secondShare > 0 else { return main.costPerMeter }
        let other = profile.rate(second)
        guard other.isSet else { return nil }
        let share = min(1, max(0, profile.secondShare))
        return main.costPerMeter * (1 - share) + other.costPerMeter * share
    }

    /// Стоимость пути в сумах, округлённая для глаз; nil — профиль не готов.
    static func cost(meters: Double, profile: FuelProfile, energy: VehicleEnergy) -> Double? {
        guard let perMeter = costPerMeter(profile: profile, energy: energy) else { return nil }
        return rounded(max(0, meters) * perMeter)
    }

    /// До 100 сумов на малых суммах, до 1 000 — от 10 000: «12 300 сум» за
    /// поездку и «420 000 сум» за месяц, без ложной точности до сума.
    static func rounded(_ sum: Double) -> Double {
        let step = sum >= 10_000 ? 1_000.0 : 100.0
        return (sum / step).rounded() * step
    }

    /// Дорога на работу в месяц: сумма поездок этого направления за 30 дней
    /// окна. nil — профиль не готов или поездок за 30 дней нет.
    static func monthly(trips: [Commute.Trip], costPerMeter: Double?, now: Date) -> Double? {
        guard let costPerMeter else { return nil }
        let since = now.addingTimeInterval(-30 * 86_400)
        let meters = trips.filter { $0.departure >= since }.reduce(0) { $0 + $1.distanceMeters }
        guard meters > 0 else { return nil }
        return rounded(meters * costPerMeter)
    }

    /// Пора ли просить обновить цену: с последней правки прошло 60 дней.
    static func needsPriceUpdate(profile: FuelProfile, now: Date) -> Bool {
        guard let updated = profile.pricesUpdatedAt else { return false }
        return now.timeIntervalSince(updated) >= AppConfig.fuelPriceStaleDays * 86_400
    }

    /// Поездка закончилась до последней правки цены — сумма посчитана по
    /// нынешней цене, и об этом надо сказать.
    static func isAtCurrentPrice(endedAt: Date, profile: FuelProfile) -> Bool {
        guard let updated = profile.pricesUpdatedAt else { return false }
        return endedAt < updated
    }
}
