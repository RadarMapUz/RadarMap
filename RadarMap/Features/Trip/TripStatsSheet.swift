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
    @State private var shareSubject: ShareSubjectBox?
    @State private var showRatingInfo = false
    @State private var showFinesInfo = false
    /// Расшифровка охвата предупреждений: что именно считается промахом.
    @State private var showRecallInfo = false
    /// Экран «Возможные штрафы» со строками проездов и пометкой «не пришёл».
    @State private var showFines = false
    @State private var selectedBadge: Achievement?
    /// Вся сохранённая история отдельным экраном — вместо сегмента «Всё время»,
    /// который обещал показать всё, а показывал последние записи.
    @State private var showAllTrips = false
    /// Поездка, выбранная в «Всех поездках»: деталка откроется после того, как
    /// список ЗАКОНЧИТ закрываться (см. onDismiss у шита).
    @State private var pendingDetailRecord: TripRecord?
    /// Список поездок показан целиком (иначе — первые statsTripsPreview).
    @State private var tripsExpanded = false
    /// Раскрыты ли «Детали периода» (KPI, график по дням, часы риска).
    @State private var detailsExpanded = false
    /// «Это разные» по карточке склейки — прячем её сразу (Storage не observable).
    @State private var mergeSuggestionHidden = false
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
                LazyVStack(spacing: 16, pinnedViews: [.sectionHeaders]) {
                    // Живая поездка — вне периодов: таймер, скорость, живые метрики.
                    // Отдельная вью: она читает скорость (меняется каждый тик GPS),
                    // и пока жила в body листа, каждый тик пересчитывал сводку
                    // всего периода по всей истории.
                    if active {
                        LiveTripCard()
                            .entrance(0, appeared)
                    }

                    // Пикер и стрелки — одна визуальная группа и ЛИПКАЯ:
                    // прокрутив до списка поездок, человек переставал видеть,
                    // за какое окно эти цифры, и «3–9 августа» приходилось
                    // искать обратной прокруткой. Section с pinnedViews держит
                    // её на месте (LazyVStack умеет это без своей геометрии).
                    Section {
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
                        riskCard(summary: summary)
                            .entrance(2, appeared)
                        pendingNudgeRow
                            .entrance(2, appeared)
                        mapCard
                            .entrance(3, appeared)
                            .id("map")
                        // Календарь — только в «Месяце»: неделя видна и в
                        // столбиках, а месяц по клеткам читается одним взглядом.
                        if period == .month {
                            MonthCalendarCard(days: trip.days, anchor: anchor) { day in
                                withAnimation(.snappy(duration: 0.3)) {
                                    period = .day
                                    anchor = day
                                }
                            }
                            .entrance(3, appeared)
                            .id("calendar")
                        }
                        periodDetails(summary: summary)
                            .entrance(3, appeared)
                        tripsSection(trip: trip, proxy: proxy)
                            .entrance(4, appeared)
                            .id("history")
                    }

                    contributionRow
                        .entrance(5, appeared)

                    if !trip.lifetime.isEmpty {
                        LabeledDivider(title: String(localized: "За всё время"))
                            .entrance(5, appeared)
                        lifetimeStrip(trip: trip)
                            .entrance(5, appeared)
                        // Охват — цифра пожизненная, а не за период: на неделе
                        // это три камеры, и доля от трёх ничего не доказывает.
                        AlertRecallCard(tally: trip.alertRecall) { showRecallInfo = true }
                            .entrance(5, appeared)
                        achievementsSection(trip: trip)
                            .entrance(5, appeared)
                    }
                    } header: {
                        VStack(spacing: 6) {
                            periodPicker
                            periodNavigator
                        }
                        .padding(.vertical, 8)
                        .background {
                            // Под шапкой проезжают карточки — ей нужен свой
                            // фон, иначе цифры наезжают на цифры. Волосяная
                            // линия снизу делает срез карточки намеренным, а
                            // не похожим на артефакт прокрутки.
                            Rectangle()
                                .fill(Theme.background)
                                .padding(.horizontal, -20)
                                .padding(.top, -20)
                                .overlay(alignment: .bottom) {
                                    Rectangle()
                                        .fill(Theme.stroke)
                                        .frame(height: 1)
                                }
                        }
                        .entrance(0, appeared)
                    }
                }
                .padding(20)
                #if DEBUG
                .onAppear {
                    // Скриншот-автоматизация: прокрутить к истории или календарю.
                    let args = ProcessInfo.processInfo.arguments
                    if args.contains("-scrollHistory") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation { proxy.scrollTo("history", anchor: .top) }
                        }
                    }
                    if args.contains("-scrollCalendar") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation { proxy.scrollTo("calendar", anchor: .center) }
                        }
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
                // Выбранная поездка могла не попасть в новый период; раскрытый
                // список — тоже атрибут конкретного окна.
                withAnimation(.snappy(duration: 0.3)) {
                    clearMapSelection()
                    tripsExpanded = false
                }
            }
            .onChange(of: anchor) {
                withAnimation(.snappy(duration: 0.3)) {
                    clearMapSelection()
                    tripsExpanded = false
                }
            }
            .onAppear {
                appeared = true
                // Дневная воронка: какие экраны вообще открывают. Только имя
                // экрана и счётчик — ни времени, ни содержимого.
                env.usage.noteScreen("stats")
                #if DEBUG
                // Скриншот-автоматизация: открыть вложенные экраны (с паузой —
                // sheet поверх ещё анимирующегося sheet молча не показывается).
                let args = ProcessInfo.processInfo.arguments
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    if args.contains("-showMonth") { period = .month }
                    if args.contains("-openFirstTrip") { selectedRecord = env.trip.history.first }
                    if args.contains("-showRatingInfo") { showRatingInfo = true }
                    if args.contains("-showSavingsInfo") { showFinesInfo = true }
                    if args.contains("-showFines") { showFines = true }
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
            RatingDetailSheet(summary: TripHistory.summary(days: env.trip.days,
                                                           history: env.trip.history,
                                                           period: period, anchor: anchor),
                              period: period,
                              interval: period.interval(containing: anchor),
                              anchor: anchor)
        }
        .sheet(isPresented: $showFinesInfo) {
            SavingsInfoSheet(summary: TripHistory.summary(days: env.trip.days,
                                                          history: env.trip.history,
                                                          period: period, anchor: anchor),
                             period: period,
                             interval: period.interval(containing: anchor))
        }
        .sheet(isPresented: $showFines) {
            FinesSheet(period: period, anchor: anchor)
        }
        .sheet(item: $selectedBadge) { badge in AchievementInfoSheet(badge: badge) }
        .sheet(isPresented: $showRecallInfo) {
            AlertRecallInfoSheet(tally: env.trip.alertRecall)
        }
        // Деталка открывается из onDismiss, а не в один тик с закрытием списка:
        // sheet поверх ещё анимирующегося sheet молча не показывается (см.
        // комментарий к скриншот-хукам) — тап по поездке закрывал список, а
        // деталка не появлялась, и повторный тап по той же записи был мёртв.
        .sheet(isPresented: $showAllTrips, onDismiss: {
            if let pending = pendingDetailRecord {
                pendingDetailRecord = nil
                selectedRecord = pending
            }
        }) {
            AllTripsSheet(onOpenDetail: { record in
                pendingDetailRecord = record
                showAllTrips = false
            }, onRepeat: onRoute.map { route in
                { coord, name in dismiss(); route(coord, name) }
            })
        }
        .sheet(item: $shareSubject) { box in
            SharePreviewSheet(subject: box.subject)
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
                // Голая стрелка, мишень прежняя: капсулы-подложки делали из
                // строки периода третий ряд «кнопочной» мебели подряд.
                .frame(width: 36, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
        // Тернарник даёт String, и Text берёт НЕлокализующий инициализатор —
        // без явного String(localized:) подпись оставалась русской на узбекском.
        .accessibilityLabel(Text(symbol == "chevron.left"
                                 ? String(localized: "Предыдущий период")
                                 : String(localized: "Следующий период")))
    }

    private func step(_ direction: Int) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.snappy(duration: 0.3)) {
            anchor = period.shifted(anchor, by: direction)
        }
    }

    // MARK: - Герой: рейтинг + километры + выводы периода

    /// Одна карточка-рассказ: кольцо рейтинга, главная цифра периода с дельтой
    /// и — под тонкой чертой — выводы (PeriodInsights). Раньше выводы жили
    /// своей коробкой с заголовком «Разбор недели»: три отдельных карточки
    /// подряд читались тяжело, а выводы и есть объяснение рейтинга, поэтому
    /// им место в его карточке, и тап по любому месту ведёт в расшифровку.
    private func heroCard(trip: TripStats, summary: PeriodSummary) -> some View {
        Button {
            showRatingInfo = true
        } label: {
            VStack(spacing: 14) {
                heroTopRow(trip: trip, summary: summary)
                let insights = PeriodInsights.build(summary)
                if !insights.isEmpty {
                    Divider().overlay(Theme.stroke)
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(insights) { insightRow($0) }
                    }
                }
            }
            .statCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // combine, а не свой label: у Button собственная подпись ЗАМЕНЯЕТ
        // производную, и VoiceOver терял ровно то, ради чего сюда смотрят —
        // балл, километры, дельту и вывод. Назначение кнопки говорит hint.
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Как считается рейтинг"))
    }

    private func heroTopRow(trip: TripStats, summary: PeriodSummary) -> some View {
        HStack(spacing: 16) {
            if let rating = summary.rating {
                RatingRing(rating: rating)
                    .frame(width: 88, height: 88)
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
                    // Уровень и движение рейтинга — в одной строке. Раньше
                    // бейдж «−16» висел под кольцом и прижимался к его обводке:
                    // круг держал сразу три вещи — число, подпись и дельту.
                    HStack(spacing: 8) {
                        Text(DrivingScore.level(for: rating))
                            .font(.rounded(14, .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        if let delta = summary.ratingDelta,
                           abs(delta) >= AppConfig.insightRatingStep {
                            ratingDeltaBadge(delta)
                        }
                    }
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
            .accessibilityLabel(Text(up ? String(localized: "Рейтинг вырос")
                                        : String(localized: "Рейтинг снизился")))
    }

    // MARK: - Строка вывода (живёт в герой-карточке)

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
            .accessibilityLabel(Text(up ? String(localized: "Больше, чем в прошлый период")
                                        : String(localized: "Меньше, чем в прошлый период")))
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
                        // Список проездов с суммами и пометкой «не пришёл»;
                        // карта каждого проезда — внутри, тапом по строке.
                        showFines = true
                    }
                } label: {
                    HStack(spacing: 14) {
                        // Иконка спокойная даже у риска: красным на первом
                        // экране имеет право быть ОДНА вещь — сама сумма.
                        // Раньше с ней спорили красный значок и красная
                        // подложка, и экран читался как авария.
                        Image(systemName: ok ? "shield.lefthalf.filled.badge.checkmark"
                                             : "exclamationmark.shield.fill")
                            .font(.rounded(22, .bold))
                            .foregroundStyle(ok ? Theme.success : Theme.textSecondary)
                            .frame(width: 48, height: 48)
                            .background((ok ? Theme.success : Theme.textSecondary).opacity(0.10),
                                        in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(ok ? String(localized: "Зона риска")
                                    : String(localized: "Возможные штрафы"))
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
                                // Что за проезды и «не пришёл» — на своём экране.
                                Label("Разобрать проезды", systemImage: "list.bullet.circle.fill")
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

    /// «Ждут ответа: N» — зависшие денежные ожидания старше месяца, по всей
    /// истории, а не окну периода: зависший штраф остаётся зависшим, в каком
    /// периоде на него ни смотри. Тап открывает штрафы того периода, где лежит
    /// самый старый, — иначе кнопка вела бы в окно, где их не видно.
    @ViewBuilder private var pendingNudgeRow: some View {
        if let nudge = TripHistory.pendingFineNudge(env.trip.history) {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.snappy(duration: 0.3)) {
                    period = .month
                    anchor = nudge.oldest
                }
                showFines = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "envelope.badge.clock")
                        .font(.rounded(13, .bold))
                        .foregroundStyle(Theme.warning)
                        .frame(width: 30, height: 30)
                        .background(Theme.warning.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: String(localized: "Ждут ответа: %lld"),
                                    nudge.count))
                            .font(.rounded(14, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Отметьте: штраф пришёл или нет")
                            .font(.rounded(11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.rounded(12, .bold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .statCard(padding: 12, radius: Theme.cornerMedium)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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

    // Полоса KPI и «Когда рискуете» — в TripStatsCards.swift: карточки
    // читают только summary, и экрану они не должны стоить ни строчки.

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

    // MARK: - Детали периода (свёрнуты по умолчанию)

    /// KPI-плитки, график по дням и «Когда рискуете» — под одной раскрывашкой.
    /// Главную историю экран рассказывает выше (рейтинг → выводы → деньги →
    /// карта); эти три блока — справка для любопытных, и развёрнутые всегда они
    /// уводили список поездок за два экрана прокрутки. Свёрнутые они ещё и
    /// бесплатны: dailyKm не считается, пока раскрывашку не открыли.
    private func periodDetails(summary: PeriodSummary) -> some View {
        VStack(spacing: 16) {
            Button {
                withAnimation(.snappy(duration: 0.3)) { detailsExpanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.rounded(13, .bold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 30, height: 30)
                        .background(Theme.accent.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Детали периода")
                            .font(.rounded(14, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Средние, график по дням, часы риска")
                            .font(.rounded(11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.rounded(12, .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(detailsExpanded ? 180 : 0))
                }
                .statCard(padding: 14, radius: Theme.cornerMedium)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(detailsExpanded
                                     ? String(localized: "Скрыть детали периода")
                                     : String(localized: "Показать детали периода")))
            if detailsExpanded {
                KPIStrip(summary: summary,
                         activeDaysText: activeDaysText(summary))
                if let days = period.chartDays(containing: anchor) {
                    dailyChart(days: days, summary: summary)
                }
                RiskHoursCard(summary: summary)
            }
        }
    }

    // MARK: - Список поездок периода

    /// Первые statsTripsPreview строк + «Показать все поездки (N)»: неделя
    /// активной езды — это 20+ записей, и без обрезки блок «За всё время»
    /// приходилось искать археологией.
    private func tripsSection(trip: TripStats, proxy: ScrollViewProxy) -> some View {
        let all = TripHistory.historyList(trip.history, period: period, anchor: anchor)
        let shown = tripsExpanded ? all : Array(all.prefix(AppConfig.statsTripsPreview))
        return VStack(spacing: 10) {
            if let pair = mergeSuggestion {
                mergeSuggestionCard(pair)
            }
            TripHistorySection(
                title: period.tripsTitle,
                records: shown,
                total: all.count,
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
                },
                canMerge: { trip.canMergeWithPrevious(id: $0.id) },
                onMerge: { merge(next: $0) })
            if !tripsExpanded, all.count > AppConfig.statsTripsPreview {
                Button {
                    withAnimation(.snappy(duration: 0.3)) { tripsExpanded = true }
                } label: {
                    HStack(spacing: 6) {
                        Text(String(format: String(localized: "Показать все поездки (%lld)"),
                                    all.count))
                            .font(.rounded(13, .semibold))
                        Image(systemName: "chevron.down")
                            .font(.rounded(10, .bold))
                    }
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity)
                    // Голая строка-ссылка: капсула на всю ширину выглядела ещё
                    // одной карточкой в и без того плотном столбце.
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
            }
        }
    }

    // MARK: - Предложение склейки

    /// Пара «предыдущую завершили кнопкой, новая стартовала рядом и скоро»:
    /// автосклейка не имела права (ручной стоп — намерение), но чаще всего это
    /// заезд в магазин со стопом по привычке — предлагаем объединить одним тапом.
    private var mergeSuggestion: (previous: TripRecord, next: TripRecord)? {
        guard !mergeSuggestionHidden else { return nil }
        let history = env.trip.history
        guard history.count >= 2 else { return nil }
        let next = history[0], previous = history[1]
        // Уже отклоняли для этой пары — не пристаём.
        guard Storage.double(.mergeSuggestDismissedID) != next.id else { return nil }
        // Карточка живёт рядом со списком своего окна, а не во всех периодах.
        guard period.interval(containing: anchor).contains(next.startedAt) else { return nil }
        guard TripMerge.suggestsMerge(previous: previous, next: next,
                                      savedPlaces: env.settings.savedPlaceCoordinates)
        else { return nil }
        return (previous, next)
    }

    private func mergeSuggestionCard(_ pair: (previous: TripRecord, next: TripRecord)) -> some View {
        let gap = pair.next.startedAt.timeIntervalSince(pair.previous.endedAt)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.merge")
                    .font(.rounded(14, .bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 34, height: 34)
                    .background(Theme.accent.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Похоже, это одна поездка")
                        .font(.rounded(14, .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(String(format: String(localized: "%1$@ и %2$@ разделяет стоянка %3$@"),
                                pair.previous.startedAt.formatted(date: .omitted, time: .shortened),
                                pair.next.startedAt.formatted(date: .omitted, time: .shortened),
                                Formatting.duration(gap)))
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Button {
                    merge(next: pair.next)
                } label: {
                    Text("Объединить")
                        .font(.rounded(13, .semibold))
                        .foregroundStyle(Theme.background)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Theme.accent.gradient, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
                Button {
                    Storage.set(pair.next.id, for: .mergeSuggestDismissedID)
                    withAnimation(.snappy(duration: 0.3)) { mergeSuggestionHidden = true }
                } label: {
                    Text("Это разные")
                        .font(.rounded(13, .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Theme.surface, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
            }
        }
        .statCard()
    }

    /// Объединение из карточки и из контекстного меню — одним путём.
    private func merge(next record: TripRecord) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.snappy(duration: 0.35)) {
            // Любая из двух записей могла быть «применена» к карте — слепок
            // после склейки не существует, выбор снимаем.
            clearMapSelection()
            env.trip.mergeWithPrevious(id: record.id)
        }
    }

    /// Пожизненные цифры — единственная честная правда «за всё время»:
    /// история чистится, а эти счётчики нет. Отсюда же вход во все поездки.
    private func lifetimeStrip(trip: TripStats) -> some View {
        let cells: [(String, LocalizedStringKey, String)] = [
            ("\(trip.lifetime.trips)", "поездок", "car.side"),
            (Formatting.distance(trip.lifetime.distanceMeters), "пройдено",
             "point.topleft.down.to.point.bottomright.curvepath"),
            ("\(trip.lifetime.camerasInLimit)", "камер в лимите", "checkmark.shield"),
            ("\(trip.lifetime.bestStreak)", "лучшая серия", "flame"),
        ]
        return VStack(spacing: 12) {
            // Две на две, а не четыре в ряд. Четыре колонки на 390 pt дают по
            // 87 pt: узбекские подписи там переносились, а «2 590 км» просто
            // обрезалось троеточием. ViewThatFits тут не помогает — любой
            // maxWidth: .infinity внутри кандидата делает его «влезающим»
            // всегда, и мерить оказывается нечего. Сетка 2×2 честно даёт
            // каждому числу половину ширины и выглядит одинаково на обоих
            // языках; цена — сорок точек высоты.
            VStack(spacing: 14) {
                HStack(spacing: 0) {
                    StatStripCell(value: cells[0].0, label: cells[0].1, icon: cells[0].2)
                    StatStripDivider()
                    StatStripCell(value: cells[1].0, label: cells[1].1, icon: cells[1].2)
                }
                HStack(spacing: 0) {
                    StatStripCell(value: cells[2].0, label: cells[2].1, icon: cells[2].2)
                    StatStripDivider()
                    StatStripCell(value: cells[3].0, label: cells[3].1, icon: cells[3].2)
                }
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

    // MARK: - Вклад в общую карту

    /// «Ваши отметки». Единственное место, где автору возвращается результат
    /// его тапов: сколько поставил и сколько из них подтвердили другие
    /// водители. Без этой строки краудсорс односторонний — человек отдаёт
    /// сигнал и никогда не узнаёт, дошёл ли он.
    ///
    /// Ничего не отмечал — строки нет вовсе: нулевой счётчик читается как
    /// упрёк, а звать в краудсорс должна кнопка на карте, а не Итоги.
    @ViewBuilder private var contributionRow: some View {
        let mine = env.mobile.mineSummary()
        if mine.total > 0 {
            HStack(spacing: 12) {
                Image(systemName: "person.2.wave.2.fill")
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 34, height: 34)
                    .background(Theme.accent.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ваши отметки за 30 дней")
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textSecondary)
                    Text(mine.confirmed > 0
                         ? String(format: String(localized: "%lld · подтвердили другие: %lld"),
                                  mine.total, mine.confirmed)
                         : String(format: String(localized: "%lld · ждут подтверждения"),
                                  mine.total))
                        .font(.rounded(15, .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                }
                Spacer(minLength: 0)
                if env.mobile.pendingCount > 0 {
                    // Честно про очередь: иначе «отправлю позже» звучит один
                    // раз в поездке и больше нигде не подтверждается.
                    Text(String(format: String(localized: "%lld ждёт связи"),
                                env.mobile.pendingCount))
                        .font(.rounded(11, .semibold))
                        .foregroundStyle(Theme.warning)
                }
            }
            .statCard()
            .accessibilityElement(children: .combine)
        }
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
                    // Подпись и название — в столбик: на узбекском «Eng yaqin
                    // maqsad» и «Ketma-ket 5 toza» вставали вплотную и читались
                    // как одна слипшаяся фраза.
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Ближайшая цель")
                            .font(.rounded(11, .medium))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                        Text(badge.title)
                            .font(.rounded(13, .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
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
        // Даты, а не одно слово: «Неделя» на картинке через месяц не значит
        // ничего, «3–9 августа» остаётся понятным всегда.
        let periodTitle = period.rangeTitle(containing: anchor)
        let tracks = mapData.tracks
        Task {
            let passes = TripHistory.records(env.trip.history, period: period,
                                             anchor: anchor).flatMap(\.passed)
            let map = await TripMapSnapshot.render(
                track: tracks.flatMap { $0 }, passes: passes,
                size: CGSize(width: 1032, height: 420))
            shareSubject = ShareSubjectBox(
                subject: .period(summary, title: periodTitle, map: map))
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
