//
//  TripStatsSheet+Lifetime.swift
//  RadarMap
//
//  Итоги: «за всё время», вклад в рейтинг, достижения и ближайшая цель, отправка карточки.
//

import SwiftUI
import Charts
import MapKit
import CoreLocation

extension TripStatsSheet {

    // MARK: - Детали периода (свёрнуты по умолчанию)

    /// KPI-плитки, график по дням и «Когда рискуете» — под одной раскрывашкой.
    /// Главную историю экран рассказывает выше (рейтинг → выводы → деньги →
    /// карта); эти три блока — справка для любопытных, и развёрнутые всегда они
    /// уводили список поездок за два экрана прокрутки. Свёрнутые они ещё и
    /// бесплатны: dailyKm не считается, пока раскрывашку не открыли.
    /// Пожизненный хвост Итогов одним сворачиваемым блоком.
    func lifetimeSection(trip: TripStats) -> some View {
        VStack(spacing: 16) {
            Button {
                withMotion(Motion.standard) { lifetimeExpanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    IconBadge(symbol: "infinity", tint: Theme.accent, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("За всё время")
                            .font(.rounded(15, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Пожизненные цифры и охват предупреждений")
                            .font(.rounded(12))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.rounded(15, .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(lifetimeExpanded ? 180 : 0))
                }
                .statCard(padding: 14, radius: Theme.cornerMedium)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(lifetimeExpanded
                                     ? String(localized: "Скрыть цифры за всё время")
                                     : String(localized: "Показать цифры за всё время")))
            if lifetimeExpanded {
                lifetimeStrip(trip: trip)
                AlertRecallCard(tally: trip.alertRecall) { showRecallInfo = true }
                // Достижения — в «Вы и сообщество» (31E).
            }
        }
    }

    /// Пожизненные цифры — единственная честная правда «за всё время»:
    /// история чистится, а эти счётчики нет. Отсюда же вход во все поездки.
    func lifetimeStrip(trip: TripStats) -> some View {
        let cells: [(String, LocalizedStringKey, String, Color)] = [
            ("\(trip.lifetime.trips)", LocalizedStringKey(Formatting.tripsLabel(trip.lifetime.trips)),
             "car.side.fill", Theme.Icon.distance),
            (Formatting.distance(trip.lifetime.distanceMeters), "пройдено",
             "point.topleft.down.to.point.bottomright.curvepath", Theme.Icon.distance),
            ("\(trip.lifetime.camerasInLimit)", "камер в лимите", "checkmark.shield.fill", Theme.Icon.rating),
            ("\(trip.lifetime.bestStreak)", "лучшая серия", "flame.fill", Theme.Icon.streak),
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
                    StatStripCell(value: cells[0].0, label: cells[0].1, icon: cells[0].2,
                                  tint: cells[0].3)
                    StatStripDivider()
                    StatStripCell(value: cells[1].0, label: cells[1].1, icon: cells[1].2,
                                  tint: cells[1].3)
                }
                HStack(spacing: 0) {
                    StatStripCell(value: cells[2].0, label: cells[2].1, icon: cells[2].2,
                                  tint: cells[2].3)
                    StatStripDivider()
                    StatStripCell(value: cells[3].0, label: cells[3].1, icon: cells[3].2,
                                  tint: cells[3].3)
                }
            }
            Button {
                showAllTrips = true
            } label: {
                HStack(spacing: 6) {
                    Text("Архив поездок")
                        .font(.rounded(15, .semibold))
                    Image(systemName: "chevron.right")
                        .font(.rounded(10, .bold))
                }
                .foregroundStyle(Theme.accent)
                // Строка 15 pt — около 20 pt в высоту; мишень — полные 44.
                .frame(maxWidth: .infinity, minHeight: Theme.controlSize)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
        }
        .statCard(padding: 14)
    }

    // MARK: - Вклад в общую карту

    /// «Ваши отметки». Единственное место, где автору возвращается результат
    /// его тапов: сколько поставил и сколько раз их подтвердили другие
    /// водители (31E: число подтверждений с сервера, ReportImpact). Без этой
    /// строки краудсорс односторонний — человек отдаёт сигнал и никогда не
    /// узнаёт, дошёл ли он.
    ///
    /// Окно — 30 дней и названо словами: столько живёт UUID отметок, старше
    /// сервер про нас не знает. «Подтверждений», а не «водителей»: один
    /// водитель мог подтвердить две ваши отметки.
    ///
    /// Ничего не отмечал — строки нет вовсе: нулевой счётчик читается как
    /// упрёк, а звать в краудсорс должна кнопка на карте, а не Итоги.
    @ViewBuilder var contributionRow: some View {
        // Ревизия — чтобы строка перерисовалась, когда сервер ответил.
        let _ = env.mobile.impactRevision
        let impact = env.mobile.impactSummary()
        if impact.reports > 0 {
            HStack(spacing: 12) {
                IconBadge(symbol: "person.2.wave.2.fill", tint: Theme.accent, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ваши отметки за 30 дней")
                        .font(.rounded(13))
                        .foregroundStyle(Theme.textSecondary)
                    Text(String(localized: "\(impact.reports) отметок"))
                        .font(.rounded(15, .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                    Text(impact.confirmations > 0
                         ? String(localized: "Их подтвердили другие водители: \(impact.confirmations) раз")
                         : String(localized: "Пока без подтверждений других водителей"))
                        .font(.rounded(13))
                        .foregroundStyle(impact.confirmations > 0 ? Theme.success : Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
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

    func achievementsSection(trip: TripStats) -> some View {
        // Без своего заголовка (31E): живёт в блоке «Вы и сообщество».
        VStack(alignment: .leading, spacing: 16) {
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
    func nextGoalRow(_ badge: Achievement) -> some View {
        Button {
            selectedBadge = badge
        } label: {
            HStack(spacing: 12) {
                IconBadge(symbol: badge.icon, tint: Theme.accent, size: 38)
                VStack(alignment: .leading, spacing: 5) {
                    // Подпись и название — в столбик: на узбекском «Eng yaqin
                    // maqsad» и «Ketma-ket 5 toza» вставали вплотную и читались
                    // как одна слипшаяся фраза.
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Ближайшая цель")
                            .font(.rounded(11, .medium))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text(badge.title)
                            .font(.rounded(15, .bold))
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
                                    .fill(Theme.accent)
                                    .frame(width: max(6, geometry.size.width * badge.fraction))
                            }
                        }
                        .clipShape(Capsule())
                }
                Text(badge.progressText)
                    .font(.rounded(15, .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .statCard(padding: 14, radius: Theme.cornerMedium)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Шеринг периода

    /// Рендерим карточку в момент тапа — данные всегда свежие, открытие не тормозим.
    func share(summary: PeriodSummary) {
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
}
