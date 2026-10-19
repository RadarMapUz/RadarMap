//
//  CommuteCard.swift
//  RadarMap
//
//  «Дорога на работу» и «Дорога домой» в Итогах — ответ на вопрос, который
//  водитель задаёт себе каждый день: сколько я сегодня ехал, это нормально,
//  и когда надо было выехать.
//
//  Карточка говорит словами, а не средними: «Вчера · 8:22 → 9:17 · 55 мин ·
//  на 12 мин дольше обычного», «Обычно 44 мин, выезд около 8:20», и совет —
//  только когда он настоящий: «Выезжайте в 7:45 — в среднем 37 мин». Все
//  цифры готовые из Commute (модель, под тестами), вьюха не считает ничего.
//

import Charts
import SwiftUI

struct CommuteCard: View {
    let summary: Commute.Summary
    /// Стрелка «подробнее» — только там, где карточка ведёт дальше (Итоги).
    var showsChevron = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Formatting.duration(summary.last.duration))
                    .font(.rounded(30, .heavy))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                if let delay = summary.lastDelay {
                    CommuteDelayPill(delay: delay)
                }
            }
            if let usual = summary.usual {
                // Фразой, а не сеткой цифр: «Обычно 39 мин, выезжаете около
                // 18:37» читается за один взгляд, три подписанные клетки — за три.
                Text(Self.usualLine(usual: usual, departure: summary.usualDepartureMinute))
                    .font(.rounded(13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(String(format: String(localized: "Ещё %lld — и появится «обычно»"),
                            max(1, AppConfig.commuteMinTrips - summary.trips.count)))
                    .font(.rounded(12))
                    .foregroundStyle(Theme.textTertiary)
            }
            if let best = summary.best {
                CommuteAdvice(best: best)
            }
        }
        .statCard()
        .accessibilityElement(children: .combine)
    }

    private var header: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: summary.direction.symbol,
                      tint: summary.direction == .toWork ? Theme.Icon.work : Theme.Icon.home)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.direction.title)
                    .font(.rounded(15, .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(Self.whenLine(summary.last))
                    .font(.rounded(12))
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.rounded(13, .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    /// «Обычно 39 мин, выезжаете около 18:37».
    static func usualLine(usual: TimeInterval, departure: Int?) -> String {
        let time = Formatting.unbreakable(Formatting.duration(usual))
        guard let departure else {
            return String(format: String(localized: "Обычно %@"), time)
        }
        return String(format: String(localized: "Обычно %1$@, выезжаете около %2$@"),
                      time, Formatting.clock(minuteOfDay: departure))
    }

    /// «Вчера · 8:22 → 9:17», «пт, 9 октября · 18:34 → 19:15».
    static func whenLine(_ trip: Commute.Trip) -> String {
        "\(dayLine(trip.departure)) · \(Formatting.clock(trip.departure)) → \(Formatting.clock(trip.arrival))"
    }

    /// День поездки: «Сегодня», «Вчера», иначе с днём недели — дорога на
    /// работу живёт неделями, и «пт» говорит больше, чем «9 октября».
    static func dayLine(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) || calendar.isDateInYesterday(date) {
            return Formatting.dayTitle(date, calendar: calendar)
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.wide))
    }
}

/// «Вам нужно быть на работе к 9:00?» — один раз, когда распорядок уже
/// виден по поездкам (ArrivalTarget.suggestion). Без ответа «да» срока нет,
/// и призрак не говорит «позже срока» никогда.
struct ArrivalTargetQuestion: View {
    let minute: Int
    let onAnswer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                IconBadge(symbol: "clock.fill", tint: Theme.Icon.work)
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: String(localized: "Вам нужно быть на работе к %@?"),
                                Formatting.clock(minuteOfDay: minute)))
                        .font(.rounded(15, .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Тогда в дороге будет видно, успеваете ли: «с запасом» или «впритык». Срок останется на телефоне.")
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                SecondaryButton(title: "Нет") { onAnswer(false) }
                SecondaryButton(title: "Да", systemImage: "checkmark") { onAnswer(true) }
            }
        }
        .statCard()
    }
}

/// «Напоминать, когда выезжать?» — один раз, когда есть что напомнить:
/// выгодное время выезда или срок «быть к 9:00» (DepartureReminder).
struct DepartureReminderOffer: View {
    let onAnswer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                IconBadge(symbol: "bell.fill", tint: Theme.Icon.time)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Напоминать, когда выезжать?")
                        .font(.rounded(15, .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("По будням, за 10 минут — только когда выехать в другое время выгоднее или нужно успеть к сроку. По вашим поездкам, на телефоне.")
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                SecondaryButton(title: "Не нужно") { onAnswer(false) }
                SecondaryButton(title: "Напоминать", systemImage: "bell") { onAnswer(true) }
            }
        }
        .statCard()
    }
}

/// «на 12 мин дольше обычного» — красным, «быстрее» — зелёным, «как обычно» —
/// спокойным серым. Цвет — второй признак: смысл в словах.
struct CommuteDelayPill: View {
    let delay: TimeInterval

    var body: some View {
        let tint: Color = delay >= AppConfig.commuteNoticeableDelaySeconds ? Theme.danger
            : delay <= -AppConfig.commuteNoticeableDelaySeconds ? Theme.success : Theme.textSecondary
        Text(Formatting.delayPhrase(delay))
            .font(.rounded(12, .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// Совет о времени выезда — только когда он есть (Commute.bestWindow).
struct CommuteAdvice: View {
    let best: Commute.BestWindow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            IconBadge(symbol: "lightbulb.fill", tint: Theme.Icon.rating, size: 28)
            // Число не отрывается от «мин» (unbreakable): «на 7 / мин» через
            // перенос читалось как две разные вещи.
            Text(String(format: String(localized: "Выезжайте в %1$@ — в среднем %2$@, на %3$@ быстрее"),
                        Formatting.clock(minuteOfDay: best.startMinute),
                        Formatting.unbreakable(Formatting.duration(best.medianDuration)),
                        Formatting.unbreakable(Formatting.duration(best.saving))))
                .font(.rounded(13, .medium))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.success.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
    }
}

/// Подробно: точки «время выезда → время в пути», линия «обычно», окно-совет
/// и последние поездки. Видно глазом то, что карточка говорит словами:
/// раньше выезжаешь — быстрее доезжаешь (или нет).
struct CommuteDetailSheet: View {
    let summary: Commute.Summary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    CommuteCard(summary: summary, showsChevron: false)
                    chartCard
                    tripsCard
                    Text("Считается на телефоне по вашим поездкам между домом и работой. Наружу эти данные не уходят.")
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 4)
                }
                .padding(16)
            }
            .background(Theme.screenBackground)
            .navigationTitle(summary.direction.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
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
            ForEach(Array(summary.trips.prefix(12).enumerated()), id: \.element.id) { index, trip in
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
