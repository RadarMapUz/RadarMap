//
//  FinesScreen.swift
//  RadarMap
//
//  «Штрафы» — один экран на оба смысла слова (34b, вариант Ш-A владельца).
//  До 34 их было два: «Возможные штрафы» (оценка по проездам периода) и
//  «Штрафы» (пришедшие постановления) — почти одно имя, четыре входа,
//  перекрёстная ссылка из одного в другой и три разные суммы «возможных
//  штрафов» без подписанного окна. Водитель думает «мои штрафы», а не
//  «оценка» и «постановления».
//
//  Шапка — две денежные правды рядом: «К оплате» (факт, постановления) и
//  «Могут прийти» (оценка по ступеням за окно, окно подписано). Ниже — две
//  вкладки: «Могут прийти» (проезды со ступенью штрафа, «Пришёл / Не пришёл»)
//  и «Пришли» (постановления, сроки, «Оплатить»). Справка «как считаем» —
//  внизу свёрнута.
//
//  Окно оценки — `FinesWindow`: из «Итогов» — период экрана (то же число,
//  что в карточке-ответе), отовсюду ещё — последние `fineExpiresDays` дней:
//  после них штраф обычно уже не приходит.
//
//  Все цифры «Пришли» — один FineLedger (правило 14). Сроки — ориентир
//  (👤 правила не подтверждены), поэтому слова нейтральные. Штрафы и номер
//  машины с телефона не уходят.
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

/// Вкладка экрана «Штрафы».
enum FinesTab: Hashable {
    case possible, received
}

/// Окно оценки «Могут прийти».
enum FinesWindow: Equatable {
    /// Период «Итогов» — то же окно, что у суммы в карточке-ответе.
    case period(StatsPeriod, Date)
    /// Последние `AppConfig.fineExpiresDays` дней.
    case recent
}

/// Как открыть экран: окно и вкладка (nil — «Пришли», если там что-то есть).
struct FinesRequest: Identifiable {
    let id = UUID()
    var window: FinesWindow = .recent
    var tab: FinesTab? = nil
    /// Сумма периода с карточки «Итогов» — по дневным сводкам; если строк
    /// меньше, шапка говорит об этом, а не показывает другое число молча.
    var periodRisk: Double? = nil
}

struct FinesScreen: View {
    @Environment(AppEnvironment.self) var env
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) var openURL
    var request = FinesRequest()

    @State var entry: FineEntryRequest?
    /// «Номер постановления скопирован» — под строкой, где нажали «Оплатить».
    @State var copiedFor: UUID?
    @State var tab: FinesTab = .received
    @State private var chosenTab = false
    /// Проезд, открытый на карте.
    @State var selectedPass: PassMapPayload?
    @State var explainerOpen = false

    /// Слепок для шита карты: пара (проезд, запись) в момент тапа.
    struct PassMapPayload: Identifiable {
        let pass: PassedCamera
        let record: TripRecord
        var id: UUID { pass.id }
    }

    var body: some View {
        // Пересчёт на каждую правку: штрафы и история — @Observable.
        let ledger = FineLedger.build(fines: env.fines.fines, history: env.trip.history, now: Date())
        let items = Self.possibleItems(env.trip.history, window: request.window, now: Date())
        let possibleSum = items.filter(\.pass.countsTowardFines).reduce(0.0) { $0 + $1.fine }
        let receivedCount = ledger.received.count + ledger.marked.count
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    header(ledger, possibleSum: possibleSum,
                           possibleCount: items.filter(\.pass.countsTowardFines).count)
                    Picker("", selection: $tab) {
                        Text(String(format: String(localized: "Могут прийти · %lld"),
                                    items.filter(\.pass.countsTowardFines).count))
                            .tag(FinesTab.possible)
                        Text(String(format: String(localized: "Пришли · %lld"), receivedCount))
                            .tag(FinesTab.received)
                    }
                    .pickerStyle(.segmented)
                    .padding(.vertical, 2)
                    switch tab {
                    case .possible:
                        possibleTab(items, sum: possibleSum)
                    case .received:
                        receivedTab(ledger)
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
        .sheet(item: $selectedPass) { payload in
            PassMapSheet(pass: payload.pass, track: payload.record.trackPoints, record: payload.record)
        }
        .onAppear {
            if !chosenTab {
                chosenTab = true
                tab = request.tab ?? (receivedCount > 0 || items.isEmpty ? .received : .possible)
            }
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

    /// Подпись окна оценки: «за неделю», «за 60 дней».
    var windowCaption: String {
        switch request.window {
        case .period(let period, _): return period.caption
        case .recent: return String(format: String(localized: "за %lld дней"), AppConfig.fineExpiresDays)
        }
    }

    private func header(_ ledger: FineLedger, possibleSum: Double, possibleCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("К оплате")
                    .font(.rounded(13, .medium))
                    .foregroundStyle(Theme.textSecondary)
                Text(ledger.toPay > 0 ? FineFormat.money(ledger.toPay) : String(localized: "ничего"))
                    .font(.numeral(28, .heavy))
                    .foregroundStyle(ledger.toPay > 0 ? Theme.danger : Theme.textPrimary)
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
                figure(title: String(localized: "Могут прийти"),
                       value: possibleSum > 0 ? "≈ " + Formatting.money(possibleSum) : "0",
                       caption: possibleCount > 0
                           ? windowCaption + " · " + String(format: String(localized: "проездов: %lld"), possibleCount)
                           : windowCaption)
                figure(title: String(localized: "Пришло"),
                       value: "\(ledger.received.count)",
                       caption: ledger.paidTotal > 0
                           ? String(format: String(localized: "оплачено %@"), FineFormat.money(ledger.paidTotal))
                           : nil)
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
                Text(caption)
                    .font(.rounded(11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - «Пришли»

    @ViewBuilder private func receivedTab(_ ledger: FineLedger) -> some View {
        PrimaryButton(title: "Внести штраф", systemImage: "plus") {
            entry = FineEntryRequest()
        }
        if ledger.received.isEmpty && ledger.marked.isEmpty {
            emptyReceived
        }
        ForEach(ledger.received) { receivedRow($0) }
        if !ledger.marked.isEmpty {
            SectionHeader(String(localized: "Отмечены «пришёл» без постановления"))
            ForEach(ledger.marked) { markedRow($0) }
        }
    }

    private var emptyReceived: some View {
        VStack(spacing: 10) {
            IconBadge(symbol: Icon.fines, tint: Theme.textSecondary, size: 44)
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
            Text("Сроки и льготный срок — ориентир по общим правилам; точные даты и суммы — в постановлении. «Могут прийти» — оценка по ступеням штрафа за проезды с достоверным лимитом, не постановления. Рейтинг от отметок не меняется.")
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
