//
//  TripStatsSheet+Pages.swift
//  RadarMap
//
//  Страницы разделов «Итогов» (34b, Г-A): сюда переехало всё, что раньше
//  висело на главном листе лентой. Страница — часть стека листа, «Назад»
//  возвращает к ответу. Шапка страницы — окно периода одной строкой: на
//  главном листе оно в липкой шапке, здесь его иначе не видно.
//
//    «Поездки»      — карта-снимок, по дням (график недели или календарь
//                     месяца — над списком), склейка, список со свайпом
//                     удаления, средние, часы риска; день календаря — уровнем
//                     ниже в том же стеке;
//    «За всё время» — пожизненные цифры, архив, ближайшая цель и достижения;
//    «Смены»        — рабочие рейсы таксиста;
//    «Новые камеры» — список и «Понятно».
//

import SwiftUI

extension TripStatsSheet {

    // MARK: - Поездки

    /// Страница окна: карта-снимок → по дням (календарь месяца или столбики
    /// недели — над списком, аудит 05.11) → список с удалением свайпом →
    /// средние и часы риска. Список — `List`: свайп удаления есть только у
    /// него, а прятать удаление в долгое нажатие значило не дать его вовсе.
    var tripsPage: some View {
        let itogi = current
        let summary = itogi.summary
        return ScrollViewReader { proxy in
            List {
                Section {
                    pageWindowLine
                        .itogiPlainRow()
                    mapCard
                        .id("map")
                        .itogiPlainRow()
                    // По дням — одно на окно: у месяца календарь (тап — день
                    // следующим уровнем этого же стека), у недели столбики.
                    if period == .month {
                        MonthCalendarCard(days: env.trip.days, anchor: anchor) { day in
                            path.append(.day(day))
                        }
                        .id("calendar")
                        .itogiPlainRow()
                    } else if let days = period.chartDays(containing: anchor) {
                        dailyChart(days: days, summary: summary)
                            .itogiPlainRow()
                    }
                    if let pair = mergeSuggestion {
                        mergeSuggestionCard(pair)
                            .itogiPlainRow()
                    }
                }
                tripRows(itogi.trips, proxy: proxy)
                Section {
                    if !summary.isEmpty {
                        KPIStrip(summary: summary, activeDaysText: activeDaysText(summary))
                            .itogiPlainRow()
                    }
                    RiskHoursCard(summary: summary)
                        .itogiPlainRow()
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
        }
        .background(Theme.background)
        .navigationTitle("Поездки")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Поездки по дням: секция на день, строка — карточкой, свайп влево —
    /// «Удалить» (полный свайп выключен: поездка не должна исчезать от
    /// неловкого жеста), долгое нажатие — карта, повтор, склейка.
    @ViewBuilder
    func tripRows(_ records: [TripRecord], proxy: ScrollViewProxy?) -> some View {
        ForEach(TripHistory.dayGroups(records.filter { !deletedTripIDs.contains($0.id) }), id: \.day) { group in
            Section {
                ForEach(group.records) { record in
                    Button {
                        path.append(.trip(record.id))
                    } label: {
                        TripListRow(record: record, title: Formatting.clock(record.startedAt),
                                    selected: mapSelection?.id == record.id)
                    }
                    .buttonStyle(PressableStyle(.row))
                    .accessibilityElement(children: .combine)
                    .accessibilityHint(Text("Открыть подробности"))
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Theme.surface)
                    .listRowSeparatorTint(Theme.stroke)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            deleteTrip(record)
                        } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                    }
                    .contextMenu { tripMenu(record, proxy: proxy) }
                }
            } header: {
                Text(Formatting.dayTitle(group.day))
                    .font(.rounded(12, .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .textCase(.uppercase)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    func tripMenu(_ record: TripRecord, proxy: ScrollViewProxy?) -> some View {
        if record.hasTrack, let proxy {
            Button {
                showOnMap(record, proxy: proxy)
            } label: {
                Label("Показать на карте", systemImage: "map")
            }
        }
        if let onRoute, let end = record.endCoordinate {
            Button {
                dismiss()
                onRoute(end, String(localized: "Как в прошлый раз"))
            } label: {
                Label("Повторить маршрут", systemImage: "arrow.triangle.turn.up.right.circle")
            }
        }
        if env.trip.canMergeWithPrevious(id: record.id) {
            Button {
                merge(next: record)
            } label: {
                Label("Объединить с предыдущей", systemImage: "arrow.triangle.merge")
            }
        }
        Button(role: .destructive) {
            deleteTrip(record)
        } label: {
            Label("Удалить запись", systemImage: "trash")
        }
    }

    func deleteTrip(_ record: TripRecord) {
        deletedTripIDs.insert(record.id)
        withMotion {
            if mapSelection?.id == record.id { clearMapSelection() }
            env.trip.deleteRecord(id: record.id)
        }
    }

    // MARK: - День

    /// День из календаря месяца — следующий уровень того же стека, а не
    /// подмена периода: «Назад» возвращает в месяц, где и нажали.
    func dayPage(_ day: Date) -> some View {
        let interval = StatsPeriod.day.interval(containing: day)
        let records = env.trip.history.filter { interval.contains($0.startedAt) }
        let summary = TripDayBook.summary(env.trip.days, in: interval)
        return List {
            Section {
                ItogiFactStrip(facts: [
                    .init(id: "km", value: Formatting.distance(summary.distance),
                          caption: String(localized: "пройдено")),
                    .init(id: "trips", value: "\(summary.trips)", caption: Formatting.tripsLabel(summary.trips)),
                    .init(id: "time", value: Formatting.duration(summary.movingDuration),
                          caption: String(localized: "за рулём")),
                ])
                .statCard()
                .itogiPlainRow()
                if records.isEmpty {
                    Text(summary.isEmpty ? String(localized: "В этот день поездок не было")
                                         : String(localized: "Полные записи за этот день уже удалены — остались дневные итоги."))
                        .font(.rounded(13))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .itogiPlainRow()
                }
            }
            tripRows(records, proxy: nil)
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .background(Theme.background)
        .navigationTitle(Formatting.dayTitle(day))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// «26 окт.–1 нояб.» — окно, за которое страница.
    var pageWindowLine: some View {
        Text(period.rangeTitle(containing: anchor))
            .font(.rounded(13))
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    // MARK: - За всё время

    var lifetimePage: some View {
        let trip = env.trip
        return ScrollView {
            VStack(spacing: 16) {
                lifetimeStrip(trip: trip)
                ItogiRowGroup(items: [
                    ItogiRowItem(id: "archive", symbol: Icon.archive,
                                 title: String(localized: "Архив поездок"),
                                 caption: String(localized: "Все сохранённые поездки по месяцам"),
                                 value: "\(trip.storedTripCount)",
                                 action: { showAllTrips = true }),
                ])
                achievementsSection(trip: trip)
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle("За всё время")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Смены

    var shiftsPage: some View {
        ScrollView {
            VStack(spacing: 16) {
                WorkShiftsCard(shifts: WorkShiftsCard.shown(env.workShifts))
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle("Смены")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// «Новые камеры на ваших дорогах» (31E, 12.2) — страница раздела: список и
/// «Понятно». Раньше — карточка во всю ширину с широкой кнопкой, самым
/// крупным элементом своего блока.
struct CameraNewsPage: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let items: [CameraNews.Item]

    @State private var cameras: [Camera] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Появились с обновлением базы там, где вы ездили за два месяца")
                    .font(.rounded(13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                if !cameras.isEmpty {
                    ItogiRowGroup(items: cameras.prefix(AppConfig.cameraNewsRows).map { camera in
                        ItogiRowItem(id: "\(camera.id)", symbol: Icon.cameras, tint: Theme.Icon.camera,
                                     title: camera.displayTitle, caption: camera.kind.displayName)
                    })
                }
                SecondaryButton(title: "Понятно") {
                    withMotion(Motion.standard) { env.roadMemory.dismissNews() }
                    dismiss()
                }
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle(String(localized: "Новые камеры: \(items.count)"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: items.map(\.id)) {
            let ids = Set(items.map(\.id))
            let order = Dictionary(items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
            cameras = env.cameras.cameras.filter { ids.contains($0.id) }
                .sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
        }
    }
}

/// Строка `List` без своей подложки и разделителя: карточки страниц «Итогов»
/// рисуют фон сами (statCard), список даёт только прокрутку и свайп.
extension View {
    func itogiPlainRow() -> some View {
        self.listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
