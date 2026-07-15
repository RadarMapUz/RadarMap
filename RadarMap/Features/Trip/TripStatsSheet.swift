//
//  TripStatsSheet.swift
//  RadarMap
//
//  «Итоги»: текущая/последняя поездка + история поездок.
//

import SwiftUI
import CoreLocation

struct TripStatsSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    /// Повторить поездку: маршрут к точке финиша записи из истории.
    var onRoute: ((CLLocationCoordinate2D, String) -> Void)? = nil

    var body: some View {
        let trip = env.trip
        let active = env.location.isTripActive

        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statusHeader(active: active, trip: trip)
                    statsGrid(trip: trip)

                    if !trip.passed.isEmpty {
                        passedSection(trip: trip)
                    }

                    if !trip.history.isEmpty {
                        historySection(trip: trip)
                    } else if !active {
                        emptyHint
                    }
                }
                .padding(20)
            }
            .background(Theme.background)
            .navigationTitle("Итоги")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
                if !trip.history.isEmpty {
                    ToolbarItem(placement: .cancellationAction) {
                        Menu {
                            Button("Очистить историю", systemImage: "trash", role: .destructive) {
                                trip.clearHistory()
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Заголовок статуса

    @ViewBuilder
    private func statusHeader(active: Bool, trip: TripStats) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill((active ? Theme.success : Theme.textTertiary).opacity(0.15))
                    .frame(width: 46, height: 46)
                Image(systemName: active ? "record.circle" : "flag.checkered")
                    .font(.rounded(20, .bold))
                    .foregroundStyle(active ? Theme.success : Theme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(active ? "Поездка идёт" : (trip.startedAt != nil || trip.distanceMeters > 0 ? "Последняя поездка" : "Поездка не начата"))
                    .font(.rounded(17, .bold))
                    .foregroundStyle(Theme.textPrimary)
                if active, let started = trip.startedAt {
                    Text(timerInterval: started...Date.distantFuture, countsDown: false)
                        .font(.rounded(14, .medium).monospacedDigit())
                        .foregroundStyle(Theme.success)
                } else if trip.durationSeconds > 0 {
                    Text(Formatting.duration(trip.durationSeconds))
                        .font(.rounded(14, .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
    }

    // MARK: - Сетка метрик

    private func statsGrid(trip: TripStats) -> some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: cols, spacing: 12) {
            tile("\(trip.camerasPassed)", "камер пройдено", "camera.metering.center.weighted", Theme.accent)
            tile(Formatting.distance(trip.distanceMeters), "пройдено пути", "point.topleft.down.to.point.bottomright.curvepath", Theme.success)
            tile("\(Int(trip.maxSpeedKmh))", "макс. км/ч", "gauge.with.dots.needle.100percent", Theme.danger)
            tile("\(Int(trip.averageSpeedKmh))", "средняя км/ч", "gauge.with.dots.needle.33percent", Theme.radar)
        }
    }

    private func tile(_ value: String, _ label: LocalizedStringKey, _ icon: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).font(.rounded(18, .bold)).foregroundStyle(color)
            Text(value).font(.rounded(28, .bold)).foregroundStyle(Theme.textPrimary)
            Text(label).font(.rounded(12)).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
    }

    // MARK: - Пройденные камеры (со скоростью прохождения)

    private func passedSection(trip: TripStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Пройденные камеры")
                .font(.rounded(14, .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(trip.passed.reversed()) { pass in
                HStack(spacing: 12) {
                    Image(systemName: pass.kind.symbolName)
                        .font(.rounded(13, .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(pass.kind.tint.gradient, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pass.location.isEmpty ? pass.kind.displayName : pass.location)
                            .font(.rounded(14, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text(pass.date.formatted(date: .omitted, time: .shortened))
                            .font(.rounded(11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 8)
                    Text("\(Int(pass.speedKmh)) км/ч")
                        .font(.rounded(15, .bold))
                        .foregroundStyle(speedColor(pass.speedKmh))
                }
                .padding(12)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
            }
        }
    }

    private func speedColor(_ kmh: Double) -> Color {
        switch kmh {
        case ..<90:  return Theme.success
        case 90..<110: return Theme.radar
        default:     return Theme.danger
        }
    }

    // MARK: - История

    private func historySection(trip: TripStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("История поездок")
                .font(.rounded(14, .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(trip.history) { record in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.rounded(14, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("\(Formatting.distance(record.distanceMeters)) · \(Formatting.duration(record.duration)) · \(Int(record.averageSpeedKmh)) км/ч сред.")
                            .font(.rounded(12))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 8)
                    // Повторить: маршрут к финишу той поездки.
                    if let onRoute, let end = record.endCoordinate {
                        Button {
                            onRoute(end, String(localized: "Как в прошлый раз"))
                            dismiss()
                        } label: {
                            Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                                .font(.rounded(24))
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    VStack(spacing: 2) {
                        Text("\(record.camerasPassed)").font(.rounded(18, .bold)).foregroundStyle(Theme.accent)
                        Image(systemName: "camera.fill").font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
            }
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "car.side").font(.rounded(30)).foregroundStyle(Theme.textTertiary)
            Text("Нажмите «Начать поездку» на карте — здесь появятся её итоги и история.")
                .font(.rounded(13))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
    }
}
