//
//  EnergyNumber.swift
//  RadarMap
//
//  Одно число «Машины и расходов» (21.10): что это, в чём, где лежит в
//  профиле и как проверить, правдоподобно ли. Строка сводки, шаг мастера и
//  лист правки работают с одним и тем же числом — поэтому описание одно.
//
//  Чистая логика (запись/чтение и отметка цены) — EnergySplitTests.
//

import Foundation

nonisolated enum EnergyNumber: Hashable, Identifiable, Sendable {
    /// Расход на 100 км. Электричество — цифра с панели машины.
    case per100(Fuel)
    /// Цена топлива за единицу (бензин, метан, пропан).
    case price(Fuel)
    /// Свет дома, сум/кВт·ч — прежняя единственная цена электричества.
    case homePrice
    case stationPrice
    case battery
    case passport
    case realRange

    var id: String {
        switch self {
        case .per100(let fuel): return "per100-\(fuel.rawValue)"
        case .price(let fuel): return "price-\(fuel.rawValue)"
        case .homePrice: return "homePrice"
        case .stationPrice: return "stationPrice"
        case .battery: return "battery"
        case .passport: return "passport"
        case .realRange: return "realRange"
        }
    }

    var isPrice: Bool {
        switch self {
        case .price, .homePrice, .stationPrice: return true
        default: return false
        }
    }

    /// Десятые нужны расходу и ёмкости, не цене и не километрам.
    var decimals: Bool {
        switch self {
        case .per100, .battery: return true
        default: return false
        }
    }

    func value(in profile: FuelProfile) -> Double {
        switch self {
        case .per100(let fuel): return profile.rate(fuel).per100Km
        case .price(let fuel): return profile.rate(fuel).price
        case .homePrice: return profile.rate(.electricity).price
        case .stationPrice: return profile.stationPrice ?? 0
        case .battery: return profile.batteryKWh ?? 0
        case .passport: return profile.evPassportKm ?? 0
        case .realRange: return profile.evRealKm ?? 0
        }
    }

    /// Записать число; пусто (0) — «не указано». Цена отмечает время правки
    /// только если изменилась: открыть поле и закрыть — не обновление цены.
    func set(_ raw: Double, in profile: inout FuelProfile, now: Date) {
        let value = max(0, min(raw, limit))
        guard value != self.value(in: profile) else { return }
        let optional: Double? = value > 0 ? value : nil
        switch self {
        case .per100(let fuel):
            var rate = profile.rate(fuel)
            rate.per100Km = value
            profile.rates[fuel] = rate
        case .price(let fuel):
            var rate = profile.rate(fuel)
            rate.price = value
            profile.rates[fuel] = rate
        case .homePrice:
            var rate = profile.rate(.electricity)
            rate.price = value
            profile.rates[.electricity] = rate
        case .stationPrice: profile.stationPrice = optional
        case .battery: profile.batteryKWh = optional
        case .passport: profile.evPassportKm = optional
        case .realRange: profile.evRealKm = optional
        }
        if isPrice { profile.pricesUpdatedAt = now }
    }

    /// Верхняя граница поля — от случайного лишнего нуля, а не правдоподобие
    /// (его говорит EnergyHints).
    private var limit: Double {
        switch self {
        case .per100: return 100
        case .price, .homePrice, .stationPrice: return 1_000_000
        case .battery: return 300
        case .passport, .realRange: return 2_000
        }
    }

    /// Что проверять подсказкой правдоподобия.
    func hint(_ energy: VehicleEnergy) -> EnergyHints.Field {
        switch self {
        case .per100(let fuel):
            switch fuel {
            case .petrol: return .petrol(energy)
            case .methane: return .methane
            case .propane: return .propane
            case .electricity: return .kWh
            }
        case .price(let fuel): return .price(fuel)
        case .homePrice, .stationPrice: return .price(.electricity)
        case .battery: return .battery(energy)
        case .passport: return .passportRange(energy)
        case .realRange: return .realRange(energy)
        }
    }

    /// Числа расхода для машины — в порядке мастера.
    static func consumption(for energy: VehicleEnergy, profile: FuelProfile) -> [EnergyNumber] {
        switch energy {
        case .fuel, .hev, .hybrid: return [.per100(.petrol)]
        case .cng: return profile.secondShare > 0 ? [.per100(.methane), .per100(.petrol)] : [.per100(.methane)]
        case .lpg: return profile.secondShare > 0 ? [.per100(.propane), .per100(.petrol)] : [.per100(.propane)]
        case .electric: return []
        }
    }

    /// Цены, которые нужны для суммы, — по топливу и месту зарядки.
    static func prices(for energy: VehicleEnergy, profile: FuelProfile) -> [EnergyNumber] {
        var electricity: [EnergyNumber] {
            switch profile.chargePlace ?? .home {
            case .home: return [.homePrice]
            case .station: return [.stationPrice]
            case .both: return [.homePrice, .stationPrice]
            }
        }
        switch energy {
        case .fuel, .hev: return [.price(.petrol)]
        case .cng: return profile.secondShare > 0 ? [.price(.methane), .price(.petrol)] : [.price(.methane)]
        case .lpg: return profile.secondShare > 0 ? [.price(.propane), .price(.petrol)] : [.price(.propane)]
        case .electric: return electricity
        case .hybrid: return electricity + [.price(.petrol)]
        }
    }
}
