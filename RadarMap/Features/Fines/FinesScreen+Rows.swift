//
//  FinesScreen+Rows.swift
//  RadarMap
//
//  Строки экрана «Штрафы»: пришедший штраф (срок, сверка, «Оплатить»),
//  проезд, отмеченный «пришёл» без постановления, и ожидаемый проезд.
//  Кнопки — РЯДОМ с кнопкой строки, не внутри: вложенные кнопки в SwiftUI
//  ненадёжны (как в «Возможных штрафах»).
//

import SwiftUI

extension FinesScreen {

    // MARK: - Пришедший штраф

    func receivedRow(_ item: FineLedger.Received) -> some View {
        let fine = item.fine
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                entry = FineEntryRequest(editing: fine)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    IconBadge(symbol: fine.isPaid ? "checkmark.seal.fill" : "doc.text.fill",
                              tint: fine.isPaid ? Theme.success : Theme.Icon.money, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fine.place ?? String(localized: "Место не указано"))
                            .font(.rounded(14, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(2)
                        if let at = fine.violationAt {
                            Text(FineFormat.moment(at, withTime: fine.timeKnown == true))
                                .font(.rounded(11))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        // Номер постановления — своей строкой: рядом с датой
                        // он обрезался до «№ QR 7…», а его сверяют с квитанцией.
                        if let resolution = fine.resolution {
                            Text(String(format: String(localized: "№ %@"), resolution))
                                .font(.rounded(11))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(fine.amount.map(FineFormat.money) ?? String(localized: "сумма не указана"))
                        .font(.rounded(fine.amount == nil ? 12 : 15, .bold))
                        .foregroundStyle(fine.amount == nil ? Theme.textTertiary : Theme.textPrimary)
                        .multilineTextAlignment(.trailing)
                    Image(systemName: "chevron.right")
                        .font(.rounded(11, .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Открыть штраф"))

            statusLine(item)
            linkLine(item.link)

            if !fine.isPaid {
                HStack(spacing: 8) {
                    actionButton(String(localized: "Оплатить"), symbol: "creditcard",
                                 tint: Theme.accent) { pay(fine) }
                    actionButton(String(localized: "Оплачен"), symbol: "checkmark.circle",
                                 tint: Theme.success) {
                        env.setReceivedFinePaid(fine.id, paid: true)
                    }
                }
                if copiedFor == fine.id {
                    Text("Номер постановления скопирован — вставьте его на портале.")
                        .font(.rounded(11))
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                actionButton(String(localized: "Не оплачен"), symbol: "arrow.uturn.backward.circle",
                             tint: Theme.textSecondary) {
                    env.setReceivedFinePaid(fine.id, paid: false)
                }
            }
        }
        .statCard(padding: 14, radius: Theme.cornerMedium)
    }

    /// Срок: льготный, обычный, прошёл, оплачен — и напоминание, если стоит.
    @ViewBuilder
    private func statusLine(_ item: FineLedger.Received) -> some View {
        let reminder = item.fine.reminderAt.flatMap { $0 > Date() ? $0 : nil }
        switch item.status {
        case .discount(let until):
            statusLabel(item.terms?.discounted.map {
                String(format: String(localized: "Льготный срок — до %1$@: ≈ %2$@"),
                       FineFormat.day(until), FineFormat.money($0))
            } ?? String(format: String(localized: "Льготный срок — до %@"), FineFormat.day(until)),
                        symbol: "clock", tint: Theme.accent, reminder: reminder)
        case .due(let until):
            statusLabel(item.terms?.dueIsOfficial == true
                        ? String(format: String(localized: "Оплатить до %@"), FineFormat.day(until))
                        : String(format: String(localized: "Оплатить до %@ — ориентир"), FineFormat.day(until)),
                        symbol: "clock", tint: Theme.warning, reminder: reminder)
        case .overdue(let since):
            statusLabel(String(format: String(localized: "Срок оплаты прошёл %@"), FineFormat.day(since)),
                        symbol: "exclamationmark.circle", tint: Theme.danger, reminder: nil)
        case .paid:
            statusLabel(item.fine.paidAt.map {
                String(format: String(localized: "Оплачен %@"), FineFormat.day($0))
            } ?? String(localized: "Оплачен"), symbol: "checkmark.circle", tint: Theme.success, reminder: nil)
        case .unknown:
            EmptyView()
        }
    }

    private func statusLabel(_ text: String, symbol: String, tint: Color, reminder: Date?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(text, systemImage: symbol)
                .font(.rounded(12, .medium))
                .foregroundStyle(tint)
            if let reminder {
                Text(String(format: String(localized: "Напомним %@"), FineFormat.day(reminder)))
                    .font(.rounded(11))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    /// С чем сверен: проезд, сводка дня или «без поездки».
    @ViewBuilder
    private func linkLine(_ link: FineLedger.LinkState) -> some View {
        switch link {
        case .pass(let pass, _):
            Label(passCaption(pass), systemImage: "link")
                .font(.rounded(12))
                .foregroundStyle(Theme.textSecondary)
        case .passGone:
            Label(String(localized: "Сверен с поездкой — её запись уже не хранится"), systemImage: "link")
                .font(.rounded(12))
                .foregroundStyle(Theme.textTertiary)
        case .day(let day):
            Label(String(format: String(localized: "По сводке дня %@: превышение было, запись поездки не хранится"),
                         FineFormat.day(day)), systemImage: "calendar")
                .font(.rounded(12))
                .foregroundStyle(Theme.textTertiary)
        case .none:
            Label(String(localized: "Без поездки в истории"), systemImage: "minus.circle")
                .font(.rounded(12))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    /// «Проезд 12 окт., 18:47 · 88 км/ч при 60» — наш замер рядом с постановлением.
    func passCaption(_ pass: PassedCamera) -> String {
        let moment = FineFormat.moment(pass.date, withTime: true)
        let speed = Int(pass.speedKmh.rounded())
        if let limit = pass.limitKmh {
            return String(format: String(localized: "Проезд %1$@ · %2$lld км/ч при %3$lld"), moment, speed, limit)
        }
        return String(format: String(localized: "Проезд %1$@ · %2$lld км/ч"), moment, speed)
    }

    // MARK: - Проезды

    /// «Пришёл» отмечен кнопкой, постановление не внесено: предложить внести —
    /// тогда появятся сумма, срок и напоминание.
    func markedRow(_ item: FineLedger.Expected) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            passHeader(item.pass)
            actionButton(String(localized: "Внести постановление"), symbol: "square.and.pencil",
                         tint: Theme.accent) {
                entry = FineEntryRequest(pass: item.pass, tripID: item.tripID)
            }
        }
        .statCard(padding: 14, radius: Theme.cornerMedium)
    }

    /// Ожидаемый: оценка по ступени и та же судьба, что в «Возможных
    /// штрафах», только «Пришёл» ведёт в форму — с суммой и сроком.
    func expectedRow(_ item: FineLedger.Expected) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            passHeader(item.pass)
            Text(String(format: String(localized: "риск ≈ %@"), Formatting.money(item.estimate)))
                .font(.rounded(14, .bold))
                .foregroundStyle(Theme.danger)
            HStack(spacing: 8) {
                actionButton(String(localized: "Пришёл"), symbol: "envelope.badge", tint: Theme.warning) {
                    entry = FineEntryRequest(pass: item.pass, tripID: item.tripID)
                }
                actionButton(String(localized: "Не пришёл"), symbol: "checkmark.circle", tint: Theme.success) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withMotion(Motion.standard) {
                        env.trip.setFineOutcome(.dismissed, passID: item.pass.id, tripID: item.tripID)
                    }
                }
            }
        }
        .statCard(padding: 14, radius: Theme.cornerMedium)
    }

    private func passHeader(_ pass: PassedCamera) -> some View {
        HStack(spacing: 12) {
            Image(systemName: pass.kind.symbolName)
                .font(.rounded(15, .bold))
                .foregroundStyle(pass.kind.glyphTint)
                .frame(width: 34, height: 34)
                .background(pass.kind.tint.gradient, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(pass.location.isEmpty ? pass.kind.displayName : pass.location)
                    .font(.rounded(14, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(FineFormat.moment(pass.date, withTime: true))
                    .font(.rounded(11))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 8)
            if let limit = pass.limitKmh { SpeedLimitSign(limit: limit, diameter: 26) }
            Text("\(Int(pass.speedKmh.rounded())) км/ч")
                .font(.rounded(15, .bold))
                .foregroundStyle(PassStyle.color(speed: pass.speedKmh, limit: pass.limitKmh))
        }
    }

    /// Кнопка строки — один стиль на все действия, мишень 44 pt.
    private func actionButton(_ title: String, symbol: String, tint: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.rounded(15, .semibold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(tint.opacity(0.12), in: Capsule())
                .tapTarget()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .buttonStyle(PressableStyle())
    }
}
