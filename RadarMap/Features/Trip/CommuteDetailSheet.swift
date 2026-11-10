//
//  CommuteDetailSheet.swift
//  RadarMap
//
//  «Дорога на работу / домой» подробно (Итоги). Сверху вниз (разбор 10.11,
//  docs/commute_review_2026-11-10.md): сколько обычно и как последняя
//  поездка против этого (CommuteCard), когда выезжать (CommuteChartCard),
//  где ушло время в последней поездке (CommuteLossCard), последние поездки
//  с итогом за 30 дней.
//

import CoreLocation
import SwiftUI

struct CommuteDetailSheet: View {
    let summary: Commute.Summary
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    /// «Где ушло время» по поездкам окна: id поездки → места. Считается в
    /// `.task` (CommuteLoss + свой адресник), не в body.
    @State private var losses: [Double: [CommuteLossPlace]] = [:]
    /// Край пути последней поездки: сверх обычного у начала и у конца, с.
    @State private var edges: (leaving: Double, arriving: Double) = (0, 0)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    CommuteCard(summary: summary, crowdUsual: env.crowdUsual(summary.direction))
                    // Вопросы о распорядке (быть к 9:00? напоминать?) — здесь,
                    // у самой дороги на работу, а не лентой в «Итогах» (34b).
                    if summary.direction == .toWork, let minute = env.workTargetSuggestion,
                       env.settings.workArrivalTarget == nil, !env.settings.workTargetAsked {
                        ArrivalTargetQuestion(minute: minute) { yes in
                            env.settings.workTargetAsked = true
                            if yes { env.settings.workArrivalTarget = ArrivalTarget(minute: minute) }
                        }
                    } else if summary.direction == .toWork, env.departureReminderAvailable,
                              !env.settings.departureReminders, !env.settings.departureRemindersAsked {
                        DepartureReminderOffer { env.setDepartureReminders($0) }
                    }
                    if summary.trips.count >= 2 {
                        CommuteChartCard(summary: summary)
                    }
                    if let accuracy = env.commuteProfiles.accuracyStats(summary.direction) {
                        CommuteAccuracyCard(stats: accuracy)
                    }
                    let lossCard = CommuteLossCard(direction: summary.direction,
                                                   lastDeparture: summary.last.departure,
                                                   places: losses[summary.last.id] ?? [],
                                                   leaving: edges.leaving, arriving: edges.arriving)
                    if !lossCard.isEmpty { lossCard }
                    tripsCard
                    Text("Считается на телефоне по вашим поездкам между домом и работой. Наружу эти данные не уходят.")
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 4)
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle(summary.direction.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .task(id: env.commuteProfiles.revision) { await loadLosses() }
        }
    }

    // MARK: Где ушло время (8.8.8)

    /// Места потерь для поездок окна (CommuteLoss.places): у последней — все,
    /// у медленных — самое дорогое. Подпись — улица ближайшего дома из своего
    /// адресника (файл клетки: без сети, если он уже скачан); один файл на
    /// клетку за проход, последняя поездка — первой, остальные следом.
    private func loadLosses() async {
        let variants = env.commuteProfiles.book[summary.direction]
        let trips = summary.trips.prefix(AppConfig.commuteDetailTripRows).map { trip in
            (id: trip.id, slower: rowVerdict(trip) == .slower)
        }
        let stretches = CommuteLoss.places(for: trips, lastID: summary.last.id, in: variants)
        let report = CommuteLoss.report(for: summary.last.id, in: variants)
        edges = (report?.leaving ?? 0, report?.arriving ?? 0)
        var books: [String: AddressBook?] = [:]
        func name(at point: CLLocationCoordinate2D) async -> String? {
            let key = AddressBook.key(for: point)
            if books[key] == nil { books[key] = .some(await env.roads.addressBook(for: point)) }
            guard let book = books[key] ?? nil,
                  let address = book.nearest(to: point, within: AppConfig.commuteLossNameMeters),
                  !address.street.isEmpty else { return nil }
            return StreetName.display(address.street, language: env.settings.appLanguage.mapCode)
        }
        var found: [Double: [CommuteLossPlace]] = [:]
        let order = [summary.last.id] + trips.map(\.id).filter { $0 != summary.last.id }
        for id in order {
            guard let list = stretches[id] else { continue }
            var places: [CommuteLossPlace] = []
            for stretch in list {
                places.append(CommuteLossPlace(id: stretch.segments.lowerBound,
                                               street: await name(at: stretch.midpoint),
                                               startMeters: stretch.startMeters, endMeters: stretch.endMeters,
                                               lostSeconds: stretch.lostSeconds))
            }
            if Task.isCancelled { return }
            found[id] = CommuteLossPlace.merged(places)
            // Карточка последней поездки не ждёт весь список.
            if id == summary.last.id { losses = found }
        }
        losses = found
    }

    // MARK: Последние поездки

    private func rowVerdict(_ trip: Commute.Trip) -> Commute.Verdict {
        Commute.verdict(trip.duration, usual: summary.usual, range: summary.range)
    }

    private var tripsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Последние поездки")
                .font(.rounded(14, .bold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.bottom, summary.week?.isNoticeable == true ? 2 : 8)
            if let week = summary.week, week.isNoticeable {
                // Неделя (8.8.15) — только когда она вне обычного разброса.
                Text(Self.weekLine(week))
                    .font(.rounded(12, .semibold))
                    .foregroundStyle(CommuteCard.tint(week.delta > 0 ? .slower : .faster,
                                                      confident: summary.range != nil))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
            }
            ForEach(Array(summary.trips.prefix(AppConfig.commuteDetailTripRows).enumerated()),
                    id: \.element.id) { index, trip in
                if index > 0 { Divider().overlay(Theme.stroke) }
                tripRow(trip)
            }
            if let month = env.energyLedger.commuteMonth(summary.trips + summary.other, now: Date()) {
                Divider().overlay(Theme.stroke)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: String(localized: "Поездок за 30 дней: %1$lld · %2$@ · топливо ≈ %3$@"),
                                month.trips, Formatting.distance(month.meters), Formatting.money(month.cost)))
                        .font(.rounded(13, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Топливо — по расходу и цене из настроек машины")
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 10)
            }
        }
        .statCard()
    }

    private func tripRow(_ trip: Commute.Trip) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(CommuteCard.dayLine(trip.departure))
                    .font(.rounded(14, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(Formatting.clock(trip.departure)) → \(Formatting.clock(trip.arrival))")
                    .font(.rounded(12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
                // Самое дорогое место медленной поездки (8.8.8) — у последней
                // весь список в карточке выше. Без минут: место меряется
                // медианой этого часа, а «+11 мин» справа — медианой месяца.
                if trip.id != summary.last.id, let place = losses[trip.id]?.first {
                    Text(String(format: String(localized: "больше всего — %@"),
                                place.street ?? CommuteLossCard.fromStartText(place.fromStart,
                                                                              direction: summary.direction)))
                        .font(.rounded(12, .medium))
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Formatting.duration(trip.duration))
                    .font(.rounded(15, .bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                if let usual = summary.usual {
                    let verdict = rowVerdict(trip)
                    Text(Self.shortDelta(Commute.shownDelta(trip.duration, usual)))
                        .font(.rounded(12, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(CommuteCard.tint(verdict, confident: summary.range != nil))
                }
            }
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    /// «За 7 дней обычно 61 мин — дольше обычного».
    static func weekLine(_ week: Commute.Week) -> String {
        let value = Formatting.unbreakable(Formatting.duration(week.median))
        return week.delta > 0
            ? String(format: String(localized: "За 7 дней обычно %@ — дольше обычного"), value)
            : String(format: String(localized: "За 7 дней обычно %@ — быстрее обычного"), value)
    }

    /// «+12 мин» / «−6 мин» / «как обычно» — в показанных минутах.
    static func shortDelta(_ minutes: Int) -> String {
        guard minutes != 0 else { return String(localized: "как обычно") }
        return String(format: String(localized: "%@ мин"), minutes > 0 ? "+\(minutes)" : "−\(-minutes)")
    }
}
