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

    func dailyChart(days: Int, summary: PeriodSummary) -> some View {
        let daily = TripHistory.dailyKm(
            TripHistory.records(env.trip.history, period: period, anchor: anchor),
            days: days, now: period.interval(containing: anchor).end.addingTimeInterval(-1))
        let peak = max(daily.map(\.km).max() ?? 0, 1)
        let dense = days > 10
        let hasOverspeed = daily.contains(where: \.hasOverspeed)
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: String(localized: "Километры по дням")) {
                // «Больше всего» — только когда есть из чего выбирать (34):
                // при одном дне с поездками «больше всего — вчера» пусто.
                if let busiest = summary.busiestDay, summary.busiestDayKm > 0, summary.activeDays >= 2 {
                    Text(String(format: String(localized: "Больше всего — %@"),
                                Formatting.dayTitle(busiest)))
                        .font(.rounded(15, .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            Chart(daily) { item in
                BarMark(x: .value("День", item.day, unit: .day),
                        y: .value("км", item.km),
                        width: .ratio(dense ? 0.7 : 0.55))
                // Красный столбик = день с превышением: график продолжает
                // историю «где и когда я нарушал», а не просто про километры.
                //
                // Заливка ПЛОСКАЯ, а не градиентом. Градиент снизу вверх на
                // столбике означает, что один и тот же день окрашен по-разному
                // в зависимости от своей высоты: цвет начинает кодировать
                // величину, которую уже кодирует сама высота. Это двойное
                // кодирование, и оно мешает сравнивать столбики между собой.
                .foregroundStyle(item.hasOverspeed ? Theme.danger : Theme.accent)
                .cornerRadius(4)
                // Подпись ТОЛЬКО у пика. Ось Y здесь скрыта намеренно — на
                // полосе в 96 pt она съела бы треть ширины, — но график без
                // единого числа сообщает лишь «какой-то день был длиннее
                // другого». Одна подпись у максимума задаёт масштаб всему
                // остальному: подписывать каждый столбик не нужно.
                .annotation(position: .top, spacing: 2) {
                    if item.km >= peak, item.km > 0 {
                        Text(Formatting.distance(item.km * 1000))
                            .font(.rounded(9, .bold).monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .chartYScale(domain: 0...peak * 1.15)
            .chartXAxis {
                // В месяце подписи каждого дня превращаются в кашу — раз в неделю.
                AxisMarks(values: .stride(by: .day, count: dense ? 7 : 1)) { _ in
                    AxisValueLabel(format: dense ? .dateTime.day()
                                                 : .dateTime.weekday(.abbreviated),
                                   centered: true)
                        .foregroundStyle(Theme.textTertiary)
                        .font(.rounded(9, .medium))
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 96)
            if hasOverspeed {
                legendItem(Theme.danger, String(localized: "день с превышением"))
            }
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
                    withMotion(Motion.standard) { anchor = nearest }
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

    /// Ближайшее к текущему окно с поездками: ищем по дневным агрегатам —
    /// они переживают чистку истории, значит найдут и старый период.
    func nearestNonEmptyAnchor() -> Date? {
        let calendar = Calendar.current
        let current = period.interval(containing: anchor)
        // Ближайший день с поездками — по разнице с текущим окном.
        return env.trip.days
            .filter { !current.contains($0.day) }
            .min { lhs, rhs in
                abs(lhs.day.timeIntervalSince(current.start))
                    < abs(rhs.day.timeIntervalSince(current.start))
            }
            .map { calendar.startOfDay(for: $0.day) }
    }
}
