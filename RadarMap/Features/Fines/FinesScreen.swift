//
//  FinesScreen.swift
//  RadarMap
//
//  «Штрафы» (этап 17.3): пришедшие — со сроком оплаты, льготным сроком и
//  сверкой с поездкой; ожидаемые — проезды с риском, по которым ещё ничего
//  не пришло; суммы. Вход — из «Итогов», из «Возможных штрафов», из
//  настроек (Проверить штрафы) и из напоминания об оплате.
//
//  Все цифры — один FineLedger (правило 14): шапка и строки читают его же.
//  Сроки — ориентир (👤 правила не подтверждены), поэтому слова нейтральные:
//  «срок», «льготный срок», «≈», и сноска — условия в постановлении.
//  Штрафы и номер машины с телефона не уходят — об этом сказано на экране.
//

import SwiftUI
import UniformTypeIdentifiers

/// Что открыть в форме штрафа.
struct FineEntryRequest: Identifiable {
    let id = UUID()
    /// Правка внесённого.
    var editing: ReceivedFine?
    /// «Пришёл» на проезде — форма сразу сверена с ним.
    var pass: PassedCamera?
    var tripID: Double?
    /// Снимки экрана: текст, уже вставленный в поле (DEBUG).
    var pastedText: String?
}

struct FinesScreen: View {
    @Environment(AppEnvironment.self) var env
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) var openURL
    @State var entry: FineEntryRequest?
    /// «Номер постановления скопирован» — под строкой, где нажали «Оплатить».
    @State var copiedFor: UUID?

    var body: some View {
        // Пересчёт на каждую правку: штрафы и история — @Observable.
        let ledger = FineLedger.build(fines: env.fines.fines, history: env.trip.history, now: Date())
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    summary(ledger)
                    PrimaryButton(title: "Внести штраф", systemImage: "plus") {
                        entry = FineEntryRequest()
                    }
                    if ledger.isEmpty { emptyHint }
                    if !ledger.received.isEmpty {
                        SectionHeader(String(localized: "Пришли"))
                        ForEach(ledger.received) { receivedRow($0) }
                    }
                    if !ledger.marked.isEmpty {
                        SectionHeader(String(localized: "Отмечены «пришёл» без постановления"))
                        ForEach(ledger.marked) { markedRow($0) }
                    }
                    if !ledger.expected.isEmpty {
                        SectionHeader(String(localized: "Ожидаются — по нашим замерам"))
                        ForEach(ledger.expected) { expectedRow($0) }
                    }
                    footnote
                }
                .padding(20)
            }
            .backport.scrollEdgeEffectStyle(.hard, for: .top)
            .background(Theme.background)
            .navigationTitle("Штрафы")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .sheet(item: $entry) { request in FineEntrySheet(request: request) }
        .onAppear {
            env.usage.noteScreen("receivedFines")
            env.refreshFineReminders()
            #if DEBUG
            // Снимок формы со вставленным текстом: `-finePasteDemo`.
            if ProcessInfo.processInfo.arguments.contains("-finePasteDemo") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    entry = FineEntryRequest(pastedText: FineDemo.pastedText(history: env.trip.history))
                }
            }
            #endif
        }
    }

    // MARK: - Шапка

    private func summary(_ ledger: FineLedger) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("К оплате")
                    .font(.rounded(13, .medium))
                    .foregroundStyle(Theme.textSecondary)
                Text(ledger.toPay > 0 ? FineFormat.money(ledger.toPay) : String(localized: "ничего"))
                    .font(.numeral(28, .heavy))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                if ledger.unknownAmountCount > 0 {
                    Text(String(format: String(localized: "и без суммы: %lld"), ledger.unknownAmountCount))
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Divider().overlay(Theme.stroke)
            HStack(alignment: .top, spacing: 16) {
                figure(title: String(localized: "Пришло"),
                       value: "\(ledger.received.count)",
                       caption: ledger.paidTotal > 0
                           ? String(format: String(localized: "оплачено %@"), FineFormat.money(ledger.paidTotal))
                           : nil)
                figure(title: String(localized: "Ожидаются"),
                       value: ledger.expectedSum > 0 ? "≈ " + Formatting.money(ledger.expectedSum) : "0",
                       // Окно названо (34, правило 14): без него «≈ 11 млн» здесь
                       // спорило с «2,2 млн за неделю» в «Итогах» — два разных
                       // окна под одним словом.
                       caption: ledger.expected.isEmpty ? nil
                           : String(format: String(localized: "проездов: %1$lld за %2$lld дней"),
                                    ledger.expected.count, AppConfig.fineExpiresDays))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .statCard()
    }

    private func figure(title: String, value: String, caption: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.rounded(12, .medium))
                .foregroundStyle(Theme.textTertiary)
            Text(value)
                .font(.rounded(17, .bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let caption {
                // Переносится (34): «проездов: 5 за 60 дней» в половине
                // ширины SE ужималось до нечитаемого.
                Text(caption)
                    .font(.rounded(11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Пусто и сноска

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "envelope.open")
                .font(.rounded(26))
                .foregroundStyle(Theme.accent)
            Text("Пришедших штрафов нет")
                .font(.rounded(15, .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Пришло постановление — вставьте текст СМС или заполните форму: сверим с поездкой и напомним о сроке оплаты.")
                .font(.rounded(14))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .statCard(padding: 24)
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Сроки и льготный срок — ориентир по общим правилам; точные даты и суммы — в постановлении. Ожидаемые — оценка по нашим замерам, не постановления. Рейтинг от отметок не меняется.")
            Text("Штрафы хранятся только на телефоне. Номер машины никуда не отправляется.")
        }
        .font(.rounded(11))
        .foregroundStyle(Theme.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    // MARK: - Оплатить

    /// «Оплатить»: номер постановления — в буфер (только это устройство и
    /// ненадолго), в адрес ссылки — ничего.
    func pay(_ fine: ReceivedFine) {
        if let resolution = fine.resolution {
            UIPasteboard.general.setItems(
                [[UTType.plainText.identifier: resolution]],
                options: [.localOnly: true,
                          .expirationDate: Date().addingTimeInterval(AppConfig.fineCheckClipboardSeconds)])
            copiedFor = fine.id
        }
        openURL(AppConfig.finePaymentURL)
    }
}
