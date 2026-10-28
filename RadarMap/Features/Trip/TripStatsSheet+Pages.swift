//
//  TripStatsSheet+Pages.swift
//  RadarMap
//
//  Страницы разделов «Итогов» (34b, Г-A): сюда переехало всё, что раньше
//  висело на главном листе лентой. Страница — часть стека листа, «Назад»
//  возвращает к ответу. Шапка страницы — окно периода одной строкой: на
//  главном листе оно в липкой шапке, здесь его иначе не видно.
//
//    «Поездки»      — карта-снимок, склейка, список, по дням (график недели
//                     или календарь месяца — одно на окно), средние, часы риска;
//    «За всё время» — пожизненные цифры, архив, ближайшая цель и достижения;
//    «Смены»        — рабочие рейсы таксиста;
//    «Новые камеры» — список и «Понятно».
//

import SwiftUI

extension TripStatsSheet {

    // MARK: - Поездки

    var tripsPage: some View {
        let itogi = current
        let summary = itogi.summary
        return ScrollView {
            ScrollViewReader { proxy in
                LazyVStack(spacing: 16) {
                    pageWindowLine
                    mapCard
                        .id("map")
                    tripsSection(all: itogi.trips, proxy: proxy)
                        .id("history")
                    // По дням — одно на окно (6.27 + 10.6 плана 34): у месяца —
                    // календарь (тап — день подробно), у недели — столбики.
                    if period == .month {
                        MonthCalendarCard(days: env.trip.days, anchor: anchor) { day in
                            withMotion(Motion.standard) {
                                period = .day
                                anchor = day
                                path = []
                            }
                        }
                        .id("calendar")
                    } else if let days = period.chartDays(containing: anchor) {
                        dailyChart(days: days, summary: summary)
                    }
                    if !summary.isEmpty {
                        KPIStrip(summary: summary, activeDaysText: activeDaysText(summary))
                    }
                    RiskHoursCard(summary: summary)
                }
                .padding(16)
            }
        }
        .background(Theme.background)
        .navigationTitle("Поездки")
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
