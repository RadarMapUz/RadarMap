//
//  TripStatsSheet+Trips.swift
//  RadarMap
//
//  Итоги: предложение склеить две поездки (список — TripStatsSheet+Pages).
//

import SwiftUI
import Charts
import MapKit
import CoreLocation

extension TripStatsSheet {

    // MARK: - Предложение склейки

    /// Пара «предыдущую завершили кнопкой, новая стартовала рядом и скоро»:
    /// автосклейка не имела права (ручной стоп — намерение), но чаще всего это
    /// заезд в магазин со стопом по привычке — предлагаем объединить одним тапом.
    var mergeSuggestion: (previous: TripRecord, next: TripRecord)? {
        guard !mergeSuggestionHidden else { return nil }
        let history = env.trip.history
        guard history.count >= 2 else { return nil }
        let next = history[0], previous = history[1]
        // Уже отклоняли для этой пары — не пристаём.
        guard Storage.double(.mergeSuggestDismissedID) != next.id else { return nil }
        // Карточка живёт рядом со списком своего окна, а не во всех периодах.
        guard period.interval(containing: anchor).contains(next.startedAt) else { return nil }
        guard TripMerge.suggestsMerge(previous: previous, next: next,
                                      savedPlaces: env.settings.savedPlaceCoordinates)
        else { return nil }
        return (previous, next)
    }

    func mergeSuggestionCard(_ pair: (previous: TripRecord, next: TripRecord)) -> some View {
        let gap = pair.next.startedAt.timeIntervalSince(pair.previous.endedAt)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconBadge(symbol: "arrow.triangle.merge", tint: Theme.textSecondary, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Похоже, это одна поездка")
                        .font(.rounded(14, .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(String(format: String(localized: "%1$@ и %2$@ разделяет стоянка %3$@"),
                                Formatting.clock(pair.previous.startedAt),
                                Formatting.clock(pair.next.startedAt),
                                Formatting.duration(gap)))
                        .font(.rounded(15))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Button {
                    merge(next: pair.next)
                } label: {
                    Text("Объединить")
                        .font(.rounded(15, .semibold))
                        .foregroundStyle(Theme.onAccentFill)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        // 15 pt + 2×10 давали ~40 pt — мимо мишени пальца.
                        .frame(minHeight: Theme.controlSize)
                        .background(Theme.accentFill, in: Capsule())
                        .contentShape(Capsule())
                }
                // Средняя вибрация — в merge(): тот же путь у контекстного меню.
                .buttonStyle(PressableStyle(.ownFeedback))
                Button {
                    Storage.set(pair.next.id, for: .mergeSuggestDismissedID)
                    withMotion(Motion.standard) { mergeSuggestionHidden = true }
                } label: {
                    Text("Это разные")
                        .font(.rounded(15, .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .frame(minHeight: Theme.controlSize)
                        .background(Theme.surface, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle(.cancel))
            }
        }
        .statCard()
    }

    /// Объединение из карточки и из контекстного меню — одним путём.
    func merge(next record: TripRecord) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withMotion(Motion.standard) {
            // Любая из двух записей могла быть «применена» к карте — слепок
            // после склейки не существует, выбор снимаем.
            clearMapSelection()
            env.trip.mergeWithPrevious(id: record.id)
        }
    }
}
