//
//  TripHistorySection.swift
//  RadarMap
//
//  Секция «История поездок» экрана Итогов: недельная сводка + мини-график по дням,
//  список последних поездок с баллом и мини-треком. Данные считает TripHistory,
//  здесь только разметка и действия наверх (тап, повтор, удаление).
//

import SwiftUI
import CoreLocation
import Charts

struct TripHistorySection: View {
    let trip: TripStats
    let onSelect: (TripRecord) -> Void
    let onRepeat: ((CLLocationCoordinate2D, String) -> Void)?
    let onDelete: (TripRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("История поездок")
                .font(.rounded(14, .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Сводка за 7 дней + мини-график по дням — общая картина одним взглядом.
            if let week = trip.weekSummary {
                WeekCard(week: week, history: trip.history)
            }

            // Показываем только 7 последних — старое хранится лишь для статистики.
            ForEach(TripHistory.dayGroups(Array(trip.history.prefix(TripHistory.visibleHistory))),
                    id: \.day) { group in
                Text(Formatting.dayTitle(group.day))
                    .font(.rounded(12, .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .textCase(.uppercase)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                ForEach(group.records) { record in
                    row(record)
                }
            }
        }
    }

    private func row(_ record: TripRecord) -> some View {
        Button {
            onSelect(record)   // тап — деталка: карта трека, проезды, шеринг
        } label: {
            HStack(spacing: 12) {
                trackThumbnail(record)
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.startedAt.formatted(date: .omitted, time: .shortened))
                        .font(.rounded(14, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(Formatting.distance(record.distanceMeters)) · \(Formatting.duration(record.duration)) · \(Int(record.averageSpeedKmh)) км/ч сред.")
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 8)
                // Балл поездки — цвет по зоне, поездки сравниваешь с одного взгляда.
                if let score = record.score {
                    Text("\(Int(score))")
                        .font(.rounded(13, .heavy).monospacedDigit())
                        .foregroundStyle(Self.scoreColor(Int(score)))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Self.scoreColor(Int(score)).opacity(0.13), in: Capsule())
                }
                VStack(spacing: 2) {
                    Text("\(record.camerasPassed)").font(.rounded(18, .bold)).foregroundStyle(Theme.accent)
                    Image(systemName: "camera.fill").font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
                }
                Image(systemName: "chevron.right")
                    .font(.rounded(12, .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
        }
        .buttonStyle(.plain)
        // Лёгкое «проявление» строк при прокрутке — живо, но не мешает.
        .scrollTransition(.interactive(timingCurve: .easeOut)) { content, phase in
            content
                .opacity(phase.isIdentity ? 1 : 0.4)
                .scaleEffect(phase.isIdentity ? 1 : 0.96)
        }
        .contextMenu {
            if let onRepeat, let end = record.endCoordinate {
                Button {
                    onRepeat(end, String(localized: "Как в прошлый раз"))
                } label: {
                    Label("Повторить маршрут", systemImage: "arrow.triangle.turn.up.right.circle")
                }
            }
            Button(role: .destructive) {
                onDelete(record)
            } label: {
                Label("Удалить запись", systemImage: "trash")
            }
        }
    }

    /// Мини-силуэт трека — поездку узнаёшь с одного взгляда.
    @ViewBuilder private func trackThumbnail(_ record: TripRecord) -> some View {
        Group {
            if record.trackPoints.count >= 2 {
                TrackCanvas(points: record.trackPoints, lineWidth: 2)
            } else {
                Image(systemName: "car.side")
                    .font(.rounded(15))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(width: 44, height: 44)
        .background(Theme.background.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    static func scoreColor(_ score: Int) -> Color {
        switch DrivingScore.tier(for: score) {
        case 2: return Theme.success
        case 1: return Theme.radar
        default: return Theme.danger
        }
    }
}

// MARK: - Неделя: сводка + мини-график

private struct WeekCard: View {
    let week: (trips: Int, distance: CLLocationDistance, cameras: Int)
    let history: [TripRecord]
    @State private var chartAppeared = false

    var body: some View {
        let daily = TripHistory.weekDaily(history)
        let maxKm = max(daily.map(\.km).max() ?? 0, 1)
        return VStack(spacing: 12) {
            HStack(spacing: 0) {
                metric(String(format: String(localized: "%lld поездок"), week.trips), "car.fill")
                divider
                metric(Formatting.distance(week.distance), "point.topleft.down.to.point.bottomright.curvepath")
                divider
                metric(String(format: String(localized: "%lld камер"), week.cameras), "camera.fill")
            }

            // Километры по дням недели: цифры над столбиками, сегодняшний — ярче.
            Chart(daily, id: \.day) { item in
                let isToday = Calendar.current.isDateInToday(item.day)
                BarMark(
                    x: .value("День", item.day, unit: .day),
                    y: .value("км", chartAppeared ? item.km : 0),
                    width: .ratio(0.55)
                )
                .foregroundStyle(
                    LinearGradient(colors: [Theme.accent, Theme.intelligent],
                                   startPoint: .bottom, endPoint: .top)
                )
                .opacity(isToday ? 1 : 0.55)
                .cornerRadius(3)
                .annotation(position: .top, spacing: 3) {
                    if item.km >= 0.5 {
                        Text(item.km >= 10 ? "\(Int(item.km.rounded()))" : String(format: "%.1f", locale: .current, item.km))
                            .font(.rounded(9, .semibold).monospacedDigit())
                            .foregroundStyle(isToday ? Theme.textPrimary : Theme.textTertiary)
                    }
                }
            }
            // Запас сверху — подписи км над столбиками не режутся рамкой карточки.
            .chartYScale(domain: 0...maxKm * 1.35)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    // «пн, вт…»: однобуквенные дни в русском дублируются (П, В, С).
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true)
                        .foregroundStyle(Theme.textTertiary)
                        .font(.rounded(9, .medium))
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 74)
            .padding(.horizontal, 12)
            .onAppear {
                withAnimation(.spring(duration: 0.7, bounce: 0.25).delay(0.15)) {
                    chartAppeared = true
                }
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous)
            .stroke(Theme.accent.opacity(0.25), lineWidth: 1))
    }

    private func metric(_ value: String, _ icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.rounded(12, .semibold)).foregroundStyle(Theme.accent)
            Text(value).font(.rounded(14, .bold)).foregroundStyle(Theme.textPrimary)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle().fill(Theme.accent.opacity(0.2)).frame(width: 1, height: 32)
    }
}
