//
//  TripStatsSheet.swift
//  RadarMap
//
//  «Итоги»: текущая/последняя поездка + история по дням.
//  Анимации одноразовые (каскад появления, живые цифры) — GPU почти не трогаем,
//  история ленивая, спарклайны рисуются только у видимых строк.
//

import SwiftUI
import CoreLocation
import Charts

struct TripStatsSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    /// Повторить поездку: маршрут к точке финиша записи из истории.
    var onRoute: ((CLLocationCoordinate2D, String) -> Void)? = nil
    @State private var selectedRecord: TripRecord?
    /// Каскадное появление секций при открытии (одноразовое).
    @State private var appeared = false

    var body: some View {
        let trip = env.trip
        let active = env.location.isTripActive

        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    statusHeader(active: active, trip: trip)
                        .entrance(0, appeared)
                    statsGrid(trip: trip)
                        .entrance(1, appeared)

                    if !trip.passed.isEmpty {
                        passedSection(trip: trip)
                            .entrance(2, appeared)
                    }

                    if !trip.history.isEmpty {
                        historySection(trip: trip)
                            .entrance(3, appeared)
                    } else if !active {
                        emptyHint
                            .entrance(2, appeared)
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
            .onAppear {
                appeared = true
                #if DEBUG
                // Скриншот-автоматизация: сразу открыть деталку первой поездки.
                if ProcessInfo.processInfo.arguments.contains("-openFirstTrip") {
                    selectedRecord = env.trip.history.first
                }
                #endif
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .sheet(item: $selectedRecord) { record in
            TripDetailSheet(record: record, onRoute: onRoute.map { route in
                { coord, name in
                    dismiss()
                    route(coord, name)
                }
            })
        }
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
                    .symbolEffect(.pulse, options: .repeating, isActive: active)
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
            // Живая скорость — Итоги можно держать открытыми в поездке.
            if active {
                VStack(spacing: 0) {
                    Text("\(Int(env.location.speedKmh))")
                        .font(.rounded(26, .heavy).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.35), value: Int(env.location.speedKmh))
                    Text("км/ч")
                        .font(.rounded(10, .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
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
            Text(value)
                .font(.rounded(28, .bold))
                .foregroundStyle(Theme.textPrimary)
                .contentTransition(.numericText())
            Text(label).font(.rounded(12)).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
        .animation(.snappy(duration: 0.4), value: value)
    }

    // MARK: - Пройденные камеры (со скоростью прохождения)

    private func passedSection(trip: TripStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Пройденные камеры")
                .font(.rounded(14, .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(trip.passed.reversed()) { pass in
                PassRow(pass: pass)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // Новый проезд в живой поездке въезжает сверху, а не вспыхивает.
        .animation(.spring(duration: 0.4), value: trip.passed.count)
    }

    // MARK: - История

    private func historySection(trip: TripStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("История поездок")
                .font(.rounded(14, .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Сводка за 7 дней + мини-график по дням — общая картина одним взглядом.
            if let week = trip.weekSummary {
                weekCard(week: week, trip: trip)
            }

            ForEach(dayGroups(trip.history), id: \.day) { group in
                Text(group.title)
                    .font(.rounded(12, .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .textCase(.uppercase)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                ForEach(group.records) { record in
                    historyRow(record, trip: trip)
                }
            }
        }
    }

    private func historyRow(_ record: TripRecord, trip: TripStats) -> some View {
        Button {
            selectedRecord = record   // тап — деталка: карта трека, проезды, шеринг
        } label: {
            HStack(spacing: 12) {
                // Мини-силуэт трека — поездку узнаёшь с одного взгляда.
                if record.trackPoints.count >= 2 {
                    TrackCanvas(points: record.trackPoints, lineWidth: 2)
                        .frame(width: 44, height: 44)
                        .background(Theme.background.opacity(0.6),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    Image(systemName: "car.side")
                        .font(.rounded(15))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 44, height: 44)
                        .background(Theme.background.opacity(0.6),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.startedAt.formatted(date: .omitted, time: .shortened))
                        .font(.rounded(14, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(Formatting.distance(record.distanceMeters)) · \(Formatting.duration(record.duration)) · \(Int(record.averageSpeedKmh)) км/ч сред.")
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 8)
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
            if let onRoute, let end = record.endCoordinate {
                Button {
                    onRoute(end, String(localized: "Как в прошлый раз"))
                    dismiss()
                } label: {
                    Label("Повторить маршрут", systemImage: "arrow.triangle.turn.up.right.circle")
                }
            }
            Button(role: .destructive) {
                withAnimation { trip.deleteRecord(id: record.id) }
            } label: {
                Label("Удалить запись", systemImage: "trash")
            }
        }
    }

    // MARK: - Неделя: сводка + мини-график

    @State private var chartAppeared = false

    private func weekCard(week: (trips: Int, distance: CLLocationDistance, cameras: Int),
                          trip: TripStats) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                weekMetric(String(format: String(localized: "%lld поездок"), week.trips), "car.fill")
                weekDivider
                weekMetric(Formatting.distance(week.distance), "point.topleft.down.to.point.bottomright.curvepath")
                weekDivider
                weekMetric(String(format: String(localized: "%lld камер"), week.cameras), "camera.fill")
            }

            // Километры по дням недели: столбики «вырастают» один раз при открытии.
            Chart(weekDaily(trip.history), id: \.day) { item in
                BarMark(
                    x: .value("День", item.day, unit: .day),
                    y: .value("км", chartAppeared ? item.km : 0),
                    width: .ratio(0.55)
                )
                .foregroundStyle(
                    LinearGradient(colors: [Theme.accent, Theme.intelligent],
                                   startPoint: .bottom, endPoint: .top)
                )
                .cornerRadius(3)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                        .foregroundStyle(Theme.textTertiary)
                        .font(.rounded(10, .medium))
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 52)
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

    private func weekMetric(_ value: String, _ icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.rounded(12, .semibold)).foregroundStyle(Theme.accent)
            Text(value).font(.rounded(14, .bold)).foregroundStyle(Theme.textPrimary)
        }
        .frame(maxWidth: .infinity)
    }

    private var weekDivider: some View {
        Rectangle().fill(Theme.accent.opacity(0.2)).frame(width: 1, height: 32)
    }

    // MARK: - Группировка и данные графика

    private struct DayGroup {
        let day: Date
        let title: String
        let records: [TripRecord]
    }

    /// История приходит от новых к старым — группируем по календарным дням.
    private func dayGroups(_ history: [TripRecord]) -> [DayGroup] {
        let calendar = Calendar.current
        var groups: [DayGroup] = []
        for record in history {
            let day = calendar.startOfDay(for: record.startedAt)
            if let last = groups.indices.last, groups[last].day == day {
                groups[last] = DayGroup(day: day, title: groups[last].title,
                                        records: groups[last].records + [record])
            } else {
                let title: String
                if calendar.isDateInToday(day) {
                    title = String(localized: "Сегодня")
                } else if calendar.isDateInYesterday(day) {
                    title = String(localized: "Вчера")
                } else {
                    title = day.formatted(.dateTime.day().month(.wide))
                }
                groups.append(DayGroup(day: day, title: title, records: [record]))
            }
        }
        return groups
    }

    private func weekDaily(_ history: [TripRecord]) -> [(day: Date, km: Double)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<7).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let km = history
                .filter { calendar.isDate($0.startedAt, inSameDayAs: day) }
                .reduce(0.0) { $0 + $1.distanceMeters } / 1000
            return (day, km)
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.accent.opacity(0.10)).frame(width: 72, height: 72)
                Image(systemName: "car.side")
                    .font(.rounded(28))
                    .foregroundStyle(Theme.accent)
            }
            Text("Здесь появятся ваши поездки")
                .font(.rounded(16, .bold))
                .foregroundStyle(Theme.textPrimary)
            Text("Нажмите «Начать поездку» на карте — соберём трек, скорость у каждой камеры и статистику.")
                .font(.rounded(13))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }
}

