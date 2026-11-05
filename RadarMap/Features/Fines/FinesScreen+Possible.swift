//
//  FinesScreen+Possible.swift
//  RadarMap
//
//  Вкладка «Могут прийти» экрана «Штрафы» (бывший лист «Возможные штрафы»):
//  каждый проезд окна со штрафной ступенью — строкой с суммой и «Пришёл /
//  Не пришёл». Пометка убирает сумму из всех сводок (запись + дневной
//  агрегат, TripStats.setFineOutcome) и отменяется той же кнопкой — деньги
//  списываются только рукой владельца. «Пришёл» открывает форму
//  постановления, сверенную с этим проездом.
//
//  В список идут только проезды с ДОСТОВЕРНЫМ лимитом — как в fineRisk:
//  сумма в сумах по догадке о классе дороги была бы ложью про деньги.
//  Рейтинг от пометки не меняется: он про езду, а не про почту МВД.
//

import SwiftUI

/// Строка вкладки: проезд + его запись (трек нужен карте проезда).
struct FineItem: Identifiable {
    let pass: PassedCamera
    let record: TripRecord
    let fine: Double
    var id: UUID { pass.id }
}

extension FinesScreen {

    /// Проезды окна со штрафной ступенью и достоверным лимитом, новые сверху.
    /// Отменённые остаются (бледными) — иначе «Вернуть» негде.
    static func possibleItems(_ history: [TripRecord], window: FinesWindow, now: Date) -> [FineItem] {
        let records: [TripRecord]
        switch window {
        case .period(let period, let anchor):
            records = TripHistory.records(history, period: period, anchor: anchor)
        case .recent:
            let since = now.addingTimeInterval(-Double(AppConfig.fineExpiresDays) * 86_400)
            records = history.filter { $0.startedAt >= since }
        }
        return records
            .flatMap { record in
                record.passed.compactMap { pass -> FineItem? in
                    guard pass.limitIsCertain, let limit = pass.limitKmh else { return nil }
                    let fine = FineSchedule.fine(overKmh: pass.speedKmh - Double(limit))
                    guard fine > 0 else { return nil }
                    return FineItem(pass: pass, record: record, fine: fine)
                }
            }
            .sorted { $0.pass.date > $1.pass.date }
    }

    /// Окно справки «откуда сумма»: тот же интервал, что у строк.
    var explainerInterval: DateInterval {
        switch request.window {
        case .period(let period, let anchor): return period.interval(containing: anchor)
        case .recent:
            return DateInterval(start: Date().addingTimeInterval(-Double(AppConfig.fineExpiresDays) * 86_400),
                                end: Date())
        }
    }

    @ViewBuilder func possibleTab(_ items: [FineItem], sum: Double) -> some View {
        if items.isEmpty {
            emptyPossible
        } else {
            if let periodRisk = request.periodRisk, periodRisk > sum + 1000 {
                Label(String(format: String(localized: "В «Итогах» за период — %@: часть поездок старше сохранённых, их строк здесь нет"),
                             Formatting.money(periodRisk)),
                      systemImage: "internaldrive")
                    .font(.rounded(11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(items) { possibleRow($0) }
        }
        explainer(open: items.isEmpty || explainerOpen, togglable: !items.isEmpty)
    }

    private var emptyPossible: some View {
        VStack(spacing: 10) {
            IconBadge(symbol: "checkmark.shield.fill", tint: Theme.success, size: 44)
            Text("Проездов с риском штрафа нет")
                .font(.rounded(15, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            Text("Отмечать «не пришёл» можно только по сохранённым поездкам — у самых старых остались лишь итоги дня.")
                .font(.rounded(14))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .statCard(padding: 24)
    }

    /// «Как считаем и ступени КоАО» — раскрывашка и FinesExplainer.
    @ViewBuilder private func explainer(open: Bool, togglable: Bool) -> some View {
        Button {
            withMotion(Motion.standard) { explainerOpen.toggle() }
        } label: {
            HStack(spacing: 12) {
                IconBadge(symbol: "info.circle.fill", tint: Theme.textSecondary, size: 30)
                Text("Как считаем и ступени штрафа")
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
                if togglable {
                    Image(systemName: "chevron.down")
                        .font(.rounded(13, .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 11)
            .frame(minHeight: Theme.controlSize)
            .statCard(padding: 0, radius: Theme.cornerMedium)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!togglable)
        .padding(.top, 4)
        if open {
            FinesExplainer(interval: explainerInterval)
        }
    }

    // MARK: - Строка проезда

    private func possibleRow(_ item: FineItem) -> some View {
        let outcome = item.pass.fineOutcome
        let expired = outcome == .pending && Date().timeIntervalSince(item.pass.date)
            > Double(AppConfig.fineExpiresDays) * 86400
        return VStack(spacing: 10) {
            // Верх — сам проезд, тап открывает его карту.
            Button {
                selectedPass = PassMapPayload(pass: item.pass, record: item.record)
            } label: {
                HStack(spacing: 12) {
                    CameraIcon(kind: item.pass.kind, side: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.pass.location.isEmpty ? item.pass.kind.displayName
                                                        : item.pass.location)
                            .font(.rounded(14, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(2)
                        Text(Formatting.dateAndClock(item.pass.date, .dateTime.day().month(.abbreviated)))
                            .font(.rounded(11))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 8)
                    if let limit = item.pass.limitKmh {
                        SpeedLimitSign(limit: limit, diameter: 26)
                    }
                    HStack(spacing: 4) {
                        // Глиф состояния — второй носитель рядом с цветом.
                        if let symbol = PassStyle.symbol(speed: item.pass.speedKmh,
                                                         limit: item.pass.limitKmh) {
                            Image(systemName: symbol).font(.rounded(12, .bold))
                        }
                        Text("\(Int(item.pass.speedKmh.rounded())) км/ч")
                            .font(.rounded(15, .bold))
                            // Одной строкой, ужимаясь: «88 km/ / soat» на
                            // узбекском переносилось посреди единицы, а
                            // жёсткая ширина ломала название камеры.
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(PassStyle.color(speed: item.pass.speedKmh,
                                                     limit: item.pass.limitKmh))
                    Image(systemName: "chevron.right")
                        .font(.rounded(11, .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().overlay(Theme.stroke)

            // Низ — деньги и судьба штрафа. Кнопки РЯДОМ с кнопкой проезда,
            // не внутри: вложенные кнопки в SwiftUI ненадёжны.
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(outcome == .paid
                         ? (item.pass.fineAmount.map {
                               String(format: String(localized: "штраф %@"), FineFormat.money($0))
                           } ?? String(format: String(localized: "штраф ≈ %@"),
                                       Formatting.money(item.fine)))
                         : String(format: String(localized: "риск ≈ %@"),
                                  Formatting.money(item.fine)))
                        .font(.rounded(15, .bold))
                        .strikethrough(outcome == .dismissed)
                        .foregroundStyle(outcome == .pending ? Theme.danger
                                       : outcome == .paid ? Theme.warning
                                       : Theme.textTertiary)
                    if expired {
                        Text(String(format: String(localized: "Прошло больше %lld дней — обычно уже не приходит"),
                                    AppConfig.fineExpiresDays))
                            .font(.rounded(10))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                HStack(spacing: 8) {
                    if item.pass.fineReceiptID != nil {
                        // Сверен с внесённым постановлением: судьбу правит
                        // вкладка «Пришли», иначе штраф и проезд разошлись бы.
                        Label("Постановление внесено — во вкладке «Пришли»", systemImage: Icon.fines)
                            .font(.rounded(13, .medium))
                            .foregroundStyle(Theme.textSecondary)
                    } else if outcome == .pending {
                        Button {
                            entry = FineEntryRequest(pass: item.pass, tripID: item.record.id)
                        } label: {
                            outcomeLabel(String(localized: "Пришёл"), symbol: "envelope.badge",
                                         tint: Theme.warning)
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityLabel(Text("Штраф пришёл: внести постановление"))
                        outcomeButton(item, set: .dismissed,
                                      title: String(localized: "Не пришёл"),
                                      symbol: "checkmark.circle", tint: Theme.success,
                                      hint: String(localized: "Отметить: штраф не пришёл"))
                    } else {
                        outcomeButton(item, set: .pending,
                                      title: String(localized: "Вернуть"),
                                      symbol: "arrow.uturn.backward.circle",
                                      tint: Theme.textSecondary,
                                      hint: String(localized: "Вернуть штраф в сумму"))
                    }
                }
            }
        }
        .statCard(padding: 14, radius: Theme.cornerMedium)
        .opacity(outcome == .dismissed ? 0.6 : 1)
    }

    /// Кнопка судьбы штрафа — один стиль на три состояния.
    private func outcomeButton(_ item: FineItem, set outcome: PassedCamera.FineOutcome,
                               title: String, symbol: String, tint: Color,
                               hint: String) -> some View {
        Button {
            withMotion(Motion.standard) {
                env.trip.setFineOutcome(outcome, passID: item.pass.id, tripID: item.record.id)
            }
        } label: {
            outcomeLabel(title, symbol: symbol, tint: tint)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(Text(hint))
    }

    private func outcomeLabel(_ title: String, symbol: String, tint: Color) -> some View {
        Label(title, systemImage: symbol)
            .font(.rounded(15, .semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(Theme.quietFill, in: Capsule())
            // Капсула ~34 pt на глаз, мишень — 44: «Пришёл» и «Не пришёл»
            // стоят рядом, и промах ставит деньгам не ту судьбу.
            .tapTarget()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}
