//
//  JournalEntrySheet.swift
//  RadarMap
//
//  «Заправился» / «Зарядился» (21.6): количество и сумма — и всё, курсор
//  сразу в количестве, время — сейчас. Цена за единицу видна, пока человек
//  печатает. Пробег с панели и «до полного» — по желанию: из них считается
//  реальный расход.
//
//  Перед сохранением — два вопроса, каждый только когда есть о чём спросить:
//  «30 л за 3 000 сум» — опечатка? (EnergyJournal.doubts) и «обновить цену
//  в расчёте?» (EnergyJournal.priceUpdate) — цена профиля молча не меняется.
//

import SwiftUI

struct JournalEntrySheet: View {
    let request: JournalEntryRequest
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var form: JournalForm
    @State private var stableID = UUID()
    /// «Сохранить так?» — запись, которую решили проверить.
    @State private var doubtful: JournalEntry?
    /// «Обновить цену в расчёте?» — запись и предложение.
    @State private var priceAsk: PriceAsk?
    @State private var confirmsDelete = false
    @FocusState private var focus: Field?

    private enum Field { case quantity, amount, odometer }
    /// Подсказка в пустом поле — цифра, переводить нечего.
    private static let zero = "0"

    private struct PriceAsk: Identifiable {
        let entry: JournalEntry
        let update: EnergyJournal.PriceUpdate
        var id: UUID { entry.id }
    }

    init(request: JournalEntryRequest, kinds: [JournalKind]) {
        self.request = request
        if let entry = request.editing {
            _form = State(initialValue: JournalForm(entry: entry))
        } else {
            var form = JournalForm(kind: kinds.first ?? (request.mode == .charge ? .homeCharge : .petrol),
                                   now: Date())
            #if DEBUG
            if let demo = request.demo { form = demo }
            #endif
            _form = State(initialValue: form)
        }
    }

    private var kinds: [JournalKind] {
        let offered = request.mode == .charge ? env.journalChargeKinds : env.journalFillKinds
        // Правка записи другого вида (машину сменили) — её вид тоже в списке.
        return offered.contains(form.kind) ? offered : offered + [form.kind]
    }

    private var entryID: UUID { request.editing?.id ?? stableID }

    var body: some View {
        let draft = form.entry(id: entryID)
        let doubts = draft.map { EnergyJournal.doubts($0, among: env.energyJournal.entries) } ?? []
        NavigationStack {
            Form {
                whatSection
                amountSection(doubts: doubts)
                odometerSection
                if request.editing != nil {
                    Section {
                        Button("Удалить запись", role: .destructive) { confirmsDelete = true }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(JournalText.sheetTitle(request.mode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { save(draft, doubts: doubts) }
                        .disabled(draft == nil)
                }
            }
            .alert("Сохранить так?", isPresented: Binding(get: { doubtful != nil },
                                                          set: { if !$0 { doubtful = nil } }),
                   presenting: doubtful) { entry in
                Button("Сохранить") { askPrice(entry) }
                Button("Исправить", role: .cancel) {}
            } message: { _ in
                Text(doubts.map { JournalText.doubt($0, kind: form.kind) }.joined(separator: "\n"))
            }
            .alert(priceTitle, isPresented: Binding(get: { priceAsk != nil },
                                                    set: { if !$0 { priceAsk = nil } }),
                   presenting: priceAsk) { ask in
                Button(ask.update.old > 0 ? String(localized: "Обновить цену") : String(localized: "Поставить")) {
                    finish(ask.entry, price: ask.update)
                }
                Button(ask.update.old > 0 ? String(localized: "Оставить прежнюю") : String(localized: "Не ставить"),
                       role: .cancel) {
                    finish(ask.entry, price: nil)
                }
            } message: { ask in
                Text(priceMessage(ask))
            }
            .confirmationDialog("Удалить запись?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Удалить", role: .destructive) {
                    if let id = request.editing?.id { env.deleteJournalEntry(id) }
                    dismiss()
                }
                Button("Отмена", role: .cancel) {}
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            // Новая запись — сразу печатать количество: одно касание до ввода.
            if request.editing == nil, form.quantity.isEmpty { focus = .quantity }
        }
    }

    // MARK: - Разделы

    private var whatSection: some View {
        Section {
            if kinds.count > 1 {
                Picker(selection: $form.kind) {
                    ForEach(kinds, id: \.self) { kind in
                        Text(JournalText.choice(kind)).tag(kind)
                    }
                } label: {
                    Text(JournalText.sheetTitle(request.mode))
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            DatePicker(selection: $form.date, in: ...Date()) {
                Text("Когда")
            }
        }
    }

    private func amountSection(doubts: [EnergyJournal.Doubt]) -> some View {
        let fuel = form.kind.fuel
        return Section {
            FieldRow(String(format: String(localized: "Количество, %@"), fuel.unit)) {
                TextField(Self.zero, text: $form.quantity)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .focused($focus, equals: .quantity)
                    .frame(minWidth: 80)
                    .accessibilityLabel(Text(verbatim: String(format: String(localized: "Количество, %@"), fuel.unit)))
            }
            FieldRow(String(localized: "Сумма, сум")) {
                TextField(Self.zero, text: Binding(get: { form.amount }, set: {
                    form.amount = FineForm.groupedDigits($0)
                }))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .focused($focus, equals: .amount)
                    .frame(minWidth: 80)
                    .accessibilityLabel(Text("Сумма, сум"))
            }
            if let price = form.unitPrice {
                LabeledContent {
                    Text(JournalText.unitPrice(price, fuel))
                        .foregroundStyle(doubts.isEmpty ? Theme.textSecondary : Theme.warning)
                } label: {
                    Text("Цена")
                }
            }
            ForEach(Array(doubts.enumerated()), id: \.offset) { _, doubt in
                Label(JournalText.doubt(doubt, kind: form.kind), systemImage: "exclamationmark.circle")
                    .font(.rounded(13, .semibold))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Сколько")
        }
    }

    private var odometerSection: some View {
        Section {
            FieldRow(String(localized: "Пробег с панели, км")) {
                TextField(String(localized: "по желанию"), text: Binding(get: { form.odometer }, set: {
                    form.odometer = FineForm.groupedDigits($0)
                }))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .focused($focus, equals: .odometer)
                    .frame(minWidth: 80)
                    .accessibilityLabel(Text("Пробег с панели, км"))
            }
            Toggle(isOn: $form.full) {
                Text(JournalText.fullTitle(request.mode))
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Text("Пробег и «до полного» — для реального расхода: он считается между двумя полными заправками с пробегом.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Сохранение

    private func save(_ draft: JournalEntry?, doubts: [EnergyJournal.Doubt]) {
        guard let draft else { return }
        if !doubts.isEmpty {
            doubtful = draft
        } else {
            askPrice(draft)
        }
    }

    /// Цена профиля — только по ответу. Правка, где цена не менялась, не спрашивает.
    private func askPrice(_ entry: JournalEntry) {
        doubtful = nil
        let unchanged = request.editing.map { $0.unitPrice == entry.unitPrice && $0.kind == entry.kind } ?? false
        if !unchanged,
           let update = EnergyJournal.priceUpdate(for: entry, profile: env.settings.fuelProfile, now: Date()) {
            priceAsk = PriceAsk(entry: entry, update: update)
        } else {
            finish(entry, price: nil)
        }
    }

    private func finish(_ entry: JournalEntry, price: EnergyJournal.PriceUpdate?) {
        priceAsk = nil
        env.saveJournalEntry(entry, price: price)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        dismiss()
    }

    private var priceTitle: String {
        guard let ask = priceAsk, ask.update.old <= 0 else { return String(localized: "Обновить цену в расчёте?") }
        return String(localized: "Поставить цену в расчёт?")
    }

    private func priceMessage(_ ask: PriceAsk) -> String {
        let fuel = ask.entry.kind.fuel
        let paid = JournalText.unitPrice(ask.update.new, fuel)
        guard ask.update.old > 0 else {
            return String(format: String(localized: "Вы заплатили %@. По этой цене будут считаться расходы поездок."), paid)
        }
        return String(format: String(localized: "Вы заплатили %1$@, в расчёте — %2$@."),
                      paid, JournalText.unitPrice(ask.update.old, fuel))
    }
}
