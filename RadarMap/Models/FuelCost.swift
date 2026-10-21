//
//  FuelCost.swift
//  RadarMap
//
//  Что водитель сказал о своей машине (план 19.10, 12б.3; 21.10 — «Машина
//  и расходы»). Расход и цену знает только водитель: цен по умолчанию нет —
//  они меняются, и подставленная «средняя по Ташкенту» через месяц соврала
//  бы в каждой поездке. Через 60 дней после последней правки цены
//  приложение просит её обновить.
//
//  Спрашиваем то, что человек знает: запас хода по паспорту и цикл, «заряжаю
//  каждую ночь», «дома свет по … сум», цифру с панели машины. Технические
//  кВт·ч на 100 км считаем сами (EnergySplit).
//
//  Профиль лежит у пользователей на диске с 12б.3: все поля, появившиеся
//  21.10, — опциональные (правило 18), прежние не переименованы. Старая
//  цена электричества — это цена ДОМА, старый расход электричества — цифра,
//  которую водитель ввёл сам (как с панели), старая доля второго топлива —
//  для метана/пропана и запасной путь гибрида с розеткой без запаса хода.
//
//  Задним числом стоимость не хранится: старая поездка считается по
//  нынешней цене и помечается «по нынешней цене» — честнее, чем делать
//  вид, что мы знаем, сколько стоил литр в прошлом месяце.
//
//  Чистая логика — FuelCostTests, EnergySplitTests.
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
    /// Сумов за единицу; 0 — не задана. У электричества — цена ДОМА.
    var price: Double = 0
}

/// По какому циклу измерен паспортный запас хода. Реальный запас в городе —
/// паспортный × коэффициент цикла (AppConfig): CLTC обещает больше всех.
nonisolated enum RangeCycle: String, Codable, CaseIterable, Sendable {
    case cltc, nedc, wltp

    /// Название цикла — латинское сокращение, одно на всех языках.
    var title: String {
        switch self {
        case .cltc: return "CLTC"
        case .nedc: return "NEDC"
        case .wltp: return "WLTP"
        }
    }

    var factor: Double {
        switch self {
        case .cltc: return AppConfig.energyCycleFactorCLTC
        case .nedc: return AppConfig.energyCycleFactorNEDC
        case .wltp: return AppConfig.energyCycleFactorWLTP
        }
    }
}

/// Как часто гибрид с розеткой встаёт на зарядку.
nonisolated enum ChargeSchedule: String, Codable, CaseIterable, Sendable {
    case nightly, everyOtherDay, weekly, rarely

    /// Через сколько дней заряд снова полный; nil — почти не заряжают, и
    /// пробег на электричестве — постоянной долей (`FuelProfile.secondShare`).
    var everyDays: Int? {
        switch self {
        case .nightly: return 1
        case .everyOtherDay: return 2
        case .weekly: return 7
        case .rarely: return nil
        }
    }
}

/// Где заряжают — от этого цена: дома свет в разы дешевле станции.
nonisolated enum ChargePlace: String, Codable, CaseIterable, Sendable {
    case home, station, both
}

/// Всё, что водитель сказал о расходе. По виду топлива — свой расход и цена:
/// поменял «Машину» с метана на бензин — прежние цифры метана не пропали.
nonisolated struct FuelProfile: Codable, Equatable, Sendable {
    var rates: [Fuel: FuelRate] = [:]
    /// Доля пробега на втором топливе (0…1): бензин у машины на газу; у
    /// гибрида с розеткой — доля на электричестве, когда заряжают «почти
    /// никогда» или запас хода ещё не указан (так считалось до 21.10).
    var secondShare: Double = 0
    /// Когда последний раз правили цену — от него «обновите цены».
    var pricesUpdatedAt: Date?

    // MARK: 21.10 — гибрид с розеткой и электромобиль (всё опционально)

    /// Запас на электричестве по паспорту, км.
    var evPassportKm: Double?
    /// Цикл паспорта; nil — CLTC (у китайских машин, а их здесь большинство).
    var evCycle: RangeCycle?
    /// Реальный запас, поправленный водителем или «Сверить с машиной».
    /// nil — паспортный × коэффициент цикла.
    var evRealKm: Double?
    /// Ёмкость батареи, кВт·ч — из документов; необязательно.
    var batteryKWh: Double?
    var chargeSchedule: ChargeSchedule?
    var chargePlace: ChargePlace?
    /// Доля зарядки дома при «и там и там» (0…1).
    var homeChargeShare: Double?
    /// Цена на зарядной станции, сум/кВт·ч (дома — `rates[.electricity].price`).
    var stationPrice: Double?
    /// Ответ на «ваш гибрид заряжается от розетки?» уже есть (или тип выбран
    /// в новом мастере) — вопрос больше не задаём.
    var hybridPlugConfirmed: Bool?
    /// Мастер пройден или пропущен — дальше сводка, а не мастер.
    var setupDone: Bool?

    func rate(_ fuel: Fuel) -> FuelRate { rates[fuel] ?? FuelRate() }

    /// Реальный запас в городе, км; nil — не указан.
    var realRangeKm: Double? {
        if let evRealKm, evRealKm > 0 { return evRealKm }
        guard let evPassportKm, evPassportKm > 0 else { return nil }
        return evPassportKm * (evCycle ?? .cltc).factor
    }

    /// Расход электричества, кВт·ч на 100 км, и оценка ли это. Цифра с
    /// панели (введённая водителем) — первая; затем — из ёмкости и реального
    /// запаса; без обоих — типичный, с подписью «оценка».
    var kWhPer100: (value: Double, isEstimate: Bool) {
        let entered = rate(.electricity).per100Km
        if entered > 0 { return (entered, false) }
        if let batteryKWh, batteryKWh > 0, let range = realRangeKm, range > 0 {
            return (batteryKWh * AppConfig.energyUsableBatteryShare / range * 100, false)
        }
        return (AppConfig.energyDefaultKWhPer100, true)
    }

    /// Сумов за кВт·ч по месту зарядки; nil — нужной цены нет.
    var electricityPrice: Double? {
        let home = rate(.electricity).price
        let station = stationPrice ?? 0
        switch chargePlace ?? .home {
        case .home: return home > 0 ? home : nil
        case .station: return station > 0 ? station : nil
        case .both:
            guard home > 0, station > 0 else { return nil }
            let share = min(1, max(0, homeChargeShare ?? AppConfig.energyHomeChargeShareDefault))
            return home * share + station * (1 - share)
        }
    }

    /// Профиль пуст: ни одного числа — первый вход, место мастеру.
    var isBlank: Bool {
        rates.values.allSatisfy { $0.per100Km <= 0 && $0.price <= 0 }
            && evPassportKm == nil && evRealKm == nil && batteryKWh == nil && stationPrice == nil
    }
}

extension VehicleEnergy {
    /// Основное и второе топливо машины.
    nonisolated var fuels: (primary: Fuel, second: Fuel?) {
        switch self {
        case .fuel, .hev: return (.petrol, nil)
        case .cng: return (.methane, .petrol)
        case .lpg: return (.propane, .petrol)
        case .electric: return (.electricity, nil)
        case .hybrid: return (.petrol, .electricity)
        }
    }

    /// Нужна ли машине розетка: запас хода, зарядка, кВт·ч.
    nonisolated var plugs: Bool {
        switch self {
        case .hybrid, .electric: return true
        default: return false
        }
    }
}

nonisolated enum FuelCost {
    /// До 100 сумов на малых суммах, до 1 000 — от 10 000: «12 300 сум» за
    /// поездку и «420 000 сум» за месяц, без ложной точности до сума.
    static func rounded(_ sum: Double) -> Double {
        let step = sum >= 10_000 ? 1_000.0 : 100.0
        return (sum / step).rounded() * step
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
