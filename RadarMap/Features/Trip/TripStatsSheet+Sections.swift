//
//  TripStatsSheet+Sections.swift
//  RadarMap
//
//  Итоги: дни периода, дорога на работу, детали периода, пустые состояния.
//

import SwiftUI
import Charts
import MapKit
import CoreLocation

extension TripStatsSheet {

    // Полоса KPI и «Когда рискуете» — в TripStatsCards.swift: карточки
    // читают только summary, и экрану они не должны стоить ни строчки.

    /// «5 из 7» — в окне периода видно, насколько плотно катаешься.
    func activeDaysText(_ summary: PeriodSummary) -> String {
        guard let window = period.chartDays(containing: anchor) else {
            return "\(summary.activeDays)"
        }
        return String(format: String(localized: "%1$lld из %2$lld"), summary.activeDays, window)
    }

    // MARK: - График по дням

    /// Те же столбики, что в карточке-ответе (ItogiDayBars, три состояния),
    /// с подписью самого длинного дня.
    func dailyChart(days: Int, summary: PeriodSummary) -> some View {
        let daily = TripHistory.dailyKm(
            TripHistory.records(env.trip.history, period: period, anchor: anchor),
            days: days, now: period.interval(containing: anchor).end.addingTimeInterval(-1))
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: String(localized: "Километры по дням")) {
                // «Больше всего» — только когда есть из чего выбирать (34).
                if let busiest = summary.busiestDay, summary.busiestDayKm > 0, summary.activeDays >= 2 {
                    Text(String(format: String(localized: "Больше всего — %@"),
                                Formatting.dayTitle(busiest)))
                        .font(.rounded(13, .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            ItogiPeriodChart(bars: daily, unit: period == .week ? .weekday : .day, height: 110)
        }
        .statCard()
    }

    var emptyHint: some View {
        VStack(spacing: 12) {
            IconBadge(symbol: Icon.trips, tint: Theme.textSecondary, size: 72)
            Text("Здесь появятся ваши поездки")
                .font(.rounded(16, .bold))
                .foregroundStyle(Theme.textPrimary)
            // По режиму старта (Н13 плана 34): при «Авто» поездка начинается
            // сама, и «нажмите» было неправдой о приложении.
            Text(emptyHintText)
                .font(.rounded(15))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }

    /// Поездки есть, но не в этом окне: не оставляем экран пустым — сразу даём
    /// уйти туда, где данные есть.
    /// Пустое окно — не тупик: сразу предлагаем ближайший период, где поездки
    /// есть, одной кнопкой (искать его стрелками вслепую — работа для водителя).
    var emptyHintText: String {
        switch env.settings.tripStartMode {
        case .auto, .smart:
            return String(localized: "Поездка запишется сама, когда поедете: трек, скорость у каждой камеры и статистика.")
        case .carOnly:
            return String(localized: "Поездка запишется сама, когда телефон подключится к вашей машине.")
        case .manual:
            return String(localized: "Нажмите «Поездка» внизу карты — соберём трек, скорость у каждой камеры и статистику.")
        }
    }

    var emptyPeriodHint: some View {
        VStack(spacing: 10) {
            IconBadge(symbol: Icon.byDays, tint: Theme.textSecondary, size: 44)
            Text("В этом периоде поездок не было")
                .font(.rounded(15, .bold))
                .foregroundStyle(Theme.textPrimary)
            if let nearest = nearestNonEmptyAnchor() {
                Button {
                    withMotion(Motion.standard) {
                        autoShifted = false
                        anchor = nearest
                    }
                } label: {
                    Text(String(format: String(localized: "Показать: %@"),
                                period.rangeTitle(containing: nearest)))
                        .font(.rounded(15, .semibold))
                        .foregroundStyle(Theme.accent)
                        // Ссылка цветом ссылки, без пастельной капсулы (31E).
                        .frame(minHeight: Theme.controlSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .statCard(padding: 24)
    }

    /// Ближайшее к текущему окно с поездками (ItogiWindow — по дневным
    /// агрегатам, они переживают чистку истории).
    func nearestNonEmptyAnchor() -> Date? {
        ItogiWindow.nearestAnchor(days: env.trip.days, period: period, anchor: anchor)
    }
}
