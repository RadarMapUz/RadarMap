//
//  TripStatsSheet+Blocks.swift
//  RadarMap
//
//  «Итоги» — четыре блока (31E, владелец 26.10: «красиво, понятно и
//  профессионально»):
//    1. «Как я езжу» — герой и цель недели;
//    2. «Где теряю деньги и время» — штрафы, подсказка у конкретной камеры,
//       пробки, путь выше лимита, вход в «где теряете баллы»;
//    3. «Мои дороги» — дорога на работу, новые камеры, карта, поездки,
//       календарь месяца;
//    4. «Машина и работа» — расходы, обслуживание, смены, выгрузка;
//  внизу — «Вы и сообщество» и сворачиваемое «Подробнее».
//
//  Правила раскладки: пустой блок не показывается вовсе (никаких «нет
//  данных»); заголовок блока — подпись раздела, не крупнее заголовка
//  карточки; отступы по сетке 8 pt — 16 между любыми карточками, заголовок
//  на 8 ближе к своей первой карточке. Цвета — только токены Theme. Все
//  цифры уже посчитаны в ItogiScreen (вне main) — здесь только разметка.
//

import SwiftUI

extension TripStatsSheet {

    // MARK: - Каркас блока

    /// Блок: заголовок раздела и карточки. `visible == false` — блока нет.
    @ViewBuilder
    func block<Content: View>(_ title: String, visible: Bool,
                              @ViewBuilder content: () -> Content) -> some View {
        if visible {
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                    .font(.rounded(13, .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                    .padding(.bottom, -8)
                    .accessibilityAddTraits(.isHeader)
                content()
            }
        }
    }

    // MARK: - 1. Как я езжу

    @ViewBuilder
    func drivingBlock(trip: TripStats, itogi: ItogiScreen) -> some View {
        let summary = itogi.summary
        block(String(localized: "Как я езжу"), visible: !summary.isEmpty || itogi.goal != nil) {
            if !summary.isEmpty {
                heroCard(trip: trip, summary: summary)
            }
            if let goal = itogi.goal {
                WeeklyGoalCard(goal: goal)
                    .id("goal")
            }
        }
    }

    // MARK: - 2. Где теряю деньги и время

    @ViewBuilder
    func lossesBlock(_ itogi: ItogiScreen) -> some View {
        let summary = itogi.summary
        let judged = summary.cleanPasses + summary.overPasses > 0
        let hint = hintLine(itogi)
        let jams = (summary.jamSeconds ?? 0) >= AppConfig.jamMinPeriodSeconds
        let overLimit = summary.overLimitShare != nil
        let fines = !env.fines.fines.isEmpty || summary.overPasses > 0
        let points = (summary.rating ?? 100) < 100
        block(String(localized: "Где теряю деньги и время"),
              visible: !summary.isEmpty && (judged || hint != nil || jams || overLimit || fines || points)) {
            riskCard(summary: summary)
            if let hint {
                heroLine(symbol: hint.symbol, tint: hint.tint, text: hint.text)
                    .statCard()
            }
            pendingNudgeRow(itogi)
            receivedFinesRow(summary: summary)
            roadRows(itogi)
            if points {
                compactRow(symbol: "chart.line.downtrend.xyaxis", tint: Theme.warning,
                           title: String(localized: "Где теряете баллы"),
                           caption: summary.topOverLocation
                               ?? String(localized: "Из чего сложился рейтинг: поездки и камеры")) {
                    showRatingInfo = true
                }
            }
        }
    }

    /// Подсказка блока: действием у конкретной камеры (31E), а если
    /// превышений нет — вывод разбора («стали ездить чище», оговорка о лимитах).
    func hintLine(_ itogi: ItogiScreen) -> (symbol: String, tint: Color, text: String)? {
        if let action = itogi.action {
            return ("hand.raised.fill", Theme.warning, actionText(action))
        }
        if let insight = itogi.insights.first {
            return (insight.icon, Self.insightTint(insight.kind), insight.text)
        }
        return nil
    }

    // MARK: - 3. Мои дороги

    @ViewBuilder
    func roadsBlock(_ itogi: ItogiScreen, proxy: ScrollViewProxy) -> some View {
        let summary = itogi.summary
        let news = env.roadMemory.news
        block(String(localized: "Мои дороги"),
              visible: !summary.isEmpty || !env.commute.isEmpty || !news.isEmpty) {
            if !env.commute.isEmpty {
                commuteCards
                    .id("commute")
            }
            if !news.isEmpty {
                CameraNewsCard(items: news)
                    .id("cameraNews")
            }
            if !summary.isEmpty {
                mapCard
                    .id("map")
                tripsSection(all: itogi.trips, proxy: proxy)
                    .id("history")
                // Календарь месяца (6.1, 31E) — клетки дней со своими дорогами.
                if period == .month {
                    MonthCalendarCard(days: env.trip.days, anchor: anchor) { day in
                        withMotion(Motion.standard) {
                            period = .day
                            anchor = day
                        }
                    }
                    .id("calendar")
                }
            }
        }
    }

    // MARK: - 4. Машина и работа

    @ViewBuilder
    func carBlock(summary: PeriodSummary) -> some View {
        let fuel = fuelRowVisible(summary: summary)
        let maintenance = env.maintenance.attention()
        let shifts = WorkShiftsCard.shown(env.workShifts)
        block(String(localized: "Машина и работа"), visible: fuel || !maintenance.isEmpty || !shifts.isEmpty) {
            fuelRow(summary: summary)
            // Обслуживание (18.2) — только когда что-то скоро или пора.
            if !maintenance.isEmpty {
                NavigationLink {
                    MaintenancePage()
                } label: {
                    MaintenanceCard(states: maintenance)
                }
                .buttonStyle(PressableStyle())
                .accessibilityHint(Text("Открыть обслуживание"))
                .id("maintenance")
            }
            // Смены таксиста (12б.9) — из рабочих рейсов.
            if !shifts.isEmpty {
                WorkShiftsCard(shifts: shifts)
                    .id("shifts")
            }
            if !summary.isEmpty {
                exportRow(summary: summary)
            }
        }
    }

    /// «Выгрузить поездки» — одна строка, CSV или PDF на выбор (31E, п. 6).
    func exportRow(summary: PeriodSummary) -> some View {
        Menu {
            Button("Таблица CSV", systemImage: "tablecells") { export(.csv, summary: summary) }
            Button("Документ PDF", systemImage: "doc.richtext") { export(.pdf, summary: summary) }
        } label: {
            HStack(spacing: 12) {
                IconBadge(symbol: "square.and.arrow.up", tint: Theme.accent, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Выгрузить поездки периода")
                        .font(.rounded(14, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("CSV или PDF: служебные километры, отчёт по сменам")
                        .font(.rounded(11))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if exporting {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.rounded(15, .bold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .statCard(padding: 12, radius: Theme.cornerMedium)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(exporting)
    }

    // MARK: - Вы и сообщество

    @ViewBuilder
    func communityBlock(trip: TripStats) -> some View {
        // Ревизия — чтобы блок появился, когда сервер ответил (31E).
        let _ = env.mobile.impactRevision
        let reports = env.mobile.impactSummary().reports > 0
        let achievements = !trip.lifetime.isEmpty && trip.isLifetimeTrusted
        block(String(localized: "Вы и сообщество"), visible: reports || achievements) {
            contributionRow
            if achievements {
                achievementsSection(trip: trip)
            }
        }
    }

    // MARK: - Подробнее

    /// «За всё время», охват и подробные графики — сворачиваемыми строками,
    /// как раньше: их смотрят раз в месяц.
    @ViewBuilder
    func moreBlock(summary: PeriodSummary, trip: TripStats) -> some View {
        let lifetime = !trip.lifetime.isEmpty && trip.isLifetimeTrusted
        block(String(localized: "Подробнее"), visible: !summary.isEmpty || lifetime) {
            if !summary.isEmpty {
                periodDetails(summary: summary, trip: trip)
            }
            // Не перенесено (старт до разблокировки) — в памяти лишь вклад
            // процесса: не показывать его как «за всё время».
            if lifetime {
                lifetimeSection(trip: trip)
                    .id("lifetime")
            }
        }
    }
}
