//
//  TripStatsSheet.swift
//  RadarMap
//
//  «Итоги» — единый экран статистики. Фильтр периода (День / Неделя / Месяц)
//  правит ВСЕМ разделом до разделителя «За всё время»: герой, разбор, зона
//  риска, карта, KPI, график и список поездок читают одну и ту же PeriodSummary.
//  Никаких двух источников правды: раньше рядом жили «Штрафы за 30 дней»,
//  недельная карточка истории и отдельный отчёт — три пересчёта одного и того же,
//  а расшифровки по тапу показывали своё окно (85 в шапке против 82 внутри).
//
//  Периоды КАЛЕНДАРНЫЕ и листаются стрелками (см. anchor и StatsPeriod):
//  «5–11 августа», а не «последние 168 часов», которые менялись сами по себе.
//  Сегмента «Всё время» нет: он врал — история чистится, и «всё время»
//  показывало последние записи. Пожизненная правда живёт в блоке «За всё время»
//  (LifetimeStats) плюс отдельный экран «Все поездки».
//
//  Порядок блоков отвечает на вопросы в том порядке, в каком их задаёт водитель:
//  «как я езжу» (герой) → «сколько рискую и где» (зона риска) → «покажи на
//  карте» → детали (плитки, график) → пожизненное (достижения, история).
//  Раньше зона риска стояла под картой высотой 230 pt и уезжала за сгиб.
//
//  Каждый блок нажимается: герой → как считается рейтинг; карта и зона риска →
//  полноэкранная карта проездов (риск — сразу с фокусом на «своей» камере);
//  достижение → его условия; поездка → деталка.
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
    /// Какое именно окно показываем: любая дата внутри него. Стрелки листают
    /// якорь, а не «сдвигают окно на N дней» — периоды календарные.
    @State private var anchor = Date()
    @State private var selectedRecord: TripRecord?
    /// Каскадное появление секций при открытии (одноразовое).
    @State private var appeared = false
    @State private var sharePayload: ShareImagePayload?
    @State private var showRatingInfo = false
    @State private var showFinesInfo = false
    @State private var selectedBadge: Achievement?
    /// Вся сохранённая история отдельным экраном — вместо сегмента «Всё время»,
    /// который обещал показать всё, а показывал последние записи.
    @State private var showAllTrips = false
    /// Полноэкранная карта проездов (item — чтобы передать фокус зоны риска).
    @State private var mapPayload: PeriodMapPayload?
    /// Треки, маркеры и слой частоты — считаются на смену периода, а не в body.
    @State private var mapData = PeriodMapData()
    /// Поездка, «применённая» к карте тапом по списку (nil — весь период).
    @State private var mapSelection: TripRecord?
    @State private var mapPosition: MapCameraPosition = .automatic
    /// Скользящая пилюля фильтра периода.
    @Namespace private var periodPill

    /// Ключ пересчёта данных карты: период и состав истории.
    private struct MapDataKey: Equatable {
        let period: StatsPeriod
        let anchor: Date
        let count: Int
        let latest: Double?
    }

    var body: some View {
        let trip = env.trip
        let active = env.location.isTripActive
        let summary = TripHistory.summary(days: trip.days, history: trip.history,
                                          period: period, anchor: anchor)

        NavigationStack {
            ScrollView {
                ScrollViewReader { proxy in
                LazyVStack(spacing: 16) {
                    // Живая поездка — вне периодов: таймер, скорость, живые метрики.
                    // Отдельная вью: она читает скорость (меняется каждый тик GPS),
                    // и пока жила в body листа, каждый тик пересчитывал сводку
                    // всего периода по всей истории.
                    if active {
                        LiveTripCard()
                            .entrance(0, appeared)
                    }

                    periodPicker
                        .entrance(0, appeared)
                    periodNavigator
                        .entrance(0, appeared)

                    if summary.isEmpty {
                        // Пусто может быть по двум причинам: поездок нет вообще
                        // или нет именно в этом периоде — это разные подсказки.
                        if trip.history.isEmpty {
                            if !active { emptyHint.entrance(1, appeared) }
                        } else {
                            emptyPeriodHint.entrance(1, appeared)
                        }
                    } else {
                        heroCard(trip: trip, summary: summary)
                            .entrance(1, appeared)
                        // Разбор идёт сразу за рейтингом: сначала вывод, потом
                        // цифры, на которых он построен, — а не наоборот.
                        insightsCard(summary: summary)
                            .entrance(1, appeared)
                        riskCard(summary: summary)
                            .entrance(2, appeared)
                        mapCard
                            .entrance(3, appeared)
                            .id("map")
                        kpiStrip(summary: summary)
                            .entrance(3, appeared)
                        if let days = period.chartDays(containing: anchor) {
                            dailyChart(days: days, summary: summary)
                                .entrance(4, appeared)
                        }
                        riskHoursCard(summary: summary)
                            .entrance(4, appeared)
                        tripsSection(trip: trip, proxy: proxy)
                            .entrance(4, appeared)
                            .id("history")
                    }

                    if !trip.lifetime.isEmpty {
                        LabeledDivider(title: String(localized: "За всё время"))
                            .entrance(5, appeared)
                        lifetimeStrip(trip: trip)
                            .entrance(5, appeared)
                        achievementsSection(trip: trip)
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
            // Карточки уезжали под прозрачный бар и просвечивали сквозь него:
            // «85 рейтинг» читался поверх кнопок. Жёсткий край прокрутки
            // отделяет содержимое от панели.
            .backport.scrollEdgeEffectStyle(.hard, for: .top)
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
            // Треки и слой частоты — один пересчёт на смену периода/истории.
            // В body это делать нельзя: пересчёт шёл бы на каждый кадр прокрутки.
            .task(id: MapDataKey(period: period, anchor: anchor, count: trip.history.count,
                                 latest: trip.history.first?.id)) {
                mapData = await TripHistory.mapData(trip.history, period: period, anchor: anchor)
                if mapSelection == nil { framePeriod() }
            }
            .onChange(of: period) {
                // Выбранная поездка могла не попасть в новый период.
                withAnimation(.snappy(duration: 0.3)) { clearMapSelection() }
            }
            .onChange(of: anchor) {
                withAnimation(.snappy(duration: 0.3)) { clearMapSelection() }
            }
            .onAppear {
                appeared = true
                #if DEBUG
                // Скриншот-автоматизация: открыть вложенные экраны (с паузой —
                // sheet поверх ещё анимирующегося sheet молча не показывается).
                let args = ProcessInfo.processInfo.arguments
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    if args.contains("-showMonth") { period = .month }
                    if args.contains("-openFirstTrip") { selectedRecord = env.trip.history.first }
                    if args.contains("-showRatingInfo") { showRatingInfo = true }
                    if args.contains("-showSavingsInfo") { showFinesInfo = true }
                    if args.contains("-showPeriodMap") { openMap(focus: nil) }
                    if args.contains("-shareStats") {
                        share(summary: TripHistory.summary(days: env.trip.days,
                                                          history: env.trip.history,
                                                          period: period, anchor: anchor))
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
            PeriodMapSheet(data: payload.data, focus: payload.focus)
        }
        // Шиты получают ТУ ЖЕ сводку, что показала карточка: расшифровка
        // обязана объяснять именно то число, по которому тапнули.
        .sheet(isPresented: $showRatingInfo) {
            RatingInfoSheet(summary: TripHistory.summary(days: env.trip.days,
                                                         history: env.trip.history,
                                                         period: period, anchor: anchor),
                            period: period,
                            interval: period.interval(containing: anchor),
                            onOpenTrip: { id in
                                selectedRecord = env.trip.history.first { $0.id == id }
                            })
        }
        .sheet(isPresented: $showFinesInfo) {
            SavingsInfoSheet(summary: TripHistory.summary(days: env.trip.days,
                                                          history: env.trip.history,
                                                          period: period, anchor: anchor),
                             period: period,
                             interval: period.interval(containing: anchor))
        }
        .sheet(item: $selectedBadge) { badge in AchievementInfoSheet(badge: badge) }
        .sheet(isPresented: $showAllTrips) {
            AllTripsSheet(onOpenDetail: { record in
                showAllTrips = false
                selectedRecord = record
            }, onRepeat: onRoute.map { route in
                { coord, name in dismiss(); route(coord, name) }
            })
        }
        .sheet(item: $sharePayload) { payload in
            ActivityShareSheet(image: payload.image)
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
    }

    // MARK: - Фильтр периода

    /// Сегменты на общей дорожке: выделение переезжает между ними, а не
    /// перекрашивается на месте — сразу видно, что это один переключатель.
    private var periodPicker: some View {
        HStack(spacing: 2) {
            ForEach(StatsPeriod.allCases) { item in
                let selected = period == item
                Button {
                    withAnimation(.snappy(duration: 0.3)) { period = item }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Text(item.title)
                        .font(.rounded(13, .semibold))
                        .foregroundStyle(selected ? Theme.background : Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background {
                            if selected {
                                Capsule().fill(Theme.accent.gradient)
                                    .matchedGeometryEffect(id: "periodPill", in: periodPill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(4)
        .background(Theme.surface, in: Capsule())
    }

    /// Строка периода со стрелками: «‹ 5–11 августа ›». Без неё календарные
    /// периоды бессмысленны — непонятно, какое окно на экране и что листаешь.
    private var periodNavigator: some View {
        HStack(spacing: 8) {
            navArrow("chevron.left", enabled: true) { step(-1) }
            Text(period.rangeTitle(containing: anchor))
                .font(.rounded(14, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.25), value: anchor)
            // Вперёд из текущего периода некуда: будущего в статистике нет.
            navArrow("chevron.right", enabled: period.canGoForward(from: anchor)) { step(1) }
        }
        .padding(.horizontal, 4)
    }

    private func navArrow(_ symbol: String, enabled: Bool,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.rounded(13, .bold))
                .foregroundStyle(enabled ? Theme.accent : Theme.textTertiary.opacity(0.4))
                .frame(width: 36, height: 32)
                .background(Theme.surface, in: Capsule())
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
        .accessibilityLabel(Text(symbol == "chevron.left" ? "Предыдущий период"
                                                          : "Следующий период"))
    }

    private func step(_ direction: Int) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.snappy(duration: 0.3)) {
            anchor = period.shifted(anchor, by: direction)
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
                    VStack(spacing: 6) {
                        RatingRing(rating: rating)
                            .frame(width: 88, height: 88)
                        // Рейтинг сам по себе — абстракция. Движение к прошлому
                        // такому же периоду делает его понятным.
                        if let delta = summary.ratingDelta,
                           abs(delta) >= AppConfig.insightRatingStep {
                            ratingDeltaBadge(delta)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(period.caption)
                        .font(.rounded(11, .medium))
                        .foregroundStyle(Theme.textTertiary)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Formatting.distance(summary.distance))
                            .font(.rounded(30, .heavy))
                            .foregroundStyle(Theme.textPrimary)
                            .contentTransition(.numericText())
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
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
                        .lineLimit(1)               // «за рулём» уезжало на вторую
                        .minimumScaleFactor(0.75)   // строку и рвало ритм карточки
                    if trip.lifetime.cleanStreak >= 2 {
                        Label(String(format: String(localized: "чистая серия: %lld подряд"),
                                     trip.lifetime.cleanStreak),
                              systemImage: "flame.fill")
                            .font(.rounded(11, .semibold))
                            .foregroundStyle(Theme.warning)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.rounded(13, .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .statCard()
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

    /// «+6» под кольцом: рост рейтинга — зелёный, просадка — красная.
    private func ratingDeltaBadge(_ delta: Int) -> some View {
        let up = delta > 0
        let tint = up ? Theme.success : Theme.danger
        return Label(up ? "+\(delta)" : "\(delta)",
                     systemImage: up ? "arrow.up" : "arrow.down")
            .font(.rounded(11, .bold).monospacedDigit())
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
            .accessibilityLabel(Text(up ? "Рейтинг вырос" : "Рейтинг снизился"))
    }

    // MARK: - Разбор периода

    /// Два-три вывода вместо стены цифр: стало лучше или хуже, где и когда
    /// рискуете. Всё формулирует модель (PeriodInsights) — вьюха только красит.
    @ViewBuilder
    private func insightsCard(summary: PeriodSummary) -> some View {
        let insights = PeriodInsights.build(summary)
        if !insights.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(period.insightsTitle)
                ForEach(insights) { insight in
                    insightRow(insight)
                }
            }
            .statCard()
        }
    }

    private func insightRow(_ insight: Insight) -> some View {
        let tint = Self.insightTint(insight.kind)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: insight.icon)
                .font(.rounded(13, .bold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.14), in: Circle())
            Text(insight.text)
                .font(.rounded(13, .medium))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private static func insightTint(_ kind: Insight.Kind) -> Color {
        switch kind {
        case .good:    return Theme.success
        case .warning: return Theme.warning
        case .bad:     return Theme.danger
        case .neutral: return Theme.accent
        }
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

    // MARK: - Зона риска (тап — карта с фокусом на камере)

    /// Второй блок сверху: главный вопрос после «как я езжу» — «сколько это
    /// стоит и где». Сумма всегда в одну строку (раньше «риск ≈ 4,4 млн сум»
    /// ломался на две), (i) о ступенях штрафа — отдельной кнопкой в углу, чтобы
    /// основной тап остался за картой.
    @ViewBuilder
    private func riskCard(summary: PeriodSummary) -> some View {
        let total = summary.cleanPasses + summary.overPasses
        if total > 0 {
            let ok = summary.overPasses == 0
            ZStack(alignment: .topTrailing) {
                Button {
                    if ok {
                        showFinesInfo = true
                    } else {
                        // Фокус: самая «нарушаемая» камера периода.
                        openMap(focus: mapData.markers.filter(\.hasViolation)
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
                            Text(ok ? "Зона риска" : "Возможные штрафы")
                                .font(.rounded(13, .medium))
                                .foregroundStyle(Theme.textSecondary)
                            Text(ok ? String(localized: "0 штрафов")
                                    : Formatting.money(summary.fineRisk))
                                .font(.rounded(28, .heavy))
                                .foregroundStyle(ok ? Theme.success : Theme.danger)
                                .contentTransition(.numericText())
                                .lineLimit(1)
                                .minimumScaleFactor(0.55)
                            Text(passesLine(summary, total: total, ok: ok))
                                .font(.rounded(11))
                                .foregroundStyle(Theme.textTertiary)
                            if !ok {
                                // Где именно и сколько раз — сказал разбор выше;
                                // здесь остаётся только вход на карту.
                                Label("Показать на карте", systemImage: "mappin.circle.fill")
                                    .font(.rounded(11, .medium))
                                    .foregroundStyle(Theme.warning)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        if ok {
                            Image(systemName: "chevron.right")
                                .font(.rounded(13, .semibold))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .statCard()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Вложенные кнопки в SwiftUI ненадёжны — (i) висит рядом с
                // основной кнопкой, а не внутри её label.
                if !ok {
                    Button {
                        showFinesInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.rounded(15))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Как считаются штрафы"))
                }
            }
        }
    }

    /// «Превышений: 2 · проездов камер: 6» — форма после двоеточия не зависит от
    /// числа, поэтому не нужны падежные варианты на каждое число.
    private func passesLine(_ summary: PeriodSummary, total: Int, ok: Bool) -> String {
        if ok {
            return String(format: String(localized: "Проездов камер: %lld — все в лимите"), total)
        }
        return String(format: String(localized: "Превышений: %1$lld · проездов камер: %2$lld"),
                      summary.overPasses, total)
    }

    // MARK: - Карта проездов (превью → полноэкранная)

    /// Карта живёт в двух состояниях. «Все поездки»: треки склеены в слой частоты —
    /// постоянный коридор яркий и толстый, разовая поездка едва видна, поэтому
    /// вместо паутины читается личная карта дорог. «Одна поездка» (тап по строке
    /// списка): её трек в полную яркость со стартом и финишем, остальные — призраки,
    /// камеры — только этого проезда.
    @ViewBuilder private var mapCard: some View {
        if !mapData.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    openMap(focus: nil)
                } label: {
                    mapPreview
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(Text(mapSelection == nil
                                         ? "Карта проездов за период. Открыть на весь экран"
                                         : "Карта выбранной поездки. Открыть на весь экран"))
                mapFooter
                    .padding(.horizontal, 4)
            }
        }
    }

    private var mapPreview: some View {
        Map(position: $mapPosition) {
            if let selected = mapSelection {
                selectedTripContent(selected)
            } else {
                heatContent
            }
            ForEach(shownMarkers) { marker in
                Annotation("", coordinate: marker.coordinate, anchor: .center) {
                    previewDot(marker)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll,
                            showsTraffic: false))
        // Жесты самой карты выключены: превью целиком — кнопка «открыть на весь
        // экран», а панорамировать можно там. Форму тапа задаём ниже: без неё
        // выключенный хит-тест карты съедает и тап по кнопке.
        .allowsHitTesting(false)
        .frame(height: 190)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
            .stroke(Theme.stroke, lineWidth: 1))
        .overlay(alignment: .topLeading) {
            if let selected = mapSelection { tripChip(selected).padding(10) }
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
    }

    /// Слой частоты: три градуса толщины и яркости. Подложка только у заметных
    /// линий — на редких она превратила бы карту в кашу и удвоила бы число ломаных.
    @MapContentBuilder private var heatContent: some MapContent {
        ForEach(mapData.heat) { line in
            if line.tier > 0 {
                MapPolyline(coordinates: line.coordinates)
                    .stroke(Theme.background.opacity(0.7),
                            style: Self.strokeStyle(width: line.tier == 2 ? 8 : 6))
            }
        }
        ForEach(mapData.heat) { line in
            MapPolyline(coordinates: line.coordinates)
                .stroke(Theme.accent.opacity(Self.heatOpacity(line.tier)),
                        style: Self.strokeStyle(width: Self.heatWidth(line.tier)))
        }
    }

    /// Выбранная поездка: остальные треки остаются призраками — видно, как эта
    /// поездка легла в общую картину недели.
    @MapContentBuilder private func selectedTripContent(_ record: TripRecord) -> some MapContent {
        ForEach(Array(mapData.tracks.enumerated()), id: \.offset) { _, track in
            MapPolyline(coordinates: track.map {
                CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
            })
            .stroke(Theme.accent.opacity(0.12), style: Self.strokeStyle(width: 2))
        }
        let points = record.trackPoints
        MapPolyline(coordinates: points.map {
            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
        })
        .stroke(Theme.background.opacity(0.8), style: Self.strokeStyle(width: 8))
        MapPolyline(coordinates: points.map {
            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
        })
        .stroke(Theme.accent, style: Self.strokeStyle(width: 4))
        if let start = points.first, let finish = points.last {
            Annotation("", coordinate: CLLocationCoordinate2D(latitude: start.lat,
                                                              longitude: start.lon),
                       anchor: .center) {
                endpointDot(.white, size: 11)
            }
            .annotationTitles(.hidden)
            Annotation("", coordinate: CLLocationCoordinate2D(latitude: finish.lat,
                                                              longitude: finish.lon),
                       anchor: .center) {
                endpointDot(Theme.accent, size: 15)
            }
            .annotationTitles(.hidden)
        }
    }

    private static func strokeStyle(width: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    }

    private static func heatWidth(_ tier: Int) -> CGFloat {
        switch tier {
        case 2:  return 5
        case 1:  return 3.5
        default: return 2
        }
    }

    private static func heatOpacity(_ tier: Int) -> Double {
        switch tier {
        case 2:  return 1
        case 1:  return 0.7
        default: return 0.35
        }
    }

    /// Маркеры камер: в режиме одной поездки — только её проезды.
    private var shownMarkers: [PassMarker] {
        mapSelection.map { TripHistory.passMarkers(of: $0) } ?? mapData.markers
    }

    private func previewDot(_ marker: PassMarker) -> some View {
        let size = min(26.0, 15 + Double(marker.times) * 2)
        return Circle()
            .fill(marker.hasViolation ? Theme.danger : Theme.success)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.5))
    }

    private func endpointDot(_ color: Color, size: CGFloat) -> some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 2))
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
    }

    /// Подпись выбранной поездки поверх карты — не занимает строку под ней.
    private func tripChip(_ record: TripRecord) -> some View {
        HStack(spacing: 8) {
            Text(record.startedAt.formatted(date: .omitted, time: .shortened))
                .font(.rounded(12, .bold))
                .foregroundStyle(Theme.textPrimary)
            Text(Formatting.distance(record.distanceMeters))
                .font(.rounded(12, .medium))
                .foregroundStyle(Theme.textSecondary)
            if let score = record.score {
                Text("\(Int(score))")
                    .font(.rounded(12, .heavy).monospacedDigit())
                    .foregroundStyle(TripHistorySection.scoreColor(Int(score)))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Theme.background.opacity(0.8), in: Capsule())
        .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
    }

    // MARK: - Подпись под картой

    /// Без выбора — легенда с цифрами и вход в полный экран. С выбором — возврат
    /// ко всем поездкам и вход в деталку: тап по строке теперь занят картой.
    @ViewBuilder private var mapFooter: some View {
        if let selected = mapSelection {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.snappy(duration: 0.3)) { clearMapSelection() }
                } label: {
                    Label("Все поездки", systemImage: "xmark.circle.fill")
                        .font(.rounded(11, .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(PressableStyle())
                Spacer(minLength: 0)
                Button {
                    selectedRecord = selected
                } label: {
                    HStack(spacing: 4) {
                        Text("Подробнее")
                            .font(.rounded(11, .semibold))
                        Image(systemName: "chevron.right")
                            .font(.rounded(9, .bold))
                    }
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(PressableStyle())
            }
        } else {
            HStack(spacing: 14) {
                // На карте — точки, то есть УНИКАЛЬНЫЕ камеры; повторные
                // проезды одной камеры складываются в один маркер.
                legendItem(Theme.success,
                           String(format: String(localized: "Камер в лимите: %lld"),
                                  mapData.markers.filter { !$0.hasViolation }.count))
                if mapData.markers.contains(where: \.hasViolation) {
                    legendItem(Theme.danger,
                               String(format: String(localized: "Камер с превышением: %lld"),
                                      mapData.markers.filter(\.hasViolation).count))
                }
                Spacer(minLength: 0)
                Button {
                    openMap(focus: nil)
                } label: {
                    HStack(spacing: 4) {
                        Text("Открыть")
                            .font(.rounded(11, .semibold))
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.rounded(9, .bold))
                    }
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(PressableStyle())
            }
        }
    }

    private func legendItem(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(.rounded(11)).foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: - Выбор поездки и переходы на карту

    /// Тап по строке списка «применяет» поездку к карте: экран сам подкручивается
    /// к карте (иначе изменение произошло бы за кадром), камера едет к треку.
    private func showOnMap(_ record: TripRecord, proxy: ScrollViewProxy) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let same = mapSelection?.id == record.id
        withAnimation(.snappy(duration: 0.35)) {
            if same {
                clearMapSelection()
            } else {
                mapSelection = record
                if let rect = PeriodMapSheet.boundingRect(
                    tracks: [record.trackPoints], markers: TripHistory.passMarkers(of: record)) {
                    mapPosition = .rect(rect)
                }
            }
            proxy.scrollTo("map", anchor: .top)
        }
    }

    private func clearMapSelection() {
        mapSelection = nil
        framePeriod()
    }

    /// Рамка по всем трекам и камерам периода. `.automatic` тут не годится: он
    /// обрамляет содержимое с таким запасом, что вместо города показывает область.
    private func framePeriod() {
        guard let rect = PeriodMapSheet.boundingRect(tracks: mapData.tracks,
                                                    markers: mapData.markers) else { return }
        mapPosition = .rect(rect)
    }

    private func openMap(focus: PassMarker?) {
        // Полноэкранная карта уважает выбор: показывает то же, что и превью.
        let data = mapSelection.map { TripHistory.mapData(of: $0) } ?? mapData
        mapPayload = PeriodMapPayload(data: data, focus: focus)
    }

    // MARK: - Полоса KPI

    /// Четыре цифры одной строкой вместо сетки 2×2 из разноцветных плиток.
    /// Сетка занимала полэкрана и красила каждую цифру в свой цвет — цвет
    /// переставал что-либо значить. Здесь цветом отмечено только состояние
    /// (зона риска, рейтинг), а справочные числа спокойные.
    private func kpiStrip(summary: PeriodSummary) -> some View {
        HStack(spacing: 0) {
            // Именно ПРОЕЗДЫ: одна камера, пройденная дважды, — это два.
            // Легенда карты считает уникальные точки — слово должно отличаться.
            kpiCell(value: "\(summary.cameras)", label: "проездов камер",
                    icon: "camera.metering.center.weighted")
            kpiDivider
            kpiCell(value: activeDaysText(summary), label: "дней за рулём",
                    icon: "calendar")
            kpiDivider
            kpiCell(value: "\(Int(summary.averageSpeedKmh))", label: "средняя км/ч",
                    icon: "gauge.with.dots.needle.33percent")
            kpiDivider
            kpiCell(value: "\(Int(summary.maxSpeedKmh))", label: "макс. км/ч",
                    icon: "gauge.with.dots.needle.100percent")
        }
        .statCard(padding: 14)
    }

    private func kpiCell(value: String, label: LocalizedStringKey, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.rounded(11, .semibold))
                .foregroundStyle(Theme.textTertiary)
            Text(value)
                .font(.rounded(21, .heavy).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.rounded(10, .medium))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(value), ") + Text(label))
    }

    private var kpiDivider: some View {
        Rectangle().fill(Theme.stroke).frame(width: 1, height: 42)
    }

    // MARK: - Когда рискуете

    /// Превышения по времени суток. «Где» уже отвечает карта, а «когда» до этого
    /// не отвечал никто — хотя вечерний час пик и пустая ночная дорога дают
    /// совершенно разные привычки.
    @ViewBuilder
    private func riskHoursCard(summary: PeriodSummary) -> some View {
        if summary.overPasses >= AppConfig.insightMinOverForHours,
           let peak = summary.peakBlock {
            let blocks = summary.overByBlock
            let top = max(blocks.max() ?? 1, 1)
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: String(localized: "Когда рискуете")) {
                    Text(peak.title)
                        .font(.rounded(12, .semibold))
                        .foregroundStyle(Theme.danger)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { index, count in
                        hourBar(count: count, peak: top, isPeak: index == peak.index,
                                hour: index * 4)
                    }
                }
            }
            .statCard()
        }
    }

    private func hourBar(count: Int, peak: Int, isPeak: Bool, hour: Int) -> some View {
        VStack(spacing: 6) {
            Text(count > 0 ? "\(count)" : " ")
                .font(.rounded(10, .bold).monospacedDigit())
                .foregroundStyle(isPeak ? Theme.danger : Theme.textTertiary)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isPeak ? Theme.danger.gradient : Theme.accent.opacity(0.35).gradient)
                // Пустой блок оставляет тонкую риску: полоса читается как шкала
                // суток, а не как случайный набор столбиков.
                .frame(height: max(3, 52 * Double(count) / Double(peak)))
            Text(String(format: "%02d", hour))
                .font(.rounded(10, .medium).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(String(format: String(localized: "С %1$02d до %2$02d часов: превышений %3$lld"),
                                        hour, (hour + 4) % 24, count)))
    }

    /// «5 из 7» — в окне периода видно, насколько плотно катаешься.
    private func activeDaysText(_ summary: PeriodSummary) -> String {
        guard let window = period.chartDays(containing: anchor) else {
            return "\(summary.activeDays)"
        }
        return String(format: String(localized: "%1$lld из %2$lld"), summary.activeDays, window)
    }

    // MARK: - График по дням

    private func dailyChart(days: Int, summary: PeriodSummary) -> some View {
        let daily = TripHistory.dailyKm(
            TripHistory.records(env.trip.history, period: period, anchor: anchor),
            days: days, now: period.interval(containing: anchor).end.addingTimeInterval(-1))
        let peak = max(daily.map(\.km).max() ?? 0, 1)
        let dense = days > 10
        let hasOverspeed = daily.contains(where: \.hasOverspeed)
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: String(localized: "Километры по дням")) {
                if let busiest = summary.busiestDay, summary.busiestDayKm > 0 {
                    Text(String(format: String(localized: "Больше всего — %@"),
                                Formatting.dayTitle(busiest)))
                        .font(.rounded(12, .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            Chart(daily) { item in
                BarMark(x: .value("День", item.day, unit: .day),
                        y: .value("км", item.km),
                        width: .ratio(dense ? 0.7 : 0.55))
                // Красный столбик = день с превышением: график продолжает
                // историю «где и когда я нарушал», а не просто про километры.
                .foregroundStyle(item.hasOverspeed
                                 ? LinearGradient(colors: [Theme.danger, Theme.warning],
                                                  startPoint: .bottom, endPoint: .top)
                                 : LinearGradient(colors: [Theme.accent, Theme.Types.intelligent],
                                                  startPoint: .bottom, endPoint: .top))
                .opacity(Calendar.current.isDateInToday(item.day) ? 1 : 0.6)
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
            if hasOverspeed {
                legendItem(Theme.danger, String(localized: "день с превышением"))
            }
        }
        .statCard()
    }

    // MARK: - Список поездок периода

    private func tripsSection(trip: TripStats, proxy: ScrollViewProxy) -> some View {
        TripHistorySection(
            title: period.tripsTitle,
            records: TripHistory.historyList(trip.history, period: period, anchor: anchor),
            selectedID: mapSelection?.id,
            onShowOnMap: { showOnMap($0, proxy: proxy) },
            onOpenDetail: { selectedRecord = $0 },
            onRepeat: onRoute.map { route in
                { coord, name in dismiss(); route(coord, name) }
            },
            onDelete: { record in
                withAnimation {
                    if mapSelection?.id == record.id { clearMapSelection() }
                    trip.deleteRecord(id: record.id)
                }
            })
    }

    /// Пожизненные цифры — единственная честная правда «за всё время»:
    /// история чистится, а эти счётчики нет. Отсюда же вход во все поездки.
    private func lifetimeStrip(trip: TripStats) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                kpiCell(value: "\(trip.lifetime.trips)", label: "поездок",
                        icon: "car.side")
                kpiDivider
                kpiCell(value: Formatting.distance(trip.lifetime.distanceMeters),
                        label: "пройдено", icon: "point.topleft.down.to.point.bottomright.curvepath")
                kpiDivider
                kpiCell(value: "\(trip.lifetime.camerasInLimit)", label: "камер в лимите",
                        icon: "checkmark.shield")
                kpiDivider
                kpiCell(value: "\(trip.lifetime.bestStreak)", label: "лучшая серия",
                        icon: "flame")
            }
            Button {
                showAllTrips = true
            } label: {
                HStack(spacing: 6) {
                    Text("Все поездки")
                        .font(.rounded(13, .semibold))
                    Image(systemName: "chevron.right")
                        .font(.rounded(10, .bold))
                }
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
        }
        .statCard(padding: 14)
    }

    // MARK: - Достижения

    private func achievementsSection(trip: TripStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(String(localized: "Достижения"))
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
    private func nextGoalRow(_ badge: Achievement) -> some View {
        Button {
            selectedBadge = badge
        } label: {
            HStack(spacing: 12) {
                Image(systemName: badge.icon)
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 38, height: 38)
                    .background(Theme.accent.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("Ближайшая цель")
                            .font(.rounded(11, .medium))
                            .foregroundStyle(Theme.textTertiary)
                        Text(badge.title)
                            .font(.rounded(13, .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                    }
                    Capsule()
                        .fill(Theme.stroke)
                        .frame(height: 5)
                        .overlay(alignment: .leading) {
                            GeometryReader { geometry in
                                Capsule()
                                    .fill(Theme.accent.gradient)
                                    .frame(width: max(6, geometry.size.width * badge.fraction))
                            }
                        }
                        .clipShape(Capsule())
                }
                Text(badge.progressText)
                    .font(.rounded(12, .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .statCard(padding: 14, radius: Theme.cornerMedium)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Шеринг периода

    /// Рендерим карточку в момент тапа — данные всегда свежие, открытие не тормозим.
    private func share(summary: PeriodSummary) {
        guard !summary.isEmpty else { return }
        let periodTitle = period.title
        let tracks = mapData.tracks
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

    // MARK: - Пустые состояния

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

    /// Поездки есть, но не в этом окне: не оставляем экран пустым — сразу даём
    /// уйти туда, где данные есть.
    /// Пустое окно — не тупик: сразу предлагаем ближайший период, где поездки
    /// есть, одной кнопкой (искать его стрелками вслепую — работа для водителя).
    private var emptyPeriodHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .font(.rounded(26))
                .foregroundStyle(Theme.textTertiary)
            Text("В этом периоде поездок не было")
                .font(.rounded(15, .bold))
                .foregroundStyle(Theme.textPrimary)
            if let nearest = nearestNonEmptyAnchor() {
                Button {
                    withAnimation(.snappy(duration: 0.3)) { anchor = nearest }
                } label: {
                    Text(String(format: String(localized: "Показать: %@"),
                                period.rangeTitle(containing: nearest)))
                        .font(.rounded(13, .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Theme.accent.opacity(0.12), in: Capsule())
                }
                .buttonStyle(PressableStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .statCard(padding: 24)
    }

    /// Ближайшее к текущему окно с поездками: ищем по дневным агрегатам —
    /// они переживают чистку истории, значит найдут и старый период.
    private func nearestNonEmptyAnchor() -> Date? {
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

/// Слепок данных для полноэкранной карты: собирается в момент тапа, чтобы sheet
/// не пересобирался за спиной при изменении периода.
struct PeriodMapPayload: Identifiable {
    let id = UUID()
    let data: PeriodMapData
    let focus: PassMarker?
}

// MARK: - Живая поездка

/// Одна карточка на всю живую поездку. Отдельная вью не для красоты: она
/// единственная в Итогах читает скорость и метрики, меняющиеся каждый тик GPS, —
/// в body листа это чтение пересчитывало сводку периода по всей истории ежесекундно.
private struct LiveTripCard: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let trip = env.trip
        VStack(spacing: 14) {
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
                Spacer(minLength: 0)
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
            Divider().overlay(Theme.stroke)
            HStack(spacing: 0) {
                metric(Formatting.distance(trip.distanceMeters), "пройдено", Theme.success)
                metric("\(trip.camerasPassed)", "камер", Theme.accent)
                metric("\(Int(trip.maxSpeedKmh))", "макс. км/ч", Theme.danger)
                metric("\(Int(trip.averageSpeedKmh))", "средняя", Theme.warning)
            }
        }
        .statCard()
    }

    private func metric(_ value: String, _ label: LocalizedStringKey,
                        _ color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.rounded(18, .heavy).monospacedDigit())
                .foregroundStyle(color)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.4), value: value)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.rounded(10, .medium))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
