//
//  WorkShiftsCard.swift
//  RadarMap
//
//  «Смены» в «Итогах» (12б.9): для таксиста и курьера день — это смена, а не
//  десятки поездок. Строка смены: день и часы, длина, км, превышения, штрафы
//  по замерам и топливо (если заданы расход и цена). Только последние смены:
//  история хранит полные записи 30 дней и до 50 штук.
//

import SwiftUI

struct WorkShiftsCard: View {
    @Environment(AppEnvironment.self) private var env
    let shifts: [WorkShift]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(String(localized: "Смены"))
            VStack(spacing: 0) {
                ForEach(Array(shifts.prefix(AppConfig.workShiftsShown).enumerated()), id: \.element.id) { index, shift in
                    if index > 0 { Divider().overlay(Theme.stroke) }
                    row(shift)
                }
            }
            .statCard(padding: 14, radius: Theme.cornerMedium)
        }
    }

    private func row(_ shift: WorkShift) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(shift.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)
                    .locale(Formatting.numberLocale)))
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(String(format: String(localized: "%1$@–%2$@"),
                            Formatting.clock(shift.start), Formatting.clock(shift.end)))
                    .font(.rounded(13).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
                Text(Formatting.duration(shift.duration))
                    .font(.rounded(15, .bold).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
            }
            Text(details(shift))
                .font(.rounded(12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    /// «212 км · рейсов 18 · превышений 3 · штрафы ~450 000 сум · топливо ~120 000 сум».
    private func details(_ shift: WorkShift) -> String {
        var parts = [Formatting.distance(shift.distanceMeters),
                     String(format: String(localized: "рейсов: %lld"), shift.trips)]
        parts.append(shift.overspeeds == 0 ? String(localized: "без превышений")
                     : String(format: String(localized: "превышений: %lld"), shift.overspeeds))
        if shift.fineRisk > 0 {
            parts.append(String(format: String(localized: "штрафы ~%@"), Formatting.money(shift.fineRisk)))
        }
        if let fuel = env.settings.fuelCost(meters: shift.distanceMeters) {
            parts.append(String(format: String(localized: "топливо ~%@"), Formatting.money(fuel)))
        }
        return parts.joined(separator: " · ")
    }
}
