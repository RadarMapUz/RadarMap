//
//  CommuteCard.swift
//  RadarMap
//
//  Шапка листа «Дорога на работу / домой» — один ответ за три секунды
//  (разбор 10.11, docs/commute_review_2026-11-10.md): сколько обычно и какой
//  разброс, как последняя поездка против обычного одной фразой, и когда лучше
//  выезжать — только если это окно и правда есть.
//
//  Цвет — только за пределами обычного разброса: колебание в пределах
//  половины поездок и есть «обычно», красить его тревогой — значит красить
//  половину дней. Красного нет совсем: красный — камера и штраф.
//  Все цифры готовые из Commute (модель, под тестами), вьюха не считает.
//

import SwiftUI

struct CommuteCard: View {
    let summary: Commute.Summary
    /// «у других водителей ~35 мин» (8.8.16) — пока своего «обычно» нет.
    var crowdUsual: TimeInterval? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let usual = summary.usual {
                usualBlock(usual)
                Divider().overlay(Theme.stroke)
                lastTrip
                if let best = summary.best {
                    CommuteAdvice(best: best, usual: usual)
                }
            } else {
                firstTrips
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .statCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spoken))
    }

    // MARK: Обычно

    private func usualBlock(_ usual: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Обычно")
                .font(.rounded(13, .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text(Formatting.duration(usual))
                .font(.numeral(30, .heavy))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
            if let range = summary.range {
                Text(Self.rangeLine(range))
                    .font(.rounded(14))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(Self.sampleLine(summary))
                .font(.rounded(12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// «Вчера · 18:35 → 19:33» и фраза сравнения слева, «58 мин» справа; на
    /// крупном шрифте — столбиком, чтобы фраза не обрезалась.
    private var lastTrip: some View {
        let when = Text(Self.whenLine(summary.last))
            .font(.rounded(13))
            .monospacedDigit()
            .foregroundStyle(Theme.textSecondary)
        let verdict = Text(Self.verdictPhrase(summary))
            .font(.rounded(15, .semibold))
            .foregroundStyle(Self.verdictTint(summary))
            .fixedSize(horizontal: false, vertical: true)
        let duration = Text(Formatting.duration(summary.last.duration))
            .font(.numeral(22, .bold))
            .monospacedDigit()
            .foregroundStyle(Theme.textPrimary)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) { when; verdict }
                Spacer(minLength: 8)
                duration.fixedSize()
            }
            VStack(alignment: .leading, spacing: 3) { when; duration; verdict }
        }
    }

    /// Мало поездок: крупно — последняя, ниже — сколько ещё до «обычно».
    private var firstTrips: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.whenLine(summary.last))
                .font(.rounded(13))
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
            Text(Formatting.duration(summary.last.duration))
                .font(.numeral(30, .heavy))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
            if let crowdUsual {
                // Чужое «обычно» — с названным источником, своё его сменит.
                Text(Self.crowdLine(crowdUsual))
                    .font(.rounded(13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(Self.untilUsualLine(summary))
                .font(.rounded(12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Слова

    /// «Половина поездок — от 45 до 60 мин»: межквартильный размах словами.
    static func rangeLine(_ range: ClosedRange<TimeInterval>, spoken: Bool = false) -> String {
        let time: (TimeInterval) -> String = spoken
            ? { SpokenUnits.duration($0) }
            : { Formatting.unbreakable(Formatting.duration($0)) }
        return String(format: String(localized: "Половина поездок — от %1$@ до %2$@"),
                      time(range.lowerBound), time(range.upperBound))
    }

    /// «По 22 поездкам за 30 дней, выезд около 18:35» — из чего «обычно».
    static func sampleLine(_ summary: Commute.Summary) -> String {
        guard let departure = summary.usualDepartureMinute else {
            return String(format: String(localized: "По %1$lld поездкам за %2$lld дней"),
                          summary.trips.count, AppConfig.commuteWindowDays)
        }
        return String(format: String(localized: "По %1$lld поездкам за %2$lld дней, выезд около %3$@"),
                      summary.trips.count, AppConfig.commuteWindowDays,
                      Formatting.clock(minuteOfDay: departure))
    }

    static func untilUsualLine(_ summary: Commute.Summary) -> String {
        String(format: String(localized: "Ещё %lld — и появится «обычно»"),
               max(1, AppConfig.commuteMinTrips - summary.trips.count))
    }

    /// Одна фраза сравнения последней поездки: «на 6 мин дольше обычного»,
    /// «+2 мин — в пределах обычного», «как обычно». Минуты — разность
    /// показанных чисел (`shownDelay`), чтобы «58» и «обычно 52» давали 6.
    static func verdictPhrase(_ summary: Commute.Summary, spoken: Bool = false) -> String {
        guard let delta = summary.shownDelay else { return "" }
        let minutes = spoken ? SpokenUnits.minutes(abs(delta)) : Formatting.unbreakable(
            String(format: String(localized: "%lld мин"), abs(delta)))
        switch summary.verdict {
        case .slower:
            return String(format: String(localized: "на %@ дольше обычного"), minutes)
        case .faster:
            return String(format: String(localized: "на %@ быстрее обычного"), minutes)
        case .usual:
            guard summary.range != nil, delta != 0 else { return String(localized: "как обычно") }
            let signed = (delta > 0 ? "+" : "−") + minutes
            return String(format: String(localized: "%@ — в пределах обычного"), signed)
        }
    }

    /// Цвет фразы: тревожный и зелёный — только вне обычного разброса.
    static func verdictTint(_ summary: Commute.Summary) -> Color {
        tint(summary.verdict, confident: summary.range != nil)
    }

    static func tint(_ verdict: Commute.Verdict, confident: Bool) -> Color {
        guard confident else { return Theme.textSecondary }
        switch verdict {
        case .slower: return Theme.warning
        case .faster: return Theme.success
        case .usual: return Theme.textSecondary
        }
    }

    /// «у других водителей ~35 мин»; голосом — «Обычно около 35 минут,
    /// по данным водителей».
    static func crowdLine(_ seconds: TimeInterval, spoken: Bool = false) -> String {
        guard !spoken else {
            return String(format: String(localized: "Обычно около %@, по данным водителей"),
                          SpokenUnits.duration(seconds))
        }
        // «у других водителей», а не «(по водителям)» (аудит 05.11): скобка
        // читалась как пометка о точности, а это чужая норма рядом с вашей.
        return String(format: String(localized: "у других водителей ~%@"),
                      Formatting.unbreakable(Formatting.duration(seconds)))
    }

    /// Всё, что на карточке, — фразами для VoiceOver.
    private var spoken: String {
        var parts = [summary.direction.title]
        if let usual = summary.usual {
            parts.append(String(format: String(localized: "Обычно %@"), SpokenUnits.duration(usual)))
            if let range = summary.range { parts.append(Self.rangeLine(range, spoken: true)) }
            parts.append(Self.sampleLine(summary))
            parts.append(Self.whenLine(summary.last, spoken: true) + ", " + SpokenUnits.duration(summary.last.duration))
            parts.append(Self.verdictPhrase(summary, spoken: true))
            if let best = summary.best { parts.append(CommuteAdvice.line(best, usual: usual, spoken: true)) }
        } else {
            parts.append(Self.whenLine(summary.last, spoken: true) + ", " + SpokenUnits.duration(summary.last.duration))
            if let crowdUsual { parts.append(Self.crowdLine(crowdUsual, spoken: true)) }
            parts.append(Self.untilUsualLine(summary))
        }
        return parts.joined(separator: ". ")
    }

    /// «Вчера · 8:22 → 9:17», «пт, 9 октября · 18:34 → 19:15»; голосом —
    /// «пятница, 9 октября, с 18:34 до 19:15» (стрелка звучит словом «стрелка»).
    static func whenLine(_ trip: Commute.Trip, spoken: Bool = false) -> String {
        guard !spoken else {
            return dayLine(trip.departure, spoken: true) + ", "
                + String(format: String(localized: "с %1$@ до %2$@"),
                         Formatting.clock(trip.departure), Formatting.clock(trip.arrival))
        }
        return "\(dayLine(trip.departure)) · \(Formatting.clock(trip.departure)) → \(Formatting.clock(trip.arrival))"
    }

    /// День поездки: «Сегодня», «Вчера», иначе с днём недели — дорога на
    /// работу живёт неделями, и «пт» говорит больше, чем «9 октября».
    /// `spoken` — день недели полностью: «пт» голосом — две буквы.
    static func dayLine(_ date: Date, calendar: Calendar = .current, spoken: Bool = false) -> String {
        if calendar.isDateInToday(date) || calendar.isDateInYesterday(date) {
            return Formatting.dayTitle(date, calendar: calendar)
        }
        // Названия дня и месяца — на языке приложения (правило 7): при английском
        // языке системы было бы «Fri, 9 October» посреди русского текста.
        return date.formatted(.dateTime.weekday(spoken ? .wide : .abbreviated).day().month(.wide)
            .locale(Formatting.numberLocale))
    }
}

/// Совет о времени выезда — только когда окно есть (Commute.bestWindow):
/// 2+ поездки, экономия от 5 мин, и быстрее обычного две из трёх.
struct CommuteAdvice: View {
    let best: Commute.BestWindow
    let usual: TimeInterval

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            IconBadge(symbol: "lightbulb.fill", tint: Theme.success, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                // Число не отрывается от «мин» (unbreakable): «на 7 / мин» через
                // перенос читалось как две разные вещи.
                Text(Self.line(best, usual: usual))
                    .font(.rounded(14, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(String(format: String(localized: "По %lld поездкам с выездом в это время"), best.trips))
                    .font(.rounded(12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.quietFill,
                    in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
    }

    /// «Лучше выезжать в 18:00 — обычно 45 мин, на 7 мин быстрее»; экономия —
    /// разность показанных минут. `spoken` — минуты словом, для VoiceOver.
    static func line(_ best: Commute.BestWindow, usual: TimeInterval, spoken: Bool = false) -> String {
        let saving = max(1, Commute.shownDelta(usual, best.medianDuration))
        let duration = spoken ? SpokenUnits.duration(best.medianDuration)
            : Formatting.unbreakable(Formatting.duration(best.medianDuration))
        let minutes = spoken ? SpokenUnits.minutes(saving)
            : Formatting.unbreakable(String(format: String(localized: "%lld мин"), saving))
        return String(format: String(localized: "Лучше выезжать в %1$@ — обычно %2$@, на %3$@ быстрее"),
                      Formatting.clock(minuteOfDay: best.startMinute), duration, minutes)
    }
}
