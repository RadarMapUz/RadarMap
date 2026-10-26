//
//  CommuteDetailSheet.swift
//  RadarMap
//
//  «Дорога на работу» подробно (Итоги): когда выезжали и сколько ехали,
//  где ушло время в последней поездке (CommuteLoss, 8.8.8) и последние
//  поездки. Карточка-сводка — CommuteCard рядом.
//

import Charts
import CoreLocation
import SwiftUI

/// Подробно: точки «время выезда → время в пути», линия «обычно», окно-совет
/// и последние поездки. Видно глазом то, что карточка говорит словами:
/// раньше выезжаешь — быстрее доезжаешь (или нет).
struct CommuteDetailSheet: View {
    let summary: Commute.Summary
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    /// «Где ушло время» по поездкам окна: id поездки → места. Считается в
    /// `.task` (CommuteLoss + свой адресник), не в body.
    @State private var losses: [Double: [LossPlace]] = [:]

    /// Место, где поездка потеряла время, — с подписью из своего адресника.
    struct LossPlace: Identifiable, Equatable {
        let id: Int
        /// Улица; nil — в адреснике рядом ничего (подписью станет расстояние).
        let street: String?
        /// Середина отрезка от начала пути, м.
        let fromStart: Double
        let lostMinutes: Int
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    CommuteCard(summary: summary, showsChevron: false,
                                monthlyCost: env.energyLedger.monthly(summary.trips, now: Date()),
                                crowdUsual: env.crowdUsual(summary.direction))
                    chartCard
                    if let accuracy = env.commuteProfiles.accuracyStats(summary.direction) {
                        CommuteAccuracyCard(stats: accuracy)
                    }
                    lossCard
                    tripsCard
                    Text("Считается на телефоне по вашим поездкам между домом и работой. Наружу эти данные не уходят.")
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textTertiary)
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

    /// Последняя поездка — целиком, до трёх мест; только если ей есть что
    /// сказать. Быстрых мест нет нарочно: похвала за участок подталкивает гнать.
    @ViewBuilder private var lossCard: some View {
        if let places = losses[summary.last.id], !places.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    IconBadge(symbol: "hourglass", tint: Theme.warning, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Где ушло время")
                            .font(.rounded(14, .bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(String(format: String(localized: "Последняя поездка, %@"),
                                    CommuteCard.dayLine(summary.last.departure).lowercased()))
                            .font(.rounded(11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                ForEach(places) { place in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(place.street ?? fromStartText(place.fromStart))
                                .font(.rounded(15, .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            if place.street != nil {
                                Text(fromStartText(place.fromStart))
                                    .font(.rounded(12))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        Spacer(minLength: 8)
                        Text(String(format: String(localized: "%@ мин"), "+\(place.lostMinutes)"))
                            .font(.rounded(15, .bold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.danger)
                    }
                    .accessibilityElement(children: .combine)
                }
                Text("Против ваших обычных поездок в это же время. Стоянки по дороге не считаются.")
                    .font(.rounded(11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .statCard()
        }
    }

    /// «1,5 км от дома» — где на пути это место, если улицы рядом не нашлось.
    private func fromStartText(_ meters: Double) -> String {
        let distance = Formatting.distance(meters)
        return summary.direction == .toWork ? String(localized: "\(distance) от дома")
                                            : String(localized: "\(distance) от работы")
    }

    /// Места потерь для поездок окна (CommuteLoss.places): у последней — все,
    /// у медленных — самое дорогое. Подпись — улица ближайшего дома из своего
    /// адресника (файл клетки: без сети, если он уже скачан); один файл на
    /// клетку за проход, последняя поездка — первой, остальные следом.
    private func loadLosses() async {
        let usual = summary.usual
        let trips = summary.trips.prefix(AppConfig.commuteDetailTripRows).map { trip in
            (id: trip.id, slower: usual.map { trip.duration - $0 >= AppConfig.commuteNoticeableDelaySeconds } ?? false)
        }
        let stretches = CommuteLoss.places(for: trips, lastID: summary.last.id,
                                           in: env.commuteProfiles.book[summary.direction])
        var books: [String: AddressBook?] = [:]
        func name(at point: CLLocationCoordinate2D) async -> String? {
            let key = AddressBook.key(for: point)
            if books[key] == nil { books[key] = .some(await env.roads.addressBook(for: point)) }
            guard let book = books[key] ?? nil,
                  let address = book.nearest(to: point, within: AppConfig.commuteLossNameMeters),
                  !address.street.isEmpty else { return nil }
            return StreetName.display(address.street, language: env.settings.appLanguage.mapCode)
        }
        var found: [Double: [LossPlace]] = [:]
        let order = [summary.last.id] + trips.map(\.id).filter { $0 != summary.last.id }
        for id in order {
            guard let list = stretches[id] else { continue }
            var places: [LossPlace] = []
            for stretch in list {
                places.append(LossPlace(id: stretch.segments.lowerBound,
                                        street: await name(at: stretch.midpoint),
                                        fromStart: (stretch.startMeters + stretch.endMeters) / 2,
                                        lostMinutes: stretch.lostMinutes))
            }
            if Task.isCancelled { return }
            found[id] = places
            // Карточка последней поездки не ждёт весь список.
            if id == summary.last.id { losses = found }
        }
        losses = found
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                IconBadge(symbol: "clock.fill", tint: Theme.Icon.time, size: 28)
                Text("Когда выезжали и сколько ехали")
                    .font(.rounded(14, .bold))
                    .foregroundStyle(Theme.textPrimary)
            }
            Chart {
                if let best = summary.best {
                    RectangleMark(
                        xStart: .value("Окно", Self.today(best.startMinute)),
                        xEnd: .value("Окно", Self.today(best.startMinute + AppConfig.commuteBucketMinutes)))
                        .foregroundStyle(Theme.success.opacity(0.14))
                }
                if let usual = summary.usual {
                    RuleMark(y: .value("Обычно", usual / 60))
                        .foregroundStyle(Theme.textTertiary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text(String(format: String(localized: "обычно %@"), Formatting.duration(usual)))
                                .font(.rounded(10, .medium))
                                .foregroundStyle(Theme.textTertiary)
                        }
                }
                ForEach(summary.trips) { trip in
                    PointMark(
                        x: .value("Выезд", Self.today(Commute.minuteOfDay(trip.departure))),
                        y: .value("Минут", trip.duration / 60))
                        .foregroundStyle(trip.id == summary.last.id ? Theme.accent : Theme.Icon.time.opacity(0.45))
                        .symbolSize(trip.id == summary.last.id ? 90 : 50)
                }
            }
            // Ось — ровные получасы, с запасом под окно-совет: от данных она
            // начиналась с «18:12» и обрезала окно справа.
            .chartXScale(domain: Self.today(xDomain.lowerBound)...Self.today(xDomain.upperBound))
            .chartXAxis {
                AxisMarks(values: .stride(by: .minute, count: 30)) { value in
                    AxisGridLine().foregroundStyle(Theme.stroke)
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(Theme.stroke)
                    if let minutes = value.as(Double.self) {
                        AxisValueLabel(String(format: String(localized: "%lld мин"), Int(minutes)))
                    }
                }
            }
            .frame(height: 200)
            .accessibilityLabel(Text("График: время выезда и время в пути"))
        }
        .statCard()
    }

    private var tripsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Последние поездки")
                .font(.rounded(14, .bold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.bottom, 8)
            ForEach(Array(summary.trips.prefix(AppConfig.commuteDetailTripRows).enumerated()),
                    id: \.element.id) { index, trip in
                if index > 0 { Divider().overlay(Theme.stroke) }
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(CommuteCard.dayLine(trip.departure))
                            .font(.rounded(14, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("\(Formatting.clock(trip.departure)) → \(Formatting.clock(trip.arrival))")
                            .font(.rounded(12))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textSecondary)
                        // Самое дорогое место медленной поездки (8.8.8; места —
                        // только у поездок дольше обычного, CommuteLoss.places) —
                        // у последней весь список в карточке выше. Без минут:
                        // место меряется медианой этого часа, а «+11 мин» справа —
                        // медианой месяца; два разных «+N» рядом путали бы.
                        if trip.id != summary.last.id, let place = losses[trip.id]?.first {
                            Text(String(format: String(localized: "больше всего — %@"),
                                        place.street ?? fromStartText(place.fromStart)))
                                .font(.rounded(11, .medium))
                                .foregroundStyle(Theme.danger)
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
                            Text(Self.shortDelta(trip.duration - usual))
                                .font(.rounded(11, .semibold))
                                .monospacedDigit()
                                .foregroundStyle(Self.deltaTint(trip.duration - usual))
                        }
                    }
                }
                .padding(.vertical, 9)
                .accessibilityElement(children: .combine)
            }
        }
        .statCard()
    }

    /// Минуты от полуночи, в которые укладываются все выезды и окно-совет,
    /// округлённые до получаса наружу.
    private var xDomain: ClosedRange<Int> {
        var minutes = summary.trips.map { Commute.minuteOfDay($0.departure) }
        if let best = summary.best {
            minutes += [best.startMinute, best.startMinute + AppConfig.commuteBucketMinutes]
        }
        let low = ((minutes.min() ?? 0) / 30) * 30
        let high = (((minutes.max() ?? 30) + 29) / 30) * 30
        return low...max(high, low + 30)
    }

    /// «+12 мин» / «−6 мин» / «≈» — коротко в строке списка.
    private static func shortDelta(_ delay: TimeInterval) -> String {
        let minutes = Int((delay / 60).rounded())
        if abs(delay) < AppConfig.commuteNoticeableDelaySeconds || minutes == 0 {
            return String(localized: "как обычно")
        }
        return String(format: String(localized: "%@ мин"), minutes > 0 ? "+\(minutes)" : "−\(-minutes)")
    }

    private static func deltaTint(_ delay: TimeInterval) -> Color {
        delay >= AppConfig.commuteNoticeableDelaySeconds ? Theme.danger
            : delay <= -AppConfig.commuteNoticeableDelaySeconds ? Theme.success : Theme.textTertiary
    }

    /// Минуты от полуночи — как сегодняшняя дата: ось графика — часы дня.
    private static func today(_ minute: Int) -> Date {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(minute) * 60)
    }
}
