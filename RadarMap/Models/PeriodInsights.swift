//
//  PeriodInsights.swift
//  RadarMap
//
//  Разбор периода: превращает сводку в два-три коротких вывода на человеческом
//  языке. Экран Итогов до этого показывал только цифры — «128 км, 6 превышений,
//  рейтинг 74», — а вопрос водителя другой: стало лучше или хуже, где и когда
//  я рискую, что делать. Цифра на него не отвечает, вывод отвечает.
//
//  Сравнения нормированы на дистанцию: неделя с поездкой на дачу в 600 км
//  всегда «хуже» недели, когда машина стояла во дворе, если считать превышения
//  штуками. Считаем на 100 км.
//
//  Чистые nonisolated-функции без обращения к часам — всё воспроизводимо
//  в тестах (PeriodInsightsTests).
//

import Foundation

/// Один вывод разбора: тон задаёт цвет строки, иконка — тему.
nonisolated struct Insight: Identifiable, Equatable {
    enum Kind: Equatable {
        case good       // стало лучше / период чистый
        case warning    // есть на что обратить внимание
        case bad        // стало хуже
        case neutral    // факт без оценки
    }

    let id: String
    let kind: Kind
    let icon: String
    let text: String
}

/// Что сделать: держать лимит у конкретной камеры. Текст собирает вьюха —
/// деньги форматируются на главном акторе (Formatting.money).
nonisolated struct ActionHint: Equatable, Sendable {
    let location: String
    /// Проездов с штрафуемым превышением у этой камеры.
    let over: Int
    /// Проездов этой камеры всего.
    let passes: Int
    /// Лимит, по которому там судили чаще всего (nil — только догадки).
    let limitKmh: Int?
    /// Ждущие ответа штрафы по этой камере, сум (0 — суммы назвать нельзя).
    let fine: Double
}

nonisolated enum PeriodInsights {

    /// Выводы по сводке — от самого важного к менее важному, не больше трёх.
    /// Порядок правил и есть приоритет: сначала динамика (стало лучше/хуже),
    /// потом «где» и «когда», и только потом рейтинг и оговорки о данных.
    static func build(_ summary: PeriodSummary) -> [Insight] {
        var found: [Insight] = []
        if let trend = trendInsight(summary) { found.append(trend) }
        if let clean = cleanInsight(summary) { found.append(clean) }
        if let place = placeInsight(summary) { found.append(place) }
        if let hours = hoursInsight(summary) { found.append(hours) }
        if let rating = ratingInsight(summary) { found.append(rating) }
        if let limits = limitsInsight(summary) { found.append(limits) }
        return Array(found.prefix(AppConfig.insightsMaxCount))
    }

    /// Один вывод для героя «Итогов» (6.1–6.2): место и часы риска живут в
    /// «Где теряете» и «Когда рискуете», движение рейтинга — меткой у числа;
    /// здесь — только то, чего нигде больше нет (динамика, чистый период,
    /// оговорка о лимитах).
    static func hero(_ summary: PeriodSummary) -> Insight? {
        build(summary).first { !heroDuplicates.contains($0.id) }
    }

    static let heroDuplicates: Set<String> = ["place", "hours", "rating.up", "rating.down"]

    /// Подсказка действием (31E): не «рискуете чаще», а что сделать и где —
    /// камера, сколько проездов из скольких выше лимита, какой лимит держать и
    /// во что это обошлось бы. nil — штрафуемых превышений в окне нет или
    /// камеру не назвать (запись вычищена, отметка водителей без места).
    static func action(_ summary: PeriodSummary) -> ActionHint? {
        guard summary.overPasses > 0, let location = summary.topOverLocation,
              summary.topOverCount > 0 else { return nil }
        return ActionHint(location: location, over: summary.topOverCount,
                          passes: max(summary.topOverPasses, summary.topOverCount),
                          limitKmh: summary.topOverLimit, fine: summary.topOverFine)
    }

    // MARK: - Правила

    /// Динамика нарушений к прошлому такому же периоду. Требуем и относительное
    /// изменение, и минимальный абсолютный шаг — иначе одна поездка сделает
    /// «рост вдвое» из ничего.
    private static func trendInsight(_ summary: PeriodSummary) -> Insight? {
        guard let current = summary.overPer100km,
              let previous = summary.previousOverPer100km else { return nil }
        let step = abs(current - previous)
        guard step >= AppConfig.insightTrendMinStep else { return nil }

        if current < previous * (1 - AppConfig.insightTrendChange) {
            return Insight(
                id: "trend.better", kind: .good, icon: "arrow.down.right.circle.fill",
                text: String(format: String(localized: "Стали ездить чище: %1$@ превышения на 100 км против %2$@ в прошлый период"),
                             rate(current), rate(previous)))
        }
        // «против 0,0 в прошлый период» — арифметика, а не мысль: если
        // превышений раньше не было, так и говорим.
        if previous < 0.05, current > previous {
            return Insight(
                id: "trend.worse", kind: .bad, icon: "arrow.up.right.circle.fill",
                text: String(format: String(localized: "Появились превышения: %@ на 100 км, в прошлый период их не было"),
                             rate(current)))
        }
        if current > previous * (1 + AppConfig.insightTrendChange) {
            return Insight(
                id: "trend.worse", kind: .bad, icon: "arrow.up.right.circle.fill",
                text: String(format: String(localized: "Рискуете чаще: %1$@ превышения на 100 км против %2$@ в прошлый период"),
                             rate(current), rate(previous)))
        }
        return nil
    }

    /// Период без единого штрафуемого проезда — это главная новость, если она есть.
    /// Без числа (6.2): «Камер в лимите: 31» здесь считало проезды с известным
    /// лимитом, легенда карты — разные камеры, «Детали» — все проезды; три
    /// числа под похожими словами. Число проездов — в карточке денег рядом.
    private static func cleanInsight(_ summary: PeriodSummary) -> Insight? {
        // Чистым период называем, только если судили хотя бы половину
        // проездов: один проезд с лимитом из сорока — не «ни одного превышения».
        guard summary.overPasses == 0, summary.cleanPasses > 0,
              summary.cleanPasses >= summary.cameras - summary.cleanPasses else { return nil }
        return Insight(
            id: "clean", kind: .good, icon: "checkmark.shield.fill",
            text: String(localized: "Ни одного штрафуемого превышения"))
    }

    /// Место, где превышают систематически: одна случайность советом не является.
    private static func placeInsight(_ summary: PeriodSummary) -> Insight? {
        guard let location = summary.topOverLocation, summary.topOverCount >= 2 else { return nil }
        return Insight(
            id: "place", kind: .warning, icon: "mappin.and.ellipse",
            text: String(format: String(localized: "Чаще всего — %1$@: превышений %2$lld из %3$lld"),
                         location, summary.topOverCount, summary.overPasses))
    }

    /// Время суток: вечер после работы и ночь пустых дорог ведут себя по-разному,
    /// и водитель обычно об этом не догадывается.
    private static func hoursInsight(_ summary: PeriodSummary) -> Insight? {
        guard summary.overPasses >= AppConfig.insightMinOverForHours,
              let peak = summary.peakBlock,
              peak.share >= AppConfig.insightPeakShare else { return nil }
        return Insight(
            id: "hours", kind: .warning, icon: "clock.badge.exclamationmark.fill",
            text: String(format: String(localized: "Время риска — %1$@: там %2$lld из %3$lld превышений"),
                         peak.title, peak.count, summary.overPasses))
    }

    /// Рейтинг — итоговая оценка стиля; называем только заметное движение.
    private static func ratingInsight(_ summary: PeriodSummary) -> Insight? {
        guard let rating = summary.rating, let previous = summary.previousRating,
              let delta = summary.ratingDelta,
              abs(delta) >= AppConfig.insightRatingStep else { return nil }
        let level = DrivingScore.level(for: rating)
        if delta > 0 {
            return Insight(
                id: "rating.up", kind: .good, icon: "chart.line.uptrend.xyaxis",
                text: String(format: String(localized: "Рейтинг вырос: %1$lld → %2$lld (%3$@)"),
                             previous, rating, level))
        }
        return Insight(
            id: "rating.down", kind: .warning, icon: "chart.line.downtrend.xyaxis",
            text: String(format: String(localized: "Рейтинг просел: %1$lld → %2$lld (%3$@)"),
                         previous, rating, level))
    }

    /// Честная оговорка: камеры проезжали, но лимит дороги у них неизвестен —
    /// значит, нули в «превышениях» это не заслуга водителя, а нехватка данных.
    private static func limitsInsight(_ summary: PeriodSummary) -> Insight? {
        let judged = summary.cleanPasses + summary.overPasses
        guard summary.cameras > 0, judged * 2 < summary.cameras else { return nil }
        // Ни одного известного лимита — прежняя фраза; большинство неизвестно
        // (1 из 41) — та же оговорка про большинство: иначе «превышений нет»
        // карточки денег стояло бы без объяснения, почему судили одну камеру.
        return Insight(
            id: "limits", kind: .neutral, icon: "questionmark.circle.fill",
            text: judged == 0
                ? String(localized: "У пройденных камер неизвестен лимит дороги — превышения по ним не считались")
                : String(localized: "У большинства пройденных камер неизвестен лимит дороги — превышения по ним не считались"))
    }

    /// «1,2» — одна цифра после запятой в локали приложения.
    private static func rate(_ value: Double) -> String {
        Formatting.decimal(value)
    }
}
