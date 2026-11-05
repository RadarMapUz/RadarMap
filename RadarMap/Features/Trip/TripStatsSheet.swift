//
//  TripStatsSheet.swift
//  RadarMap
//
//  «Итоги» — вариант Г-A «Ответ и разделы» (34b, выбор владельца 28.10).
//  До 34 лист был лентой из 18 карточек на 7 экранов SE: сумма возможных
//  штрафов стояла в восьми местах, камера-лидер — в девяти, а на главный
//  вопрос «как я съездил и что с этим делать» отвечали три разных блока.
//
//  Теперь три слоя, и каждое число живёт в одном месте:
//    1. карточка-ответ — рейтинг, километры, уровень, сдвиг к прошлому и одна
//       строка денег (тап — «Штрафы» на вкладке «Могут прийти»);
//    2. «Сделать» — до трёх дел по важности: сбавить у камеры, оплатить
//       пришедший штраф, отметить, пришёл ли старый;
//    3. «Разделы» — строки с одним числом: новые камеры, дорога на работу и
//       домой, пробки и лимит, расходы, поездки, машина, смены, сообщество,
//       за всё время. Подробности — на страницах разделов (стек: «Назад»
//       возвращает сюда, а не на карту).
//
//  Периоды КАЛЕНДАРНЫЕ и листаются стрелками (anchor, StatsPeriod), шапка
//  с периодом липкая. Все цифры приходят готовыми из ItogiScreen (вне main)
//  и моделей — вьюха не считает (ARCHITECTURE.md: данные в модели).
//

import SwiftUI
import Charts
import MapKit
import CoreLocation

/// Куда проваливаться из «Итогов». Путь — идентификаторы: записи достаются
/// из истории в момент показа.
enum ItogiRoute: Hashable {
    case trips, lifetime, shifts, expenses, expensesJournal, expensesSettings, cameraNews, maintenance
    case trip(Double)
    case pass(trip: Double, pass: UUID)
    /// День из календаря месяца — уровнем ниже, а не подменой периода.
    case day(Date)
    /// DEBUG: сетка значков раздела (`-itogiIcons`); в релизе пусто.
    case iconGallery
}

struct TripStatsSheet: View {
    @Environment(AppEnvironment.self) var env
    @Environment(\.dismiss) var dismiss
    /// Повторить поездку: маршрут к точке финиша записи из истории.
    var onRoute: ((CLLocationCoordinate2D, String) -> Void)? = nil

    @State var period: StatsPeriod = .week
    /// Окно открылось не идущим, потому что в идущем пусто (понедельник утром) —
    /// над карточкой об этом строка (ItogiWindow.notice). Сбрасывает любое
    /// листание и смена периода.
    @State var autoShifted = false
    /// Какое именно окно показываем: любая дата внутри него. Стрелки листают
    /// якорь, а не «сдвигают окно на N дней» — периоды календарные.
    @State var anchor = Date()
    @State var path: [ItogiRoute] = []
    /// Каскадное появление при открытии (одноразовое).
    @State var appeared = false
    @State var shareSubject: ShareSubjectBox?
    /// «Очистить историю» стирает все поездки разом — только после вопроса.
    @State var confirmsClear = false
    @State var showRatingInfo = false
    /// Один экран «Штрафы» (Ш-A) — окно и вкладка задаются входом.
    @State var finesRequest: FinesRequest?
    @State var selectedBadge: Achievement?
    /// Вся сохранённая история отдельным экраном.
    @State var showAllTrips = false
    /// Список поездок показан целиком (иначе — первые statsTripsPreview).
    @State var tripsExpanded = false
    /// «Это разные» по карточке склейки — прячем её сразу (Storage не observable).
    @State var mergeSuggestionHidden = false
    /// Полноэкранная карта проездов (item — чтобы передать фокус камеры).
    @State var mapPayload: PeriodMapPayload?
    /// Треки, маркеры и слой частоты — считаются на смену периода, а не в body.
    @State var mapData = PeriodMapData()
    /// Чьи это данные карты: ключ кэша картинки (ставится вместе с mapData).
    @State var mapStamp = ""
    /// Поездка, «применённая» к карте тапом по списку (nil — весь период).
    @State var mapSelection: TripRecord?
    /// Скользящая пилюля фильтра периода.
    @Namespace var periodPill
    /// Открытая «Дорога на работу/домой».
    @State var commuteDetail: Commute.Summary?
    /// «Заправился» / «Зарядился» со страницы расходов (21.6).
    @State var journalRequest: JournalEntryRequest?
    /// «Пробки и лимит» (31E) — лист с вкладками.
    @State var roadHabit: RoadHabitPayload?
    /// Выгрузка периода (31E): готовые файлы для «Поделиться» и признак работы.
    @State var exportShare: ShareFilesPayload?
    @State var exporting = false
    @State var exportFailed = false

    /// Сводка, выводы, напоминание о штрафах и поездки периода — посчитанные
    /// вне main на смену периода или данных (ItogiScreen, 6.4).
    @State var screen: ItogiScreen?
    @State var screenKey: ScreenKey?

    struct ScreenKey: Equatable {
        let period: StatsPeriod
        let anchor: Date
        let revision: Int
    }

    var currentKey: ScreenKey {
        ScreenKey(period: period, anchor: anchor, revision: env.trip.dataRevision)
    }

    /// Готовый экран; синхронно — только в кадр, когда ключ уже сменился, а
    /// фоновый пересчёт ещё не вернулся: иначе шапка показала бы новый период
    /// над цифрами старого.
    var current: ItogiScreen {
        if let screen, screenKey == currentKey { return screen }
        return ItogiScreen.build(days: env.trip.days, history: env.trip.history,
                                 period: period, anchor: anchor, now: Date())
    }

    /// Ключ пересчёта данных карты: период и состав истории.
    struct MapDataKey: Equatable {
        let period: StatsPeriod
        let anchor: Date
        let count: Int
        let latest: Double?
    }

    var body: some View {
        let trip = env.trip
        let active = env.location.isTripActive
        let itogi = current
        let summary = itogi.summary

        NavigationStack(path: $path) {
            ScrollView {
                ScrollViewReader { proxy in
                LazyVStack(spacing: 16, pinnedViews: [.sectionHeaders]) {
                    // Живая поездка — вне периодов. Отдельная вью: она читает
                    // скорость (каждый тик GPS), а в body листа это пересчитывало
                    // бы сводку периода ежесекундно.
                    if active {
                        LiveTripCard()
                            .entrance(0, appeared)
                    }
                    // Пикер и стрелки — ЛИПКАЯ шапка: окно цифр видно всегда.
                    Section {
                        windowNotice
                        if summary.isEmpty {
                            // Поездок нет вообще или нет именно в этом периоде —
                            // это разные подсказки.
                            if trip.history.isEmpty {
                                if !active { emptyHint.entrance(1, appeared) }
                            } else {
                                emptyPeriodHint.entrance(1, appeared)
                            }
                        }
                        // «Сохранять поездки в iCloud?» (27.F) — вопрос, а не
                        // цифра: над ответом, один раз.
                        if !active, env.cloud.shouldOffer(storedTrips: trip.storedTripCount) {
                            CloudOfferCard()
                                .entrance(1, appeared)
                        }
                        if !summary.isEmpty {
                            answerCard(itogi: itogi)
                                .entrance(1, appeared)
                        }
                        if let goal = itogi.goal, showsGoal {
                            WeeklyGoalCard(goal: goal)
                                .entrance(2, appeared)
                                .id("goal")
                        }
                        todoSection(itogi)
                            .entrance(2, appeared)
                            .id("todo")
                        recentTrips(itogi)
                            .entrance(3, appeared)
                            .id("trips")
                        windowSection(itogi)
                            .entrance(3, appeared)
                            .id("sections")
                        otherWindows(trip: trip)
                            .entrance(3, appeared)
                            .id("other")
                    } header: {
                        VStack(spacing: 8) {
                            periodPicker
                            periodNavigator
                        }
                        .padding(.vertical, 8)
                        .background {
                            // Под шапкой проезжают карточки — свой фон и
                            // волосяная линия снизу, чтобы срез был намеренным.
                            Rectangle()
                                .fill(Theme.background)
                                .padding(.horizontal, -16)
                                .padding(.top, -16)
                                .overlay(alignment: .bottom) {
                                    Rectangle()
                                        .fill(Theme.stroke)
                                        .frame(height: 1)
                                }
                        }
                        .entrance(0, appeared)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                #if DEBUG
                .onAppear {
                    // `-scrollTo todo|sections` — снимки «сверху донизу».
                    let args = ProcessInfo.processInfo.arguments
                    if let index = args.firstIndex(of: "-scrollTo"), index + 1 < args.count {
                        let target = args[index + 1]
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            proxy.scrollTo(target, anchor: UnitPoint(x: 0.5, y: -0.2))
                        }
                    }
                }
                #endif
                }
            }
            // Жёсткий край прокрутки: карточки не просвечивают сквозь бар.
            .backport.scrollEdgeEffectStyle(.hard, for: .top)
            .background(Theme.background)
            .navigationTitle("Итоги")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ItogiRoute.self) { destination($0) }
            // Тот же лист и то же удаление, что в Настройки → Поездка →
            // «История поездок» (15.3, 15.6).
            .sheet(isPresented: $confirmsClear) { EraseHistorySheet() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
                if !trip.history.isEmpty {
                    ToolbarItemGroup(placement: .primaryAction) {
                        // «…» — действия над историей, а не цифры: выгрузка
                        // (была строкой в блоке «Машина и работа») и очистка.
                        Menu {
                            if !summary.isEmpty {
                                Button("Выгрузить период — CSV", systemImage: "tablecells") {
                                    export(.csv, summary: summary)
                                }
                                Button("Выгрузить период — PDF", systemImage: "doc.richtext") {
                                    export(.pdf, summary: summary)
                                }
                            }
                            Button("Очистить историю", systemImage: "trash", role: .destructive) {
                                confirmsClear = true
                            }
                            // До чтения истории и переноса старых счётчиков
                            // очистка отклоняется (S9).
                            .disabled(!trip.isLoaded || !trip.isLifetimeTrusted)
                        } label: {
                            if exporting { ProgressView() } else { Image(systemName: "ellipsis.circle") }
                        }
                        .accessibilityLabel(Text("Ещё"))
                        if !summary.isEmpty {
                            Button { share(summary: summary) } label: {
                                Image(systemName: Icon.export)
                            }
                            .accessibilityLabel(Text("Поделиться итогами"))
                        }
                    }
                }
            }
        }
        // Цифры экрана — один пересчёт вне main на смену периода/данных.
        .task(id: currentKey) {
            let key = currentKey
            let built = await ItogiScreen.screen(days: env.trip.days, history: env.trip.history,
                                                 period: key.period, anchor: key.anchor, now: Date())
            guard key == currentKey else { return }
            screen = built
            screenKey = key
        }
        // Треки и слой частоты — один пересчёт на смену периода/истории.
        .task(id: MapDataKey(period: period, anchor: anchor, count: trip.history.count,
                             latest: trip.history.first?.id)) {
            let window = period.interval(containing: anchor).start.timeIntervalSince1970
            let stamp = "\(period)|\(Int(window))|\(trip.history.count)|\(trip.history.first?.id ?? 0)"
            let data = await TripHistory.mapData(trip.history, period: period, anchor: anchor)
            mapData = data
            mapStamp = stamp
        }
        .onChange(of: period) {
            withMotion(Motion.standard) {
                clearMapSelection()
                tripsExpanded = false
            }
        }
        .onChange(of: anchor) {
            withMotion(Motion.standard) {
                clearMapSelection()
                tripsExpanded = false
            }
        }
        .onAppear {
            appeared = true
            // Дневная воронка: какие экраны вообще открывают. Только имя.
            env.usage.noteScreen("stats")
            // Понедельник утром текущая неделя пуста — открываем там, где
            // поездки есть; к пустой текущей неделе вернуться можно стрелкой.
            if let opening = ItogiWindow.openingAnchor(days: env.trip.days, period: period, now: Date()) {
                anchor = opening
                autoShifted = true
            }
            #if DEBUG
            debugOpen()
            #endif
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .sheet(item: $mapPayload) { payload in
            PeriodMapSheet(data: payload.data, focus: payload.focus,
                           periodTitle: period.rangeTitle(containing: anchor))
        }
        // Расшифровка получает ТУ ЖЕ сводку, что показала карточка-ответ.
        .sheet(isPresented: $showRatingInfo) {
            RatingDetailSheet(summary: current.summary,
                              period: period,
                              interval: period.interval(containing: anchor),
                              anchor: anchor)
        }
        .sheet(item: $finesRequest) { request in FinesScreen(request: request) }
        .sheet(item: $journalRequest) { request in
            JournalEntrySheet(request: request,
                              kinds: request.mode == .charge ? env.journalChargeKinds : env.journalFillKinds)
        }
        .sheet(item: $selectedBadge) { badge in AchievementInfoSheet(badge: badge) }
        .sheet(item: $commuteDetail) { commute in
            CommuteDetailSheet(summary: commute)
                .presentationDetents([.large])
        }
        // Поездки открываются внутри своего стека «Архива» (6.10).
        .sheet(isPresented: $showAllTrips) {
            AllTripsSheet(onRepeat: onRoute.map { route in
                { coord, name in dismiss(); route(coord, name) }
            })
        }
        .sheet(item: $shareSubject) { box in
            SharePreviewSheet(subject: box.subject)
        }
        .sheet(item: $roadHabit) { payload in RoadHabitSheet(payload: payload) }
        .sheet(item: $exportShare) { payload in
            ActivityFilesSheet(payload: payload)
                .presentationDetents([.medium, .large])
        }
        .alert("Не удалось выгрузить период", isPresented: $exportFailed) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text("В этом периоде нет сохранённых поездок или не хватило места. Попробуйте ещё раз.")
        }
        // Подтверждения своих отметок (31E) — с открытием «Итогов», не чаще
        // раза в полчаса (ReportImpact.isDue).
        .task { await env.mobile.refreshImpactIfDue() }
    }

    /// Цель недели — про ТЕКУЩУЮ неделю: на «Месяце» и на прошлых неделях она
    /// висела под чужим окном (П3 плана 34).
    var showsGoal: Bool {
        period == .week && period.interval(containing: anchor).contains(Date())
    }

    // MARK: - Страницы

    @ViewBuilder func destination(_ route: ItogiRoute) -> some View {
        switch route {
        case .trips: tripsPage
        case .lifetime: lifetimePage
        case .shifts: shiftsPage
        case .expenses: expensesPage
        case .expensesJournal: EnergyJournalPage()
        case .expensesSettings: EnergySettingsPage()
        case .cameraNews: CameraNewsPage(items: env.roadMemory.news)
        case .maintenance: MaintenancePage()
        case .day(let day): dayPage(day)
        case .trip(let id):
            if let record = env.trip.history.first(where: { $0.id == id }) {
                TripDetailContent(record: record,
                                  onRoute: onRoute.map { route in
                                      { coord, name in dismiss(); route(coord, name) }
                                  },
                                  onOpenPass: { path.append(.pass(trip: id, pass: $0.id)) })
                    .navigationTitle(Formatting.tripTitle(record.startedAt))
                    .navigationBarTitleDisplayMode(.inline)
            }
        case .iconGallery:
            #if DEBUG
            ItogiIconGallery()
                .navigationTitle(Text(verbatim: "Значки «Итогов»"))
                .navigationBarTitleDisplayMode(.inline)
            #else
            EmptyView()
            #endif
        case .pass(let tripID, let passID):
            if let record = env.trip.history.first(where: { $0.id == tripID }),
               let pass = record.passed.first(where: { $0.id == passID }) {
                PassDetailView(pass: pass, track: record.trackPoints, record: record,
                               days: env.trip.days, interval: period.interval(containing: anchor),
                               period: period)
            }
        }
    }

    #if DEBUG
    /// Скриншот-автоматизация: открыть вложенные экраны и страницы (с паузой —
    /// sheet поверх ещё анимирующегося sheet молча не показывается).
    /// `-itogiPage trips|lifetime|shifts|expenses|news|trip`.
    func debugOpen() {
        let args = ProcessInfo.processInfo.arguments
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            if args.contains("-showMonth") || args.contains("-scrollCalendar") { period = .month }
            if args.contains("-showDay") { period = .day }
            if args.contains("-openFirstTrip"), let first = env.trip.history.first {
                path = [.trips, .trip(first.id)]
            }
            if args.contains("-openLongestTrip"),
               let longest = env.trip.history.max(by: { $0.distanceMeters < $1.distanceMeters }) {
                path = [.trips, .trip(longest.id)]
            }
            if args.contains("-scrollHistory") || args.contains("-scrollCalendar") { path = [.trips] }
            if let index = args.firstIndex(of: "-itogiPage"), index + 1 < args.count {
                switch args[index + 1] {
                case "trips": path = [.trips]
                case "lifetime": path = [.lifetime]
                case "shifts": path = [.shifts]
                case "expenses": path = [.expenses]
                case "news": path = [.cameraNews]
                case "icons": path = [.iconGallery]
                default: break
                }
            }
            if args.contains("-showRatingInfo") { showRatingInfo = true }
            if args.contains("-showSavingsInfo") || args.contains("-showFines") {
                finesRequest = FinesRequest(window: .period(period, anchor), tab: .possible,
                                            periodRisk: current.summary.fineRisk)
            }
            if args.contains("-showReceivedFines") { finesRequest = FinesRequest(tab: .received) }
            if args.contains("-showPeriodMap") { openMap(focus: nil) }
            if args.contains("-showAllTrips") { showAllTrips = true }
            if args.contains("-showCommute") { commuteDetail = env.commute.first }
            if args.contains("-showRoads") { roadHabit = payload(.jams, current) }
            if args.contains("-shareStats") {
                share(summary: TripHistory.summary(days: env.trip.days, history: env.trip.history,
                                                  period: period, anchor: anchor))
            }
        }
    }
    #endif
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
    @Environment(AppEnvironment.self) var env

    var body: some View {
        let trip = env.trip
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Theme.quietFill)
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
                        .font(.numeral(26, .heavy).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                        // Скорость меняется на каждом фиксе: liveNumber, не
                        // numericText (CPU-размытие, правило 11.10).
                        .liveNumber()
                    Text("км/ч")
                        .font(.rounded(10, .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Divider().overlay(Theme.stroke)
            // Подписи — те же, что в «Деталях» периода (6.3): «проездов
            // камер», «средняя, км/ч». Цифры спокойные: красный «максимум» в
            // поездке без единого превышения читался как тревога — цветом в
            // Итогах говорит только состояние (как KPIStrip).
            HStack(spacing: 0) {
                metric(Formatting.distance(trip.distanceMeters), "пройдено")
                metric("\(trip.camerasPassed)", LocalizedStringKey(Formatting.passesLabel(trip.camerasPassed)))
                metric("\(Int(trip.maxSpeedKmh))", "максимум, км/ч")
                metric("\(Int(trip.averageSpeedKmh))", "средняя, км/ч")
            }
        }
        .statCard()
    }

    func metric(_ value: String, _ label: LocalizedStringKey) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.rounded(18, .heavy).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                .liveNumber()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            // Две строки, как у KPIStrip: «проездов камер» в одну строку на SE
            // ужималось до нечитаемого кегля.
            Text(label)
                .font(.rounded(10, .medium))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(height: 26, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
