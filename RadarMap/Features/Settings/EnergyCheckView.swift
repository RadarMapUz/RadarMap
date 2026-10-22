//
//  EnergyCheckView.swift
//  RadarMap
//
//  «Сверить с машиной» (21.10, 21.5): что показывает панель за неделю или
//  месяц — и одна кнопка «Поправить» на каждое расхождение. Числа панели
//  нигде не хранятся: сверка — разовая, в профиль уходит только принятая
//  поправка. Считает EnergyCheck.
//

import SwiftUI

struct EnergyCheckView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var days = 30
    @State private var share: Double?
    @State private var kWh: Double?
    @State private var litres: Double?
    /// Принятые поправки — строкой «Поправлено». Своим списком: после
    /// `apply` поправка выпадает из сверки, и метка у неё не показывалась
    /// никогда (отчёт качества 22.10, п. 4).
    @State private var applied: [EnergyCheck.Suggestion] = []
    /// Окно дней — пересчёт только при смене периода или данных поездок.
    @State private var window: [EnergySplit.Day] = []
    @State private var result: EnergyCheck.Result?

    /// Всё, от чего зависит сверка: меняется — пересчёт (после паузы ввода).
    private struct Inputs: Equatable {
        var window: [EnergySplit.Day]
        var panel: EnergyCheck.Panel
        var profile: FuelProfile
        var energy: VehicleEnergy
    }

    private struct WindowKey: Equatable {
        var days: Int
        var revision: Int
    }

    var body: some View {
        let settings = env.settings
        let energy = settings.vehicleEnergy
        let panel = EnergyCheck.Panel(electricShare: share.map { $0 / 100 }, kWhPer100: kWh, litresPer100: litres)
        VStack(alignment: .leading, spacing: 18) {
            Text("Средние из бортового компьютера за тот же период. Заполните, что знаете, — остальное можно оставить пустым.")
                .font(.rounded(15))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker(String(localized: "Период"), selection: $days) {
                Text("Неделя").tag(7)
                Text("Месяц").tag(30)
            }
            .pickerStyle(.segmented)
            if energy == .hybrid {
                field(String(localized: "На электричестве"), unit: "%", decimals: false, value: share) {
                    share = $0.map { min(100, $0) }
                }
            }
            if energy.plugs {
                field(String(localized: "Электричество"), unit: EnergyText.unit(.per100(.electricity)),
                      decimals: true, value: kWh) { kWh = $0 }
            }
            if energy != .electric {
                field(String(localized: "Бензин"), unit: EnergyText.unit(.per100(.petrol)),
                      decimals: true, value: litres) { litres = $0 }
            }
            if let result {
                estimateCard(result.estimate, energy: energy)
                if result.estimate.meters < AppConfig.energyCheckMinMeters {
                    Label("За этот период поездок нет — сверять не с чем.", systemImage: "info.circle")
                        .font(.rounded(14))
                        .foregroundStyle(Theme.textSecondary)
                } else if result.allMatch, applied.isEmpty {
                    Label("Сходится — расчёт близок к машине.", systemImage: "checkmark.circle.fill")
                        .font(.rounded(15, .semibold))
                        .foregroundStyle(Theme.success)
                }
                ForEach(Array(applied.enumerated()), id: \.offset) { _, suggestion in
                    suggestionRow(suggestion, done: true)
                }
                ForEach(Array(result.suggestions.enumerated()), id: \.offset) { _, suggestion in
                    suggestionRow(suggestion, done: false)
                }
            }
        }
        // Окно дней — по периоду и ревизии данных поездок, не по вводу.
        .task(id: WindowKey(days: days, revision: env.trip.dataRevision)) {
            window = EnergyCheck.window(tripDays: env.trip.days, history: env.trip.history, last: days)
        }
        // Сверка — вне body и вне главного потока; ввод цифр — после паузы.
        .task(id: Inputs(window: window, panel: panel, profile: settings.fuelProfile, energy: energy)) {
            if result != nil { await Task.pause(seconds: AppConfig.energyCheckDebounceSeconds) }
            guard !Task.isCancelled else { return }
            let window = window, profile = settings.fuelProfile
            let computed = await offMain {
                EnergyCheck.compare(panel: panel, days: window, profile: profile, energy: energy)
            }
            guard !Task.isCancelled else { return }
            result = computed
        }
        .onChange(of: days) { applied = [] }
    }

    private func field(_ title: String, unit: String, decimals: Bool, value: Double?,
                       onChange: @escaping (Double?) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            EnergyBlockTitle(text: title)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                NumberField(placeholder: "—", decimals: decimals, optional: value, alignment: .leading,
                            onChange: onChange)
                    .font(.rounded(24, .bold))
                    .accessibilityLabel(Text(verbatim: "\(title), \(unit)"))
                Text(unit)
                    .font(.rounded(15))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 1))
        }
    }

    private func estimateCard(_ estimate: EnergyCheck.Estimate, energy: VehicleEnergy) -> some View {
        var parts: [String] = []
        if energy == .hybrid, let share = estimate.electricShare {
            parts.append(String(format: String(localized: "%@ на электричестве"), EnergyText.percent(share)))
        }
        if energy.plugs {
            let rate = EnergyText.per100Short(estimate.kWhPer100, .electricity)
            parts.append(estimate.kWhIsEstimate ? String(format: String(localized: "%@ · оценка"), rate) : rate)
        }
        if energy != .electric, let litres = estimate.litresPer100 {
            parts.append(EnergyText.per100Short(litres, .petrol))
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text(String(format: String(localized: "Мы посчитали за %@"), Formatting.distance(estimate.meters)))
                .font(.rounded(13, .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text(parts.joined(separator: " · "))
                .font(.rounded(17, .bold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .statCard(padding: 14, radius: Theme.cornerMedium)
        .accessibilityElement(children: .combine)
    }

    private func suggestionRow(_ suggestion: EnergyCheck.Suggestion, done: Bool) -> some View {
        HStack(spacing: 12) {
            Text(Self.text(suggestion))
                .font(.rounded(15))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if done {
                Label("Поправлено", systemImage: "checkmark")
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.success)
            } else {
                Button("Поправить") {
                    env.settings.fuelProfile = EnergyCheck.apply(suggestion, to: env.settings.fuelProfile)
                    applied.append(suggestion)
                }
                .font(.rounded(15, .semibold))
                .tapTarget()
            }
        }
        .statCard(padding: 14, radius: Theme.cornerMedium)
    }

    /// «Запас: 90 → 104 км» — было и станет.
    static func text(_ suggestion: EnergyCheck.Suggestion) -> String {
        let none = String(localized: "не указан")
        switch suggestion {
        case .realRange(let from, let to):
            return String(format: String(localized: "Реальный запас: %1$@ → %2$@"),
                          from.map { EnergyText.km($0) } ?? none, EnergyText.km(to))
        case .kWhPer100(let from, let to):
            return String(format: String(localized: "Электричество: %1$@ → %2$@"),
                          EnergyText.per100Short(from, .electricity), EnergyText.per100Short(to, .electricity))
        case .litresPer100(let from, let to):
            return String(format: String(localized: "Бензин: %1$@ → %2$@"),
                          from.map { EnergyText.per100Short($0, .petrol) } ?? none, EnergyText.per100Short(to, .petrol))
        }
    }
}
