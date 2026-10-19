//
//  ItogiScreen.swift
//  RadarMap
//
//  Всё, что экран «Итогов» считает по истории, — одним проходом вне главного
//  потока (план 19.10, 6.4), как разбор рейтинга (RatingBreakdown.screen).
//
//  До этого сводка периода, выводы героя, напоминание о штрафах и список
//  поездок считались в body: на каждую пересборку — смену раскрывашки,
//  анимацию появления, выбор поездки на карте. Цифры от этого не менялись,
//  менялся только расход. Теперь пересчёт — на смену периода или данных
//  (`TripStats.dataRevision`), а body лишь рисует готовое.
//

import Foundation

nonisolated struct ItogiScreen: Equatable {
    var summary: PeriodSummary
    /// Вывод героя (PeriodInsights.hero) — один, без дублей других карточек.
    var insights: [Insight]
    /// «Ждут ответа: N» — по всей истории, не по окну (см. pendingFineNudge).
    var pendingCount: Int
    var pendingOldest: Date?
    /// Поездки окна периода, новые первыми.
    var trips: [TripRecord]

    static func == (a: ItogiScreen, b: ItogiScreen) -> Bool {
        a.summary == b.summary && a.insights == b.insights
            && a.pendingCount == b.pendingCount && a.pendingOldest == b.pendingOldest
            && a.trips.map(\.id) == b.trips.map(\.id)
    }

    /// Чистая сборка — её и проверяет тест; `screen` лишь уводит её с main.
    static func build(days: [TripDay], history: [TripRecord], period: StatsPeriod,
                      anchor: Date, now: Date) -> ItogiScreen {
        let summary = TripHistory.summary(days: days, history: history,
                                          period: period, anchor: anchor)
        let nudge = TripHistory.pendingFineNudge(history, now: now)
        return ItogiScreen(summary: summary,
                           insights: PeriodInsights.hero(summary).map { [$0] } ?? [],
                           pendingCount: nudge?.count ?? 0,
                           pendingOldest: nudge?.oldest,
                           trips: TripHistory.historyList(history, period: period, anchor: anchor))
    }

    @concurrent
    static func screen(days: [TripDay], history: [TripRecord], period: StatsPeriod,
                       anchor: Date, now: Date) async -> ItogiScreen {
        build(days: days, history: history, period: period, anchor: anchor, now: now)
    }
}
