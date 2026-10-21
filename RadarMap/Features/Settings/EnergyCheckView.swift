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
    @State private var applied: Set<String> = []

    var body: some View {
        let settings = env.settings
        let energy = settings.vehicleEnergy
        let window = Self.days(env.trip.days, history: env.trip.history, last: days)
        let panel = EnergyCheck.Panel(electricShare: share.map { $0 / 100 }, kWhPer100: kWh, litresPer100: litres)
        let result = EnergyCheck.compare(panel: panel, days: window, profile: settings.fuelProfile, energy: energy)
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
            estimateCard(result.estimate, energy: energy)
            if result.estimate.meters < 1_000 {
                Label("За этот период поездок нет — сверять не с чем.", systemImage: "info.circle")
                    .font(.rounded(14))
                    .foregroundStyle(Theme.textSecondary)
            } else if result.allMatch {
                Label("Сходится — расчёт близок к машине.", systemImage: "checkmark.circle.fill")
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.success)
            }
            ForEach(Array(result.suggestions.enumerated()), id: \.offset) { _, suggestion in
                suggestionRow(suggestion)
            }
        }
    }

    /// Дни окна «последние N дней» — в расчёт EnergySplit.
    static func days(_ tripDays: [TripDay], history: [TripRecord], last count: Int,
                     now: Date = Date(), calendar: Calendar = .current) -> [EnergySplit.Day] {
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -(count - 1), to: today),
              let end = calendar.date(byAdding: .day, value: 1, to: today) else { return [] }
        let interval = DateInterval(start: start, end: end)
        let records = history.filter { $0.startedAt >= start && $0.startedAt < end }
        return EnergySplit.days(tripDays: TripDayBook.days(tripDays, in: interval), records: records,
                                calendar: calendar)
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

    private func suggestionRow(_ suggestion: EnergyCheck.Suggestion) -> some View {
        let key = String(describing: suggestion)
        let done = applied.contains(key)
        return HStack(spacing: 12) {
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
                    applied.insert(key)
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
