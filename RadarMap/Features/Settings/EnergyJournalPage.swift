//
//  EnergyJournalPage.swift
//  RadarMap
//
//  «Машина и расходы» → «Журнал заправок» (21.6): кнопки «Заправился» /
//  «Зарядился» сверху, расход по факту, записи по месяцам с суммой месяца.
//  Тап по записи — правка, смахивание — удаление. Всё считает EnergyJournal;
//  страница только показывает.
//

import SwiftUI

struct EnergyJournalPage: View {
    @Environment(AppEnvironment.self) private var env
    @State private var request: JournalEntryRequest?

    var body: some View {
        let entries = env.energyJournal.entries
        let months = EnergyJournal.months(entries, calendar: .current)
        Form {
            Section {
                JournalActionRows { request = $0 }
            } footer: {
                if entries.isEmpty {
                    Text("Впишите заправку или зарядку — «Итоги» покажут реальные траты, а не оценку. Всё остаётся на телефоне.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            measuredSection(entries)
            ForEach(months) { month in
                Section {
                    ForEach(month.entries) { entry in
                        Button { request = .edit(entry) } label: { JournalRow(entry: entry) }
                            .tint(Theme.textPrimary)
                            .swipeActions {
                                Button(role: .destructive) {
                                    env.deleteJournalEntry(entry.id)
                                } label: {
                                    Label("Удалить", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: JournalText.month(month.start))
                        Spacer(minLength: 8)
                        Text(verbatim: Formatting.money(month.amount))
                    }
                }
            }
        }
        .settingsPage("Журнал заправок")
        .sheet(item: $request) { request in
            JournalEntrySheet(request: request,
                              kinds: request.mode == .charge ? env.journalChargeKinds : env.journalFillKinds)
        }
        .onAppear {
            env.energyJournal.reloadIfNeeded()
            env.usage.noteScreen("energyJournal")
            #if DEBUG
            if let demo = JournalDemo.request(ProcessInfo.processInfo.arguments, env: env) {
                Task {
                    await Task.pause(seconds: 0.9)
                    request = demo
                }
            }
            #endif
        }
    }

    /// «По факту: 5,8 л/100 км · последние 620 км» — по последнему отрезку
    /// «бак к баку» каждого топлива; нет отрезка — нет строки.
    @ViewBuilder
    private func measuredSection(_ entries: [JournalEntry]) -> some View {
        let latest = Fuel.allCases.compactMap { EnergyJournal.latest(entries, fuel: $0) }
        if !latest.isEmpty {
            Section {
                ForEach(latest, id: \.fuel) { measured in
                    LabeledContent {
                        Text(EnergyText.per100Short(measured.per100, measured.fuel))
                            .foregroundStyle(Theme.textPrimary)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(measured.fuel.title)
                            Text(String(format: String(localized: "последние %@"), EnergyText.km(measured.km)))
                                .font(.rounded(13))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            } header: {
                Text("Расход по факту")
            } footer: {
                Text("Между двумя заправками «до полного» с пробегом с панели: всё залитое между ними ушло на эти километры.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// «Заправился» / «Зарядился» строками формы — то, что есть у этой машины.
struct JournalActionRows: View {
    @Environment(AppEnvironment.self) private var env
    let open: (JournalEntryRequest) -> Void

    var body: some View {
        ForEach(env.journalModes, id: \.self) { mode in
            Button { open(JournalEntryRequest(mode: mode)) } label: {
                Label(JournalText.action(mode), systemImage: JournalText.actionSymbol(mode))
                    .font(.rounded(17, .semibold))
            }
        }
    }
}

/// Строка записи: вид, когда, сколько и по чём, сумма.
struct JournalRow: View {
    let entry: JournalEntry

    var body: some View {
        let title = Text(JournalText.title(entry.kind))
            .font(.rounded(16, .semibold))
            .foregroundStyle(Theme.textPrimary)
        let money = Text(Formatting.money(entry.amount))
            .font(.rounded(16, .semibold))
            .foregroundStyle(Theme.textPrimary)
        HStack(alignment: .top, spacing: 12) {
            IconBadge(symbol: JournalText.symbol(entry.kind),
                      tint: entry.kind.isCharge ? Theme.accent : Theme.Icon.money, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                // Сумма не ломается по буквам: не влезает рядом — уходит под вид.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        title
                        Spacer(minLength: 8)
                        money.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        title
                        money
                    }
                }
                Text(JournalText.date(entry.date))
                    .font(.rounded(13))
                    .foregroundStyle(Theme.textSecondary)
                Text(JournalText.detail(entry))
                    .font(.rounded(13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [JournalText.title(entry.kind), Formatting.money(entry.amount),
                                            JournalText.date(entry.date), JournalText.detail(entry)]
            .joined(separator: ", ")))
        .accessibilityHint(Text("Изменить запись"))
    }
}


/// «+» рядом со строкой расходов в «Итогах»: одна запись у машины — одно
/// касание до листа; заправка и зарядка — меню из двух строк.
struct JournalAddButton: View {
    @Environment(AppEnvironment.self) private var env
    let open: (JournalEntryRequest) -> Void

    var body: some View {
        let modes = env.journalModes
        Group {
            if modes.count == 1, let only = modes.first {
                Button { open(JournalEntryRequest(mode: only)) } label: { face }
                    .accessibilityLabel(Text(JournalText.action(only)))
            } else {
                Menu {
                    ForEach(modes, id: \.self) { mode in
                        Button { open(JournalEntryRequest(mode: mode)) } label: {
                            Label(JournalText.action(mode), systemImage: JournalText.actionSymbol(mode))
                        }
                    }
                } label: { face }
                    .accessibilityLabel(Text("Записать заправку или зарядку"))
            }
        }
        .buttonStyle(PressableStyle())
    }

    private var face: some View {
        Image(systemName: "plus")
            .font(.rounded(18, .bold))
            .foregroundStyle(Theme.accent)
            .frame(width: 30)
            .frame(maxHeight: .infinity)
            .statCard(padding: 11, radius: Theme.cornerMedium)
            .contentShape(Rectangle())
    }
}
