//
//  TripStatsSheet+Hero.swift
//  RadarMap
//
//  Итоги: шапка периода — выбор периода, рейтинг, подсказки, сдвиг к прошлому.
//

import SwiftUI
import Charts
import MapKit
import CoreLocation

extension TripStatsSheet {

    // MARK: - Фильтр периода

    /// Сегменты на общей дорожке: выделение переезжает между ними, а не
    /// перекрашивается на месте — сразу видно, что это один переключатель.
    var periodPicker: some View {
        HStack(spacing: 2) {
            ForEach(StatsPeriod.allCases) { item in
                let selected = period == item
                Button {
                    withMotion(Motion.standard) { period = item }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Text(item.title)
                        .font(.rounded(15, .semibold))
                        // Белое на accentFill: ночной accent светлый (он бывает
                        // текстом), и графитовый Theme.background на нём был
                        // текстом цвета фона, а не контрастной подписью.
                        .foregroundStyle(selected ? Theme.onAccentFill : Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background {
                            if selected {
                                Capsule().fill(Theme.accentFill.gradient)
                                    .matchedGeometryEffect(id: "periodPill", in: periodPill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(4)
        .background(Theme.surface, in: Capsule())
    }

    /// Строка периода со стрелками: «‹ 5–11 августа ›». Без неё календарные
    /// периоды бессмысленны — непонятно, какое окно на экране и что листаешь.
    var periodNavigator: some View {
        HStack(spacing: 8) {
            navArrow("chevron.left", enabled: true) { step(-1) }
            Text(period.rangeTitle(containing: anchor))
                .font(.rounded(14, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity)
                .contentTransition(.numericText())
                .motionAnimation(Motion.quick, value: anchor)
            // Вперёд из текущего периода некуда: будущего в статистике нет.
            navArrow("chevron.right", enabled: period.canGoForward(from: anchor)) { step(1) }
        }
        .padding(.horizontal, 4)
    }

    func navArrow(_ symbol: String, enabled: Bool,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.rounded(15, .bold))
                .foregroundStyle(enabled ? Theme.accent : Theme.textTertiary.opacity(0.4))
                // Голая стрелка: капсулы-подложки делали из строки периода
                // третий ряд «кнопочной» мебели подряд. Мишень — полные 44 pt:
                // при 36×32 соседний период пролистывался мимо пальца.
                .frame(width: Theme.controlSize, height: Theme.controlSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
        // Тернарник даёт String, и Text берёт НЕлокализующий инициализатор —
        // без явного String(localized:) подпись оставалась русской на узбекском.
        .accessibilityLabel(Text(symbol == "chevron.left"
                                 ? String(localized: "Предыдущий период")
                                 : String(localized: "Следующий период")))
    }

    func step(_ direction: Int) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withMotion(Motion.standard) {
            anchor = period.shifted(anchor, by: direction)
        }
    }

    // MARK: - Герой: рейтинг + километры + выводы периода

    /// Одна карточка-рассказ: кольцо рейтинга, главная цифра периода с дельтой
    /// и — под тонкой чертой — выводы (PeriodInsights). Раньше выводы жили
    /// своей коробкой с заголовком «Разбор недели»: три отдельных карточки
    /// подряд читались тяжело, а выводы и есть объяснение рейтинга, поэтому
    /// им место в его карточке, и тап по любому месту ведёт в расшифровку.
    func heroCard(trip: TripStats, summary: PeriodSummary, insights: [Insight]) -> some View {
        Button {
            showRatingInfo = true
        } label: {
            VStack(spacing: 14) {
                heroTopRow(trip: trip, summary: summary)
                if !insights.isEmpty {
                    Divider().overlay(Theme.stroke)
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(insights) { insightRow($0) }
                    }
                }
            }
            .statCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // combine, а не свой label: у Button собственная подпись ЗАМЕНЯЕТ
        // производную, и VoiceOver терял ровно то, ради чего сюда смотрят —
        // балл, километры, дельту и вывод. Назначение кнопки говорит hint.
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Как считается рейтинг"))
    }

    func heroTopRow(trip: TripStats, summary: PeriodSummary) -> some View {
        HStack(spacing: 16) {
            if let rating = summary.rating {
                RatingRing(rating: rating)
                    .frame(width: 88, height: 88)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(period.caption)
                    .font(.rounded(11, .medium))
                    .foregroundStyle(Theme.textTertiary)
                // Метка дельты словами — «↘ 89 % к прошлой неделе» (6.3); не
                // влезает рядом с числом — встаёт под ним, а не сжимает его.
                let distance = Text(Formatting.distance(summary.distance))
                    .font(.rounded(30, .heavy))
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                // Третий вариант — короткие слова: на SE при крупном кегле и
                // в узбекском «↗ 100 % к прошлому месяцу» не помещается и под
                // числом. Голым «↘ 73 %» он был до 20.10 — и тогда «−8» у
                // рейтинга тоже оставалось без «к чему»; голос — целиком.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        distance
                        if let delta = summary.distanceDeltaPercent { deltaBadge(delta) }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        distance
                        if let delta = summary.distanceDeltaPercent { deltaBadge(delta) }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        distance.minimumScaleFactor(0.6)
                        if let delta = summary.distanceDeltaPercent { deltaBadge(delta, words: .short) }
                    }
                    // Последний — голый процент: на SE при xxxLarge и короткое
                    // «к прошлому» не помещается, а fixedSize выдавил бы карточку.
                    VStack(alignment: .leading, spacing: 4) {
                        distance.minimumScaleFactor(0.6)
                        if let delta = summary.distanceDeltaPercent { deltaBadge(delta, words: .none) }
                    }
                }
                if let rating = summary.rating {
                    // Уровень и движение рейтинга — в одной строке. Раньше
                    // бейдж «−16» висел под кольцом и прижимался к его обводке:
                    // круг держал сразу три вещи — число, подпись и дельту.
                    // Не влезает рядом («Уверенный, но с риском» + «−8 к
                    // прошлой» на SE) — метка встаёт под уровнем.
                    let level = Text(DrivingScore.level(for: rating))
                        .font(.rounded(14, .bold))
                        .foregroundStyle(Theme.textPrimary)
                    if let delta = summary.ratingDelta,
                       abs(delta) >= AppConfig.insightRatingStep {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                level.fixedSize()
                                ratingDeltaBadge(delta)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                level.fixedSize(horizontal: false, vertical: true)
                                ratingDeltaBadge(delta)
                            }
                        }
                    } else {
                        level.fixedSize(horizontal: false, vertical: true)
                    }
                }
                // Переносится, а не обрезается: при крупном шрифте «за рулём»
                // превращалось в «за ру…» — обрезанная фраза хуже второй строки.
                Text(heroSubtitle(summary))
                    .font(.rounded(13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if trip.isLifetimeTrusted, trip.lifetime.cleanStreak >= 2 {
                    // Огонёк цветной, подпись — обычным вторичным текстом:
                    // коричневая строка читалась как предупреждение, а это похвала.
                    HStack(spacing: 4) {
                        Image(systemName: "flame.fill")
                            .foregroundStyle(Theme.warning)
                        Text(String(format: String(localized: "чистая серия: %lld подряд"),
                                    trip.lifetime.cleanStreak))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .font(.rounded(13, .semibold))
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.rounded(15, .semibold))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    /// Одна строка каталога с аргументами, а не склейка трёх: переводчик
    /// видит фразу целиком и порядок слов в узбекском свой (6.11).
    func heroSubtitle(_ summary: PeriodSummary) -> String {
        String(localized: "Поездок: \(summary.trips) · \(Formatting.duration(summary.movingDuration)) за рулём")
    }

    /// «+6 к прошлой» у уровня рейтинга: рост — зелёный, просадка — красная.
    /// Голое «↓ -8» не говорило ни что это баллы рейтинга, ни с чем сравнили
    /// (6.3); знак — типографский минус, без стрелки (стрелка и минус
    /// говорили одно и то же дважды). Голос — целиком, с числом.
    func ratingDeltaBadge(_ delta: Int) -> some View {
        let up = delta > 0
        let tint = up ? Theme.success : Theme.danger
        let versus = period.versusPrevious
        return Text(period.ratingDeltaText(delta))
            .font(.rounded(11, .bold).monospacedDigit())
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
            .fixedSize()
            .accessibilityLabel(Text(up ? String(localized: "Рейтинг вырос на \(delta) \(versus)")
                                        : String(localized: "Рейтинг снизился на \(abs(delta)) \(versus)")))
    }

    // MARK: - Строка вывода (живёт в герой-карточке)

    func insightRow(_ insight: Insight) -> some View {
        let tint = Self.insightTint(insight.kind)
        return HStack(alignment: .top, spacing: 12) {
            IconBadge(symbol: insight.icon, tint: tint, size: 30)
            Text(insight.text)
                .font(.rounded(15, .medium))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    static func insightTint(_ kind: Insight.Kind) -> Color {
        switch kind {
        case .good:    return Theme.success
        case .warning: return Theme.warning
        case .bad:     return Theme.danger
        case .neutral: return Theme.accent
        }
    }

    enum DeltaWords { case full, short, none }

    func deltaBadge(_ delta: Int, words: DeltaWords = .full) -> some View {
        let up = delta >= 0
        let text: LocalizedStringKey
        switch words {
        case .full:  text = "\(abs(delta))% \(period.versusPrevious)"
        case .short: text = "\(abs(delta))% \(period.versusPreviousShort)"
        case .none:  text = "\(abs(delta))%"
        }
        return Label(text, systemImage: up ? "arrow.up.right" : "arrow.down.right")
            .font(.rounded(11, .bold))
            .foregroundStyle(up ? Theme.accent : Theme.textSecondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background((up ? Theme.accent : Theme.textSecondary).opacity(0.14), in: Capsule())
            .accessibilityLabel(Text((up ? String(localized: "Больше, чем в прошлый период")
                                         : String(localized: "Меньше, чем в прошлый период"))
                                     + ": \(abs(delta)) %"))
            .fixedSize()
    }
}
