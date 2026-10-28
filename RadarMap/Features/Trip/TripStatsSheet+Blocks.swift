//
//  TripStatsSheet+Blocks.swift
//  RadarMap
//
//  Три слоя главного листа «Итогов» (34b, Г-A): карточка-ответ, «Сделать»,
//  «Разделы». Правила:
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

    /// Рейтинг, километры, уровень, сдвиг к прошлому — тап открывает разбор
    /// рейтинга; ниже одна строка денег — тап открывает «Штрафы».
    func answerCard(trip: TripStats, itogi: ItogiScreen) -> some View {
        let summary = itogi.summary
        return VStack(alignment: .leading, spacing: 0) {
            heroCard(trip: trip, summary: summary)
            if let money = moneyLine(summary) {
                Divider().overlay(Theme.stroke)
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    finesRequest = FinesRequest(window: .period(period, anchor), tab: .possible,
                                                periodRisk: summary.fineRisk)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: Icon.fines)
                            .font(.rounded(15, .semibold))
                            .foregroundStyle(money.tint)
                            .frame(width: 22)
                            .accessibilityHidden(true)
                        // Сумма и счётчик — двумя строками: одной строкой
                        // «· превышений: 1» переносилось с висящей точкой.
                        VStack(alignment: .leading, spacing: 2) {
                            Text(money.text)
                                .font(.rounded(15, .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(money.caption)
                                .font(.rounded(12))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(.rounded(13, .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(minHeight: Theme.controlSize)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint(Text("Открыть штрафы"))
            }
            // Вывод периода — когда дела у камеры нет («стали ездить чище»,
            // «у пройденных камер неизвестен лимит»): строкой ответа.
            if itogi.action == nil, let insight = itogi.insights.first {
                Divider().overlay(Theme.stroke)
                heroLine(symbol: insight.icon, tint: Self.insightTint(insight.kind), text: insight.text)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
        .statCard(padding: 0)
    }

    /// Строка денег: «Возможные штрафы ≈ 2,2 млн · превышений: 1» — оценка
    /// периода (то же число, что шапка «Штрафов» для этого окна). Без
    /// проездов с известным лимитом — строки нет.
    func moneyLine(_ summary: PeriodSummary) -> (text: String, caption: String, tint: Color)? {
        guard summary.cleanPasses + summary.overPasses > 0 else { return nil }
        let passes = String(format: String(localized: "проездов камер: %lld"), summary.cameras)
        if summary.overPasses > 0, summary.fineRisk > 0 {
            return (String(format: String(localized: "Возможные штрафы ≈ %@"),
                           Formatting.unbreakable(Formatting.money(summary.fineRisk))),
                    passes + " · " + String(format: String(localized: "с превышением: %lld"), summary.overPasses),
                    Theme.danger)
        }
        if summary.overPasses > 0 {
            // Все превышения уже отмечены «пришёл / не пришёл».
            return (String(localized: "Штрафы периода отмечены"),
                    passes + " · " + String(format: String(localized: "с превышением: %lld"), summary.overPasses),
                    Theme.textSecondary)
        }
        return (String(localized: "Штрафуемых превышений нет"), passes, Theme.success)
    }

    // MARK: - 2. Сделать

    @ViewBuilder
    func todoSection(_ itogi: ItogiScreen) -> some View {
        let items = todoItems(itogi)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                ItogiGroupTitle(title: String(localized: "Сделать"))
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
            items.append(ItogiRowItem(
                id: "pending", symbol: Icon.fines,
                title: String(format: String(localized: "Ждут ответа: %lld"), itogi.pendingCount),
                caption: String(localized: "Отметьте: штраф пришёл или нет"),
                action: {
                    finesRequest = FinesRequest(window: .period(.month, oldest), tab: .possible)
                }))
        }
        return items
    }

    /// «Держите 60 у «Юнусабад»» — заголовок дела.
    func actionTitle(_ hint: ActionHint) -> String {
        hint.limitKmh.map {
            String(format: String(localized: "Держите %1$lld у «%2$@»"), $0, hint.location)
        } ?? String(format: String(localized: "Сбавьте у «%@»"), hint.location)
    }

    /// «выше лимита — 2 из 3 · ≈ 1,1 млн сум» — без суммы, если это вся сумма
    /// строки денег над делом (34: та же цифра второй раз подряд).
    func actionCaption(_ hint: ActionHint, periodRisk: Double) -> String {
        var text = String(format: String(localized: "проезды выше лимита — %1$lld из %2$lld"), hint.over, hint.passes)
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

    // MARK: - 3. Разделы

    @ViewBuilder
    func sectionsList(_ itogi: ItogiScreen, trip: TripStats) -> some View {
        let items = sectionItems(itogi, trip: trip)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                ItogiGroupTitle(title: String(localized: "Разделы"))
                ItogiRowGroup(items: items)
            }
        }
    }

    func sectionItems(_ itogi: ItogiScreen, trip: TripStats) -> [ItogiRowItem] {
        let summary = itogi.summary
        var items: [ItogiRowItem] = []

        // Новые камеры на своих дорогах — новость, пока не нажали «Понятно».
        let news = env.roadMemory.news
        if !news.isEmpty {
            items.append(ItogiRowItem(
                id: "news", symbol: Icon.cameras, tint: Theme.Icon.camera,
                title: String(localized: "Новые камеры на ваших дорогах"),
                caption: String(localized: "Появились с обновлением базы"),
                value: "+\(news.count)",
                action: { path.append(.cameraNews) }))
        }

        // Дорога на работу и домой — по одной строке, порядок по времени суток.
        for commute in env.commute {
            items.append(ItogiRowItem(
                id: "commute-\(commute.direction.rawValue)", symbol: commute.direction.symbol,
                title: commute.direction.title,
                caption: commute.lastDelay.map(Formatting.delayPhrase)
                    ?? CommuteCard.dayLine(commute.last.departure),
                value: Formatting.duration(commute.last.duration),
                valueTint: (commute.lastDelay ?? 0) >= AppConfig.commuteNoticeableDelaySeconds
                    ? Theme.danger : Theme.textPrimary,
                action: { commuteDetail = commute }))
        }

        if !summary.isEmpty {
            // Пробки и путь выше лимита — один лист с двумя вкладками.
            let jam = (summary.jamSeconds ?? 0) >= AppConfig.jamMinPeriodSeconds ? summary.jamSeconds : nil
            if jam != nil || summary.overLimitShare != nil {
                var captionParts: [String] = []
                if jam != nil { captionParts.append(String(localized: "в пробках")) }
                if let share = summary.overLimitShare {
                    captionParts.append(summary.overLimitMeters < 1
                        ? String(localized: "вне камер — в лимите")
                        : String(format: String(localized: "выше лимита вне камер: %@ пути"),
                                 Self.percentText(share)))
                }
                items.append(ItogiRowItem(
                    id: "roads", symbol: jam != nil ? Icon.trafficLayer : Icon.overLimit,
                    title: String(localized: "Пробки и лимит"),
                    caption: captionParts.joined(separator: " · "),
                    value: jam.map(Formatting.duration)
                        ?? summary.overLimitShare.map(Self.percentText),
                    action: { roadHabit = payload(jam != nil ? .jams : .overLimit, itogi) }))
            }

            if let expenses = expensesRow(summary) {
                items.append(expenses)
            }

            items.append(ItogiRowItem(
                id: "trips", symbol: Icon.trips,
                title: String(localized: "Поездки"),
                caption: String(format: String(localized: "%@ за рулём · карта, список, по дням"),
                                Formatting.duration(summary.movingDuration)),
                value: "\(summary.trips)",
                action: { path.append(.trips) }))
        }

        // Обслуживание — только когда что-то скоро или пора (18.2).
        let maintenance = env.maintenance.attention()
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
        let shifts = WorkShiftsCard.shown(env.workShifts)
        if !shifts.isEmpty {
            items.append(ItogiRowItem(
                id: "shifts", symbol: Icon.shifts,
                title: String(localized: "Смены"),
                caption: String(localized: "Рейсы, превышения и расходы по сменам"),
                value: "\(shifts.count)",
                action: { path.append(.shifts) }))
        }

        // Свои отметки радаров (31E) — сообщает, никуда не ведёт.
        let _ = env.mobile.impactRevision
        let impact = env.mobile.impactSummary()
        if impact.reports > 0 {
            items.append(ItogiRowItem(
                id: "community", symbol: Icon.community,
                title: String(localized: "Ваши отметки за 30 дней"),
                caption: impact.confirmations > 0
                    ? String(localized: "Их подтвердили другие водители: \(impact.confirmations) раз")
                    : String(localized: "Пока без подтверждений других водителей"),
                value: "\(impact.reports)"))
        }

        // Пожизненное — отдельным разделом (правило 14: своё окно).
        if !trip.lifetime.isEmpty, trip.isLifetimeTrusted {
            items.append(ItogiRowItem(
                id: "lifetime", symbol: Icon.lifetime,
                title: String(localized: "За всё время"),
                caption: String(localized: "Поездки, километры, достижения"),
                value: Formatting.distance(trip.lifetime.distanceMeters),
                action: { path.append(.lifetime) }))
        }
        return items
    }
}
