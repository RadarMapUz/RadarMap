//
//  TripEnergyCard.swift
//  RadarMap
//
//  Во что обошлась дорога (21.10, 21.4) — в детали поездки и в «Итогах».
//
//  Деталь поездки: «4 300 сум · 27 км на электричестве · ≈ 4,3 кВт·ч» и
//  бензиновая часть, если была; «Как посчитано» раскрывает формулу, из
//  которой видно, правдоподобна ли сумма. «Итоги»: «Расходы ≈ 84 000 сум ·
//  92 % на электричестве» и одной спокойной строкой «на бензине вышло бы ≈
//  310 000 сум» — только когда цена бензина известна, без «экономии»
//  крупными буквами (решение владельца 21.10, п. 2).
//
//  Нет цены — нет суммы, но километры по видам энергии у машины с батареей
//  видны всё равно. Цифры — из EnergySplit (`env.energyLedger`).
//

import SwiftUI

struct TripEnergyCard: View {
    @Environment(AppEnvironment.self) private var env
    let record: TripRecord
    @State private var expanded = false

    var body: some View {
        let ledger = env.energyLedger
        if let use = ledger.trips[record.id]?.use, Self.isWorthShowing(use, model: ledger.model) {
            let current = FuelCost.isAtCurrentPrice(endedAt: record.endedAt, profile: env.settings.fuelProfile)
            card(use, model: ledger.model, atCurrentPrice: current && use.cost != nil)
        }
    }

    /// Сумма есть — показываем; у машины с батареей — и без суммы (километры
    /// по видам энергии); у бензиновой без цены карточке сказать нечего.
    static func isWorthShowing(_ use: EnergySplit.Use, model: EnergySplit.Model) -> Bool {
        guard use.totalMeters > 0 else { return false }
        if use.cost != nil { return true }
        if model.kind == .needsRange { return true }
        return model.usesBattery
    }

    private func card(_ use: EnergySplit.Use, model: EnergySplit.Model, atCurrentPrice: Bool) -> some View {
        let fuels = EnergyText.fuels(of: use)
        let headline = use.cost.map { Formatting.money(FuelCost.rounded($0)) }
            ?? (use.unsplitMeters > 0 ? String(localized: "Укажите запас на электричестве")
                                      : EnergyText.dayLine(use))
        let formula = EnergyText.formula(use, model: model)
        let notes = EnergyText.notes(use, model: model)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                IconBadge(symbol: model.usesBattery ? "bolt.fill" : "fuelpump.fill", tint: Theme.Icon.money, size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline)
                        .font(.numeral(20, .bold).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(fuels, id: \.self) { fuel in
                        Text(EnergyText.part(fuel, of: use))
                            .font(.rounded(13))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if atCurrentPrice {
                        Text("по нынешней цене")
                            .font(.rounded(12))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    if use.beyondRangeTrips > 0 {
                        Label("Длиннее реального запаса — нужна зарядка в пути.", systemImage: "bolt.car.fill")
                            .font(.rounded(13, .semibold))
                            .foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: Self.spoken(use, headline: headline, current: atCurrentPrice)))
            if !formula.isEmpty || !notes.isEmpty {
                Button {
                    withMotion(Motion.standard) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Label("Как посчитано", systemImage: "function")
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                            .accessibilityHidden(true)
                    }
                    .font(.rounded(14, .semibold))
                    .foregroundStyle(Theme.accent)
                    .tapTarget()
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? Text("раскрыто") : Text("свёрнуто"))
                if expanded {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array((formula + notes).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.rounded(13))
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .statCard(padding: 14, radius: Theme.cornerMedium)
        #if DEBUG
        .onAppear { if ProcessInfo.processInfo.arguments.contains("-energyFormula") { expanded = true } }
        #endif
    }

    static func spoken(_ use: EnergySplit.Use, headline: String, current: Bool) -> String {
        var parts = [headline]
        parts += EnergyText.fuels(of: use).map { EnergyText.spokenPart($0, of: use) }
        if current { parts.append(String(localized: "по нынешней цене")) }
        return EnergyText.spoken(parts.joined(separator: ". "))
    }
}

/// «Расходы ≈ 84 000 сум · 92 % на электричестве» — строка «Итогов» за период.
struct PeriodEnergyRow: View {
    let use: EnergySplit.Use
    let model: EnergySplit.Model
    let atCurrentPrice: Bool
    /// Журнал заправок за период (21.6): есть записи — сверху реальные
    /// деньги, расчёт — второй строкой. nil или пусто — как было.
    var journal: EnergyJournal.Period? = nil

    var body: some View {
        let lines = Self.lines(use, model: model, current: atCurrentPrice, journal: journal)
        HStack(spacing: 12) {
            IconBadge(symbol: model.usesBattery ? "bolt.fill" : "fuelpump.fill", tint: Theme.Icon.money, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(lines.title)
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(lines.detail)
                    .font(.rounded(12))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach([lines.estimate, lines.allPetrol, lines.measured].compactMap { $0 }, id: \.self) { extra in
                    Text(extra)
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.rounded(12, .semibold))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
        }
        .statCard(padding: 14, radius: Theme.cornerMedium)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: EnergyText.spoken(
            [lines.title, lines.detail, lines.estimate, lines.allPetrol, lines.measured].compactMap { $0 }.joined(separator: ". "))))
        .accessibilityHint(journal?.isEmpty == false ? Text("Открыть журнал заправок")
                                                     : Text("Открыть «Машина и расходы»"))
    }

    /// Показывать ли строку: записи журнала, сумма или у машины с батареей есть доля.
    static func isWorthShowing(_ use: EnergySplit.Use, model: EnergySplit.Model,
                               journal: EnergyJournal.Period? = nil) -> Bool {
        if let journal, !journal.isEmpty { return true }
        guard use.totalMeters > 0 else { return false }
        return use.cost != nil || (model.usesBattery && use.electricShare != nil)
    }

    struct Lines: Equatable {
        var title: String
        var detail: String
        var allPetrol: String?
        /// «по расчёту ≈ …» — оценка под реальными деньгами журнала.
        var estimate: String?
        /// «по факту 5,8 л/100 км» — только из журнала, только «бак к баку».
        var measured: String?
    }

    static func lines(_ use: EnergySplit.Use, model: EnergySplit.Model, current: Bool,
                      journal: EnergyJournal.Period? = nil) -> Lines {
        if let journal, !journal.isEmpty {
            return journalLines(journal, use: use, model: model, current: current)
        }
        let share = model.usesBattery ? use.electricShare : nil
        // Доля — неразрывно: «41 % на / электричестве» на двух строках
        // разрывало мысль (снимок 21.10).
        let shareText = share.map {
            Formatting.unbreakable(String(format: String(localized: "%@ на электричестве"), EnergyText.percent($0)))
        }
        var title: String
        var detail: String
        if let cost = use.cost {
            title = String(format: String(localized: "Расходы ≈ %@"), Formatting.money(FuelCost.rounded(cost)))
            if let shareText { title += " · " + shareText }
            detail = Formatting.distance(use.totalMeters)
            if current { detail += " · " + String(localized: "по нынешней цене") }
        } else {
            title = shareText ?? Formatting.distance(use.totalMeters)
            detail = EnergyText.fuels(of: use)
                .map { "\(Formatting.distance(use.meters($0))) \(EnergyText.onFuel($0))" }
                .joined(separator: " · ")
        }
        // «На бензине вышло бы» — одна спокойная строка, только когда было
        // электричество и водитель сам назвал расход и цену бензина.
        var allPetrol: String?
        if model.usesBattery, use.meters(.electricity) > 0, let cost = use.cost,
           let petrol = EnergySplit.allPetrolCost(meters: use.totalMeters, model: model), petrol > cost {
            allPetrol = String(format: String(localized: "на бензине вышло бы ≈ %@"),
                               Formatting.money(FuelCost.rounded(petrol)))
        }
        return Lines(title: title, detail: detail, allPetrol: allPetrol)
    }

    /// По журналу: «Потрачено 412 000 сум», под ним «3 заправки, 9 зарядок»,
    /// «по расчёту ≈ …» (оценка вторым планом) и расход по факту, если он
    /// есть. «На бензине вышло бы» здесь нет: это сравнение двух оценок, а
    /// сверху теперь реальные деньги. Счёт — своей строкой: в заголовке
    /// «· 2» оставалось в конце строки, а «заправки» уезжали на следующую.
    private static func journalLines(_ journal: EnergyJournal.Period, use: EnergySplit.Use,
                                     model: EnergySplit.Model, current: Bool) -> Lines {
        var estimate: String?
        if let cost = use.cost {
            estimate = JournalText.estimate(cost)
            if current { estimate? += " · " + Formatting.unbreakable(String(localized: "по нынешней цене")) }
        }
        return Lines(title: JournalText.spent(journal.spending), detail: JournalText.counts(journal.spending),
                     estimate: estimate, measured: JournalText.measured(journal.measured, mixedPetrol: hasPlug(model)))
    }

    /// Машина с розеткой — и та, у которой запас ещё не указан (`needsRange`
    /// бывает только у гибрида с розеткой): её бензин тоже на весь путь.
    private static func hasPlug(_ model: EnergySplit.Model) -> Bool {
        if case .needsRange = model.kind { return true }
        return model.usesBattery
    }
}
