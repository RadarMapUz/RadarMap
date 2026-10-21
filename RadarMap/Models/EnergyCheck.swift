//
//  EnergyCheck.swift
//  RadarMap
//
//  «Сверить с машиной» (план 21.10, 21.5): водитель вводит, что за период
//  показывает панель машины — долю на электричестве, кВт·ч и литры на
//  100 км, — приложение сравнивает со своим расчётом и предлагает поправить
//  запас хода или расход одним касанием. Так оценка становится точной за
//  минуту, а не «по паспорту навсегда».
//
//  Поправка запаса — не пропорция, а подбор: доля на электричестве зависит
//  от того, как легли поездки по дням (короткий день доли не меняет вовсе),
//  поэтому запас ищется тем же расчётом EnergySplit по тем же дням, пока
//  доля не совпадёт с панелью.
//
//  Чистая логика — EnergyCheckTests.
//

import Foundation

nonisolated enum EnergyCheck {

    /// Что показывает панель машины; nil — водитель это поле не заполнил.
    struct Panel: Equatable, Sendable {
        /// Доля пути на электричестве, 0…1.
        var electricShare: Double?
        var kWhPer100: Double?
        var litresPer100: Double?
    }

    /// Что посчитали мы за тот же период.
    struct Estimate: Equatable, Sendable {
        var electricShare: Double?
        var kWhPer100: Double
        var kWhIsEstimate: Bool
        var litresPer100: Double?
        var meters: Double
    }

    /// Одна поправка — одним касанием.
    enum Suggestion: Equatable, Sendable {
        /// Реальный запас, км.
        case realRange(from: Double?, to: Double)
        case kWhPer100(from: Double, to: Double)
        case litresPer100(from: Double?, to: Double)
    }

    struct Result: Equatable, Sendable {
        var estimate: Estimate
        var suggestions: [Suggestion]
        /// Сверка была (хоть одно поле) и всё сошлось.
        var allMatch: Bool
    }

    static func compare(panel: Panel, days: [EnergySplit.Day], profile: FuelProfile,
                        energy: VehicleEnergy, calendar: Calendar = .current) -> Result {
        let model = EnergySplit.model(profile: profile, energy: energy)
        let use = EnergySplit.split(days, model: model, calendar: calendar).days.values
            .reduce(EnergySplit.Use(), +)
        let petrol = profile.rate(.petrol).per100Km
        let kWh = profile.kWhPer100
        let estimate = Estimate(electricShare: use.electricShare, kWhPer100: kWh.value,
                                kWhIsEstimate: kWh.isEstimate, litresPer100: petrol > 0 ? petrol : nil,
                                meters: use.totalMeters)
        var suggestions: [Suggestion] = []
        var compared = false

        if energy == .hybrid, let target = panel.electricShare {
            compared = true
            let ours = estimate.electricShare
            if ours.map({ abs($0 - target) > AppConfig.energyCheckSharePoints }) ?? true,
               let range = rangeMatching(share: target, days: days, profile: profile, calendar: calendar) {
                let current = profile.realRangeKm
                if current.map({ abs($0 - range) >= AppConfig.energyCheckMinRangeStepKm }) ?? true {
                    suggestions.append(.realRange(from: current, to: range))
                }
            }
        }
        if energy.plugs, let target = panel.kWhPer100, target > 0 {
            compared = true
            if kWh.isEstimate || differs(kWh.value, target) {
                suggestions.append(.kWhPer100(from: kWh.value, to: target))
            }
        }
        if energy != .electric, let target = panel.litresPer100, target > 0 {
            compared = true
            if petrol <= 0 || differs(petrol, target) {
                suggestions.append(.litresPer100(from: petrol > 0 ? petrol : nil, to: target))
            }
        }
        return Result(estimate: estimate, suggestions: suggestions, allMatch: compared && suggestions.isEmpty)
    }

    /// Расход разошёлся больше чем на 5 % от цифры панели.
    private static func differs(_ ours: Double, _ panel: Double) -> Bool {
        abs(ours - panel) / panel > AppConfig.energyCheckConsumptionShare
    }

    /// Реальный запас, при котором наш расчёт по этим дням даёт долю панели.
    /// nil — такой доли не получить ни при каком запасе в разумных границах
    /// (например, «0 %» при ежедневной зарядке — значит, график не тот).
    static func rangeMatching(share target: Double, days: [EnergySplit.Day], profile: FuelProfile,
                              calendar: Calendar = .current) -> Double? {
        let schedule = profile.chargeSchedule ?? .nightly
        guard let every = schedule.everyDays else { return nil }
        func share(_ range: Double) -> Double? {
            var model = EnergySplit.model(profile: profile, energy: .hybrid)
            model.kind = .plugIn(rangeKm: range, everyDays: every)
            return EnergySplit.split(days, model: model, calendar: calendar).days.values
                .reduce(EnergySplit.Use(), +).electricShare
        }
        let bounds = AppConfig.energyCheckRangeSearch
        guard let low = share(bounds.lowerBound), let high = share(bounds.upperBound) else { return nil }
        let goal = min(1, max(0, target))
        guard goal >= low - AppConfig.energyCheckSharePoints,
              goal <= high + AppConfig.energyCheckSharePoints else { return nil }
        // Доля не убывает с запасом: ищем наименьший запас, дающий долю панели.
        var lo = bounds.lowerBound, hi = bounds.upperBound
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if (share(mid) ?? 0) >= goal - 0.0005 { hi = mid } else { lo = mid }
        }
        return hi.rounded()
    }

    /// Принять поправку — новый профиль.
    static func apply(_ suggestion: Suggestion, to profile: FuelProfile) -> FuelProfile {
        var result = profile
        switch suggestion {
        case .realRange(_, let to):
            result.evRealKm = to
        case .kWhPer100(_, let to):
            var rate = result.rate(.electricity)
            rate.per100Km = to
            result.rates[.electricity] = rate
        case .litresPer100(_, let to):
            var rate = result.rate(.petrol)
            rate.per100Km = to
            result.rates[.petrol] = rate
        }
        return result
    }
}

/// Проверка правдоподобия чисел, которые водитель вводит сам: опечатка в
/// расходе молча врала бы в каждой поездке. Не запрет — подсказка: «40 л» —
/// «проверьте, это на 100 км?».
nonisolated enum EnergyHints {
    enum Field: Equatable, Sendable {
        case petrol(VehicleEnergy)
        case methane, propane, kWh
        case passportRange(VehicleEnergy)
        case realRange(VehicleEnergy)
        case battery(VehicleEnergy)
        case price(Fuel)
    }

    enum Verdict: Equatable, Sendable {
        case ok
        /// Вне обычного — «обычно 4–6».
        case unusual
        /// Похоже на другую единицу или на весь бак — «это на 100 км?».
        case wrongScale
    }

    /// Обычные значения — то, что подсказка называет словами.
    static func typical(_ field: Field) -> ClosedRange<Double> {
        switch field {
        case .petrol(let energy):
            switch energy {
            case .hev, .hybrid: return 4...6
            default: return 6...12
            }
        case .methane: return 7...10
        case .propane: return 9...12
        case .kWh: return 14...20
        case .passportRange(let energy): return energy == .electric ? 350...600 : 60...200
        case .realRange(let energy): return energy == .electric ? 250...500 : 45...150
        case .battery(let energy): return energy == .electric ? 40...90 : 10...35
        case .price(let fuel):
            switch fuel {
            case .electricity: return 500...4_000
            case .petrol: return 9_000...16_000
            case .methane: return 3_000...8_000
            case .propane: return 5_000...10_000
            }
        }
    }

    /// Границы правдоподобного: внутри — «ок», чуть за — «необычно», а
    /// дальше — «другая единица».
    private static func accepted(_ field: Field) -> ClosedRange<Double> {
        switch field {
        case .petrol(let energy):
            switch energy {
            case .hev, .hybrid: return 2.5...10
            default: return 3...18
            }
        case .methane: return 4...16
        case .propane: return 5...18
        case .kWh: return 9...32
        case .passportRange(let energy): return energy == .electric ? 100...1_100 : 20...400
        case .realRange(let energy): return energy == .electric ? 80...900 : 15...320
        case .battery(let energy): return energy == .electric ? 15...150 : 4...60
        case .price(let fuel):
            switch fuel {
            case .electricity: return 100...10_000
            case .petrol: return 4_000...40_000
            case .methane: return 1_000...20_000
            case .propane: return 2_000...25_000
            }
        }
    }

    static func check(_ value: Double, _ field: Field) -> Verdict {
        guard value > 0 else { return .ok }
        let ok = accepted(field)
        if ok.contains(value) { return .ok }
        // В разы больше или меньше — почти наверняка не та единица (расход
        // на бак, цена в тысячах).
        if value > ok.upperBound * 2 || value < ok.lowerBound / 2 { return .wrongScale }
        return .unusual
    }
}
