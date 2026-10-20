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
                    Text(String(format: String(localized: "По будням, за %lld мин до выезда — только когда выехать в другое время выгоднее или нужно успеть к сроку. По вашим поездкам, на телефоне."),
                                AppConfig.departureReminderLeadMinutes))
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
