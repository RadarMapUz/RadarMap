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
        // Без своего заголовка (34b): карточка живёт на странице «Смены»
        // «Итогов», и «Смены» под навбаром «Смены» было бы повтором.
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(shifts.prefix(AppConfig.workShiftsShown).enumerated()), id: \.element.id) { index, shift in
                if index > 0 { Divider().overlay(Theme.stroke) }
                row(shift)
            }
        }
        .statCard(padding: 14, radius: Theme.cornerMedium)
    }

    private func row(_ shift: WorkShift) -> some View {
        let day = Text(shift.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)
            .locale(Formatting.numberLocale)))
            .font(.rounded(15, .semibold))
            .foregroundStyle(Theme.textPrimary)
        let hours = Text(String(format: String(localized: "%1$@–%2$@"),
                                Formatting.clock(shift.start), Formatting.clock(shift.end)))
            .font(.rounded(13).monospacedDigit())
            .foregroundStyle(Theme.textSecondary)
        let length = Text(Formatting.duration(shift.duration))
            .font(.rounded(15, .bold).monospacedDigit())
            .foregroundStyle(Theme.textPrimary)
        return VStack(alignment: .leading, spacing: 4) {
            // День, часы и длина — строкой, пока влезают. Крупный шрифт и
            // узбекские «Sesh, 20-okt» / «12 soat 15 daq» строку не держат:
            // день ломался на две строки рядом с часами (снимок 14.6) — тогда
            // часы уходят строкой ниже, а при совсем узкой — и длина.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    day
                    hours
                    Spacer(minLength: 0)
                    length
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        day
                        Spacer(minLength: 8)
                        length
                    }
                    hours
                }
                VStack(alignment: .leading, spacing: 2) {
                    day.fixedSize(horizontal: false, vertical: true)
                    hours
                    length
                }
            }
            Text(details(shift))
                .font(.rounded(12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
        // Одна смена — одна мысль, и голосом словами: «вторник, 20 октября,
        // с 7:30 до 19:45, 12 часов 15 минут…», а не «вт, 20 окт., 12 ч 15 мин».
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spoken(shift)))
    }

    /// Что показать: смены из истории, а в DEBUG с `-demoWorkShifts` — две
    /// демо-смены, когда рабочих рейсов нет (снимки экранов).
    static func shown(_ real: [WorkShift]) -> [WorkShift] {
        #if DEBUG
        if real.isEmpty, ProcessInfo.processInfo.arguments.contains("-demoWorkShifts") {
            let today = Calendar.current.startOfDay(for: Date())
            func shift(_ day: Int, from: Double, to: Double, km: Double, trips: Int,
                       overspeeds: Int, fine: Double) -> WorkShift {
                let start = today.addingTimeInterval(Double(day) * 86_400 + from * 3600)
                return WorkShift(id: start.timeIntervalSince1970, start: start,
                                 end: today.addingTimeInterval(Double(day) * 86_400 + to * 3600),
                                 trips: trips, distanceMeters: km * 1000,
                                 movingSeconds: (to - from) * 2400, overspeeds: overspeeds, fineRisk: fine)
            }
            return [shift(0, from: 7.5, to: 19.75, km: 212.4, trips: 18, overspeeds: 3, fine: 450_000),
                    shift(-1, from: 8, to: 17, km: 164, trips: 12, overspeeds: 0, fine: 0)]
        }
        #endif
        return real
    }

    /// «212 км · рейсов 18 · превышений 3 · штрафы ~450 000 сум · расходы ≈ 120 000 сум».
    private func details(_ shift: WorkShift) -> String {
        var parts = [Formatting.distance(shift.distanceMeters),
                     String(format: String(localized: "рейсов: %lld"), shift.trips)]
        parts.append(shift.overspeeds == 0 ? String(localized: "без превышений")
                     : String(format: String(localized: "превышений: %lld"), shift.overspeeds))
        if shift.fineRisk > 0 {
            parts.append(String(format: String(localized: "штрафы ~%@"), Formatting.money(shift.fineRisk)))
        }
        if let cost = shiftCost(shift) {
            parts.append(String(format: String(localized: "расходы ≈ %@"), Formatting.money(cost)))
        }
        return parts.joined(separator: " · ")
    }

    /// Та же строка смены для VoiceOver: полные слова вместо сокращений и
    /// «около» вместо тильды.
    private func spoken(_ shift: WorkShift) -> String {
        var parts = [
            shift.start.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Formatting.numberLocale)),
            String(format: String(localized: "с %1$@ до %2$@"),
                   Formatting.clock(shift.start), Formatting.clock(shift.end)),
            SpokenUnits.duration(shift.duration),
            SpokenUnits.distance(shift.distanceMeters),
            String(format: String(localized: "рейсов: %lld"), shift.trips),
            shift.overspeeds == 0 ? String(localized: "без превышений")
                : String(format: String(localized: "превышений: %lld"), shift.overspeeds),
        ]
        if shift.fineRisk > 0 {
            parts.append(String(format: String(localized: "штрафы около %@"), Formatting.money(shift.fineRisk)))
        }
        if let cost = shiftCost(shift) {
            parts.append(String(format: String(localized: "расходы около %@"), Formatting.money(cost)))
        }
        return parts.joined(separator: ", ")
    }

    /// Расходы смены (21.4): рейсы смены из общего расчёта — с зарядом дня,
    /// как такси и считает топливо на смену. nil — суммы нет.
    private func shiftCost(_ shift: WorkShift) -> Double? {
        env.energyLedger.use(from: shift.start, through: shift.end, workOnly: true).cost.map(FuelCost.rounded)
    }
}
