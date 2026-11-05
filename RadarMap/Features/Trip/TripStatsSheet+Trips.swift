//
//  TripStatsSheet+Trips.swift
//  RadarMap
//
//  Итоги: список поездок периода и предложение склеить.
//

import SwiftUI
import Charts
import MapKit
import CoreLocation

extension TripStatsSheet {

    // MARK: - Список поездок периода

    /// Первые statsTripsPreview строк + «Показать все поездки (N)»: неделя
    /// активной езды — это 20+ записей, и без обрезки блок «За всё время»
    /// приходилось искать археологией.
    /// `all` — из того же экрана, что герой: второе чтение `current` в кадр
    /// смены периода собирало бы весь экран второй раз (ревью 19.10).
    func tripsSection(all: [TripRecord], proxy: ScrollViewProxy) -> some View {
        let shown = tripsExpanded ? all : Array(all.prefix(AppConfig.statsTripsPreview))
        return VStack(spacing: 10) {
            if let pair = mergeSuggestion {
                mergeSuggestionCard(pair)
            }
            TripHistorySection(
                title: "",
                records: shown,
                selectedID: mapSelection?.id,
                onShowOnMap: { showOnMap($0, proxy: proxy) },
                onOpenDetail: { path.append(.trip($0.id)) },
                onRepeat: onRoute.map { route in
                    { coord, name in dismiss(); route(coord, name) }
                },
                onDelete: { record in
                    withMotion {
                        if mapSelection?.id == record.id { clearMapSelection() }
                        env.trip.deleteRecord(id: record.id)
                    }
                },
                canMerge: { env.trip.canMergeWithPrevious(id: $0.id) },
                onMerge: { merge(next: $0) })
            if !tripsExpanded, all.count > AppConfig.statsTripsPreview {
                Button {
                    withMotion(Motion.standard) { tripsExpanded = true }
                } label: {
                    HStack(spacing: 6) {
                        Text(String(format: String(localized: "Показать все поездки (%lld)"),
                                    all.count))
                            .font(.rounded(15, .semibold))
                        Image(systemName: "chevron.down")
                            .font(.rounded(10, .bold))
                    }
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity)
                    // Голая строка-ссылка: капсула на всю ширину выглядела ещё
                    // одной карточкой в и без того плотном столбце.
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
            }
        }
    }

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
