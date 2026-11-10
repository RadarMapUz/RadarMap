//
//  TripStatsSheet+Blocks.swift
//  RadarMap
//
//  Главный лист «Итогов» — вариант A аудита 05.11 «Неделя одним взглядом»,
//  порядок плана 78: карточка-ответ, «Что сделать», дорога на работу,
//  поездки окна, «Где теряете баллы», цель недели, «Ещё за неделю» (числа
//  того же окна) и «Не только эта неделя» (у каждой строки своё окно).
//  Блок с выключенным своим переключателем не показывается. Правила:
//    * одно число — одно место: сумма штрафов периода — только в строке денег
//      карточки-ответа, камера-лидер — только в «Сделать», обслуживание —
//      только строкой «Машина»;
//    * пустое не показывается: нет дел — нет «Сделать», нет пробок — нет строки;
//    * значки — из словаря Icon, в нейтральной плашке, цвет — только по смыслу.
//  Все цифры уже посчитаны (ItogiScreen, модели) — здесь только разметка.
//

import SwiftUI

extension TripStatsSheet {

    // MARK: - 1. Карточка-ответ

    /// Рейтинг «из 100» и за что сняли — тап открывает разбор; ниже факты,
    /// неделя столбиками и «Могут прийти» — тап открывает «Штрафы».
    func answerCard(itogi: ItogiScreen) -> some View {
        ItogiAnswerCard(itogi: itogi, period: period,
                        onRating: { showRatingInfo = true },
                        onFines: {
                            finesRequest = FinesRequest(window: .period(period, anchor), tab: .possible,
                                                        periodRisk: itogi.summary.fineRisk)
                        },
                        onOpenDay: { path.append(.day($0)) })
    }

    // MARK: - 2. Что сделать

    @ViewBuilder
    func todoSection(_ itogi: ItogiScreen) -> some View {
        let items = todoItems(itogi)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                ItogiGroupTitle(title: String(localized: "Что сделать"))
                ItogiRowGroup(items: items)
            }
        }
    }

    /// До трёх дел по важности: камера, где теряются деньги и баллы; пришедший
    /// штраф к оплате; старые проезды, по которым не отмечено, пришёл ли штраф.
    func todoItems(_ itogi: ItogiScreen) -> [ItogiRowItem] {
        var items: [ItogiRowItem] = []
        if let action = itogi.action {
            items.append(ItogiRowItem(
                id: "action", symbol: Icon.cameras, tint: Theme.Icon.camera,
                title: actionTitle(action),
                caption: actionCaption(action, periodRisk: itogi.summary.fineRisk),
                action: { openMap(focus: mapData.markers.first { $0.location == action.location }) },
                accessibilityHint: String(localized: "Показать камеру на карте")))
        }
        let dues = FineLedger.dues(env.fines.fines, now: Date())
        if dues.toPay > 0 || dues.overdue > 0 {
            items.append(ItogiRowItem(
                id: "toPay", symbol: Icon.fines, tint: Theme.danger,
                title: dues.toPay > 0
                    ? String(format: String(localized: "К оплате %@"), FineFormat.money(dues.toPay))
                    : String(localized: "Штраф к оплате"),
                caption: duesCaption(dues),
                action: { finesRequest = FinesRequest(tab: .received) }))
        }
        if itogi.pendingCount > 0, let oldest = itogi.pendingOldest {
            // Вопрос, а не счётчик (аудит 05.11): «Ждут ответа: 3» не говорило,
            // чего ждут и зачем отвечать. Окно — месяц старейшего проезда, и
            // экран «Штрафов» подписывает его крупно.
            items.append(ItogiRowItem(
                id: "pending", symbol: Icon.fines,
                title: Self.pendingQuestion(itogi.pendingCount),
                caption: String(localized: "Отметьте — сумма «могут прийти» станет точной"),
                action: {
                    finesRequest = FinesRequest(window: .period(.month, oldest), tab: .possible)
                }))
        }
        return items
    }

    /// «Пришёл ли старый штраф?» / «Пришли ли 3 старых штрафа?».
    static func pendingQuestion(_ count: Int) -> String {
        switch PluralRu.form(count) {
        case .one where count == 1: return String(localized: "Пришёл ли старый штраф?")
        case .one:  return String(format: String(localized: "Пришёл ли %lld старый штраф?"), count)
        case .few:  return String(format: String(localized: "Пришли ли %lld старых штрафа?"), count)
        case .many: return String(format: String(localized: "Пришли ли %lld старых штрафов?"), count)
        }
    }

    /// «Держите 60 у «Юнусабад»» — заголовок дела.
    /// Где сняли больше всего: полоска — доля самой дорогой камеры.
    @ViewBuilder
    func lossSection(_ itogi: ItogiScreen) -> some View {
        if !itogi.losses.isEmpty {
            let peak = max(itogi.losses.map(\.points).max() ?? 1, 0.1)
            VStack(alignment: .leading, spacing: 14) {
                ItogiGroupTitle(title: String(localized: "Где теряете баллы"))
                Button { showRatingInfo = true } label: {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(itogi.losses) { loss in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(ItogiCalendar.shortPlace(loss.location))
                                    .font(.rounded(15, .semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(2)
                                GeometryReader { geo in
                                    Capsule()
                                        .fill(Theme.Stats.commute)
                                        .frame(width: max(8, geo.size.width * loss.points / peak), height: 6)
                                }
                                .frame(height: 6)
                                Text(String(format: String(localized: "%1$@ баллов · %2$@"),
                                            "−\(max(1, Int(loss.points.rounded())))", ItogiWords.times(loss.times)))
                                    .font(.rounded(12))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle(.card))
                .statCard(padding: 0)
            }
        }
    }

    func actionTitle(_ hint: ActionHint) -> String {
        hint.limitKmh.map {
            String(format: String(localized: "Держите %1$lld у «%2$@»"), $0, ItogiCalendar.shortPlace(hint.location))
        } ?? String(format: String(localized: "Сбавьте у «%@»"), ItogiCalendar.shortPlace(hint.location))
    }

    /// «2 из 3 проездов выше лимита · ≈ 1,1 млн сум» — без суммы, если это
    /// вся сумма «Могут прийти» над делом (та же цифра второй раз подряд).
    func actionCaption(_ hint: ActionHint, periodRisk: Double) -> String {
        var text = String(format: String(localized: "%1$lld из %2$lld %3$@ выше лимита"),
                          hint.over, hint.passes, ItogiWords.passesGenitive(hint.passes))
        if hint.fine > 0, abs(hint.fine - periodRisk) >= 1 {
            text += " · ≈\u{00A0}" + Formatting.unbreakable(Formatting.money(hint.fine))
        }
        return text
    }

    private func duesCaption(_ dues: FineLedger.Dues) -> String {
        if dues.overdue > 0 {
            return String(format: String(localized: "Срок оплаты прошёл: %lld"), dues.overdue)
        }
        if let next = dues.nextDeadline {
            return String(format: String(localized: "Ближайший срок — %@"), FineFormat.day(next))
        }
        return String(format: String(localized: "Не оплачено: %lld"), dues.unpaid)
    }

    // MARK: - Дорога на работу

    /// Дорога на работу и домой — окно «последняя поездка», на первом экране
    /// (план 78). Опоздание — не красным: красный здесь — штраф и камера.
    /// Выключено «Время дороги на работу» — блока нет.
    @ViewBuilder
    func commuteSection() -> some View {
        let items = commuteItems()
        if !items.isEmpty {
            ItogiRowGroup(items: items)
        }
    }

    func commuteItems() -> [ItogiRowItem] {
        guard env.settings.commuteLearning else { return [] }
        return env.commute.map { commute in
            // Та же фраза, что в шапке листа: разброс, показанные минуты.
            let delay = commute.usual != nil ? CommuteCard.verdictPhrase(commute) : nil
            return ItogiRowItem(
                id: "commute-\(commute.direction.rawValue)", symbol: commute.direction.symbol,
                title: commute.direction.title,
                caption: [String(localized: "последняя поездка"), delay ?? CommuteCard.dayLine(commute.last.departure)]
                    .joined(separator: " · "),
                value: Formatting.duration(commute.last.duration),
                action: { commuteDetail = commute })
        }
    }

    // MARK: - 3. Поездки окна

    /// Три последние поездки окна строками и вход на страницу «Поездки»: до
    /// 05.11 поездки прятались строкой в списке разделов, и чтобы увидеть
    /// вчерашнюю, нужно было знать, где она.
    @ViewBuilder
    func recentTrips(_ itogi: ItogiScreen) -> some View {
        let all = itogi.trips
        if !all.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                ItogiGroupTitle(title: Self.tripsTitle(period))
                VStack(spacing: 0) {
                    ForEach(Array(all.prefix(AppConfig.itogiRecentTrips).enumerated()), id: \.element.id) { index, record in
                        if index > 0 {
                            Divider().overlay(Theme.stroke).padding(.leading, 70)
                        }
                        Button {
                            path.append(.trip(record.id))
                        } label: {
                            TripListRow(record: record, title: Formatting.tripTitle(record.startedAt))
                        }
                        .buttonStyle(PressableStyle(.row))
                        .accessibilityElement(children: .combine)
                        .accessibilityHint(Text("Открыть подробности"))
                    }
                    Divider().overlay(Theme.stroke)
                    Button {
                        path.append(.trips)
                    } label: {
                        HStack(spacing: 6) {
                            Text(String(format: String(localized: "Все %1$lld %2$@, карта и календарь"),
                                        all.count, Formatting.tripsLabel(all.count)))
                                .font(.rounded(15, .semibold))
                                .foregroundStyle(Theme.accent)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.rounded(13, .semibold))
                                .foregroundStyle(Theme.accent)
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: Theme.controlSize)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle(.row))
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
                .statCard(padding: 0, radius: Theme.cornerMedium)
            }
        }
    }

    static func tripsTitle(_ period: StatsPeriod) -> String {
        switch period {
        case .day:   return String(localized: "Поездки дня")
        case .week:  return String(localized: "Поездки недели")
        case .month: return String(localized: "Поездки месяца")
        }
    }

    // MARK: - 4. Ещё об окне

    /// Пробки, скорость вне камер и расходы — числа ТОГО ЖЕ окна, поэтому
    /// своей группой под заголовком окна, а не вперемешку с «за 30 дней».
    @ViewBuilder
    func windowSection(_ itogi: ItogiScreen) -> some View {
        let items = windowItems(itogi)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                ItogiGroupTitle(title: Self.windowTitle(period))
                ItogiRowGroup(items: items)
            }
        }
    }

    static func windowTitle(_ period: StatsPeriod) -> String {
        switch period {
        case .day:   return String(localized: "Ещё за день")
        case .week:  return String(localized: "Ещё за неделю")
        case .month: return String(localized: "Ещё за месяц")
        }
    }

    func windowItems(_ itogi: ItogiScreen) -> [ItogiRowItem] {
        let summary = itogi.summary
        guard !summary.isEmpty else { return [] }
        var items: [ItogiRowItem] = []
        // Две строки вместо «Пробки и лимит» с подписью «в пробках · выше
        // лимита вне камер: 4 % пути» (аудит): у каждой своё число.
        if let jam = summary.jamSeconds, jam >= AppConfig.jamMinPeriodSeconds {
            items.append(ItogiRowItem(
                id: "jams", symbol: Icon.trafficLayer,
                title: String(localized: "Пробки"),
                caption: String(localized: "где и когда стояли"),
                value: Formatting.duration(jam),
                action: { roadHabit = payload(.jams, itogi) }))
        }
        if let share = summary.overLimitShare, env.settings.speedLimitsEnabled {
            items.append(ItogiRowItem(
                id: "overLimit", symbol: Icon.overLimit,
                title: String(localized: "Скорость вне камер"),
                caption: summary.overLimitMeters < 1
                    ? String(localized: "весь путь с известным лимитом — не выше")
                    : String(format: String(localized: "%@ пути выше лимита"), Self.percentText(share)),
                value: Self.percentText(share),
                action: { roadHabit = payload(.overLimit, itogi) }))
        }
        if env.showsCarLog(.expenses), let expenses = expensesRow(summary) {
            items.append(expenses)
        }
        return items
    }

    // MARK: - 5. Не только это окно

    @ViewBuilder
    func otherWindows(trip: TripStats) -> some View {
        let items = otherItems(trip: trip)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                ItogiGroupTitle(title: Self.otherTitle(period))
                ItogiRowGroup(items: items)
            }
        }
    }

    static func otherTitle(_ period: StatsPeriod) -> String {
        switch period {
        case .day:   return String(localized: "Не только этот день")
        case .week:  return String(localized: "Не только эта неделя")
        case .month: return String(localized: "Не только этот месяц")
        }
    }

    /// Строки других окон — у каждой окно подписано (правило 14): «последняя
    /// поездка», «за 30 дней», «за всё время».
    func otherItems(trip: TripStats) -> [ItogiRowItem] {
        var items: [ItogiRowItem] = []

        // Новые камеры на своих дорогах — новость, пока не нажали «Понятно».
        let news = env.roadMemory.news
        if !news.isEmpty {
            items.append(ItogiRowItem(
                id: "news", symbol: Icon.cameras, tint: Theme.Icon.camera,
                title: String(localized: "Новые камеры на ваших дорогах"),
                caption: String(localized: "с последним обновлением базы"),
                value: "+\(news.count)",
                action: { path.append(.cameraNews) }))
        }

        // Обслуживание — только когда что-то скоро или пора (18.2).
        let maintenance = env.showsCarLog(.maintenance) ? env.maintenance.attention() : []
        if !maintenance.isEmpty {
            items.append(ItogiRowItem(
                id: "car", symbol: Icon.maintenance,
                title: String(localized: "Обслуживание"),
                caption: maintenance.first.map { $0.kind.title },
                value: String(format: String(localized: "пора: %lld"), maintenance.count),
                valueTint: Theme.danger,
                action: { path.append(.maintenance) }))
        }

        // Смены таксиста (12б.9) — из рабочих рейсов.
        let shifts = env.showsCarLog(.shifts) ? WorkShiftsCard.shown(env.workShifts) : []
        if !shifts.isEmpty {
            items.append(ItogiRowItem(
                id: "shifts", symbol: Icon.shifts,
                title: String(localized: "Смены"),
                caption: String(localized: "рейсы, превышения и расходы по сменам"),
                value: "\(shifts.count)",
                action: { path.append(.shifts) }))
        }

        // Свои отметки радаров (31E) — сообщает, никуда не ведёт.
        let _ = env.mobile.impactRevision
        let impact = env.mobile.impactSummary()
        if impact.reports > 0 {
            items.append(ItogiRowItem(
                id: "community", symbol: Icon.community,
                title: String(localized: "Ваши отметки радаров"),
                caption: impact.confirmations > 0
                    ? String(format: String(localized: "за 30 дней · подтвердили %@"),
                             ItogiWords.times(impact.confirmations))
                    : String(localized: "за 30 дней · пока без подтверждений"),
                value: "\(impact.reports)"))
        }

        // Пожизненное — отдельным окном (правило 14). Архив — только отсюда.
        if !trip.lifetime.isEmpty, trip.isLifetimeTrusted {
            items.append(ItogiRowItem(
                id: "lifetime", symbol: Icon.lifetime,
                title: String(localized: "За всё время"),
                caption: String(localized: "километры, достижения, архив"),
                value: Formatting.distance(trip.lifetime.distanceMeters),
                action: { path.append(.lifetime) }))
        }
        return items
    }
}
