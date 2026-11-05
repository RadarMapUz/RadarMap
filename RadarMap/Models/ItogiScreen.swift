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
    /// Подсказка действием в герое (31E) — заменяет вывод, когда она есть.
    var action: ActionHint?
    /// Пробки окна: места и часы по записям (31E); сумма — в summary.
    var jams: TrafficTime.Period
    /// Где чаще выше лимита вне камер (31E).
    var overLimitPlaces: [OverLimit.Place]
    /// Цель недели — по дням, не по окну периода (31E).
    var goal: WeeklyGoal?
    /// Показывать ли рейтинг и какой (аудит 05.11: мало данных — без кольца,
    /// у дня рейтинга нет).
    var availability: ItogiRating.Availability = .none
    /// «Сняли 35: камеры −15, резкая езда −20» — то же разложение, что в
    /// разборе рейтинга (RatingBreakdown.sources), в целых.
    var taken: ItogiRating.Taken?
    /// Километры по дням окна — у недели (у месяца — календарь на странице
    /// «Поездки», у дня — нечего делить).
    var bars: [DayBar] = []

    static func == (a: ItogiScreen, b: ItogiScreen) -> Bool {
        a.summary == b.summary && a.insights == b.insights
            && a.pendingCount == b.pendingCount && a.pendingOldest == b.pendingOldest
            && a.trips.map(\.id) == b.trips.map(\.id)
            && a.action == b.action && a.jams == b.jams
            && a.overLimitPlaces == b.overLimitPlaces && a.goal == b.goal
            && a.availability == b.availability && a.taken == b.taken && a.bars == b.bars
    }

    /// Чистая сборка — её и проверяет тест; `screen` лишь уводит её с main.
    static func build(days: [TripDay], history: [TripRecord], period: StatsPeriod,
                      anchor: Date, now: Date) -> ItogiScreen {
        let summary = TripHistory.summary(days: days, history: history,
                                          period: period, anchor: anchor, now: now)
        let nudge = TripHistory.pendingFineNudge(history, now: now)
        let trips = TripHistory.historyList(history, period: period, anchor: anchor)
        let interval = period.interval(containing: anchor)
        let availability = ItogiRating.availability(summary, period: period)
        var taken: ItogiRating.Taken?
        if case .shown(let rating) = availability {
            taken = ItogiRating.taken(rating: rating,
                                      sources: RatingBreakdown.sources(records: trips, days: days, in: interval))
        }
        let bars = period == .week
            ? TripHistory.dailyKm(trips, days: 7, now: interval.end.addingTimeInterval(-1)) : []
        return ItogiScreen(summary: summary,
                           insights: PeriodInsights.hero(summary).map { [$0] } ?? [],
                           pendingCount: nudge?.count ?? 0,
                           pendingOldest: nudge?.oldest,
                           trips: trips,
                           action: PeriodInsights.action(summary),
                           jams: TrafficTime.period(trips),
                           overLimitPlaces: OverLimit.places(trips),
                           goal: WeeklyGoal.build(days: days, now: now),
                           availability: availability, taken: taken, bars: bars)
    }

    @concurrent
    static func screen(days: [TripDay], history: [TripRecord], period: StatsPeriod,
                       anchor: Date, now: Date) async -> ItogiScreen {
        build(days: days, history: history, period: period, anchor: anchor, now: now)
    }
}
