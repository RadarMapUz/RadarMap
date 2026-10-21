//
//  EnergyChoiceEditors.swift
//  RadarMap
//
//  Выборы «Машины и расходов» (21.10): тип машины, как и где заряжаете,
//  доли. Карточками, а не пикерами: у каждого варианта — пример словами,
//  по которому человек узнаёт себя («Prius, Camry Hybrid»), а не термин.
//

import SwiftUI

// MARK: - Тип машины

struct EnergyTypePicker: View {
    @Environment(AppEnvironment.self) private var env
    /// Выбрали — мастер идёт дальше сам.
    var onPick: () -> Void = {}

    var body: some View {
        let current = env.settings.vehicleEnergy
        VStack(spacing: 10) {
            ForEach(VehicleEnergy.allCases) { energy in
                EnergyChoiceCard(symbol: EnergyText.symbol(energy), title: energy.title,
                                 subtitle: EnergyText.subtitle(energy),
                                 selected: energy == current && !env.settings.needsHybridQuestion) {
                    env.settings.chooseVehicle(energy)
                    onPick()
                }
            }
        }
    }
}

// MARK: - Как заряжаете

struct EnergyScheduleEditor: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let settings = env.settings
        let current = settings.fuelProfile.chargeSchedule ?? .nightly
        VStack(alignment: .leading, spacing: 10) {
            ForEach(ChargeSchedule.allCases, id: \.self) { schedule in
                EnergyChoiceCard(symbol: EnergyText.scheduleSymbol(schedule),
                                 title: EnergyText.schedule(schedule),
                                 subtitle: Self.subtitle(schedule, range: settings.fuelProfile.realRangeKm),
                                 selected: schedule == current) {
                    var profile = settings.fuelProfile
                    profile.chargeSchedule = schedule
                    settings.fuelProfile = profile
                }
            }
            if current == .rarely {
                EnergyShareSlider(title: String(localized: "Пути на электричестве"),
                                  value: settings.fuelProfile.secondShare, range: 0...1) { share in
                    var profile = settings.fuelProfile
                    profile.secondShare = share
                    settings.fuelProfile = profile
                }
                .padding(.top, 6)
            }
        }
    }

    /// Что значит график — словами, с запасом водителя.
    static func subtitle(_ schedule: ChargeSchedule, range: Double?) -> String {
        let reach = range.map { EnergyText.km($0) } ?? String(localized: "запас")
        switch schedule {
        case .nightly: return String(format: String(localized: "Каждое утро снова %@ на электричестве"), reach)
        case .everyOtherDay: return String(format: String(localized: "%@ на два дня"), reach)
        case .weekly: return String(format: String(localized: "%@ на неделю"), reach)
        case .rarely: return String(localized: "Почти всё на бензине — доля ниже")
        }
    }
}

// MARK: - Где заряжаете

struct EnergyPlaceEditor: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let settings = env.settings
        let current = settings.fuelProfile.chargePlace ?? .home
        VStack(alignment: .leading, spacing: 10) {
            ForEach(ChargePlace.allCases, id: \.self) { place in
                EnergyChoiceCard(symbol: EnergyText.placeSymbol(place), title: EnergyText.place(place),
                                 subtitle: Self.subtitle(place), selected: place == current) {
                    var profile = settings.fuelProfile
                    profile.chargePlace = place
                    settings.fuelProfile = profile
                }
            }
            if current == .both {
                EnergyShareSlider(title: String(localized: "Доля дома"),
                                  value: settings.fuelProfile.homeChargeShare ?? AppConfig.energyHomeChargeShareDefault,
                                  range: 0.05...0.95) { share in
                    var profile = settings.fuelProfile
                    profile.homeChargeShare = share
                    settings.fuelProfile = profile
                }
                .padding(.top, 6)
            }
        }
    }

    static func subtitle(_ place: ChargePlace) -> String {
        switch place {
        case .home: return String(localized: "По домашнему тарифу — дешевле всего")
        case .station: return String(localized: "По цене зарядной станции")
        case .both: return String(localized: "Обе цены, доля — ниже")
        }
    }
}

// MARK: - Доли

/// Ползунок доли с шагом 5 % и значением голосом словами.
struct EnergyShareSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let onChange: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                Text(EnergyText.percent(value))
                    .font(.rounded(17, .bold).monospacedDigit())
                    .foregroundStyle(Theme.accent)
            }
            .accessibilityHidden(true)
            // Шаг 5 % — тот же, к которому округляет запись: без него
            // VoiceOver шагал на десятую часть шкалы, и число в голосе
            // расходилось с сохранённым (было в «Расход и цены»).
            Slider(value: Binding(get: { value }, set: { onChange(($0 * 20).rounded() / 20) }),
                   in: range, step: 0.05)
                .accessibilityLabel(Text(verbatim: title))
                .accessibilityValue(Text(verbatim: EnergyText.percent(value)))
        }
        .statCard(padding: 14, radius: Theme.cornerMedium)
    }
}

/// Доля бензина у машины на газу — с подсказкой, откуда она берётся.
struct EnergyGasShareEditor: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let settings = env.settings
        VStack(alignment: .leading, spacing: 6) {
            EnergyShareSlider(title: String(localized: "Пути на бензине"),
                              value: settings.fuelProfile.secondShare, range: 0...0.9) { share in
                var profile = settings.fuelProfile
                profile.secondShare = share
                settings.fuelProfile = profile
            }
            Text("Обычно 5–10 % — когда АГНКС нет рядом или там очередь.")
                .font(.rounded(13))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
