//
//  CommuteCard.swift
//  RadarMap
//
//  Шапка листа «Дорога на работу / домой» — ответ на вопрос, который
//  водитель задаёт себе каждый день: сколько я сегодня ехал, это нормально,
//  и когда надо было выехать. В самих «Итогах» дорога — строкой раздела
//  (34b), сюда ведёт тап по ней.
//
//  Карточка говорит словами, а не средними: «Вчера · 8:22 → 9:17 · 55 мин ·
//  на 12 мин дольше обычного», «Обычно 44 мин, выезд около 8:20», и совет —
//  только когда он настоящий: «Выезжайте в 7:45 — в среднем 37 мин». Все
//  цифры готовые из Commute (модель, под тестами), вьюха не считает ничего.
//

import SwiftUI

struct CommuteCard: View {
    let summary: Commute.Summary
    /// Дорога этого направления за 30 дней в сумах (EnergySplit — по
    /// поездкам, с зарядом дня); nil — суммы нет.
    var monthlyCost: Double? = nil
    /// «Обычно ~35 мин (по водителям)» (8.8.16) — пока своего «обычно» нет.
    var crowdUsual: TimeInterval? = nil

    var body: some View {
        let monthly = monthlyCost
        VStack(alignment: .leading, spacing: 12) {
            header
            // Пилюля — рядом с цифрой, пока влезает; иначе строкой ниже.
            // Узбекское «odatdagidan 7 daq uzoqroq» рядом с «55 daq» на
            // крупном шрифте обрезалось до «uzoqr…» (снимок 14.6) — а в
            // пилюле весь смысл: дольше или быстрее.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    lastDuration
                    if let delay = summary.lastDelay {
                        CommuteDelayPill(delay: delay)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    lastDuration
                    if let delay = summary.lastDelay {
                        CommuteDelayPill(delay: delay)
                    }
                }
            }
            // «Обычно» есть — оно подписано пунктиром графика под карточкой
            // (34: «обычно 53 мин» стояло на экране трижды); нет — подсказка.
            if summary.usual == nil {
                if let crowdUsual {
                    // Чужое «обычно» — с названным источником, своё его сменит.
                    Text(Self.crowdLine(crowdUsual))
                        .font(.rounded(13))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(String(format: String(localized: "Ещё %lld — и появится «обычно»"),
                            max(1, AppConfig.commuteMinTrips - summary.trips.count)))
                    .font(.rounded(12))
                    .foregroundStyle(Theme.textTertiary)
            }
            if let week = summary.week, week.isNoticeable {
                // Неделя дороги (8.8.15) — только если она не «как обычно».
                Text(Self.weekLine(week))
                    .font(.rounded(13))
                    .foregroundStyle(week.delta > 0 ? Theme.warning : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let monthly {
                // «В месяц ≈ 46 000 сум» (12б.3, 21.4): те же поездки, тот же расчёт.
                Label(String(format: String(localized: "Расходы в месяц ≈ %@"), Formatting.money(monthly)),
                      systemImage: "fuelpump")
                    .font(.rounded(13))
                    .foregroundStyle(Theme.textSecondary)
            }
            if let best = summary.best {
                CommuteAdvice(best: best)
            }
        }
        .statCard()
        // Карточка — одна мысль, и голосом словами: «55 минут, на 12 минут
        // дольше обычного», «с 8:22 до 9:17» — без «мин», стрелок и тильд.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spoken(monthlyFuel: monthly)))
    }

    private var lastDuration: some View {
        Text(Formatting.duration(summary.last.duration))
            .font(.numeral(30, .heavy))
            .monospacedDigit()
            .foregroundStyle(Theme.textPrimary)
    }

    /// Всё, что на карточке, — фразами для VoiceOver.
    private func spoken(monthlyFuel: Double?) -> String {
        var parts = [summary.direction.title,
                     Self.whenLine(summary.last, spoken: true),
                     SpokenUnits.duration(summary.last.duration)]
        if let delay = summary.lastDelay { parts.append(CommuteDelayPill.spoken(delay)) }
        if let usual = summary.usual {
            parts.append(Self.usualLine(usual: usual, departure: summary.usualDepartureMinute, spoken: true))
        } else {
            if let crowdUsual { parts.append(Self.crowdLine(crowdUsual, spoken: true)) }
            parts.append(String(format: String(localized: "Ещё %lld — и появится «обычно»"),
                                max(1, AppConfig.commuteMinTrips - summary.trips.count)))
        }
        if let week = summary.week, week.isNoticeable { parts.append(Self.weekLine(week, spoken: true)) }
        if let monthlyFuel {
            parts.append(String(format: String(localized: "Расходы в месяц около %@"), Formatting.money(monthlyFuel)))
        }
        if let best = summary.best { parts.append(CommuteAdvice.line(best, spoken: true)) }
        return parts.joined(separator: ". ")
    }

    /// Шапка листа «Дорога домой»: название — в навбаре, здесь только когда
    /// (34: «Дорога домой» стояло дважды подряд).
    private var header: some View {
        Text(Self.whenLine(summary.last))
            .font(.rounded(13))
            .foregroundStyle(Theme.textSecondary)
            .monospacedDigit()
    }

    /// «Обычно 39 мин, выезжаете около 18:37». `spoken` — для VoiceOver:
    /// «Обычно 39 минут, …».
    static func usualLine(usual: TimeInterval, departure: Int?, spoken: Bool = false) -> String {
        let time = spoken ? SpokenUnits.duration(usual) : Formatting.unbreakable(Formatting.duration(usual))
        guard let departure else {
            return String(format: String(localized: "Обычно %@"), time)
        }
        return String(format: String(localized: "Обычно %1$@, выезжаете около %2$@"),
                      time, Formatting.clock(minuteOfDay: departure))
    }

    /// «Обычно ~35 мин (по водителям)»; голосом — «Обычно около 35 минут,
    /// по данным водителей».
    static func crowdLine(_ seconds: TimeInterval, spoken: Bool = false) -> String {
        guard !spoken else {
            return String(format: String(localized: "Обычно около %@, по данным водителей"),
                          SpokenUnits.duration(seconds))
        }
        return String(format: String(localized: "Обычно ~%@ (по водителям)"),
                      Formatting.unbreakable(Formatting.duration(seconds)))
    }

    /// «За 7 дней в среднем 41 мин — на 3 мин дольше обычного». «За 7 дней»,
    /// а не «за неделю»: окно скользящее, а «Неделя» в «Итогах» — календарная.
    static func weekLine(_ week: Commute.Week, spoken: Bool = false) -> String {
        let average = spoken ? SpokenUnits.duration(week.average)
            : Formatting.unbreakable(Formatting.duration(week.average))
        let minutes = spoken ? SpokenUnits.duration(abs(week.delta))
            : Formatting.unbreakable(Formatting.duration(abs(week.delta)))
        return week.delta > 0
            ? String(format: String(localized: "За 7 дней в среднем %1$@ — на %2$@ дольше обычного"), average, minutes)
            : String(format: String(localized: "За 7 дней в среднем %1$@ — на %2$@ меньше обычного"), average, minutes)
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

/// «Вам нужно быть на работе к 9:00?» — один раз, когда распорядок уже
/// виден по поездкам (ArrivalTarget.suggestion). Без ответа «да» срока нет,
/// и призрак не говорит «позже срока» никогда.
struct ArrivalTargetQuestion: View {
    let minute: Int
    let onAnswer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                IconBadge(symbol: "clock.fill", tint: Theme.textSecondary, size: 30)
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
                SecondaryButton(title: "Нет", touch: .cancel) { onAnswer(false) }
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
                IconBadge(symbol: "bell.fill", tint: Theme.textSecondary, size: 30)
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
            .background(Theme.quietFill, in: Capsule())
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .accessibilityLabel(Text(Self.spoken(delay)))
    }

    /// `Formatting.delayPhrase` голосом: «на 12 минут дольше обычного».
    static func spoken(_ delay: TimeInterval) -> String {
        let minutes = Int((abs(delay) / 60).rounded())
        if abs(delay) < AppConfig.commuteNoticeableDelaySeconds || minutes == 0 {
            return String(localized: "как обычно")
        }
        return delay > 0
            ? String(format: String(localized: "на %@ дольше обычного"), SpokenUnits.minutes(minutes))
            : String(format: String(localized: "на %@ быстрее обычного"), SpokenUnits.minutes(minutes))
    }
}

/// Совет о времени выезда — только когда он есть (Commute.bestWindow).
struct CommuteAdvice: View {
    let best: Commute.BestWindow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            IconBadge(symbol: "lightbulb.fill", tint: Theme.textSecondary, size: 30)
            // Число не отрывается от «мин» (unbreakable): «на 7 / мин» через
            // перенос читалось как две разные вещи.
            Text(Self.line(best))
                .font(.rounded(13, .medium))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.quietFill,
                    in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.line(best, spoken: true)))
    }

    /// «Выезжайте в 7:45 — в среднем 37 мин, на 7 мин быстрее»; `spoken` —
    /// минуты словом, для VoiceOver.
    static func line(_ best: Commute.BestWindow, spoken: Bool = false) -> String {
        let time: (TimeInterval) -> String = spoken
            ? { SpokenUnits.duration($0) }
            : { Formatting.unbreakable(Formatting.duration($0)) }
        return String(format: String(localized: "Выезжайте в %1$@ — в среднем %2$@, на %3$@ быстрее"),
                      Formatting.clock(minuteOfDay: best.startMinute),
                      time(best.medianDuration), time(best.saving))
    }
}
