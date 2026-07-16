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
    @State private var sharePayload: ShareImagePayload?
    @State private var showRatingInfo = false
    @State private var showSavingsInfo = false
    @State private var selectedBadge: Achievement?
    @State private var selectedPass: PassedCamera?

    var body: some View {
        let trip = env.trip
        let active = env.location.isTripActive
        // После перезапуска приложения живых метрик нет — показываем последнюю
        // поездку из истории, а не нули.
        let lastRecord = trip.fallbackRecord(isTripActive: active)
        let passes = lastRecord.map(\.passed) ?? trip.passed

        NavigationStack {
            ScrollView {
                ScrollViewReader { proxy in
                LazyVStack(spacing: 16) {
                    ratingHero(trip: trip)
                        .entrance(0, appeared)
                    statusHeader(active: active, trip: trip, last: lastRecord)
                        .entrance(1, appeared)
                    statsGrid(trip: trip, last: lastRecord)
                        .entrance(2, appeared)
                    savedCard(trip: trip)
                        .entrance(3, appeared)

                    if !passes.isEmpty {
                        passedSection(passes: passes, track: lastRecord?.trackPoints ?? [])
                            .entrance(4, appeared)
                    }

                    achievementsSection(trip: trip)
                        .entrance(5, appeared)

                    if !trip.history.isEmpty {
                        historySection(trip: trip)
                            .entrance(6, appeared)
                            .id("history")
                    } else if !active {
                        emptyHint
                            .entrance(5, appeared)
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
                        // Похвастаться итогами: рейтинг + экономия одной картинкой.
                        if trip.rating != nil {
                            Button { share(trip: trip) } label: {
                                Image(systemName: "square.and.arrow.up")
                            }
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
                    if args.contains("-showSavingsInfo") { showSavingsInfo = true }
                    if args.contains("-shareStats") { share(trip: env.trip) }
                    if args.contains("-showPassMap") {
                        selectedPass = env.trip.history.first?.passed.first { $0.coordinate != nil }
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
        .sheet(isPresented: $showRatingInfo) { RatingInfoSheet() }
        .sheet(isPresented: $showSavingsInfo) { SavingsInfoSheet() }
        .sheet(item: $selectedBadge) { badge in AchievementInfoSheet(badge: badge) }
        .sheet(item: $sharePayload) { payload in
            ActivityShareSheet(image: payload.image)
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
        .sheet(item: $selectedPass) { pass in
            PassMapSheet(pass: pass,
                         track: (env.location.isTripActive || trip.distanceMeters > 0)
                             ? [] : trip.history.first?.trackPoints ?? [])
        }
    }

    // MARK: - Рейтинг вождения (герой)

    @ViewBuilder
    private func ratingHero(trip: TripStats) -> some View {
        HStack(spacing: 18) {
            if let rating = trip.rating {
                // Тап — расшифровка: шкала, из чего складывается, как поднять.
                Button {
                    showRatingInfo = true
                } label: {
                    HStack(spacing: 18) {
                        RatingRing(rating: rating)
                            .frame(width: 96, height: 96)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(DrivingScore.level(for: rating))
                                .font(.rounded(17, .bold))
                                .foregroundStyle(Theme.textPrimary)
                            if let trend = trip.ratingTrend, trend != 0 {
                                HStack(spacing: 4) {
                                    Image(systemName: trend > 0 ? "arrow.up.right" : "arrow.down.right")
                                        .font(.rounded(11, .bold))
                                    Text(String(format: String(localized: "%lld за неделю"), abs(trend)))
                                        .font(.rounded(12, .semibold))
                                }
                                .foregroundStyle(trend > 0 ? Theme.success : Theme.danger)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background((trend > 0 ? Theme.success : Theme.danger).opacity(0.12),
                                            in: Capsule())
                            }
                            if trip.lifetime.cleanStreak >= 2 {
                                Label(String(format: String(localized: "чистая серия: %lld подряд"),
                                             trip.lifetime.cleanStreak),
                                      systemImage: "flame.fill")
                                    .font(.rounded(12, .semibold))
                                    .foregroundStyle(Theme.radar)
                            }
                            Text("как считается")
                                .font(.rounded(11, .medium))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.rounded(13, .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "gauge.with.needle")
                    .font(.rounded(30))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 64, height: 64)
                    .background(Theme.accent.opacity(0.10), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text("Рейтинг вождения")
                        .font(.rounded(16, .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Появится после первых поездок мимо камер — считаем скорость у каждой и плавность езды.")
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
    }

    // MARK: - Сэкономлено на штрафах

    @ViewBuilder
    private func savedCard(trip: TripStats) -> some View {
        // Тап — таблица штрафных ступеней и как считаем экономию.
        Button {
            showSavingsInfo = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                    .font(.rounded(22, .bold))
                    .foregroundStyle(Theme.success)
                    .frame(width: 48, height: 48)
                    .background(Theme.success.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    if trip.lifetime.savedFinesSum > 0 {
                        Text("Сэкономлено на штрафах")
                            .font(.rounded(13, .medium))
                            .foregroundStyle(Theme.textSecondary)
                        Text("≈ \(Formatting.money(trip.lifetime.savedFinesSum))")
                            .font(.rounded(24, .heavy))
                            .foregroundStyle(Theme.success)
                            .contentTransition(.numericText())
                        Text("за 30 дней: ≈ \(Formatting.money(trip.monthSaved)) · как считаем?")
                            .font(.rounded(11))
                            .foregroundStyle(Theme.textTertiary)
                    } else {
                        Text("Сэкономлено на штрафах")
                            .font(.rounded(15, .bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Каждая камера, пройденная в лимите, — несостоявшийся штраф. Посчитаем и покажем.")
                            .font(.rounded(12))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
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

    // MARK: - Заголовок статуса

    @ViewBuilder
    private func statusHeader(active: Bool, trip: TripStats, last: TripRecord?) -> some View {
        if let last {
            // Живых метрик нет (перезапуск) — последняя поездка из истории, тап — деталка.
            Button {
                selectedRecord = last
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(Theme.textTertiary.opacity(0.15))
                            .frame(width: 46, height: 46)
                        Image(systemName: "flag.checkered")
                            .font(.rounded(20, .bold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Последняя поездка")
                            .font(.rounded(17, .bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("\(last.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(Formatting.duration(last.duration))")
                            .font(.rounded(14, .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.rounded(13, .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(16)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
            }
            .buttonStyle(.plain)
        } else {
            liveHeader(active: active, trip: trip)
        }
    }

    @ViewBuilder
    private func liveHeader(active: Bool, trip: TripStats) -> some View {
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
                // Тернарник из литералов вывелся бы в String и обошёл локализацию.
                Group {
                    if active {
                        Text("Поездка идёт")
                    } else if trip.startedAt != nil || trip.distanceMeters > 0 {
                        Text("Последняя поездка")
                    } else {
                        Text("Поездка не начата")
                    }
                }
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

    private func statsGrid(trip: TripStats, last: TripRecord?) -> some View {
        // Живая сессия либо последняя запись из истории (после перезапуска).
        let cameras = last?.camerasPassed ?? trip.camerasPassed
        let distance = last?.distanceMeters ?? trip.distanceMeters
        let maxSpeed = last?.maxSpeedKmh ?? trip.maxSpeedKmh
        let avgSpeed = last?.averageSpeedKmh ?? trip.averageSpeedKmh
        let cols = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: cols, spacing: 12) {
            tile("\(cameras)", "камер пройдено", "camera.metering.center.weighted", Theme.accent)
            tile(Formatting.distance(distance), "пройдено пути", "point.topleft.down.to.point.bottomright.curvepath", Theme.success)
            tile("\(Int(maxSpeed))", "макс. км/ч", "gauge.with.dots.needle.100percent", Theme.danger)
            tile("\(Int(avgSpeed))", "средняя км/ч", "gauge.with.dots.needle.33percent", Theme.radar)
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

    private func passedSection(passes: [PassedCamera], track: [TrackPoint]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Пройденные камеры")
                .font(.rounded(14, .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(passes.reversed()) { pass in
                PassRowButton(pass: pass) { selectedPass = $0 }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // Новый проезд в живой поездке въезжает сверху, а не вспыхивает.
        .animation(.spring(duration: 0.4), value: passes.count)
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
                // Балл поездки — цвет по зоне, поездки сравниваешь с одного взгляда.
                if let score = record.score {
                    Text("\(Int(score))")
                        .font(.rounded(13, .heavy).monospacedDigit())
                        .foregroundStyle(scoreColor(Int(score)))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(scoreColor(Int(score)).opacity(0.13), in: Capsule())
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
        let daily = TripHistory.weekDaily(trip.history)
        let maxKm = max(daily.map(\.km).max() ?? 0, 1)
        return VStack(spacing: 12) {
            HStack(spacing: 0) {
                weekMetric(String(format: String(localized: "%lld поездок"), week.trips), "car.fill")
                weekDivider
                weekMetric(Formatting.distance(week.distance), "point.topleft.down.to.point.bottomright.curvepath")
                weekDivider
                weekMetric(String(format: String(localized: "%lld камер"), week.cameras), "camera.fill")
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

    private func scoreColor(_ score: Int) -> Color {
        switch DrivingScore.tier(for: score) {
        case 2: return Theme.success
        case 1: return Theme.radar
        default: return Theme.danger
        }
    }

    // MARK: - Шеринг итогов

    /// Рендерим карточку в момент тапа — данные всегда свежие, открытие не тормозим.
    private func share(trip: TripStats) {
        guard trip.rating != nil else { return }   // хвастаться пока нечем
        let renderer = ImageRenderer(content: StatsShareCard(trip: trip))
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: 540, height: 675)
        if let uiImage = renderer.uiImage {
            sharePayload = ShareImagePayload(image: uiImage)
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


// MARK: - Бейдж достижения

/// Полученный — залит акцентом; будущий — серый с кольцом прогресса, видно, сколько осталось.
private struct AchievementBadge: View {
    let badge: Achievement

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                if badge.earned {
                    Circle().fill(Theme.accent.gradient)
                        .shadow(color: Theme.accent.opacity(0.45), radius: 6)
                } else {
                    Circle().fill(Theme.surface)
                    Circle()
                        .trim(from: 0, to: badge.fraction)
                        .stroke(Theme.accent.opacity(0.55),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(1.5)
                }
                Image(systemName: badge.icon)
                    .font(.rounded(19, .semibold))
                    .foregroundStyle(badge.earned ? Theme.background : Theme.textTertiary)
            }
            .frame(width: 56, height: 56)

            Text(badge.title)
                .font(.rounded(10, .medium))
                .foregroundStyle(badge.earned ? Theme.textPrimary : Theme.textTertiary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(width: 82)
    }
}

// MARK: - Карточка «Мои итоги» для шеринга (рендерится в 1080×1350)

private struct StatsShareCard: View {
    let trip: TripStats

    var body: some View {
        VStack(spacing: 0) {
            // Шапка
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(Theme.accent)
                Text("RadarMap")
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Text("Мои итоги")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 32)
            .padding(.top, 32)

            Spacer()

            // Рейтинг
            if let rating = trip.rating {
                RatingRing(rating: rating, animated: false)
                    .frame(width: 170, height: 170)
                Text(DrivingScore.level(for: rating))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.top, 16)
                if trip.lifetime.cleanStreak >= 2 {
                    Label(String(format: String(localized: "чистая серия: %lld подряд"),
                                 trip.lifetime.cleanStreak),
                          systemImage: "flame.fill")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.radar)
                        .padding(.top, 6)
                }
            }

            // Экономия
            if trip.lifetime.savedFinesSum > 0 {
                VStack(spacing: 4) {
                    Text("Сэкономлено на штрафах")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                    Text("≈ \(Formatting.money(trip.lifetime.savedFinesSum))")
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .foregroundStyle(Theme.success)
                }
                .padding(.top, 26)
            }

            Spacer()

            // Метрики недели
            HStack(spacing: 0) {
                cardMetric(Formatting.distance(trip.weekSummary?.distance ?? 0),
                           String(localized: "за 7 дней"))
                cardDivider
                cardMetric("\(trip.weekSummary?.cameras ?? 0)", String(localized: "камер"))
                cardDivider
                cardMetric("\(trip.lifetime.trips)", String(localized: "поездок всего"))
            }
            .padding(.vertical, 20)
            .background(.white.opacity(0.06))

            Text("Карта камер и навигатор Узбекистана")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.vertical, 14)
        }
        .frame(width: 540, height: 675)
        .background(
            ZStack {
                Theme.background
                RadialGradient(colors: [Theme.accent.opacity(0.14), .clear],
                               center: .center, startRadius: 40, endRadius: 380)
            }
        )
    }

    private func cardMetric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
    }

    private var cardDivider: some View {
        Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 34)
    }
}
