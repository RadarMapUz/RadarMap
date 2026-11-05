//
//  TripStatsSheet+Hero.swift
//  RadarMap
//
//  Итоги: шапка периода — выбор периода, стрелки окна и подпись подменённого окна.
//  Сама карточка-ответ — ItogiAnswerCard.
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
                    withMotion(Motion.standard) {
                        autoShifted = false
                        period = item
                    }
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
                .buttonStyle(PressableStyle(.choice))
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
                .foregroundStyle(enabled ? Theme.accent : Theme.textTertiary)
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
        withMotion(Motion.standard) {
            autoShifted = false
            anchor = period.shifted(anchor, by: direction)
        }
    }

    // MARK: - Подменённое окно

    /// «На этой неделе поездок ещё нет — показана прошлая»: при открытии
    /// пустое идущее окно молча менялось на прошлое, и чужие километры
    /// читались как эти (аудит 05.11). Строка живёт, пока водитель сам не
    /// листнул окно или не сменил период.
    @ViewBuilder var windowNotice: some View {
        if autoShifted, let text = ItogiWindow.notice(period: period, shown: anchor, now: Date()) {
            HStack(spacing: 8) {
                Image(systemName: Icon.byDays)
                    .font(.rounded(12, .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
                Text(text)
                    .font(.rounded(13, .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
        }
    }
}
