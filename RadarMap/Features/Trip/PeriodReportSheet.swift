//
//  PeriodReportSheet.swift
//  RadarMap
//
//  Отчёт за период: «Неделя / Месяц / Всё время». Раньше на экране Итогов была
//  одна строка «за 7 дней: N поездок» — по ней нельзя понять, стал ты ездить
//  аккуратнее или нет. Здесь: главная цифра со сравнением к прошлому периоду,
//  карта всех треков с камерами (зелёная — прошёл в лимите, красная — с
//  превышением, размер по числу проездов), плитки метрик, столбики по дням с
//  призраком прошлого периода и зона риска.
//
//  Все цифры приходят готовыми из TripHistory.summary — вьюха ничего не считает
//  (ARCHITECTURE.md: данные в модели). Карта статична: жесты не крадём у скролла.
//

import SwiftUI
import Charts
import MapKit
import CoreLocation

struct PeriodReportSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var period: StatsPeriod = .week
    @State private var appeared = false

    private var history: [TripRecord] { env.trip.history }
    private var summary: PeriodSummary { TripHistory.summary(history, period: period) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    periodPicker
                    if summary.isEmpty {
                        emptyState
                    } else {
                        hero.entrance(0, appeared)
                        mapCard.entrance(1, appeared)
                        tiles.entrance(2, appeared)
                        if let days = period.chartDays {
                            dailyChart(days: days).entrance(3, appeared)
                        }
                        riskCard.entrance(4, appeared)
                    }
                }
                .padding(20)
            }
            .background(Theme.background)
            .navigationTitle("Отчёт")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
        }
        .onAppear { appeared = true }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Период

    private var periodPicker: some View {
        HStack(spacing: 6) {
            ForEach(StatsPeriod.allCases) { item in
                Button {
                    withAnimation(.snappy(duration: 0.25)) { period = item }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Text(item.title)
                        .font(.rounded(13, .semibold))
                        .foregroundStyle(period == item ? Theme.background : Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(period == item ? AnyShapeStyle(Theme.accent.gradient)
                                                   : AnyShapeStyle(Theme.surface), in: Capsule())
                }
                .buttonStyle(PressableStyle())
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.rounded(34, .bold))
                .foregroundStyle(Theme.textTertiary)
            Text("За этот период поездок нет")
                .font(.rounded(15, .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text("Поездки записываются сами, как только вы поехали.")
                .font(.rounded(13))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }

    // MARK: - Главная цифра

    private var hero: some View {
        GlassCard {
            // GlassCard своих отступов не даёт — задаём сами, иначе стекло
            // обрезается по тексту вплотную.
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Formatting.distance(summary.distance))
                            .font(.rounded(34, .heavy))
                            .foregroundStyle(Theme.textPrimary)
                            .contentTransition(.numericText())
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                        if let delta = summary.distanceDeltaPercent {
                            deltaBadge(delta)
                        }
                    }
                    Text(subtitle)
                        .font(.rounded(13))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if let rating = summary.rating {
                    ratingRing(rating)
                }
            }
            .padding(18)
        }
    }

    private var subtitle: String {
        let trips = String(format: String(localized: "Поездок: %lld"), summary.trips)
        let time = Formatting.duration(summary.movingDuration)
        return "\(trips) · \(time) " + String(localized: "за рулём")
    }

    private func deltaBadge(_ delta: Int) -> some View {
        let up = delta >= 0
        return Label("\(abs(delta))%", systemImage: up ? "arrow.up.right" : "arrow.down.right")
            .font(.rounded(12, .bold))
            .foregroundStyle(up ? Theme.accent : Theme.textSecondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background((up ? Theme.accent : Theme.textSecondary).opacity(0.14), in: Capsule())
            .accessibilityLabel(Text(up ? "Больше, чем в прошлый период"
                                        : "Меньше, чем в прошлый период"))
    }

    private func ratingRing(_ rating: Int) -> some View {
        ZStack {
            Circle().stroke(Theme.stroke, lineWidth: 5)
            Circle()
                .trim(from: 0, to: Double(rating) / 100)
                .stroke(TripHistorySection.scoreColor(rating),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(rating)")
                .font(.rounded(16, .heavy).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
        }
        .frame(width: 52, height: 52)
        .accessibilityLabel(Text("Рейтинг вождения"))
        .accessibilityValue(Text("\(rating) из 100"))
    }

    // MARK: - Карта периода

    @ViewBuilder private var mapCard: some View {
        let tracks = TripHistory.tracks(history, period: period)
        let markers = TripHistory.passMarkers(history, period: period)
        if let rect = Self.boundingRect(tracks: tracks, markers: markers) {
            VStack(alignment: .leading, spacing: 8) {
                Map(initialPosition: .rect(rect)) {
                    ForEach(Array(tracks.enumerated()), id: \.offset) { _, track in
                        MapPolyline(coordinates: track.map {
                            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                        })
                        .stroke(Theme.accent.opacity(0.75),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    }
                    ForEach(markers) { marker in
                        Annotation("", coordinate: marker.coordinate, anchor: .center) {
                            markerDot(marker)
                        }
                        .annotationTitles(.hidden)
                    }
                }
                .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll,
                                    showsTraffic: false))
                .frame(height: 280)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1))
                .allowsHitTesting(false)
                legend
            }
        }
    }

    /// Размер кружка растёт с числом проездов: где катаешься чаще — виднее.
    private func markerDot(_ marker: PassMarker) -> some View {
        let size = min(30.0, 18 + Double(marker.times) * 2.5)
        return ZStack {
            Circle()
                .fill(marker.hasViolation ? Theme.danger : Theme.success)
                .frame(width: size, height: size)
            if marker.times > 1 {
                Text("\(marker.times)")
                    .font(.system(size: size * 0.42, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.5))
        .accessibilityLabel(Text(marker.location))
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(Theme.success, "В лимите")
            legendItem(Theme.danger, "С превышением")
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private func legendItem(_ color: Color, _ title: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(.rounded(11)).foregroundStyle(Theme.textTertiary)
        }
    }

    /// Общая рамка всех треков и маркеров периода. nil — рисовать нечего.
    static func boundingRect(tracks: [[TrackPoint]], markers: [PassMarker]) -> MKMapRect? {
        var rect = MKMapRect.null
        for track in tracks {
            for point in track {
                let mp = MKMapPoint(CLLocationCoordinate2D(latitude: point.lat,
                                                           longitude: point.lon))
                rect = rect.union(MKMapRect(origin: mp, size: MKMapSize()))
            }
        }
        for marker in markers {
            rect = rect.union(MKMapRect(origin: MKMapPoint(marker.coordinate),
                                        size: MKMapSize()))
        }
        guard !rect.isNull else { return nil }
        // Совсем короткая поездка вырождается в точку — иначе карта уйдёт в бесконечный зум.
        let padX = max(rect.width * 0.15, 400)
        let padY = max(rect.height * 0.15, 400)
        return rect.insetBy(dx: -padX, dy: -padY)
    }

    // MARK: - Плитки метрик

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(spacing: 12), GridItem(spacing: 12)], spacing: 12) {
            StatTile(value: "\(summary.trips)", label: "Поездок",
                     icon: "car.fill", color: Theme.accent)
            StatTile(value: Formatting.duration(summary.movingDuration), label: "За рулём",
                     icon: "clock.fill", color: Theme.intelligent)
            StatTile(value: "\(summary.cameras)", label: "Камер пройдено",
                     icon: "camera.fill", color: Theme.camera)
            StatTile(value: "\(Int(summary.averageSpeedKmh))", label: "Средняя, км/ч",
                     icon: "speedometer", color: Theme.radar)
            StatTile(value: "\(Int(summary.maxSpeedKmh))", label: "Максимум, км/ч",
                     icon: "gauge.with.dots.needle.100percent", color: Theme.mobile)
            StatTile(value: cleanShareText, label: "Проездов в лимите",
                     icon: "checkmark.shield.fill", color: Theme.success)
        }
    }

    private var cleanShareText: String {
        guard let share = summary.cleanShare else { return "—" }
        return "\(Int((share * 100).rounded()))%"
    }

    // MARK: - Столбики по дням

    private func dailyChart(days: Int) -> some View {
        let daily = TripHistory.dailyKm(TripHistory.records(history, period: period), days: days)
        let peak = max(daily.map(\.km).max() ?? 0, 1)
        let dense = days > 10
        return GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Километры по дням")
                        .font(.rounded(14, .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    if let busiest = summary.busiestDay, summary.busiestDayKm > 0 {
                        Text(String(format: String(localized: "Больше всего — %@"),
                                    Formatting.dayTitle(busiest)))
                            .font(.rounded(12, .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
                Chart(daily, id: \.day) { item in
                    BarMark(x: .value("День", item.day, unit: .day),
                            y: .value("км", item.km),
                            width: .ratio(dense ? 0.7 : 0.55))
                    .foregroundStyle(LinearGradient(colors: [Theme.accent, Theme.intelligent],
                                                    startPoint: .bottom, endPoint: .top))
                    .opacity(Calendar.current.isDateInToday(item.day) ? 1 : 0.55)
                    .cornerRadius(3)
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
                .frame(height: 100)
            }
            .padding(18)
        }
    }

    // MARK: - Зона риска

    @ViewBuilder private var riskCard: some View {
        if summary.overPasses > 0 {
            GlassCard {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Зона риска", systemImage: "exclamationmark.triangle.fill")
                        .font(.rounded(14, .semibold))
                        .foregroundStyle(Theme.danger)
                    Text(riskText)
                        .font(.rounded(13))
                        .foregroundStyle(Theme.textSecondary)
                    if let place = summary.topOverLocation {
                        Text(place)
                            .font(.rounded(14, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            }
        } else if summary.cleanPasses > 0 {
            GlassCard {
                Label("Ни одного превышения у камер за период",
                      systemImage: "checkmark.seal.fill")
                    .font(.rounded(14, .semibold))
                    .foregroundStyle(Theme.success)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }
        }
    }

    private var riskText: String {
        String(format: String(localized: "Проездов с превышением: %lld · возможные штрафы %@"),
               summary.overPasses, Formatting.money(summary.fineRisk))
    }
}
