//
//  EnergyExamples.swift
//  RadarMap
//
//  «Ваш обычный день: 34 км — всё на электричестве ≈ 3 400 сум» и «Длинная
//  поездка 300 км: 90 км электро + 210 км бензин ≈ …» (21.10, 21.3) — по
//  своим поездкам; пока их мало — пример, подписанный «например». Это то,
//  ради чего водитель заполнял цифры: сразу видно, правдоподобно ли.
//
//  И лист правки одной строки сводки — тот же кирпич, что шаг мастера.
//

import SwiftUI

struct EnergyExamples: View {
    @Environment(AppEnvironment.self) private var env
    /// В мастере — отдельной карточкой на фоне страницы.
    let compact: Bool

    var body: some View {
        let model = env.energyLedger.model
        let now = Date()
        let usual = EnergySplit.usualDayMeters(tripDays: env.trip.days, now: now)
        let dayMeters = usual ?? AppConfig.energyExampleDayKm * 1_000
        let day = EnergySplit.example(meters: dayMeters, model: model)
        let long = EnergySplit.longTrip(records: env.trip.history, model: model, now: now)
        let longUse = EnergySplit.example(meters: long.meters, highwayMeters: long.highwayMeters, model: model)
        let content = Group {
            row(title: usual != nil
                    ? String(format: String(localized: "Ваш обычный день: %@"), EnergyText.km(dayMeters / 1_000))
                    : String(format: String(localized: "Обычный день, например: %@"), EnergyText.km(dayMeters / 1_000)),
                line: EnergyText.exampleLine(day, model: model),
                caption: usual != nil ? String(localized: "Медиана ваших дней за два месяца")
                                      : String(localized: "Пример — своих поездок пока мало"),
                symbol: "sun.max.fill")
            row(title: long.isOwn
                    ? String(format: String(localized: "Самая длинная за месяц: %@"), EnergyText.km(long.meters / 1_000))
                    : String(format: String(localized: "Поездка %@ по трассе, например"), EnergyText.km(long.meters / 1_000)),
                line: EnergyText.exampleLine(longUse, model: model),
                caption: longCaption(longUse, own: long.isOwn),
                symbol: "road.lanes")
        }
        if compact {
            VStack(alignment: .leading, spacing: 14) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .statCard(padding: 14, radius: Theme.cornerMedium)
        } else {
            content
        }
    }

    private func longCaption(_ use: EnergySplit.Use, own: Bool) -> String {
        if use.beyondRangeTrips > 0 { return String(localized: "Длиннее реального запаса — нужна зарядка в пути") }
        if use.highwayMeters >= AppConfig.energyHighwayNoteMinMeters {
            return String(format: String(localized: "По трассе заряд тратится в %@ раза быстрее"),
                          EnergyText.number(AppConfig.energyHighwayFactor))
        }
        return own ? String(localized: "Ваша поездка за последние 30 дней") : String(localized: "Пример")
    }

    private func row(title: String, line: String, caption: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(symbol: symbol, tint: Theme.Icon.money, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(line)
                    .font(.rounded(17, .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(caption)
                    .font(.rounded(12))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, compact ? 0 : 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: EnergyText.spoken("\(title). \(line). \(caption)")))
    }
}

/// Лист одной строки сводки: «тап меняет одну цифру».
struct EnergyEditSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let part: EnergyPart

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    content
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.screenBackground)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }

    private var title: String {
        let energy = env.settings.vehicleEnergy
        switch part {
        case .type: return String(localized: "Тип машины")
        case .range: return String(localized: "Запас на электричестве")
        case .schedule: return String(localized: "Как заряжаете")
        case .place: return String(localized: "Где заряжаете")
        case .electricity: return String(localized: "Расход электричества")
        case .gasShare: return String(localized: "Пути на бензине")
        case .check: return String(localized: "Сверить с машиной")
        case .number(let number): return EnergyText.title(number, energy: energy)
        }
    }

    @ViewBuilder private var content: some View {
        switch part {
        case .type: EnergyTypePicker { dismiss() }
        case .range: EnergyRangeEditor()
        case .schedule: EnergyScheduleEditor()
        case .place: EnergyPlaceEditor()
        case .electricity: EnergyElectricityEditor()
        case .gasShare: EnergyGasShareEditor()
        case .check: EnergyCheckView()
        case .number(let number): EnergyNumberCard(number: number)
        }
    }
}
