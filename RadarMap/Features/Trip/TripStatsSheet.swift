//
//  TripStatsSheet.swift
//  RadarMap
//
//  «Итоги» — единый экран статистики. Фильтр периода (Неделя / Месяц / Всё
//  время) правит ВСЕМ разделом: герой (рейтинг + километры + дельта к прошлому
//  периоду), карта проездов, зона риска, плитки метрик и график по дням читают
//  одну и ту же PeriodSummary. Никаких двух источников правды: раньше экран
//  показывал «Штрафы за 30 дней» рядом с недельной карточкой истории и
//  отдельным отчётом — три пересчёта одного и того же в разных местах.
//
//  Каждый блок нажимается: герой → как считается рейтинг; карта и зона риска →
//  полноэкранная карта проездов (зона риска — сразу с фокусом на «своей»
//  камере); достижение → его условия; поездка в истории → деталка.
//
//  Все цифры приходят готовыми из TripHistory/PeriodSummary — вьюха не считает
//  ничего (ARCHITECTURE.md: данные в модели).
//

import SwiftUI
import Charts
import MapKit
import CoreLocation

struct TripStatsSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    /// Повторить поездку: маршрут к точке финиша записи из истории.
    var onRoute: ((CLLocationCoordinate2D, String) -> Void)? = nil

    @State private var period: StatsPeriod = .week
    @State private var selectedRecord: TripRecord?
    /// Каскадное появление секций при открытии (одноразовое).
    @State private var appeared = false
    @State private var sharePayload: ShareImagePayload?
    @State private var showRatingInfo = false
    @State private var showFinesInfo = false
    @State private var selectedBadge: Achievement?
    /// Полноэкранная карта проездов (item — чтобы передать фокус зоны риска).
    @State private var mapPayload: PeriodMapPayload?

    var body: some View {
        let trip = env.trip
        let active = env.location.isTripActive
        let summary = TripHistory.summary(trip.history, period: period)

        NavigationStack {
            ScrollView {
                ScrollViewReader { proxy in
                LazyVStack(spacing: 16) {
                    // Живая поездка — вне периодов: таймер, скорость, живые метрики.
                    if active {
                        liveHeader(trip: trip)
                            .entrance(0, appeared)
                        liveGrid(trip: trip)
                            .entrance(1, appeared)
                    }

                    periodPicker
                        .entrance(0, appeared)

                    if summary.isEmpty {
                        if !active { emptyHint.entrance(1, appeared) }
                    } else {
                        heroCard(trip: trip, summary: summary)
                            .entrance(1, appeared)
                        mapCard
                            .entrance(2, appeared)
                        riskCard(summary: summary)
                            .entrance(3, appeared)
                        periodTiles(summary: summary)
                            .entrance(3, appeared)
                        if let days = period.chartDays {
                            dailyChart(days: days, summary: summary)
                                .entrance(4, appeared)
                        }
                    }

                    achievementsSection(trip: trip)
                        .entrance(4, appeared)

                    if !trip.history.isEmpty {
                        TripHistorySection(
                            trip: trip,
                            onSelect: { selectedRecord = $0 },
                            onRepeat: onRoute.map { route in
                                { coord, name in dismiss(); route(coord, name) }
                            },
                            onDelete: { record in withAnimation { trip.deleteRecord(id: record.id) } })
                            .entrance(5, appeared)
                            .id("history")
                    }
                }
                .padding(20)
                #if DEBUG
                .onAppear {
                    // Скриншот-автоматизация: прокрутить к истории.
                    guard ProcessInfo.processInfo.arguments.contains("-scrollHistory") else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { proxy.scrollTo("history", anchor: .top) }
                    }
                }
                #endif
                }
            }
            .background(Theme.background)
            .navigationTitle("Итоги")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
                if !trip.history.isEmpty {
                    ToolbarItemGroup(placement: .cancellationAction) {
                        Menu {
                            Button("Очистить историю", systemImage: "trash", role: .destructive) {
                                trip.clearHistory()
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                            .accessibilityLabel(Text("Ещё"))
                        // Похвастаться периодом: карта + рейтинг + зона риска одной картинкой.
                        if !summary.isEmpty {
                            Button { share(summary: summary) } label: {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .accessibilityLabel(Text("Поделиться итогами"))
                        }
                    }
                }
            }
            .onAppear {
                appeared = true
                #if DEBUG
                // Скриншот-автоматизация: открыть вложенные экраны (с паузой —
                // sheet поверх ещё анимирующегося sheet молча не показывается).
                let args = ProcessInfo.processInfo.arguments
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    if args.contains("-openFirstTrip") { selectedRecord = env.trip.history.first }
                    if args.contains("-showRatingInfo") { showRatingInfo = true }
                    if args.contains("-showSavingsInfo") { showFinesInfo = true }
                    if args.contains("-showPeriodMap") { openMap(focus: nil) }
                    if args.contains("-shareStats") {
                        share(summary: TripHistory.summary(env.trip.history, period: period))
                    }
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
        .sheet(item: $mapPayload) { payload in
            PeriodMapSheet(tracks: payload.tracks, markers: payload.markers,
                           focus: payload.focus)
        }
        .sheet(isPresented: $showRatingInfo) { RatingInfoSheet() }
        .sheet(isPresented: $showFinesInfo) { SavingsInfoSheet() }
        .sheet(item: $selectedBadge) { badge in AchievementInfoSheet(badge: badge) }
        .sheet(item: $sharePayload) { payload in
            ActivityShareSheet(image: payload.image)
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
    }

    // MARK: - Фильтр периода

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

    // MARK: - Герой: рейтинг + километры периода

    /// Одна карточка вместо двух: кольцо рейтинга (тап — как считается) и
    /// главная цифра периода с дельтой к прошлому такому же.
    private func heroCard(trip: TripStats, summary: PeriodSummary) -> some View {
        Button {
            showRatingInfo = true
        } label: {
            HStack(spacing: 16) {
                if let rating = summary.rating {
                    RatingRing(rating: rating)
                        .frame(width: 88, height: 88)
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Formatting.distance(summary.distance))
                            .font(.rounded(30, .heavy))
                            .foregroundStyle(Theme.textPrimary)
                            .contentTransition(.numericText())
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        if let delta = summary.distanceDeltaPercent {
                            deltaBadge(delta)
                        }
                    }
                    if let rating = summary.rating {
                        Text(DrivingScore.level(for: rating))
                            .font(.rounded(14, .bold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    Text(heroSubtitle(summary))
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textSecondary)
                    if trip.lifetime.cleanStreak >= 2 {
                        Label(String(format: String(localized: "чистая серия: %lld подряд"),
                                     trip.lifetime.cleanStreak),
                              systemImage: "flame.fill")
                            .font(.rounded(11, .semibold))
                            .foregroundStyle(Theme.radar)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.rounded(13, .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Рейтинг и километры за период. Как считается рейтинг"))
    }

    private func heroSubtitle(_ summary: PeriodSummary) -> String {
        let trips = String(format: String(localized: "Поездок: %lld"), summary.trips)
        return "\(trips) · \(Formatting.duration(summary.movingDuration)) "
            + String(localized: "за рулём")
    }

    private func deltaBadge(_ delta: Int) -> some View {
        let up = delta >= 0
        return Label("\(abs(delta))%", systemImage: up ? "arrow.up.right" : "arrow.down.right")
            .font(.rounded(11, .bold))
            .foregroundStyle(up ? Theme.accent : Theme.textSecondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background((up ? Theme.accent : Theme.textSecondary).opacity(0.14), in: Capsule())
            .accessibilityLabel(Text(up ? "Больше, чем в прошлый период"
                                        : "Меньше, чем в прошлый период"))
    }

    // MARK: - Карта проездов (превью → полноэкранная)

    private var tracks: [[TrackPoint]] { TripHistory.tracks(env.trip.history, period: period) }
    private var markers: [PassMarker] { TripHistory.passMarkers(env.trip.history, period: period) }

    @ViewBuilder private var mapCard: some View {
        let tracks = self.tracks
        let markers = self.markers
        if let rect = PeriodMapSheet.boundingRect(tracks: tracks, markers: markers) {
            Button {
                openMap(focus: nil)
            } label: {
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
                                previewDot(marker)
                            }
                            .annotationTitles(.hidden)
                        }
                    }
                    .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll,
                                        showsTraffic: false))
                    .frame(height: 230)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                        .stroke(Theme.stroke, lineWidth: 1))
                    .allowsHitTesting(false)   // превью: тап ловит кнопка, жесты — полноэкранная
                    // Легенда + явная подсказка, что карта нажимается.
                    HStack(spacing: 14) {
                        legendItem(Theme.success, "В лимите")
                        legendItem(Theme.danger, "С превышением")
                        Spacer()
                        HStack(spacing: 4) {
                            Text("Открыть")
                                .font(.rounded(11, .semibold))
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.rounded(9, .bold))
                        }
                        .foregroundStyle(Theme.accent)
                    }
                    .padding(.horizontal, 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(Text("Карта проездов за период. Открыть на весь экран"))
        }
    }

    private func previewDot(_ marker: PassMarker) -> some View {
        let size = min(26.0, 15 + Double(marker.times) * 2)
        return Circle()
            .fill(marker.hasViolation ? Theme.danger : Theme.success)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.5))
    }

    private func legendItem(_ color: Color, _ title: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(.rounded(11)).foregroundStyle(Theme.textTertiary)
        }
    }

    private func openMap(focus: PassMarker?) {
        mapPayload = PeriodMapPayload(tracks: tracks, markers: markers, focus: focus)
    }

    // MARK: - Зона риска (тап — карта с фокусом на камере)

    /// Проезды и штрафные риски ЗА ВЫБРАННЫЙ ПЕРИОД — тот же фильтр, что у всего
    /// экрана. Тап открывает карту на камере, где превышаете чаще всего;
    /// маленькая (i) — таблица штрафных ступеней.
    @ViewBuilder
    private func riskCard(summary: PeriodSummary) -> some View {
        let total = summary.cleanPasses + summary.overPasses
        if total > 0 {
            let ok = summary.overPasses == 0
            Button {
                if ok {
                    showFinesInfo = true
                } else {
                    // Фокус: самая «нарушаемая» камера периода.
                    openMap(focus: markers.filter(\.hasViolation)
                        .max { $0.overTimes < $1.overTimes })
                }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: ok ? "shield.lefthalf.filled.badge.checkmark"
                                         : "exclamationmark.shield.fill")
                        .font(.rounded(22, .bold))
                        .foregroundStyle(ok ? Theme.success : Theme.danger)
                        .frame(width: 48, height: 48)
                        .background((ok ? Theme.success : Theme.danger).opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("Зона риска")
                                .font(.rounded(13, .medium))
                                .foregroundStyle(Theme.textSecondary)
                            // Как считаем штрафы — отдельным маленьким входом,
                            // основной тап занят картой.
                            Button {
                                showFinesInfo = true
                            } label: {
                                Image(systemName: "info.circle")
                                    .font(.rounded(12))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .accessibilityLabel(Text("Как считаются штрафы"))
                        }
                        if ok {
                            Text("0 штрафов")
                                .font(.rounded(24, .heavy))
                                .foregroundStyle(Theme.success)
                            Text(String(format: String(localized: "%lld проездов камер — все в лимите"), total))
                                .font(.rounded(11))
                                .foregroundStyle(Theme.textTertiary)
                        } else {
                            Text("риск ≈ \(Formatting.money(summary.fineRisk))")
                                .font(.rounded(24, .heavy))
                                .foregroundStyle(Theme.danger)
                                .contentTransition(.numericText())
                            Text(String(format: String(localized: "%lld превышений из %lld проездов"),
                                        summary.overPasses, total))
                                .font(.rounded(11))
                                .foregroundStyle(Theme.textTertiary)
                            if let top = summary.topOverLocation {
                                Label(String(format: String(localized: "Чаще всего: %@ — показать"), top),
                                      systemImage: "mappin.circle.fill")
                                    .font(.rounded(11, .medium))
                                    .foregroundStyle(Theme.radar)
                                    .lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: ok ? "chevron.right" : "map.fill")
                        .font(.rounded(13, .semibold))
                        .foregroundStyle(ok ? Theme.textTertiary : Theme.danger)
                }
                .padding(16)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Плитки периода

    private func periodTiles(summary: PeriodSummary) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            StatTile(value: "\(summary.cameras)", label: "камер пройдено",
                     icon: "camera.metering.center.weighted", color: Theme.accent)
            StatTile(value: cleanShareText(summary), label: "проездов в лимите",
                     icon: "checkmark.shield.fill", color: Theme.success)
            StatTile(value: "\(Int(summary.maxSpeedKmh))", label: "макс. км/ч",
                     icon: "gauge.with.dots.needle.100percent", color: Theme.danger)
            StatTile(value: "\(Int(summary.averageSpeedKmh))", label: "средняя км/ч",
                     icon: "gauge.with.dots.needle.33percent", color: Theme.radar)
        }
    }

    private func cleanShareText(_ summary: PeriodSummary) -> String {
        guard let share = summary.cleanShare else { return "—" }
        return "\(Int((share * 100).rounded()))%"
    }

    // MARK: - График по дням

    private func dailyChart(days: Int, summary: PeriodSummary) -> some View {
        let daily = TripHistory.dailyKm(TripHistory.records(env.trip.history, period: period),
                                        days: days)
        let peak = max(daily.map(\.km).max() ?? 0, 1)
        let dense = days > 10
        return VStack(alignment: .leading, spacing: 12) {
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
            .frame(height: 96)
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
    }

    // MARK: - Живая поездка

    private func liveHeader(trip: TripStats) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.success.opacity(0.15))
                    .frame(width: 46, height: 46)
                Image(systemName: "record.circle")
                    .font(.rounded(20, .bold))
                    .foregroundStyle(Theme.success)
                    .symbolEffect(.pulse, options: .repeating, isActive: true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Поездка идёт")
                    .font(.rounded(17, .bold))
                    .foregroundStyle(Theme.textPrimary)
                if let started = trip.startedAt {
                    Text(timerInterval: started...Date.distantFuture, countsDown: false)
                        .font(.rounded(14, .medium).monospacedDigit())
                        .foregroundStyle(Theme.success)
                }
            }
            Spacer()
            // Живая скорость — Итоги можно держать открытыми в поездке.
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
    }

    /// Живые метрики текущей поездки — тикают на глазах (numericText).
    private func liveGrid(trip: TripStats) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            StatTile(value: "\(trip.camerasPassed)", label: "камер пройдено",
                     icon: "camera.metering.center.weighted", color: Theme.accent, animatesValue: true)
            StatTile(value: Formatting.distance(trip.distanceMeters), label: "пройдено пути",
                     icon: "point.topleft.down.to.point.bottomright.curvepath", color: Theme.success, animatesValue: true)
            StatTile(value: "\(Int(trip.maxSpeedKmh))", label: "макс. км/ч",
                     icon: "gauge.with.dots.needle.100percent", color: Theme.danger, animatesValue: true)
            StatTile(value: "\(Int(trip.averageSpeedKmh))", label: "средняя км/ч",
                     icon: "gauge.with.dots.needle.33percent", color: Theme.radar, animatesValue: true)
        }
    }

    // MARK: - Достижения

    private func achievementsSection(trip: TripStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Достижения")
                .font(.rounded(14, .semibold))
                .foregroundStyle(Theme.textSecondary)
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

    // MARK: - Шеринг периода

    /// Рендерим карточку в момент тапа — данные всегда свежие, открытие не тормозим.
    private func share(summary: PeriodSummary) {
        guard !summary.isEmpty else { return }
        let periodTitle = period.title
        Task {
            let passes = TripHistory.records(env.trip.history, period: period).flatMap(\.passed)
            let map = await TripMapSnapshot.render(
                track: tracks.flatMap { $0 }, passes: passes,
                size: CGSize(width: 1032, height: 420))
            let renderer = ImageRenderer(content: PeriodShareCard(
                summary: summary, periodTitle: periodTitle, mapImage: map))
            renderer.scale = 2
            renderer.proposedSize = ProposedViewSize(width: 540, height: 675)
            if let uiImage = renderer.uiImage {
                sharePayload = ShareImagePayload(image: uiImage)
            }
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

/// Слепок данных для полноэкранной карты: собирается в момент тапа, чтобы sheet
/// не пересобирался за спиной при изменении периода.
struct PeriodMapPayload: Identifiable {
    let id = UUID()
    let tracks: [[TrackPoint]]
    let markers: [PassMarker]
    let focus: PassMarker?
}
