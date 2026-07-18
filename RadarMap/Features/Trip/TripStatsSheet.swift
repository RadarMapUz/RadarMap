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

    var body: some View {
        let trip = env.trip
        let active = env.location.isTripActive
        // После перезапуска приложения живых метрик нет — показываем последнюю
        // поездку из истории, а не нули.
        let lastRecord = trip.fallbackRecord(isTripActive: active)

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
                    finesCard(trip: trip)
                        .entrance(3, appeared)

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
                    } else if !active {
                        emptyHint
                            .entrance(4, appeared)
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
                        // Похвастаться итогами: рейтинг + экономия одной картинкой.
                        if trip.rating != nil {
                            Button { share(trip: trip) } label: {
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
                    if args.contains("-showSavingsInfo") { showSavingsInfo = true }
                    if args.contains("-shareStats") { share(trip: env.trip) }
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

    // MARK: - Штрафы за 30 дней

    /// Честный счёт вместо виртуальной «экономии»: 0 штрафов — гордость,
    /// есть превышения — реальный риск по штрафным ступеням + где чаще всего.
    @ViewBuilder
    private func finesCard(trip: TripStats) -> some View {
        let month = trip.month30
        let total = month.clean + month.over
        let ok = month.over == 0
        // Тап — таблица штрафных ступеней (как считаем).
        Button {
            showSavingsInfo = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: ok ? "shield.lefthalf.filled.badge.checkmark"
                                     : "exclamationmark.shield.fill")
                    .font(.rounded(22, .bold))
                    .foregroundStyle(ok ? Theme.success : Theme.danger)
                    .frame(width: 48, height: 48)
                    .background((ok ? Theme.success : Theme.danger).opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("Штрафы за 30 дней")
                        .font(.rounded(13, .medium))
                        .foregroundStyle(Theme.textSecondary)
                    if total == 0 {
                        Text("Проезжайте камеры — посчитаем проезды в лимите и риск штрафов.")
                            .font(.rounded(12))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if ok {
                        Text("0 штрафов")
                            .font(.rounded(24, .heavy))
                            .foregroundStyle(Theme.success)
                        Text(String(format: String(localized: "%lld проездов камер — все в лимите"), total))
                            .font(.rounded(11))
                            .foregroundStyle(Theme.textTertiary)
                    } else {
                        Text("риск ≈ \(Formatting.money(month.risk))")
                            .font(.rounded(24, .heavy))
                            .foregroundStyle(Theme.danger)
                            .contentTransition(.numericText())
                        Text(String(format: String(localized: "%lld превышений из %lld проездов"),
                                    month.over, total))
                            .font(.rounded(11))
                            .foregroundStyle(Theme.textTertiary)
                        // «Зона риска»: камера, где превышаете чаще всего, — ясно, где сбавлять.
                        if let top = month.topOverLocation {
                            Label(String(format: String(localized: "Чаще всего: %@"), top),
                                  systemImage: "mappin.circle.fill")
                                .font(.rounded(11, .medium))
                                .foregroundStyle(Theme.radar)
                                .lineLimit(1)
                        }
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
        // Компактный заголовок секции вместо прежней крупной карточки-дубля:
        // цифры и так в сетке ниже, тап по заголовку открывает деталку.
        if let last {
            Button {
                selectedRecord = last
            } label: {
                HStack(spacing: 6) {
                    Text("Последняя поездка")
                        .font(.rounded(14, .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Text("· \(last.startedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.rounded(13))
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.rounded(12, .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .contentShape(Rectangle())
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
        // Живые цифры анимируются (numericText) — метрики тикают на глазах в поездке.
        let cols = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: cols, spacing: 12) {
            StatTile(value: "\(cameras)", label: "камер пройдено",
                     icon: "camera.metering.center.weighted", color: Theme.accent, animatesValue: true)
            StatTile(value: Formatting.distance(distance), label: "пройдено пути",
                     icon: "point.topleft.down.to.point.bottomright.curvepath", color: Theme.success, animatesValue: true)
            StatTile(value: "\(Int(maxSpeed))", label: "макс. км/ч",
                     icon: "gauge.with.dots.needle.100percent", color: Theme.danger, animatesValue: true)
            StatTile(value: "\(Int(avgSpeed))", label: "средняя км/ч",
                     icon: "gauge.with.dots.needle.33percent", color: Theme.radar, animatesValue: true)
        }
    }

    // MARK: - Шеринг итогов

    /// Рендерим карточку в момент тапа — данные всегда свежие, открытие не тормозим.
    /// Сверху — карта последней поездки (район + трек): шеринг информативнее цифр.
    private func share(trip: TripStats) {
        guard trip.rating != nil else { return }   // хвастаться пока нечем
        Task {
            let last = trip.fallbackRecord(isTripActive: env.location.isTripActive)
                ?? trip.history.first
            let map = await TripMapSnapshot.render(track: last?.trackPoints ?? [],
                                                   passes: last?.passed ?? [],
                                                   size: CGSize(width: 1032, height: 420))
            let renderer = ImageRenderer(content: StatsShareCard(trip: trip, mapImage: map))
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
