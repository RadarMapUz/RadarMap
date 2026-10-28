//
//  EnergyText.swift
//  RadarMap
//
//  Слова и строки «Машины и расходов» (21.10): названия типов, графиков и
//  мест зарядки, строки «27 км на электричестве · ≈ 4,3 кВт·ч» и формула
//  «как посчитано». Отдельно от вьюх — один источник для настроек, детали
//  поездки и «Итогов», и для VoiceOver — словами, без «≈» и сокращений.
//
//  Принцип экрана: каждая сумма раскрывается строкой, из которой видно,
//  правдоподобна ли она (план 21.10, 1.2).
//

import SwiftUI

enum EnergyText {

    // MARK: - Тип машины

    /// Символы — проверены на iOS 18 (EnergyIconsTests).
    static func symbol(_ energy: VehicleEnergy) -> String {
        switch energy {
        case .fuel: return "fuelpump.fill"
        case .cng: return "flame.fill"
        case .lpg: return "flame"
        case .hev: return "leaf.fill"
        case .hybrid: return "powerplug.fill"
        case .electric: return "bolt.car.fill"
        }
    }

    /// Что машина тратит — подпись под названием типа.
    static func subtitle(_ energy: VehicleEnergy) -> String {
        switch energy {
        case .fuel: return String(localized: "Бензин или дизель")
        case .cng: return String(localized: "Метан, иногда бензин")
        case .lpg: return String(localized: "Пропан, иногда бензин")
        case .hev: return String(localized: "Только бензин — Prius, Camry Hybrid")
        case .hybrid: return String(localized: "Электричество, потом бензин — BYD DM-i, Li Auto")
        case .electric: return String(localized: "Только электричество")
        }
    }

    /// Коротко — справа у строки в «Поездке».
    static func shortTitle(_ energy: VehicleEnergy) -> String {
        switch energy {
        case .fuel: return String(localized: "Бензин")
        case .cng: return String(localized: "Метан")
        case .lpg: return String(localized: "Пропан")
        case .hev: return String(localized: "Гибрид")
        case .hybrid: return String(localized: "С розеткой")
        case .electric: return String(localized: "Электро")
        }
    }

    static func schedule(_ schedule: ChargeSchedule) -> String {
        switch schedule {
        case .nightly: return String(localized: "Каждую ночь")
        case .everyOtherDay: return String(localized: "Через день")
        case .weekly: return String(localized: "Раз в неделю")
        case .rarely: return String(localized: "Почти никогда")
        }
    }

    static func scheduleSymbol(_ schedule: ChargeSchedule) -> String {
        switch schedule {
        case .nightly: return "moon.stars.fill"
        case .everyOtherDay: return "calendar"
        case .weekly: return "calendar.badge.clock"
        case .rarely: return "bolt.slash.fill"
        }
    }

    static func place(_ place: ChargePlace) -> String {
        switch place {
        // Не «Дома»: этот ключ в каталоге уже значит «дома́» (здания) на карте.
        case .home: return String(localized: "Дома, от розетки")
        case .station: return String(localized: "На станциях")
        case .both: return String(localized: "И там и там")
        }
    }

    static func placeSymbol(_ place: ChargePlace) -> String {
        switch place {
        case .home: return "house.fill"
        case .station: return "bolt.car.fill"
        case .both: return "arrow.left.arrow.right"
        }
    }

    // MARK: - Числа

    /// «на электричестве», «на бензине»…
    static func onFuel(_ fuel: Fuel) -> String {
        switch fuel {
        case .electricity: return String(localized: "на электричестве")
        case .petrol: return String(localized: "на бензине")
        case .methane: return String(localized: "на метане")
        case .propane: return String(localized: "на пропане")
        }
    }

    /// Число без лишнего нуля: «16», «18,3», «0,75»; разряды — пробелом.
    static func number(_ value: Double, maxDigits: Int = 1) -> String {
        value.formatted(.number.precision(.fractionLength(0...maxDigits))
            .rounded(rule: .toNearestOrAwayFromZero)
            .locale(Formatting.numberLocale))
    }

    /// «4,3 кВт·ч», «0,7 л».
    static func amount(_ value: Double, _ fuel: Fuel) -> String {
        Formatting.unbreakable("\(number(value)) \(fuel.unit)")
    }

    /// «18,3 кВт·ч на 100 км».
    static func per100(_ value: Double, _ fuel: Fuel) -> String {
        String(format: String(localized: "%@ на 100 км"), amount(value, fuel))
    }

    /// «16 кВт·ч/100 км» — в формуле, где места мало. Неразрывно целиком:
    /// после «/» строка иначе переносилась («18,3 кВт·ч/» и «100 км»).
    static func per100Short(_ value: Double, _ fuel: Fuel) -> String {
        Formatting.unbreakable(String(format: String(localized: "%@/100 км"), amount(value, fuel)))
            .replacingOccurrences(of: "/", with: "/\u{2060}")
    }

    static func percent(_ share: Double) -> String {
        Formatting.unbreakable(share.formatted(.percent.precision(.fractionLength(0))
            .locale(Formatting.numberLocale)))
    }

    /// «90 км», «1 234 км» — целыми: в сводке и формуле десятые — шум.
    static func km(_ value: Double) -> String {
        Formatting.unbreakable(String(format: String(localized: "%@ км"), number(value, maxDigits: 0)))
    }

    /// Виды энергии пути — электричество первым.
    static func fuels(of use: EnergySplit.Use) -> [Fuel] {
        [Fuel.electricity, .methane, .propane, .petrol].filter { use.meters($0) >= 1 }
    }

    /// «27,3 км на электричестве · ≈ 4,3 кВт·ч» — одна строка на вид энергии.
    static func part(_ fuel: Fuel, of use: EnergySplit.Use) -> String {
        let distance = "\(Formatting.distance(use.meters(fuel))) \(onFuel(fuel))"
        guard let units = use.amount[fuel] else { return distance }
        return "\(distance) · ≈\u{00A0}\(amount(units, fuel))"
    }

    /// То же голосом: «27 километров на электричестве, около 4,3 киловатт-часа».
    static func spokenPart(_ fuel: Fuel, of use: EnergySplit.Use) -> String {
        var text = "\(SpokenUnits.distance(use.meters(fuel))) \(onFuel(fuel))"
        if let units = use.amount[fuel] {
            text += ", " + String(format: String(localized: "около %@"), amount(units, fuel))
        }
        return text
    }

    /// Итог дня или поездки словами: «всё на электричестве», «27 км на
    /// электричестве + 7 км на бензине».
    static func dayLine(_ use: EnergySplit.Use) -> String {
        let fuels = fuels(of: use)
        if fuels.count == 1, let only = fuels.first {
            return String(format: String(localized: "всё %@"), onFuel(only))
        }
        return fuels.map { "\(km(use.meters($0) / 1_000)) \(onFuel($0))" }.joined(separator: " + ")
    }

    /// Строка примера: «всё на электричестве ≈ 3 400 сум», «90 км на
    /// электричестве + 210 км на бензине ≈ 118 000 сум», у бензиновой —
    /// «≈ 2,4 л ≈ 31 000 сум».
    static func exampleLine(_ use: EnergySplit.Use, model: EnergySplit.Model) -> String {
        if use.unsplitMeters > 0 {
            return String(localized: "укажите запас на электричестве")
        }
        let fuels = fuels(of: use)
        var text: String
        if model.usesBattery || fuels.count > 1 {
            text = dayLine(use)
        } else if let fuel = fuels.first, let units = use.amount[fuel] {
            text = "≈\u{00A0}" + amount(units, fuel)
        } else {
            return String(localized: "укажите расход — появятся литры и сумма")
        }
        if let cost = use.cost {
            text += " ≈\u{00A0}" + Formatting.money(FuelCost.rounded(cost))
        }
        return text
    }

    /// Для голоса — «около» вместо «≈».
    static func spoken(_ text: String) -> String {
        text.replacingOccurrences(of: "≈\u{00A0}", with: String(localized: "около") + " ")
            .replacingOccurrences(of: "≈ ", with: String(localized: "около") + " ")
            .replacingOccurrences(of: " · ", with: ", ")
    }

    // MARK: - Как посчитано

    /// Строка формулы на вид энергии: «27 км × 16 кВт·ч/100 км × 1 000 сум
    /// ≈ 4 300 сум». Без цены — до кВт·ч или литров.
    static func formula(_ use: EnergySplit.Use, model: EnergySplit.Model) -> [String] {
        fuels(of: use).compactMap { fuel in
            guard let per100 = model.per100[fuel] else { return nil }
            // С десятой, как строкой выше (34): «12 км × …» под «12,4 км на
            // электричестве» читалось другим числом.
            let distance = Formatting.unbreakable(Formatting.distance(use.meters(fuel)))
            let rate = per100Short(per100, fuel)
            let highway = fuel == .electricity && use.highwayMeters >= AppConfig.energyHighwayNoteMinMeters
            let line: String
            if let price = model.price[fuel], let units = use.amount[fuel] {
                line = String(format: String(localized: "%1$@ × %2$@ × %3$@ ≈ %4$@"),
                              distance, rate, Formatting.money(price), Formatting.money(FuelCost.rounded(units * price)))
            } else {
                line = String(format: String(localized: "%1$@ × %2$@ ≈ %3$@"), distance, rate,
                              amount(use.amount[fuel] ?? 0, fuel))
            }
            return highway ? line + " · " + String(localized: "с трассой") : line
        }
    }

    /// Пометки под расчётом поездки или периода.
    static func notes(_ use: EnergySplit.Use, model: EnergySplit.Model) -> [String] {
        var notes: [String] = []
        if use.highwayMeters >= AppConfig.energyHighwayNoteMinMeters {
            notes.append(String(format: String(localized: "По трассе %1$@ — заряд там тратится в %2$@ раза быстрее."),
                                Formatting.distance(use.highwayMeters), number(AppConfig.energyHighwayFactor)))
        }
        if use.noSpeedProfileMeters >= AppConfig.energyHighwayNoteMinMeters {
            notes.append(String(localized: "Трасса не учтена: профиля скорости уже нет (он хранится неделю)."))
        }
        if use.beyondRangeTrips > 0 {
            notes.append(String(localized: "Длиннее реального запаса — нужна зарядка в пути."))
        }
        if model.kWhIsEstimate, use.meters(.electricity) > 0 {
            notes.append(String(localized: "Расход электричества — оценка: укажите ёмкость батареи или цифру с панели."))
        }
        if !use.missingPrice.isEmpty {
            notes.append(String(localized: "Добавьте цены — появится сумма."))
        }
        if use.missingConsumption.contains(.petrol) {
            notes.append(String(localized: "Укажите расход бензина — появятся литры и сумма."))
        }
        return notes
    }

    // MARK: - Сводка машины

    /// «Трасса (быстрее 80 км/ч) тратит заряд в 1,3 раза быстрее».
    static var highwayRule: String {
        String(format: String(localized: "Трасса (быстрее %1$@ км/ч) тратит заряд в %2$@ раза быстрее."),
               number(AppConfig.energyHighwayKmh, maxDigits: 0), number(AppConfig.energyHighwayFactor))
    }

    /// Как посчитано — для страницы машины: откуда запас, расход и правило дня.
    static func explanation(profile: FuelProfile, energy: VehicleEnergy, model: EnergySplit.Model) -> [String] {
        var lines: [String] = []
        if energy.plugs {
            if let real = profile.evRealKm, real > 0 {
                lines.append(String(format: String(localized: "Реальный запас — %@: вы указали сами."), km(real)))
            } else if let passport = profile.evPassportKm, passport > 0 {
                let cycle = profile.evCycle ?? .cltc
                lines.append(String(format: String(localized: "Реальный запас: %1$@ по %2$@ × %3$@ ≈ %4$@ в городе."),
                                    km(passport), cycle.title, number(cycle.factor, maxDigits: 2),
                                    km(passport * cycle.factor)))
            }
            let kWh = profile.kWhPer100
            if profile.rate(.electricity).per100Km > 0 {
                lines.append(String(format: String(localized: "Расход электричества: %@ — с панели машины."),
                                    per100(kWh.value, .electricity)))
            } else if let battery = profile.batteryKWh, battery > 0, let range = profile.realRangeKm {
                lines.append(String(format: String(localized: "Расход электричества: %1$@ × %2$@ ÷ %3$@ ≈ %4$@."),
                                    amount(battery, .electricity), number(AppConfig.energyUsableBatteryShare),
                                    km(range), per100(kWh.value, .electricity)))
            } else {
                lines.append(String(format: String(localized: "Расход электричества: %@ — оценка, без ёмкости батареи и цифры с панели."),
                                    per100(kWh.value, .electricity)))
            }
        }
        switch model.kind {
        case .plugIn(let range, _):
            lines.append(String(format: String(localized: "Каждый день поездки сначала тратят заряд — его хватает на %@; дальше — бензин."),
                                km(range)))
            lines.append(String(format: String(localized: "Заряд снова полный: %@."),
                                schedule(profile.chargeSchedule ?? .nightly).lowercased()))
            lines.append(highwayRule)
        case .mixed(let primary, let second, let share):
            if share > 0 {
                lines.append(String(format: String(localized: "%1$@ пути — %2$@, %3$@ — %4$@."),
                                    percent(1 - share), onFuel(primary), percent(share), onFuel(second)))
            }
        case .electric(let range):
            lines.append(highwayRule)
            if let range {
                lines.append(String(format: String(localized: "Поездка длиннее %@ — с пометкой «нужна зарядка в пути»."),
                                    km(range)))
            }
        case .needsRange:
            lines.append(String(localized: "Укажите запас на электричестве — и станет видно, сколько пути на электричестве."))
        case .single:
            break
        }
        if energy.plugs, profile.chargePlace == .both {
            let share = profile.homeChargeShare ?? AppConfig.energyHomeChargeShareDefault
            lines.append(String(format: String(localized: "Цена кВт·ч — %1$@ дома и %2$@ на станции."),
                                percent(share), percent(1 - share)))
        }
        if energy.plugs {
            lines.append(String(localized: "Потери при зарядке не учитываются — счёт за свет будет чуть больше."))
        }
        lines.append(String(localized: "Старые поездки считаются по нынешней цене — прошлых цен приложение не знает."))
        return lines
    }
}
