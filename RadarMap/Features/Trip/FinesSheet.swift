//
//  FinesSheet.swift
//  RadarMap
//
//  «Возможные штрафы» периода: каждый проезд со штрафной ступенью — строкой
//  с суммой и кнопкой «Не пришёл». Пометка убирает сумму из всех сводок
//  (запись + дневной агрегат, см. TripStats.setFineOutcome) и отменяется
//  той же кнопкой — деньги списываются только рукой владельца.
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

    /// Проезд, открытый на карте.
    @State private var selectedItem: PassMapPayload?

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
        let paidSum = items.filter { $0.pass.fineOutcome == .paid }.reduce(0.0) { $0 + $1.fine }
        let dismissedCount = items.count { $0.pass.fineOutcome == .dismissed }

        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    if items.isEmpty {
                        emptyHint
                    } else {
                        header(sum: pendingSum, paid: paidSum, total: items.count,
                               dismissed: dismissedCount)
                        ForEach(items) { item in
                            row(item)
                        }
                        footnote
                    }
                }
                .padding(20)
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
        .motionAnimation(.snappy(duration: 0.3), value: sum)
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
                        Text(item.pass.date.formatted(date: .abbreviated, time: .shortened))
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
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(outcome == .paid
                         ? String(format: String(localized: "штраф ≈ %@"),
                                  Formatting.money(item.fine))
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
                Spacer(minLength: 8)
                if outcome == .pending {
                    outcomeButton(item, set: .paid,
                                  title: String(localized: "Пришёл"),
                                  symbol: "envelope.badge", tint: Theme.warning,
                                  hint: String(localized: "Отметить: штраф пришёл"))
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
        .statCard(padding: 14, radius: Theme.cornerMedium)
        .opacity(outcome == .dismissed ? 0.6 : 1)
    }

    /// Кнопка судьбы штрафа — один стиль на три состояния.
    private func outcomeButton(_ item: FineItem, set outcome: PassedCamera.FineOutcome,
                               title: String, symbol: String, tint: Color,
                               hint: String) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withMotion(.snappy(duration: 0.3)) {
                env.trip.setFineOutcome(outcome, passID: item.pass.id,
                                        tripID: item.record.id)
            }
        } label: {
            Label(title, systemImage: symbol)
                .font(.rounded(15, .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(tint.opacity(0.12), in: Capsule())
                .contentShape(Capsule())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(Text(hint))
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
