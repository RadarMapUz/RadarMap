//
//  EnergyText+Numbers.swift
//  RadarMap
//
//  Подписи чисел «Машины и расходов» (21.10): название, единица, пример в
//  пустом поле, подпись голосом, обычные значения и предупреждение о
//  неправдоподобной цифре, откуда взялись реальный запас и расход.
//

import Foundation

extension EnergyText {

    static func title(_ number: EnergyNumber, energy: VehicleEnergy) -> String {
        switch number {
        case .per100(let fuel):
            switch fuel {
            case .petrol:
                switch energy {
                case .hybrid: return String(localized: "Бензин, когда батарея села")
                case .cng, .lpg: return String(localized: "Бензин, когда газа нет")
                default: return String(localized: "Расход бензина")
                }
            case .methane: return String(localized: "Расход метана")
            case .propane: return String(localized: "Расход пропана")
            case .electricity: return String(localized: "Расход с панели машины")
            }
        case .price(let fuel): return fuel.title
        case .homePrice: return String(localized: "Свет дома")
        case .stationPrice: return String(localized: "Зарядная станция")
        case .battery: return String(localized: "Ёмкость батареи")
        case .passport: return String(localized: "Запас на электричестве по паспорту")
        case .realRange: return String(localized: "Реальный запас в городе")
        }
    }

    /// Единица в цене: «за л», «за кВт·ч».
    static func priceUnit(_ number: EnergyNumber) -> String {
        switch number {
        case .price(let fuel): return fuel.unit
        default: return Fuel.electricity.unit
        }
    }

    /// Единица справа от поля.
    static func unit(_ number: EnergyNumber) -> String {
        switch number {
        case .per100(let fuel): return String(format: String(localized: "%@ на 100 км"), fuel.unit)
        case .price(let fuel): return String(format: String(localized: "сум за %@"), fuel.unit)
        case .homePrice, .stationPrice: return String(format: String(localized: "сум за %@"), Fuel.electricity.unit)
        case .battery: return Fuel.electricity.unit
        case .passport, .realRange: return String(localized: "км")
        }
    }

    static func placeholder(_ number: EnergyNumber, energy: VehicleEnergy) -> String {
        switch number {
        case .per100(let fuel):
            switch fuel {
            case .petrol: return energy == .hybrid || energy == .hev ? "5" : "9"
            case .methane: return "9"
            case .propane: return "11"
            case .electricity: return "16"
            }
        case .battery: return energy == .electric ? "60" : "18"
        case .passport: return energy == .electric ? "450" : "120"
        case .realRange: return energy == .electric ? "350" : "90"
        case .price, .homePrice, .stationPrice: return "—"
        }
    }

    /// Подпись поля голосом — единица словами: «м³» голосом не читается.
    static func spokenTitle(_ number: EnergyNumber, energy: VehicleEnergy) -> String {
        let unit: String
        switch number {
        case .per100(let fuel):
            switch fuel {
            case .petrol, .propane: unit = String(localized: "литров на 100 километров")
            case .methane: unit = String(localized: "кубометров на 100 километров")
            case .electricity: unit = String(localized: "киловатт-часов на 100 километров")
            }
        case .price(let fuel):
            switch fuel {
            case .petrol, .propane: unit = String(localized: "сумов за литр")
            case .methane: unit = String(localized: "сумов за кубометр")
            case .electricity: unit = String(localized: "сумов за киловатт-час")
            }
        case .homePrice, .stationPrice: unit = String(localized: "сумов за киловатт-час")
        case .battery: unit = String(localized: "киловатт-часов")
        case .passport, .realRange: unit = String(localized: "километров")
        }
        return "\(title(number, energy: energy)), \(unit)"
    }

    /// Обычные значения под полем: «Обычно 4–6 л на 100 км». У цен — нет:
    /// цены меняются, и «обычно» через месяц стало бы неправдой.
    static func hint(_ number: EnergyNumber, energy: VehicleEnergy) -> String? {
        switch number {
        case .price, .homePrice, .stationPrice:
            return number == .homePrice
                ? String(localized: "Из квитанции за свет. Цена — только на этом телефоне.") : nil
        case .battery:
            return String(localized: "Есть в документах. Необязательно — без неё расход будет оценкой.")
        case .per100(.electricity):
            return String(localized: "Средний расход из бортового компьютера — если знаете, он точнее всего.")
        default:
            let range = EnergyHints.typical(number.hint(energy))
            return String(format: String(localized: "Обычно %1$@–%2$@ %3$@"),
                          EnergyText.number(range.lowerBound, maxDigits: 0),
                          EnergyText.number(range.upperBound, maxDigits: 0), unit(number))
        }
    }

    static func warning(_ verdict: EnergyHints.Verdict, number: EnergyNumber) -> String {
        switch (verdict, number) {
        case (.wrongScale, .per100): return String(localized: "Проверьте: это на 100 км?")
        case (.wrongScale, .price), (.wrongScale, .homePrice), (.wrongScale, .stationPrice):
            return String(localized: "Проверьте: это цена за одну единицу, в сумах?")
        case (.wrongScale, _): return String(localized: "Похоже на опечатку — проверьте цифру.")
        default: return String(localized: "Необычно для такой машины — проверьте цифру.")
        }
    }

    /// Откуда реальный запас — под крупной цифрой.
    static func realSource(_ profile: FuelProfile) -> String {
        if let real = profile.evRealKm, real > 0 { return String(localized: "Указали сами") }
        let cycle = profile.evCycle ?? .cltc
        return String(format: String(localized: "%1$@ по %2$@ × %3$@ — поправьте, если знаете свой"),
                      km(profile.evPassportKm ?? 0), cycle.title, number(cycle.factor, maxDigits: 2))
    }

    /// Откуда расход электричества.
    static func kWhSource(_ profile: FuelProfile) -> String {
        if profile.rate(.electricity).per100Km > 0 { return String(localized: "С панели машины") }
        if let battery = profile.batteryKWh, battery > 0, let range = profile.realRangeKm {
            return String(format: String(localized: "%1$@ × %2$@ ÷ %3$@ — из ёмкости и реального запаса"),
                          amount(battery, .electricity), number(AppConfig.energyUsableBatteryShare), km(range))
        }
        return String(localized: "Оценка — укажите ёмкость батареи или цифру с панели")
    }
}
