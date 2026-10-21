//
//  FinesSheet.swift
//  RadarMap
//
//  «Возможные штрафы» периода: каждый проезд со штрафной ступенью — строкой
//  с суммой и кнопкой «Не пришёл». Пометка убирает сумму из всех сводок
//  (запись + дневной агрегат, см. TripStats.setFineOutcome) и отменяется
//  той же кнопкой — деньги списываются только рукой владельца. «Пришёл»
//  открывает форму постановления (этап 17), сверенную с этим проездом:
//  сумма, срок и напоминание живут уже на экране «Штрафы».
//
//  В список идут только проезды с ДОСТОВЕРНЫМ лимитом — как в fineRisk:
//  сумма в сумах по догадке о классе дороги была бы ложью про деньги.
//  Рейтинг от пометки не меняется: он про езду, а не про почту МВД.
//

import SwiftUI

/// Строка экрана: проезд + его запись (трек нужен карте проезда).
private struct FineItem: Identifiable {
    let pass: PassedCamera
    let record: TripRecord
    let fine: Double
    var id: UUID { pass.id }
}

struct FinesSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let period: StatsPeriod
    let anchor: Date
    /// «Откуда сумма» раскрыта сразу — вход через (i) у карточки денег.
    var explainsFirst = false
    /// Риск периода с карточки «Итогов» — по дневным сводкам, которые живут
    /// дольше записей (хранятся последние 50). Если строк меньше, чем денег на
    /// карточке, шапка говорит об этом, а не показывает другое число молча.
    var periodRisk: Double? = nil

    /// Проезд, открытый на карте.
    @State private var selectedItem: PassMapPayload?
    @State private var explainerOpen = false
    /// «Пришёл» — форма постановления, сверенная с этим проездом (этап 17).
    @State private var entry: FineEntryRequest?
    /// «Штрафы» — пришедшие постановления и сроки оплаты.
    @State private var showsReceived = false

    /// Слепок для шита карты: пара (проезд, запись) в момент тапа.
    struct PassMapPayload: Identifiable {
        let pass: PassedCamera
        let record: TripRecord
        var id: UUID { pass.id }
    }

    var body: some View {
        // Пересчёт на каждую пометку: env.trip.history — @Observable, тап по
        // «Пришёл»/«Не пришёл» обновляет и шапку, и вид строки.
        let items = Self.items(env.trip.history, period: period, anchor: anchor)
        let pendingSum = items.filter(\.pass.countsTowardFines).reduce(0.0) { $0 + $1.fine }
        // Пришедшие — суммой постановления, если его внесли (paidAmount).
        let paidSum = items.reduce(0.0) { $0 + ($1.pass.paidAmount ?? 0) }
        let dismissedCount = items.count { $0.pass.fineOutcome == .dismissed }

        NavigationStack {
            ScrollView {
                ScrollViewReader { proxy in
                LazyVStack(spacing: 12) {
                    // Один экран (6.9): шапка → строки → «Откуда сумма и как
                    // считаем» раскрывашкой. Нет штрафов — объяснение раскрыто.
                    receivedLink
                    if items.isEmpty {
                        emptyHint
                    } else {
                        header(sum: pendingSum, paid: paidSum, total: items.count,
                               dismissed: dismissedCount)
                        if let periodRisk, periodRisk > pendingSum + 1000 {
                            Label(String(format: String(localized: "В «Итогах» за период — %@: часть поездок старше сохранённых, их строк здесь нет"),
                                         Formatting.money(periodRisk)),
                                  systemImage: "internaldrive")
                                .font(.rounded(11))
                                .foregroundStyle(Theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(items) { item in
                            row(item)
                        }
                        footnote
                    }
                    explainer(open: items.isEmpty || explainerOpen, togglable: !items.isEmpty)
                        .id("explainer")
                }
                .padding(20)
                // Вход через (i) — объяснение и есть то, за чем пришли.
                .onAppear {
                    guard explainsFirst, !items.isEmpty else { return }
                    explainerOpen = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        withMotion(Motion.standard) { proxy.scrollTo("explainer", anchor: .top) }
                    }
                }
                }
            }
            .backport.scrollEdgeEffectStyle(.hard, for: .top)
            .background(Theme.screenBackground)
            .navigationTitle("Возможные штрафы")
            .onAppear { env.usage.noteScreen("fines") }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .sheet(item: $selectedItem) { payload in
            PassMapSheet(pass: payload.pass, track: payload.record.trackPoints,
                         record: payload.record)
        }
        .sheet(item: $entry) { request in FineEntrySheet(request: request) }
        .sheet(isPresented: $showsReceived) { FinesScreen() }
    }

    /// Вход в «Штрафы»: пришедшие постановления, сроки, «Оплатить».
    private var receivedLink: some View {
        Button {
            showsReceived = true
        } label: {
            HStack(spacing: 10) {
                IconBadge(symbol: "doc.text.fill", tint: Theme.Icon.money, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Пришедшие штрафы и сроки оплаты")
                        .font(.rounded(14, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Вставьте текст СМС — сверим с поездкой")
                        .font(.rounded(11))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.rounded(13, .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .statCard(padding: 12, radius: Theme.cornerMedium)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// «Откуда сумма и как считаем» — заголовок-раскрывашка и FinesExplainer.
    @ViewBuilder private func explainer(open: Bool, togglable: Bool = true) -> some View {
        Button {
            withMotion(Motion.standard) { explainerOpen.toggle() }
        } label: {
            HStack(spacing: 10) {
                IconBadge(symbol: "info.circle.fill", tint: Theme.accent, size: 30)
                Text("Откуда сумма и как считаем")
                    .font(.rounded(14, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
                if togglable {
                    Image(systemName: "chevron.down")
                        .font(.rounded(13, .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
            }
            .statCard(padding: 14, radius: Theme.cornerMedium)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Без строк объяснение раскрыто всегда — сворачивать его нечем.
        .disabled(!togglable)
        .padding(.top, 4)
        if open {
            FinesExplainer(interval: period.interval(containing: anchor))
        }
    }

    /// Проезды периода со штрафной ступенью и достоверным лимитом, новые сверху.
    /// Отменённые остаются в списке (зачёркнутыми) — иначе «Вернуть» негде.
    private static func items(_ history: [TripRecord], period: StatsPeriod,
                              anchor: Date) -> [FineItem] {
        TripHistory.records(history, period: period, anchor: anchor)
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

    // MARK: - Шапка

    private func header(sum: Double, paid: Double, total: Int, dismissed: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(period.caption)
                .font(.rounded(11, .medium))
                .foregroundStyle(Theme.textTertiary)
            Text(sum > 0 ? Formatting.money(sum) : String(localized: "0 штрафов"))
                .font(.rounded(30, .heavy))
                .foregroundStyle(sum > 0 ? Theme.danger : Theme.success)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            Text(String(format: String(localized: "Проездов со ступенью штрафа: %lld"), total))
                .font(.rounded(11))
                .foregroundStyle(Theme.textTertiary)
            if paid > 0 {
                Label(String(format: String(localized: "Пришло: %@"), Formatting.money(paid)),
                      systemImage: "envelope.badge.fill")
                    .font(.rounded(11, .medium))
                    .foregroundStyle(Theme.warning)
            }
            if dismissed > 0 {
                Label(String(format: String(localized: "Не пришло: %lld — в сумме не считаются"),
                             dismissed),
                      systemImage: "checkmark.circle")
                    .font(.rounded(11, .medium))
                    .foregroundStyle(Theme.success)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .statCard()
        .motionAnimation(Motion.standard, value: sum)
    }

    // MARK: - Строка проезда

    private func row(_ item: FineItem) -> some View {
        let outcome = item.pass.fineOutcome
        let expired = outcome == .pending && Date().timeIntervalSince(item.pass.date)
            > Double(AppConfig.fineExpiresDays) * 86400
        return VStack(spacing: 10) {
            // Верх — сам проезд, тап открывает его карту.
            Button {
                selectedItem = PassMapPayload(pass: item.pass, record: item.record)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: item.pass.kind.symbolName)
                        .font(.rounded(15, .bold))
                        .foregroundStyle(item.pass.kind.glyphTint)
                        .frame(width: 34, height: 34)
                        .background(item.pass.kind.tint.gradient, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.pass.location.isEmpty ? item.pass.kind.displayName
                                                        : item.pass.location)
                            .font(.rounded(14, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        // «19 окт., 19:06» — без года и одной строкой: полная
                        // дата переносилась и раздувала каждую строку.
                        Text(item.pass.date.formatted(.dateTime.day().month(.abbreviated)
                                                        .hour().minute()
                                                        .locale(NumberFormat.locale)))
                            .font(.rounded(11))
                            .foregroundStyle(Theme.textTertiary)
                    }
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
                        // Округление, а не усечение — как на экране проезда.
                        Text("\(Int(item.pass.speedKmh.rounded())) км/ч")
                            .font(.rounded(15, .bold))
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
            // не внутри: вложенные кнопки в SwiftUI ненадёжны (см. riskCard).
            // Сумма — своей строкой, кнопки — под ней на всю ширину: в один
            // ряд «Не пришёл» обрезалось до «Не при…».
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
                    // Сверен с внесённым постановлением: судьбу правит экран
                    // «Штрафы», иначе штраф там и проезд здесь разошлись бы.
                    Label("Постановление внесено — в «Штрафах»", systemImage: "doc.text")
                        .font(.rounded(13, .medium))
                        .foregroundStyle(Theme.textSecondary)
                } else if outcome == .pending {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withMotion(Motion.standard) {
                env.trip.setFineOutcome(outcome, passID: item.pass.id,
                                        tripID: item.record.id)
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
            .background(tint.opacity(0.12), in: Capsule())
            // Капсула ~34 pt остаётся прежней на глаз, а мишень — 44:
            // «Пришёл» и «Не пришёл» стоят рядом, и промах ставит деньгам
            // не ту судьбу.
            .tapTarget()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    // MARK: - Пустое состояние и сноска

    /// Пусто бывает и при ненулевой сумме в Итогах: сумма периода живёт в
    /// дневных сводках вечно, а отмечать можно только сохранённые записи.
    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .font(.rounded(26))
                .foregroundStyle(Theme.success)
            Text("В сохранённых поездках периода нет проездов с риском штрафа")
                .font(.rounded(14, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            Text("Отмечать «не пришёл» можно только по сохранённым поездкам — история хранит последние 50.")
                .font(.rounded(15))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .statCard(padding: 24)
    }

    private var footnote: some View {
        Text("Сумма — оценка по ступеням штрафов за превышение (в БРВ), только по камерам с достоверным лимитом. Постановление обычно приходит за несколько дней; не пришло — отметьте, и сумма уйдёт из Итогов. Рейтинг это не меняет.")
            .font(.rounded(11))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }
}
