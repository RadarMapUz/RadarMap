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
                                Capsule().fill(Theme.accentFill)
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

    // MARK: - Герой: рейтинг + километры + вывод периода

    /// Герой блока «Как я езжу»: кольцо рейтинга, километры, время за рулём и
    /// разница к прошлому периоду. Тап — расшифровка рейтинга. Подсказка
    /// действием и выводы живут в блоке «Где теряю деньги и время» (31E):
    /// у карточки одна главная цифра и одно объяснение.
    ///
    /// Три кегля и ни одной плашки (31E): 30 — километры, 15 — уровень,
    /// 13 — всё подписное. Дельты — цветным текстом в строке, а не капсулами:
    /// пять кеглей и три цветных чипа читались прайс-листом (design_audit 26.10).
    func heroCard(trip: TripStats, summary: PeriodSummary) -> some View {
        Button {
            showRatingInfo = true
        } label: {
            heroTopRow(trip: trip, summary: summary)
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
                    .font(.rounded(13))
                    .foregroundStyle(Theme.textSecondary)
                Text(Formatting.distance(summary.distance))
                    .font(.numeral(30, .heavy))
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let change = summary.distanceChange {
                    // Переносится, а не ужимается: «+18 км к прошлой неделе» на
                    // SE в узбекском — две строки, и это честнее «↗ 178 %».
                    Text(distanceChangeText(change))
                        .font(.rounded(13, .semibold))
                        .foregroundStyle(change.isUp ? Theme.accent : Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(Text(distanceChangeVoice(change)))
                }
                if let rating = summary.rating {
                    ratingLine(rating: rating, delta: summary.ratingDelta)
                }
                // Переносится, а не обрезается: при крупном шрифте «за рулём»
                // превращалось в «за ру…» — обрезанная фраза хуже второй строки.
                Text(heroSubtitle(summary))
                    .font(.rounded(13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                // «Чистая серия: N подряд» ушла (34): пожизненный счётчик
                // проездов в карточке «за неделю» (правило 14) и четвёртая
                // «серия» на листе — рядом «Серия: N недель» цели недели и
                // «5 чистых подряд» ближайшего достижения.
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.rounded(15, .semibold))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    /// «Уверенный · −8 к прошлой»: уровень и движение рейтинга одной строкой,
    /// дельта — цветом текста, без капсулы. Не влезает — переносится.
    @ViewBuilder
    func ratingLine(rating: Int, delta: Int?) -> some View {
        let level = Text(DrivingScore.level(for: rating))
            .font(.rounded(15, .bold))
            .foregroundStyle(Theme.textPrimary)
        if let delta, abs(delta) >= AppConfig.insightRatingStep {
            let versus = period.versusPrevious
            let change = Text(period.ratingDeltaText(delta))
                .font(.rounded(13, .semibold).monospacedDigit())
                .foregroundStyle(delta > 0 ? Theme.success : Theme.danger)
            // Не влезает рядом — дельта строкой ниже, а не «стиль ·» с
            // повисшей точкой в конце строки (снимок SE, 26.10).
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    level.fixedSize()
                    Text(verbatim: "·").font(.rounded(13)).foregroundStyle(Theme.textTertiary)
                    change.fixedSize()
                }
                VStack(alignment: .leading, spacing: 2) {
                    level.fixedSize(horizontal: false, vertical: true)
                    change.fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(DrivingScore.level(for: rating)) + Text(verbatim: ", ")
                + Text(delta > 0 ? String(localized: "Рейтинг вырос на \(delta) \(versus)")
                                 : String(localized: "Рейтинг снизился на \(abs(delta)) \(versus)")))
        } else {
            level.fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Одна строка каталога с аргументами, а не склейка трёх: переводчик
    /// видит фразу целиком и порядок слов в узбекском свой (6.11).
    func heroSubtitle(_ summary: PeriodSummary) -> String {
        String(localized: "Поездок: \(summary.trips) · \(Formatting.duration(summary.movingDuration)) за рулём")
    }

    /// «+18 км к прошлой неделе» или «+12 % к прошлой неделе» — процент
    /// только у сопоставимых периодов (PeriodSummary.distanceChange).
    func distanceChangeText(_ change: DistanceChange) -> String {
        let versus = change.soFar ? period.versusPreviousSoFar : period.versusPrevious
        if let percent = change.percent {
            return String(format: String(localized: "%1$@ %% %2$@"), Formatting.signed(percent), versus)
        }
        let sign = change.meters >= 0 ? "+" : "−"
        return String(format: String(localized: "%1$@ %2$@"),
                      sign + Formatting.distance(abs(change.meters)), versus)
    }

    func distanceChangeVoice(_ change: DistanceChange) -> String {
        let amount = change.percent.map { "\(abs($0)) %" } ?? Formatting.distance(abs(change.meters))
        return (change.isUp ? String(localized: "Больше, чем в прошлый период")
                            : String(localized: "Меньше, чем в прошлый период")) + ": " + amount
    }

    /// «Держите 60 у «Ц-1, Амир Темур»: проезды выше лимита — 2 из 3. Это
    /// 1,1 млн сум возможных штрафов». Сумма — только достоверная (ActionHint.fine), лимит —
    /// только известный; без них фраза короче, а не с выдуманным числом.
    /// `periodRisk` — сумма карточки «Возможные штрафы» прямо над подсказкой:
    /// если вся она от этой камеры, «Это 2,2 млн сум» повторяло бы ту же
    /// цифру второй раз подряд (34) — тогда фраза без суммы.
    func actionText(_ hint: ActionHint, periodRisk: Double = 0) -> String {
        // Счётное слово — перед числами: «проезды выше лимита — 2 из 3» не
        // зависит от формы числа ни в русском, ни в узбекском.
        var text = hint.limitKmh.map {
            String(format: String(localized: "Держите %1$lld у «%2$@»: проезды выше лимита — %3$lld из %4$lld"),
                   $0, hint.location, hint.over, hint.passes)
        } ?? String(format: String(localized: "Сбавьте у «%1$@»: проезды выше лимита — %2$lld из %3$lld"),
                    hint.location, hint.over, hint.passes)
        if hint.fine > 0, abs(hint.fine - periodRisk) >= 1 {
            text += ". " + String(format: String(localized: "Это %@ возможных штрафов."), Formatting.money(hint.fine))
        }
        return text
    }

    // MARK: - Строка вывода (живёт в герой-карточке)

    /// Значок без кружка-подложки: строка — продолжение карточки, а не ещё
    /// одна плашка внутри неё.
    func heroLine(symbol: String, tint: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.rounded(15, .semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(text)
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
}
