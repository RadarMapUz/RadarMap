//
//  TripStatsSheet+Risk.swift
//  RadarMap
//
//  «Итоги»: расходы периода — строка раздела и страница «Расходы» (34b).
//  Сумма возможных штрафов живёт в строке денег карточки-ответа
//  (TripStatsSheet+Blocks), сами штрафы — на экране «Штрафы».
//

import SwiftUI

extension TripStatsSheet {

    // MARK: - Расходы за период (12б.3, 21.4, 21.6)

    /// Данные расходов окна: дни те же, что у сводки периода (`TripDayBook.days`).
    private func energyInputs() -> (use: EnergySplit.Use, model: EnergySplit.Model,
                                    journal: EnergyJournal.Period, current: Bool) {
        let interval = period.interval(containing: anchor)
        let ledger = env.energyLedger
        let use = ledger.use(of: TripDayBook.days(env.trip.days, in: interval))
        let journal = env.journalPeriod(interval)
        let current = FuelCost.isAtCurrentPrice(endedAt: interval.start, profile: env.settings.fuelProfile)
        return (use, ledger.model, journal, current && use.cost != nil)
    }

    /// Строка «Расходы» раздела: одно число — на что ушло за поездки, подпись
    /// — купленное по журналу (Н8 плана 34: «потрачено 1,3 млн» рядом с
    /// «по расчёту ≈ 25 000» читалось ошибкой в 50 раз).
    func expensesRow(_ summary: PeriodSummary) -> ItogiRowItem? {
        let inputs = energyInputs()
        guard summary.distance > 0,
              PeriodEnergyRow.isWorthShowing(inputs.use, model: inputs.model, journal: inputs.journal)
        else { return nil }
        let compact = PeriodEnergyRow.compact(inputs.use, model: inputs.model, journal: inputs.journal)
        return ItogiRowItem(
            id: "expenses", symbol: inputs.model.usesBattery ? Icon.charge : Icon.fuel,
            title: String(localized: "Расходы"),
            caption: compact.caption,
            value: compact.value,
            action: { path.append(.expenses) })
    }

    /// Страница «Расходы»: расчёт и купленное — разными строками с подписью
    /// источника, «Заправился / Зарядился», ссылки в журнал и настройки.
    var expensesPage: some View {
        let inputs = energyInputs()
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(period.rangeTitle(containing: anchor))
                    .font(.rounded(13))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 4)
                HStack(spacing: 8) {
                    PeriodEnergyRow(use: inputs.use, model: inputs.model, atCurrentPrice: inputs.current,
                                    journal: inputs.journal, showsChevron: false)
                    JournalAddButton { journalRequest = $0 }
                }
                .fixedSize(horizontal: false, vertical: true)
                ItogiRowGroup(items: [
                    ItogiRowItem(id: "journal", symbol: Icon.journal,
                                 title: String(localized: "Журнал заправок"),
                                 caption: String(localized: "Заправки и зарядки с ценой и пробегом"),
                                 action: { path.append(.expensesJournal) }),
                    ItogiRowItem(id: "settings", symbol: Icon.car,
                                 title: String(localized: "Машина и расходы"),
                                 caption: String(localized: "Расход, цены, запас на электричестве"),
                                 action: { path.append(.expensesSettings) }),
                ])
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle("Расходы")
        .navigationBarTitleDisplayMode(.inline)
    }
}
