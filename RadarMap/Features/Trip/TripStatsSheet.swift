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
//  (LifetimeStats) плюс отдельный экран «Архив поездок».
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
    @Environment(AppEnvironment.self) var env
    @Environment(\.dismiss) var dismiss
    /// Повторить поездку: маршрут к точке финиша записи из истории.
    var onRoute: ((CLLocationCoordinate2D, String) -> Void)? = nil

    @State var period: StatsPeriod = .week
    /// Какое именно окно показываем: любая дата внутри него. Стрелки листают
    /// якорь, а не «сдвигают окно на N дней» — периоды календарные.
    @State var anchor = Date()
    @State var selectedRecord: TripRecord?
    /// Каскадное появление секций при открытии (одноразовое).
    @State var appeared = false
    @State var shareSubject: ShareSubjectBox?
    /// «Очистить историю» стирает все поездки разом и безвозвратно — только
    /// после вопроса. Раньше хватало одного касания в меню «Ещё».
    @State var confirmsClear = false
    @State var showRatingInfo = false
    @State var showFinesInfo = false
    /// Расшифровка охвата предупреждений: что именно считается промахом.
    @State var showRecallInfo = false
    /// Экран «Возможные штрафы» со строками проездов и пометкой «не пришёл».
    @State var showFines = false
    /// «Штрафы» — пришедшие постановления, сроки, оплата (этап 17).
    @State var showReceivedFines = false
    @State var selectedBadge: Achievement?
    /// Вся сохранённая история отдельным экраном — вместо сегмента «Всё время»,
    /// который обещал показать всё, а показывал последние записи.
    @State var showAllTrips = false
    /// Список поездок показан целиком (иначе — первые statsTripsPreview).
    @State var tripsExpanded = false
    /// Раскрыты ли «Детали периода» (KPI, график по дням, часы риска).
    @State var detailsExpanded = false
    /// «За всё время» свёрнут по умолчанию: экран открывают ради текущего
    /// периода, а пожизненные цифры смотрят раз в месяц.
    @State var lifetimeExpanded = false
    /// «Это разные» по карточке склейки — прячем её сразу (Storage не observable).
    @State var mergeSuggestionHidden = false
    /// Полноэкранная карта проездов (item — чтобы передать фокус зоны риска).
    @State var mapPayload: PeriodMapPayload?
    /// Треки, маркеры и слой частоты — считаются на смену периода, а не в body.
    @State var mapData = PeriodMapData()
    /// Чьи это данные карты: ключ кэша картинки. Ставится вместе с mapData —
    /// иначе картинка нового периода нарисовалась бы по данным старого и
    /// легла бы в кэш под чужим ключом.
    @State var mapStamp = ""
    /// Поездка, «применённая» к карте тапом по списку (nil — весь период).
    @State var mapSelection: TripRecord?
    /// Скользящая пилюля фильтра периода.
    @Namespace var periodPill
    /// Открытая «Дорога на работу/домой».
    @State var commuteDetail: Commute.Summary?

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
    /// фоновый пересчёт ещё не вернулся (первое открытие, смена периода):
    /// иначе шапка показала бы новый период над цифрами старого.
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

                    // Обслуживание (18.2) — только когда что-то скоро или пора:
                    // это дело, а не статистика, поэтому выше периода.
                    let maintenance = env.maintenance.attention()
                    if !maintenance.isEmpty {
                        NavigationLink {
                            MaintenancePage()
                        } label: {
                            MaintenanceCard(states: maintenance)
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityHint(Text("Открыть обслуживание"))
                        .entrance(0, appeared)
                        .id("maintenance")
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
                        heroCard(trip: trip, summary: summary, insights: itogi.insights)
                            .entrance(1, appeared)
                        // Порядок (6.1): герой → деньги (с «Ждут ответа» сразу
                        // под ними) → карта → поездки → детали. Поездки выше
                        // деталей: их открывают чаще, чем графики.
                        VStack(spacing: 8) {
                            riskCard(summary: summary)
                            pendingNudgeRow(itogi)
                            receivedFinesRow(summary: summary)
                            fuelRow(summary: summary)
                        }
                        .entrance(2, appeared)
                        .id("risk")
                        mapCard
                            .entrance(3, appeared)
                            .id("map")
                        tripsSection(all: itogi.trips, proxy: proxy)
                            .entrance(3, appeared)
                            .id("history")
                        periodDetails(summary: summary, trip: trip)
                            .entrance(4, appeared)
                            .id("details")
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

                    // Вне секции периода — своё окно у каждого (6.1): дорога на
                    // работу (30 дней), свои отметки, всё время. Шапка периода
                    // над ними не висит — это уже не про выбранную неделю.
                    if !env.commute.isEmpty {
                        commuteCards
                            .entrance(5, appeared)
                            .id("commute")
                    }

                    // Смены таксиста (12б.9) — из рабочих рейсов; нет их — нет блока.
                    let shifts = WorkShiftsCard.shown(env.workShifts)
                    if !shifts.isEmpty {
                        WorkShiftsCard(shifts: shifts)
                            .entrance(5, appeared)
                            .id("shifts")
                    }

                    contributionRow
                        .entrance(5, appeared)

                    // «За всё время» — три блока в одном сворачивающемся, тем
                    // же приёмом, что «Детали периода». Экран Итогов открывают
                    // ради ТЕКУЩЕГО периода; пожизненные цифры, охват и
                    // достижения читают раз в месяц, а место занимали всегда.
                    // Не перенесено (старт до разблокировки) — в памяти лишь
                    // вклад процесса: не показывать его как «за всё время».
                    if !trip.lifetime.isEmpty, trip.isLifetimeTrusted {
                        lifetimeSection(trip: trip)
                            .entrance(5, appeared)
                            .id("lifetime")
                    }
                }
                .padding(20)
                #if DEBUG
                .onAppear {
                    // Скриншот-автоматизация: прокрутить к истории или календарю.
                    let args = ProcessInfo.processInfo.arguments
                    if args.contains("-scrollHistory") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withMotion { proxy.scrollTo("history", anchor: .top) }
                        }
                    }
                    if args.contains("-scrollCalendar") {
                        // Календарь живёт в «Деталях» (6.1) — раскрыть, потом
                        // прокрутить к ним.
                        period = .month
                        detailsExpanded = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withMotion { proxy.scrollTo("details", anchor: .top) }
                        }
                    }
                    // `-scrollTo risk|map|details|history|lifetime` — любой раздел.
                    if let index = args.firstIndex(of: "-scrollTo"), index + 1 < args.count {
                        let target = args[index + 1]
                        if args.contains("-expandAll") {
                            detailsExpanded = true
                            lifetimeExpanded = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            proxy.scrollTo(target, anchor: .top)
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
            .background(Theme.screenBackground)
            .navigationTitle("Итоги")
            .navigationBarTitleDisplayMode(.inline)
            // Тот же лист и то же удаление, что в Настройки → Поездка →
            // «История поездок»: с производным (дорога, смены, места, машина,
            // виджет) и списками «Удалится» / «Останется» (15.3, 15.6).
            .sheet(isPresented: $confirmsClear) { EraseHistorySheet() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
                if !trip.history.isEmpty {
                    // Справа, рядом с «Готово», — как в деталке поездки. Слева
                    // (cancellationAction) «Поделиться» стояло на месте кнопки
                    // отмены, и один и тот же жест на двух экранах жил в
                    // разных углах.
                    ToolbarItemGroup(placement: .primaryAction) {
                        Menu {
                            Button("Очистить историю", systemImage: "trash", role: .destructive) {
                                confirmsClear = true
                            }
                            // До чтения истории и переноса старых счётчиков
                            // очистка отклоняется (S9).
                            .disabled(!trip.isLoaded || !trip.isLifetimeTrusted)
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
            // В body это делать нельзя: пересчёт шёл бы на каждый кадр прокрутки.
            .task(id: MapDataKey(period: period, anchor: anchor, count: trip.history.count,
                                 latest: trip.history.first?.id)) {
                let window = period.interval(containing: anchor).start.timeIntervalSince1970
                let stamp = "\(period)|\(Int(window))|\(trip.history.count)|\(trip.history.first?.id ?? 0)"
                let data = await TripHistory.mapData(trip.history, period: period, anchor: anchor)
                mapData = data
                mapStamp = stamp
            }
            .onChange(of: period) {
                // Выбранная поездка могла не попасть в новый период; раскрытый
                // список — тоже атрибут конкретного окна.
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
                // Дневная воронка: какие экраны вообще открывают. Только имя
                // экрана и счётчик — ни времени, ни содержимого.
                env.usage.noteScreen("stats")
                // Понедельник утром текущая неделя пуста, и экран открывался
                // с «В этом периоде поездок не было» — у каждого, каждую
                // неделю. Открываем там, где поездки есть; стрелки периода
                // на месте, к пустой текущей неделе вернуться можно.
                if TripHistory.summary(days: env.trip.days, history: env.trip.history,
                                       period: period, anchor: anchor).isEmpty,
                   let nearest = nearestNonEmptyAnchor() {
                    anchor = nearest
                }
                #if DEBUG
                // Скриншот-автоматизация: открыть вложенные экраны (с паузой —
                // sheet поверх ещё анимирующегося sheet молча не показывается).
                let args = ProcessInfo.processInfo.arguments
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    if args.contains("-showMonth") { period = .month }
                    if args.contains("-openFirstTrip") { selectedRecord = env.trip.history.first }
                    if args.contains("-openLongestTrip") {
                        selectedRecord = env.trip.history.max { $0.distanceMeters < $1.distanceMeters }
                    }
                    if args.contains("-showRatingInfo") { showRatingInfo = true }
                    if args.contains("-showSavingsInfo") { showFinesInfo = true }
                    if args.contains("-showFines") { showFines = true }
                    if args.contains("-showReceivedFines") { showReceivedFines = true }
                    if args.contains("-showPeriodMap") { openMap(focus: nil) }
                    if args.contains("-showAllTrips") { showAllTrips = true }
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
            PeriodMapSheet(data: payload.data, focus: payload.focus,
                           periodTitle: period.rangeTitle(containing: anchor))
        }
        // Шиты получают ТУ ЖЕ сводку, что показала карточка: расшифровка
        // обязана объяснять именно то число, по которому тапнули.
        .sheet(isPresented: $showRatingInfo) {
            RatingDetailSheet(summary: current.summary,
                              period: period,
                              interval: period.interval(containing: anchor),
                              anchor: anchor)
        }
        .sheet(isPresented: $showFinesInfo) {
            // Один экран штрафов (6.9): вход через (i) раскрывает «Откуда сумма».
            FinesSheet(period: period, anchor: anchor, explainsFirst: true,
                       periodRisk: current.summary.fineRisk)
        }
        .sheet(isPresented: $showFines) {
            FinesSheet(period: period, anchor: anchor, periodRisk: current.summary.fineRisk)
        }
        .sheet(isPresented: $showReceivedFines) { FinesScreen() }
        .sheet(item: $selectedBadge) { badge in AchievementInfoSheet(badge: badge) }
        .sheet(item: $commuteDetail) { commute in
            CommuteDetailSheet(summary: commute)
                .presentationDetents([.large])
        }
        #if DEBUG
        // Скриншот-хук: `-showCommute` сразу открывает дорогу (первую по времени суток).
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-showCommute") else { return }
            await Task.pause(seconds: 0.8)
            commuteDetail = env.commute.first
        }
        #endif
        .sheet(isPresented: $showRecallInfo) {
            AlertRecallInfoSheet(tally: env.trip.alertRecall)
        }
        // Поездки открываются внутри своего стека «Всех поездок» (6.10).
        .sheet(isPresented: $showAllTrips) {
            AllTripsSheet(onRepeat: onRoute.map { route in
                { coord, name in dismiss(); route(coord, name) }
            })
        }
        .sheet(item: $shareSubject) { box in
            SharePreviewSheet(subject: box.subject)
        }
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
    @Environment(AppEnvironment.self) var env

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
                metric("\(trip.camerasPassed)", "проездов камер")
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
