//
//  TripStatsSheet+Lifetime.swift
//  RadarMap
//
//  Итоги: «за всё время», вклад в рейтинг, достижения и ближайшая цель, отправка карточки.
//

import SwiftUI
import Charts
import MapKit
import CoreLocation

extension TripStatsSheet {

    // MARK: - За всё время (страница, 34b)

    func lifetimeStrip(trip: TripStats) -> some View {
        let cells: [(String, LocalizedStringKey, String, Color)] = [
            // Значки — словарь Icon, нейтральные (34b); красная — только
            // камера, тот же глиф, что на карте.
            ("\(trip.lifetime.trips)", LocalizedStringKey(Formatting.tripsLabel(trip.lifetime.trips)),
             Icon.trips, Theme.textSecondary),
            (Formatting.distance(trip.lifetime.distanceMeters), "пройдено",
             "point.topleft.down.to.point.bottomright.curvepath", Theme.textSecondary),
            ("\(trip.lifetime.camerasInLimit)", "камер в лимите", Icon.cameras, Theme.Icon.camera),
            ("\(trip.lifetime.bestStreak)", "лучшая серия чистых проездов", "flame.fill", Theme.textSecondary),
        ]
        return VStack(spacing: 12) {
            // Две на две, а не четыре в ряд. Четыре колонки на 390 pt дают по
            // 87 pt: узбекские подписи там переносились, а «2 590 км» просто
            // обрезалось троеточием. ViewThatFits тут не помогает — любой
            // maxWidth: .infinity внутри кандидата делает его «влезающим»
            // всегда, и мерить оказывается нечего. Сетка 2×2 честно даёт
            // каждому числу половину ширины и выглядит одинаково на обоих
            // языках; цена — сорок точек высоты.
            VStack(spacing: 14) {
                HStack(spacing: 0) {
                    StatStripCell(value: cells[0].0, label: cells[0].1, icon: cells[0].2,
                                  tint: cells[0].3)
                    StatStripDivider()
                    StatStripCell(value: cells[1].0, label: cells[1].1, icon: cells[1].2,
                                  tint: cells[1].3)
                }
                HStack(spacing: 0) {
                    StatStripCell(value: cells[2].0, label: cells[2].1, icon: cells[2].2,
                                  tint: cells[2].3)
                    StatStripDivider()
                    StatStripCell(value: cells[3].0, label: cells[3].1, icon: cells[3].2,
                                  tint: cells[3].3)
                }
            }
        }
        .statCard(padding: 14)
    }

    // MARK: - Достижения

    func achievementsSection(trip: TripStats) -> some View {
        // Без своего заголовка: живёт на странице «За всё время» (34b).
        VStack(alignment: .leading, spacing: 16) {
            // Лента бейджей показывает всё сразу и не отвечает «а что дальше» —
            // ближайшая цель с прогрессом отвечает.
            if let next = Achievements.next(for: trip.lifetime) {
                nextGoalRow(next)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Achievements.all(for: trip.lifetime)) { badge in
                        // Тап — что это за достижение и сколько осталось.
                        Button {
                            selectedBadge = badge
                        } label: {
                            AchievementBadge(badge: badge)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Ближайшая цель: иконка, название, полоса прогресса и «830 / 1 000».
    func nextGoalRow(_ badge: Achievement) -> some View {
        Button {
            selectedBadge = badge
        } label: {
            HStack(spacing: 12) {
                IconBadge(symbol: badge.icon, tint: Theme.textSecondary, size: 30)
                VStack(alignment: .leading, spacing: 5) {
                    // Подпись и название — в столбик: на узбекском «Eng yaqin
                    // maqsad» и «Ketma-ket 5 toza» вставали вплотную и читались
                    // как одна слипшаяся фраза.
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Ближайшая цель")
                            .font(.rounded(11, .medium))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text(badge.title)
                            .font(.rounded(15, .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Capsule()
                        .fill(Theme.stroke)
                        .frame(height: 5)
                        .overlay(alignment: .leading) {
                            GeometryReader { geometry in
                                Capsule()
                                    .fill(Theme.accent)
                                    .frame(width: max(6, geometry.size.width * badge.fraction))
                            }
                        }
                        .clipShape(Capsule())
                }
                Text(badge.progressText)
                    .font(.rounded(15, .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .statCard(padding: 14, radius: Theme.cornerMedium)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Шеринг периода

    /// Рендерим карточку в момент тапа — данные всегда свежие, открытие не тормозим.
    func share(summary: PeriodSummary) {
        guard !summary.isEmpty else { return }
        // Даты, а не одно слово: «Неделя» на картинке через месяц не значит
        // ничего, «3–9 августа» остаётся понятным всегда.
        let periodTitle = period.rangeTitle(containing: anchor)
        let tracks = mapData.tracks
        Task {
            let passes = TripHistory.records(env.trip.history, period: period,
                                             anchor: anchor).flatMap(\.passed)
            let map = await TripMapSnapshot.render(
                track: tracks.flatMap { $0 }, passes: passes,
                size: CGSize(width: 1032, height: 420))
            shareSubject = ShareSubjectBox(
                subject: .period(summary, title: periodTitle, map: map))
        }
    }
}
