//
//  FinesSheet.swift
//  RadarMap
//
//  «Возможные штрафы» периода: каждый проезд со штрафной ступенью — строкой
//  с суммой и кнопкой «Не пришёл». Пометка убирает сумму из всех сводок
//  (запись + дневной агрегат, см. TripStats.setFineDismissed) и отменяется
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
        // «Не пришёл» обновляет и сумму в шапке, и вид строки.
        let items = Self.items(env.trip.history, period: period, anchor: anchor)
        let activeSum = items.filter(\.pass.countsTowardFines).reduce(0.0) { $0 + $1.fine }
        let dismissedCount = items.count { !$0.pass.countsTowardFines }

        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    if items.isEmpty {
                        emptyHint
                    } else {
                        header(sum: activeSum, total: items.count,
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
            .background(Theme.background)
            .navigationTitle("Возможные штрафы")
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

    private func header(sum: Double, total: Int, dismissed: Int) -> some View {
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
        .animation(.snappy(duration: 0.3), value: sum)
    }

    // MARK: - Строка проезда

    private func row(_ item: FineItem) -> some View {
        let active = item.pass.countsTowardFines
        let expired = active && Date().timeIntervalSince(item.pass.date)
            > Double(AppConfig.fineExpiresDays) * 86400
        return VStack(spacing: 10) {
            // Верх — сам проезд, тап открывает его карту.
            Button {
                selectedItem = PassMapPayload(pass: item.pass, record: item.record)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: item.pass.kind.symbolName)
                        .font(.rounded(13, .bold))
                        .foregroundStyle(.white)
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
                    Text("\(Int(item.pass.speedKmh)) км/ч")
                        .font(.rounded(15, .bold))
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

            // Низ — деньги и пометка. Кнопка РЯДОМ с кнопкой проезда, не внутри:
            // вложенные кнопки в SwiftUI ненадёжны (см. riskCard в Итогах).
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: String(localized: "риск ≈ %@"),
                                Formatting.money(item.fine)))
                        .font(.rounded(13, .bold))
                        .strikethrough(!active)
                        .foregroundStyle(active ? Theme.danger : Theme.textTertiary)
                    if expired {
                        Text(String(format: String(localized: "Прошло больше %lld дней — обычно уже не приходит"),
                                    AppConfig.fineExpiresDays))
                            .font(.rounded(10))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.snappy(duration: 0.3)) {
                        env.trip.setFineDismissed(active, passID: item.pass.id,
                                                  tripID: item.record.id)
                    }
                } label: {
                    Label(active ? String(localized: "Не пришёл")
                                 : String(localized: "Вернуть"),
                          systemImage: active ? "checkmark.circle" : "arrow.uturn.backward.circle")
                        .font(.rounded(12, .semibold))
                        .foregroundStyle(active ? Theme.success : Theme.textSecondary)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background((active ? Theme.success : Theme.textSecondary).opacity(0.12),
                                    in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(Text(active
                                         ? String(localized: "Отметить: штраф не пришёл")
                                         : String(localized: "Вернуть штраф в сумму")))
            }
        }
        .statCard(padding: 14, radius: Theme.cornerMedium)
        .opacity(active ? 1 : 0.6)
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
                .font(.rounded(12))
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
